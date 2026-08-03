import CloudKit
#if targetEnvironment(macCatalyst)
import Security
#endif
import SwiftUI
import UIKit

struct RootWorkspaceView: View {
    @Environment(\.scenePhase) private var scenePhase

    @ObservedObject var documentStore: DrawingDocumentStore
    @StateObject private var automaticBackupCoordinator: AutomaticBackupCoordinator

    @AppStorage("pdfWorkspace.activeDocumentID") private var activeDocumentID = "congruence"
    @State private var destination = RootDestination.library
    @State private var cloudSyncCoordinator: CloudLibrarySyncCoordinator?
    @State private var sharedSyncCoordinators: [String: CloudLibrarySyncCoordinator] = [:]
    @State private var collaborativeZonesByDocumentID: [String: CloudDocumentSharedZone] = [:]
    @State private var cloudSharePresentation: CloudSharePresentation?
    @State private var isPreparingCollaboration = false
    @State private var collaborationErrorMessage: String?

    init(documentStore: DrawingDocumentStore) {
        self.documentStore = documentStore
        _automaticBackupCoordinator = StateObject(
            wrappedValue: AutomaticBackupCoordinator(documentStore: documentStore)
        )
    }

    var body: some View {
        Group {
            switch destination {
            case .library:
                LibraryBrowserView(
                    documentStore: documentStore,
                    automaticBackupCoordinator: automaticBackupCoordinator,
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
        .preferredColorScheme(.dark)
        .overlay(alignment: .bottomLeading) {
            if destination == .library {
                HStack(spacing: 8) {
                    CloudSyncStatusView(status: documentStore.cloudSyncStatus)
                    AutomaticBackupStatusView(state: automaticBackupCoordinator.state)
                }
                    .padding(12)
                    .padding(.bottom, 68)
            }
        }
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
            guard scenePhase == .active, !sharedSyncCoordinators.isEmpty else { return }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                guard !Task.isCancelled else { return }
                // Refresh CKShare permission before accepting another local edit window. Push is
                // only a latency hint; polling also catches owner downgrades/revocations.
                await refreshSharedDocuments()
                for coordinator in sharedSyncCoordinators.values {
                    await coordinator.syncNow()
                }
            }
        }
        .onChange(of: documentStore.cloudSyncGeneration) { _, _ in
            automaticBackupCoordinator.scheduleBackup()
            Task {
                await scheduleAllCloudZones()
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
            collaborationErrorMessage = error.localizedDescription
        }
    }

    private func scheduleAllCloudZones() async {
        if let cloudSyncCoordinator {
            await cloudSyncCoordinator.scheduleSync()
        }
        for coordinator in sharedSyncCoordinators.values {
            await coordinator.scheduleSync()
        }
    }

    private func synchronizeAllCloudZones() async {
        if let cloudSyncCoordinator {
            await cloudSyncCoordinator.syncNow()
        }
        for coordinator in sharedSyncCoordinators.values {
            await coordinator.syncNow()
        }
        automaticBackupCoordinator.scheduleBackup()
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

private struct CloudSyncStatusView: View {
    let status: CloudLibrarySyncStatus

    var body: some View {
        HStack(spacing: 6) {
            if showsProgress {
                ProgressView()
                    .controlSize(.mini)
            } else {
                Image(systemName: symbol)
            }
            Text(label)
        }
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(color)
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(TiyiNoteTheme.chrome.opacity(0.94), in: Capsule())
        .overlay {
            Capsule().stroke(TiyiNoteTheme.hairline, lineWidth: 1)
        }
        .accessibilityLabel(label)
    }

    private var showsProgress: Bool {
        switch status {
        case .scheduled, .syncing: true
        default: false
        }
    }

    private var symbol: String {
        switch status {
        case .idle, .scheduled, .syncing: "icloud"
        case .succeeded: "checkmark.icloud.fill"
        case .waitingForAccount: "person.crop.circle.badge.exclamationmark"
        case .waitingForNetwork: "wifi.slash"
        case .failed: "exclamationmark.icloud.fill"
        }
    }

    private var label: String {
        switch status {
        case .idle: "iCloud 待同步"
        case .scheduled, .syncing: "iCloud 同步中"
        case .succeeded: "iCloud 已同步"
        case .waitingForAccount: "请登录 iCloud"
        case .waitingForNetwork: "等待网络"
        case .failed: "iCloud 同步失败"
        }
    }

    private var color: Color {
        switch status {
        case .succeeded: TiyiNoteTheme.success
        case .waitingForAccount, .waitingForNetwork, .failed: TiyiNoteTheme.danger
        default: TiyiNoteTheme.textSecondary
        }
    }
}

private struct AutomaticBackupStatusView: View {
    let state: AutomaticBackupState

    var body: some View {
        if case .disabled = state {
            EmptyView()
        } else {
            HStack(spacing: 6) {
                if case .backingUp = state {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: symbol)
                }
                Text(label)
            }
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(TiyiNoteTheme.chrome.opacity(0.94), in: Capsule())
            .overlay { Capsule().stroke(TiyiNoteTheme.hairline, lineWidth: 1) }
            .accessibilityLabel(label)
        }
    }

    private var symbol: String {
        switch state {
        case .failed: "externaldrive.badge.exclamationmark"
        default: "checkmark.circle.fill"
        }
    }

    private var label: String {
        switch state {
        case .disabled: ""
        case .ready: "备份已开启"
        case .backingUp: "正在备份"
        case .failed: "自动备份失败"
        }
    }

    private var color: Color {
        switch state {
        case .failed: TiyiNoteTheme.danger
        case .ready: TiyiNoteTheme.success
        default: TiyiNoteTheme.textSecondary
        }
    }
}
