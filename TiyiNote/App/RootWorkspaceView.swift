import CloudKit
#if targetEnvironment(macCatalyst)
import Security
#endif
import SwiftUI
import UIKit

struct RootWorkspaceView: View {
    /// Local persistence owns the first ten seconds after Pencil input. Once its durable write
    /// advances `cloudSyncGeneration`, CloudKit may start immediately if no newer input arrived.
    /// Only the user's explicit “现在同步” action bypasses this input-aware ordering gate.
    private static let automaticCloudQuietWindow: TimeInterval = 10.0
    private static let automaticCloudDebounce: TimeInterval = 0

    @Environment(\.scenePhase) private var scenePhase

    @ObservedObject var documentStore: DrawingDocumentStore
    let onExit: (() -> Void)?
    let librarySidebar: AnyView?
    let libraryContainer: ((AnyView) -> AnyView)?

    @State private var libraryBrowsingState = LibraryBrowserState()

    @AppStorage("pdfWorkspace.activeDocumentID") private var activeDocumentID = "congruence"
    @State private var destination = RootDestination.library
    @State private var cloudSyncCoordinator: CloudLibrarySyncCoordinator?
    @State private var sharedSyncCoordinators: [String: CloudLibrarySyncCoordinator] = [:]
    @State private var cloudSyncWasDeferredByDrawing = false
    @State private var collaborativeZonesByDocumentID: [String: CloudDocumentSharedZone] = [:]
    @State private var cloudSharePresentation: CloudSharePresentation?
    @State private var isPreparingCollaboration = false
    @State private var collaborationErrorMessage: String?
    /// Acquired while switching from the library into an editable hierarchy. It provides a
    /// cancellation barrier between a delayed maintenance pass and the first Pencil sample, then is
    /// released as soon as the page has mounted so genuine idle time inside an open document can
    /// still save and synchronize.
    @State private var editorMaintenanceLeaseID = UUID()
    @State private var holdsEditorMaintenanceLease = false

    init(
        documentStore: DrawingDocumentStore,
        onExit: (() -> Void)? = nil,
        librarySidebar: AnyView? = nil,
        libraryContainer: ((AnyView) -> AnyView)? = nil
    ) {
        self.documentStore = documentStore
        self.onExit = onExit
        self.librarySidebar = librarySidebar
        self.libraryContainer = libraryContainer
    }

