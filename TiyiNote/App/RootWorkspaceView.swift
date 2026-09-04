import CloudKit
#if targetEnvironment(macCatalyst)
import Security
#endif
import SwiftUI
import UIKit

struct RootWorkspaceView: View {
    private static let automaticCloudQuietWindow: TimeInterval = 5.0

    @Environment(\.scenePhase) private var scenePhase

    @ObservedObject var documentStore: DrawingDocumentStore
    let onExit: (() -> Void)?

    @AppStorage("pdfWorkspace.activeDocumentID") private var activeDocumentID = "congruence"
    @State private var destination = RootDestination.library
    @State private var cloudSyncCoordinator: CloudLibrarySyncCoordinator?
    @State private var sharedSyncCoordinators: [String: CloudLibrarySyncCoordinator] = [:]
    @State private var collaborativeZonesByDocumentID: [String: CloudDocumentSharedZone] = [:]
    @State private var cloudSharePresentation: CloudSharePresentation?
    @State private var isPreparingCollaboration = false
    @State private var collaborationErrorMessage: String?

    init(
        documentStore: DrawingDocumentStore,
        onExit: (() -> Void)? = nil
    ) {
        self.documentStore = documentStore
        self.onExit = onExit
    }

    var body: some View {
        Group {
            switch destination {
            case .library:
                LibraryBrowserView(
                    documentStore: documentStore,
                    onExit: onExit,
                    onSyncNow: {
                        await refreshSharedDocuments()
                        await synchronizeAllCloudZones()
                    },
                    onOpenDocument: openDocument,
                    canEditDocument: canEditDocument,
                    onCollaborateDocument: presentCollaboration
                )
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
        .task {
            guard cloudSyncCoordinator == nil else { return }
            guard hasCloudKitContainerEntitlement else {
                // `CKContainer(identifier:)` traps on Mac Catalyst when a local/ad-hoc build
                // does not carry the requested container entitlement. Keep the local library
                // usable; a properly provisioned build will pass this check and sync normally.
                documentStore.cloudSyncDidUpdateStatus(.waitingForAccount)
                return
            }
            let coordinator = CloudLibrarySyncCoordinator(dataSource: documentStore)
            cloudSyncCoordinator = coordinator
            await refreshSharedDocuments()
            await synchronizeAllCloudZones()
        }
        .task(id: collaborationPollingIdentity) {
            guard scenePhase == .active else { return }
            while !Task.isCancelled {
                // Keep discovering invitations even before the first shared document exists.
                // Active collaborations use a short interval; an empty library polls quietly.
                let interval: UInt64 = sharedSyncCoordinators.isEmpty
                    ? 30_000_000_000
                    : 4_000_000_000
                try? await Task.sleep(nanoseconds: interval)
                guard !Task.isCancelled else { return }
                guard !documentStore.isDrawingInteractionActive,
                      !documentStore.hadRecentDrawingInteraction(
                        within: Self.automaticCloudQuietWindow
                      ) else { continue }
                // Refresh CKShare permission before accepting another local edit window. Push is
                // only a latency hint; polling also catches owner downgrades/revocations.
                await refreshSharedDocuments()
                for coordinator in sharedSyncCoordinators.values {
                    await coordinator.syncNow()
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
            Task {
                if documentStore.isDrawingInteractionActive {
                    await cancelScheduledCloudZones()
                } else {
                    await scheduleAllCloudZones()
                }
            }
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task {
                await refreshSharedDocuments()
                await synchronizeAllCloudZones()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .CKAccountChanged)) { _ in
            Task {
                if let cloudSyncCoordinator {
                    await cloudSyncCoordinator.resetForAccountChange()
                }
                for coordinator in sharedSyncCoordinators.values {
                    await coordinator.resetForAccountChange()
                }
                await refreshSharedDocuments()
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
                guard !documentStore.isDrawingInteractionActive,
                      !documentStore.hadRecentDrawingInteraction(
                        within: Self.automaticCloudQuietWindow
                      ) else {
                    await scheduleAllCloudZones()
                    return
                }
                await refreshSharedDocuments()
                await synchronizeAllCloudZones()
            }
        }
    }

    private func openDocument(_ documentID: String) {
        documentStore.openDocument(documentID)
        activeDocumentID = documentID
        destination = .workspace
    }

    private func showLibrary() {
        destination = .library
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
            // Shared-zone discovery is background maintenance. Apple gateway/network failures
            // retry automatically and must not interrupt the user with a collaboration alert.
            if cloudKitTransientRetryDelay(for: error) == nil {
                collaborationErrorMessage = error.localizedDescription
            }
        }
    }

    private func scheduleAllCloudZones() async {
        guard !documentStore.isDrawingInteractionActive else {
            await cancelScheduledCloudZones()
            return
        }
        if let cloudSyncCoordinator {
            await cloudSyncCoordinator.scheduleSync()
        }
        for coordinator in sharedSyncCoordinators.values {
            await coordinator.scheduleSync()
        }
    }

    private func cancelScheduledCloudZones() async {
        if let cloudSyncCoordinator {
            await cloudSyncCoordinator.cancelScheduledSync()
        }
        for coordinator in sharedSyncCoordinators.values {
            await coordinator.cancelScheduledSync()
        }
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
        await synchronizeAllCloudZones()
    }

    private func refreshAfterSharingSheet() {
        Task { @MainActor in
            await refreshSharedDocuments()
            await synchronizeAllCloudZones()
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
        return "\(scenePhase)|\(keys)"
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