    var body: some View {
        Group {
            switch destination {
            case .library:
                librarySurface
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .transition(.opacity)
            case .workspace:
                CanvasScreen(
                    documentStore: documentStore,
                    canEditActiveDocument: canEditDocument(activeDocumentID),
                    onCollaborateDocument: presentCollaboration,
                    onShowLibrary: showLibrary
                )
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.16), value: destination)
        .tint(TiyiNoteTheme.selectionBlue)
        .overlay {
            if isPreparingCollaboration {
                ZStack {
                    Color.black.opacity(0.22).ignoresSafeArea()
                    ProgressView("正在准备多人协作…")
                        .padding(.horizontal, 20)
                        .padding(.vertical, 16)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
                }
            }
        }
        .sheet(item: $cloudSharePresentation, onDismiss: refreshAfterSharingSheet) { item in
            CloudSharingControllerView(
                preparation: item.preparation,
                title: item.title,
                onChanged: refreshAfterSharingSheet,
                onFailure: { error in
                    collaborationErrorMessage = error.localizedDescription
                }
            )
        }
        .alert("多人协作失败", isPresented: collaborationErrorIsPresented) {
            Button("好", role: .cancel) { collaborationErrorMessage = nil }
        } message: {
            Text(collaborationErrorMessage ?? "请稍后重试。")
        }
        .task(id: destination) {
            guard hasCloudKitContainerEntitlement else {
                // `CKContainer(identifier:)` traps on Mac Catalyst when a local/ad-hoc build
                // does not carry the requested container entitlement. Keep the local library
                // usable; a properly provisioned build will pass this check and sync normally.
                documentStore.cloudSyncDidUpdateStatus(.waitingForAccount)
                return
            }
            if cloudSyncCoordinator == nil {
                cloudSyncCoordinator = CloudLibrarySyncCoordinator(dataSource: documentStore)
            }
            guard destination == .library else {
                await resumeAutomaticCloudZones()
                await scheduleAllCloudZones()
                return
            }
            await refreshSharedDocuments()
            guard !Task.isCancelled, destination == .library else { return }
            await resumeAutomaticCloudZones()
            await scheduleAllCloudZones()
        }
        .task(id: collaborationPollingIdentity) {
            guard scenePhase == .active, destination == .library else { return }
            while !Task.isCancelled {
                // Keep discovering invitations even before the first shared document exists.
                // Active collaborations use a short interval; an empty library polls quietly.
                let interval: UInt64 = sharedSyncCoordinators.isEmpty
                    ? 30_000_000_000
                    : 4_000_000_000
                try? await Task.sleep(nanoseconds: interval)
                guard !Task.isCancelled else { return }
                guard destination == .library,
                      !documentStore.isDrawingInteractionActive,
                      !documentStore.hasPendingLocalDrawingPersistence,
                      !documentStore.hadRecentDrawingInteraction(
                        within: Self.automaticCloudQuietWindow
                      ) else { continue }
                // Refresh CKShare permission before accepting another local edit window. Push is
                // only a latency hint; polling also catches owner downgrades/revocations.
                await refreshSharedDocuments()
                for coordinator in sharedSyncCoordinators.values {
                    await coordinator.syncAutomaticallyNow()
                }
            }
        }
        .onChange(of: documentStore.cloudSyncGeneration) { _, _ in
            Task {
                await scheduleAllCloudZones()
            }
        }
        .onReceive(
            NotificationCenter.default.publisher(for: .tiyiDrawingInteractionActivityChanged)
        ) { notification in
            guard let source = notification.object as? DrawingDocumentStore,
                  source === documentStore else { return }
            let interactionIsActive = documentStore.isDrawingInteractionActive
            Task {
                if interactionIsActive {
                    let cancelledPendingSync = await cancelScheduledCloudZones()
                    guard cancelledPendingSync else { return }
                    if documentStore.isDrawingInteractionActive {
                        cloudSyncWasDeferredByDrawing = true
                    } else {
                        // The Pencil may already have lifted while actor cancellation was in
                        // flight. Restore the one pass we actually postponed.
                        await scheduleAllCloudZones()
                    }
                } else if cloudSyncWasDeferredByDrawing {
                    cloudSyncWasDeferredByDrawing = false
                    await resumeAutomaticCloudZones()
                    await scheduleAllCloudZones()
                }
            }
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task {
                await scheduleAllCloudZones()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .CKAccountChanged)) { _ in
            Task {
                // Account reset may otherwise schedule an immediate automatic retry. Hold every
                // zone behind the same input-aware gate until reset and discovery are complete.
                await suspendAutomaticCloudZones()
                if let cloudSyncCoordinator {
                    await cloudSyncCoordinator.resetForAccountChange()
                }
                for coordinator in sharedSyncCoordinators.values {
                    await coordinator.resetForAccountChange()
                }
                await refreshSharedDocuments()
                await resumeAutomaticCloudZones()
                await scheduleAllCloudZones()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .tiyiCloudKitShareAccepted)) { note in
            Task { await reloadAcceptedShare() }
        }
        .onReceive(
            NotificationCenter.default.publisher(for: .tiyiCloudKitShareAcceptanceFailed)
        ) { note in
            collaborationErrorMessage = (note.object as? Error)?.localizedDescription
                ?? "无法接受这个 iCloud 协作邀请。"
        }
        .onReceive(NotificationCenter.default.publisher(for: .tiyiCloudKitRemoteChange)) { _ in
            Task {
                // Push is only a wake-up hint. Route it through the same deep-idle gate instead of
                // beginning a library export while the user may be about to resume handwriting.
                await scheduleAllCloudZones()
            }
        }
    }

    @ViewBuilder
    private var librarySurface: some View {
        if let libraryContainer {
            libraryContainer(AnyView(libraryBrowser))
        } else {
            HStack(spacing: 0) {
                if let librarySidebar {
                    librarySidebar
                    Divider()
                        .ignoresSafeArea(.keyboard, edges: .bottom)
                }
                libraryBrowser
            }
        }
    }

    private var libraryBrowser: some View {
        LibraryBrowserView(
            documentStore: documentStore,
            browsingState: libraryBrowsingState,
            onExit: librarySidebar == nil && libraryContainer == nil ? onExit : nil,
            onSyncNow: {
                await refreshSharedDocuments()
                await synchronizeAllCloudZones()
            },
            onOpenDocument: openDocument,
            canEditDocument: canEditDocument,
            onCollaborateDocument: presentCollaboration
        )
    }

    private func openDocument(_ documentID: String) {
        acquireEditorMaintenanceLease()
        documentStore.openDocument(documentID)
        activeDocumentID = documentID
        // Do not reveal an editable PencilKit canvas until every automatic zone has received its
        // cancellation. This closes the small race where a retry could leave its timer between the
        // library tap and the first Pencil contact.
        Task { @MainActor in
            await suspendAutomaticCloudZones()
            guard activeDocumentID == documentID else { return }
            destination = .workspace
            // Let the page install its controller while all maintenance is still quiescent. The
            // lease is then released; a ten-second local idle window starts, and its completed
            // durable write is what makes automatic CloudKit work eligible. Pencil contact cancels
            // either pending stage immediately.
            await Task.yield()
            guard activeDocumentID == documentID, destination == .workspace else { return }
            releaseEditorMaintenanceLease()
            await resumeAutomaticCloudZones()
            await scheduleAllCloudZones()
        }
    }

    private func showLibrary() {
        destination = .library
        Task { @MainActor in
            // Give every disappearing page one main-actor turn to hand its immutable drawing to
            // the store before deferred disk and CloudKit maintenance become eligible again.
            await Task.yield()
            guard destination == .library else { return }
            releaseEditorMaintenanceLease()
            await resumeAutomaticCloudZones()
            await scheduleAllCloudZones()
        }
    }

    private func acquireEditorMaintenanceLease() {
        guard !holdsEditorMaintenanceLease else { return }
        holdsEditorMaintenanceLease = true
        documentStore.setDrawingInteractionActive(true, id: editorMaintenanceLeaseID)
    }

    private func releaseEditorMaintenanceLease() {
        guard holdsEditorMaintenanceLease else { return }
        holdsEditorMaintenanceLease = false
        documentStore.setDrawingInteractionActive(false, id: editorMaintenanceLeaseID)
    }

    private func canEditDocument(_ documentID: String) -> Bool {
        collaborativeZonesByDocumentID[documentID]?.accessLevel.canEdit ?? true
    }

    private func presentCollaboration(_ documentID: String) {
        guard let document = documentStore.document(withID: documentID),
              !isPreparingCollaboration else { return }
        Task { @MainActor in
            isPreparingCollaboration = true
            defer { isPreparingCollaboration = false }
            do {
                let preparation: CloudDocumentSharePreparation
                if let zone = collaborativeZonesByDocumentID[documentID] {
                    preparation = try await CloudDocumentShareService.loadExistingShare(
                        zone: zone,
                        dataSource: documentStore
                    )
                } else {
                    preparation = try await CloudDocumentShareService.prepareShare(
                        documentID: documentID,
                        title: document.title,
                        dataSource: documentStore
                    )
                    let zone = CloudDocumentSharedZone(
                        documentID: documentID,
                        zoneID: preparation.zoneID,
                        databaseScope: .private,
                        accessLevel: .owner
                    )
                    collaborativeZonesByDocumentID[documentID] = zone
                    sharedSyncCoordinators[zone.key] = preparation.syncCoordinator
                    if let cloudSyncCoordinator {
                        await cloudSyncCoordinator.setExcludedDocumentIDs(
                            Set(collaborativeZonesByDocumentID.keys)
                        )
                    }
                }
                // The preparation owns a scoped coordinator; retaining it keeps local changes
                // flowing into the document zone after the invitation sheet closes.
                if let zone = collaborativeZonesByDocumentID[documentID] {
                    sharedSyncCoordinators[zone.key] = preparation.syncCoordinator
                }
                // Share preparation is an explicit foreground action and has already completed its
                // required sync. Future passes use the same deep-idle scheduler as every other zone.
                await preparation.syncCoordinator.resumeAutomaticSync()
                cloudSharePresentation = CloudSharePresentation(
                    title: document.title,
                    preparation: preparation
                )
            } catch {
                collaborationErrorMessage = error.localizedDescription
            }
        }
    }

    @MainActor
    private func refreshSharedDocuments() async {
        guard cloudSyncCoordinator != nil else { return }
        do {
            let zones = try await CloudDocumentShareService.discoverSharedZones()
            guard !Task.isCancelled else { return }
            var zonesByDocumentID: [String: CloudDocumentSharedZone] = [:]
            for zone in zones.sorted(by: { $0.key < $1.key }) {
                // A document identity should belong to one mounted share. If corrupt server state
                // exposes two, prefer the participant/shared database because it is authoritative
                // for the current account's invitation.
                if zonesByDocumentID[zone.documentID] == nil
                    || zone.databaseScope == .shared {
                    zonesByDocumentID[zone.documentID] = zone
                }
            }

            var nextCoordinators: [String: CloudLibrarySyncCoordinator] = [:]
            for zone in zonesByDocumentID.values {
                let coordinator = sharedSyncCoordinators[zone.key] ?? CloudLibrarySyncCoordinator(
                    dataSource: documentStore,
                    zoneName: zone.zoneID.zoneName,
                    ownerName: zone.zoneID.ownerName,
                    databaseScope: zone.databaseScope,
                    scopedDocumentID: zone.documentID,
                    shouldCreateZone: false,
                    reportsStatus: false,
                    allowsUploads: zone.accessLevel.canEdit
                )
                await coordinator.setAllowsUploads(zone.accessLevel.canEdit)
                await coordinator.resumeAutomaticSync()
                nextCoordinators[zone.key] = coordinator
            }
            collaborativeZonesByDocumentID = zonesByDocumentID
            sharedSyncCoordinators = nextCoordinators
            documentStore.setReadOnlySharedDocumentIDs(
                Set(zonesByDocumentID.compactMap { documentID, zone in
                    zone.accessLevel.canEdit ? nil : documentID
                })
            )
            if let cloudSyncCoordinator {
                await cloudSyncCoordinator.setExcludedDocumentIDs(Set(zonesByDocumentID.keys))
            }
        } catch {
            guard !Task.isCancelled else { return }
            // Shared-zone discovery is background maintenance. Apple gateway/network failures
            // retry automatically and must not interrupt the user with a collaboration alert.
            if cloudKitTransientRetryDelay(for: error) == nil {
                collaborationErrorMessage = error.localizedDescription
            }
        }
    }

    private func scheduleAllCloudZones() async {
        guard !documentStore.isDrawingInteractionActive,
              !documentStore.hasPendingLocalDrawingPersistence else {
            if await cancelScheduledCloudZones() {
                cloudSyncWasDeferredByDrawing = true
            }
            return
        }
        let delay = max(
            Self.automaticCloudDebounce,
            documentStore.drawingInteractionQuietTimeRemaining(
                within: Self.automaticCloudQuietWindow
            )
        )
        if let cloudSyncCoordinator {
            await cloudSyncCoordinator.scheduleSync(after: delay)
        }
        for coordinator in sharedSyncCoordinators.values {
            await coordinator.scheduleSync(after: delay)
        }
    }

    private func suspendAutomaticCloudZones() async {
        if let cloudSyncCoordinator {
            _ = await cloudSyncCoordinator.suspendAutomaticSync()
        }
        for coordinator in sharedSyncCoordinators.values {
            _ = await coordinator.suspendAutomaticSync()
        }
    }

    private func resumeAutomaticCloudZones() async {
        if let cloudSyncCoordinator {
            await cloudSyncCoordinator.resumeAutomaticSync()
        }
        for coordinator in sharedSyncCoordinators.values {
            await coordinator.resumeAutomaticSync()
        }
    }

    @discardableResult
    private func cancelScheduledCloudZones() async -> Bool {
        var cancelledAny = false
        if let cloudSyncCoordinator {
            cancelledAny = await cloudSyncCoordinator.cancelScheduledSync() || cancelledAny
        }
        for coordinator in sharedSyncCoordinators.values {
            cancelledAny = await coordinator.cancelScheduledSync() || cancelledAny
        }
        return cancelledAny
    }

    private func synchronizeAllCloudZones() async {
        if let cloudSyncCoordinator {
            await cloudSyncCoordinator.syncNow()
        }
        for coordinator in sharedSyncCoordinators.values {
            await coordinator.syncNow()
        }
    }

    @MainActor
    private func reloadAcceptedShare() async {
        isPreparingCollaboration = true
        defer { isPreparingCollaboration = false }
        await refreshSharedDocuments()
        if destination == .library {
            await synchronizeAllCloudZones()
        }
    }

    private func refreshAfterSharingSheet() {
        Task { @MainActor in
            await refreshSharedDocuments()
            if destination == .library {
                await synchronizeAllCloudZones()
            }
        }
    }

    private var collaborationErrorIsPresented: Binding<Bool> {
        Binding(
            get: { collaborationErrorMessage != nil },
            set: { if !$0 { collaborationErrorMessage = nil } }
        )
    }

    private var collaborationPollingIdentity: String {
        let keys = sharedSyncCoordinators.keys.sorted().joined(separator: "|")
        return "\(scenePhase)|\(destination)|\(keys)"
    }

    private var hasCloudKitContainerEntitlement: Bool {
#if targetEnvironment(macCatalyst)
        guard let task = SecTaskCreateFromSelf(nil),
              let identifiers = SecTaskCopyValueForEntitlement(
                  task,
                  "com.apple.developer.icloud-container-identifiers" as CFString,
                  nil
              ) as? [String]
        else { return false }
        return identifiers.contains(CloudLibrarySyncCoordinator.containerIdentifier)
#else
#if targetEnvironment(simulator)
        // This read is safe for unsigned simulator builds (it returns nil), unlike constructing
        // CKContainer without CloudKit entitlements, which deliberately traps in recent SDKs.
        return FileManager.default.ubiquityIdentityToken != nil
#else
        return true
#endif
#endif
    }
}

private struct CloudSharePresentation: Identifiable {
    let id = UUID()
    let title: String
    let preparation: CloudDocumentSharePreparation
}

private struct CloudSharingControllerView: UIViewControllerRepresentable {
    let preparation: CloudDocumentSharePreparation
    let title: String
    let onChanged: () -> Void
    let onFailure: (Error) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(title: title, onChanged: onChanged, onFailure: onFailure)
    }

    func makeUIViewController(context: Context) -> UICloudSharingController {
        let controller = UICloudSharingController(
            share: preparation.share,
            container: preparation.container
        )
        controller.delegate = context.coordinator
        controller.availablePermissions = [.allowPrivate, .allowReadOnly, .allowReadWrite]
        return controller
    }

    func updateUIViewController(
        _ uiViewController: UICloudSharingController,
        context: Context
    ) {}

    final class Coordinator: NSObject, UICloudSharingControllerDelegate {
        let title: String
        let onChanged: () -> Void
        let onFailure: (Error) -> Void

        init(
            title: String,
            onChanged: @escaping () -> Void,
            onFailure: @escaping (Error) -> Void
        ) {
            self.title = title
            self.onChanged = onChanged
            self.onFailure = onFailure
        }

        func itemTitle(for csc: UICloudSharingController) -> String? { title }

        func cloudSharingControllerDidSaveShare(_ csc: UICloudSharingController) {
            onChanged()
        }

        func cloudSharingControllerDidStopSharing(_ csc: UICloudSharingController) {
            onChanged()
        }

        func cloudSharingController(
            _ csc: UICloudSharingController,
            failedToSaveShareWithError error: Error
        ) {
            onFailure(error)
        }
    }
}

private enum RootDestination: Hashable {
    case library
    case workspace
}
