import CloudKit
import SwiftUI
import UIKit

struct DocumentLibraryPicker: View {
    @ObservedObject var manager: DocumentLibraryManager
    @State private var showsCreate = false
    @State private var showsJoin = false
    @State private var invitationLibrary: DocumentLibrary?
    @State private var name = ""
    @State private var isWorking = false
    @State private var sharing: FamilySharingPresentation?

    var body: some View {
        Menu {
            Section("文稿库") {
                ForEach(manager.libraries) { library in
                    Button { manager.select(library.id) } label: {
                        Label(library.title + (library.id == manager.defaultID ? " · 默认" : ""),
                            systemImage: library.id == manager.selectedID ? "checkmark" : (library.isPersonal ? "person" : "person.2"))
                    }
                    .accessibilityIdentifier("document-library-\(library.id)")
                }
            }
            Section {
                Button { name = ""; showsCreate = true } label: { Label("创建家庭库", systemImage: "plus") }
                Button { showsJoin = true } label: { Label("加入家庭库", systemImage: "link") }
                if manager.selectedID != manager.defaultID {
                    Button { manager.setDefault(manager.selectedID) } label: { Label("设为默认文稿库", systemImage: "star") }
                }
                if !manager.selectedLibrary.isPersonal, manager.selectedLibrary.isOwner {
                    Button { invitationLibrary = manager.selectedLibrary } label: { Label("邀请成员", systemImage: "person.badge.plus") }
                    Button { manageMembers() } label: { Label("管理成员", systemImage: "person.2") }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: manager.selectedLibrary.isPersonal ? "person" : "person.2")
                Text(manager.selectedLibrary.title).lineLimit(1).truncationMode(.middle)
                if isWorking { ProgressView().controlSize(.mini) }
                else { Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold)) }
            }
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(TiyiNoteTheme.textPrimary)
            .frame(maxWidth: 170, alignment: .leading).frame(height: 28)
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(LibraryCompactControlStyle())
        .disabled(isWorking)
        .accessibilityLabel("文稿库：\(manager.selectedLibrary.title)")
        .accessibilityIdentifier("document-library-picker")
        .alert("创建家庭库", isPresented: $showsCreate) {
            TextField("文稿库名称", text: $name)
            Button("取消", role: .cancel) {}
            Button("创建") {
                isWorking = true
                Task { @MainActor in
                    defer { isWorking = false }
                    do { _ = try await manager.createFamily(named: name) }
                    catch { manager.errorMessage = error.localizedDescription }
                }
            }
        } message: { Text("创建后可邀请家人加入，所有成员都可以编辑文稿。") }
        .sheet(isPresented: $showsJoin) {
            JoinFamilyLibraryView()
        }
        .sheet(item: $invitationLibrary) { library in
            InviteFamilyMemberView(title: library.title) {
                try await manager.createOneTimeInvitation(to: library.id)
            }
        }
        .sheet(item: $sharing) { value in
            FamilyCloudSharingView(share: value.share, onChange: {
                Task { await manager.refresh(force: true) }
            }, onError: { manager.errorMessage = $0.localizedDescription })
        }
    }

    private func manageMembers() {
        let id = manager.selectedID
        isWorking = true
        Task { @MainActor in
            defer { isWorking = false }
            do { sharing = FamilySharingPresentation(share: try await manager.shareForManagement(id)) }
            catch { manager.errorMessage = error.localizedDescription }
        }
    }
}

@MainActor final class FamilyMemberInvitationModel: ObservableObject {
    @Published private(set) var invitationURL: URL?
    @Published private(set) var isWorking = false
    @Published private(set) var errorMessage: String?
    private let invite: () async throws -> URL

    init(invite: @escaping () async throws -> URL) {
        self.invite = invite
    }

    func generate() async {
        guard !isWorking, invitationURL == nil else { return }
        isWorking = true
        errorMessage = nil
        defer { isWorking = false }
        do {
            invitationURL = try await invite()
        } catch { errorMessage = FamilyLibraryInvitation.message(for: error) }
    }
}

struct InviteFamilyMemberView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model: FamilyMemberInvitationModel
    @State private var copied = false
    let title: String

    init(title: String, invite: @escaping () async throws -> URL) {
        self.title = title
        _model = StateObject(wrappedValue: FamilyMemberInvitationModel(invite: invite))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section(title) {
                    if let url = model.invitationURL {
                        Label("一次性邀请链接已生成", systemImage: "checkmark.circle")
                        Text("每个链接只能供一人加入。邀请其他家人时，请重新生成链接。加入后可以编辑这个家庭库的所有文稿。")
                            .foregroundStyle(.secondary)
                        Text("把邀请链接发给对方。对方在文稿库菜单中选择“加入家庭库”，粘贴链接即可接受邀请。")
                            .foregroundStyle(.secondary)
                        Button {
                            UIPasteboard.general.url = url
                            copied = true
                        } label: {
                            Label(copied ? "已复制邀请链接" : "复制邀请链接", systemImage: copied ? "checkmark" : "doc.on.doc")
                        }
                        ShareLink(item: url) { Label("分享邀请链接", systemImage: "square.and.arrow.up") }
                    } else {
                        Text("生成链接后发给要邀请的家人，无需填写邮箱。首位接受链接的人可以加入，并编辑这个家庭库的所有文稿。")
                            .foregroundStyle(.secondary)
                    }
                }
                if let errorMessage = model.errorMessage {
                    Section { Text(errorMessage).foregroundStyle(.red) }
                }
                if model.invitationURL == nil {
                    Section {
                        Button { Task { await model.generate() } } label: {
                            HStack {
                                Text(model.isWorking ? "正在生成…" : "生成一次性邀请链接")
                                if model.isWorking { Spacer(); ProgressView() }
                            }
                        }
                        .disabled(model.isWorking)
                        .accessibilityIdentifier("generate-one-time-family-invitation")
                    } footer: {
                        Text("每个链接只能供一人加入，请只发送给要邀请的家人。")
                    }
                }
            }
            .navigationTitle("邀请成员")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(model.invitationURL == nil ? "取消" : "完成") { dismiss() }.disabled(model.isWorking)
                }
            }
        }
        .interactiveDismissDisabled(model.isWorking)
    }
}

struct JoinFamilyLibraryView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var link = ""
    @State private var isJoining = false
    @State private var didJoin = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                if didJoin {
                    Section {
                        Label("已接受邀请", systemImage: "checkmark.circle")
                        Text("家庭库同步后会出现在文稿库列表中，选择即可进入。")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Section {
                        TextField("粘贴 iCloud 邀请链接", text: $link, axis: .vertical)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                            .accessibilityIdentifier("family-invitation-link")
                            .disabled(isJoining)
                    } footer: {
                        Text("粘贴创建者从“邀请成员”生成的链接，使用设备已登录的 iCloud 账号加入。加入后，所有成员都可以编辑文稿。")
                    }
                    if let errorMessage {
                        Section { Text(errorMessage).foregroundStyle(.red) }
                    }
                    Section {
                        Button {
                            isJoining = true
                            errorMessage = nil
                            Task { @MainActor in
                                defer { isJoining = false }
                                do {
                                    let url = try FamilyLibraryInvitation.url(from: link)
                                    try await FamilyLibraryInvitation.accept(url, familyOnly: true)
                                    didJoin = true
                                } catch { errorMessage = error.localizedDescription }
                            }
                        } label: {
                            HStack {
                                Text(isJoining ? "正在加入…" : "加入家庭库")
                                if isJoining { Spacer(); ProgressView() }
                            }
                        }
                        .disabled(isJoining || link.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityIdentifier("accept-family-invitation")
                    }
                }
            }
            .navigationTitle("加入家庭库")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(didJoin ? "完成" : "取消") { dismiss() }.disabled(isJoining)
                }
            }
        }
        .interactiveDismissDisabled(isJoining)
    }
}

private struct FamilySharingPresentation: Identifiable {
    let id = UUID()
    let share: CKShare
}

private struct FamilyCloudSharingView: UIViewControllerRepresentable {
    let share: CKShare
    let onChange: () -> Void
    let onError: (Error) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }
    func makeUIViewController(context: Context) -> UICloudSharingController {
        let controller = UICloudSharingController(share: share,
            container: CKContainer(identifier: CloudLibrarySyncCoordinator.containerIdentifier))
        // Only explicitly invited participants; every family member gets editing access.
        controller.availablePermissions = [.allowPrivate, .allowReadWrite]
        controller.delegate = context.coordinator
        return controller
    }
    func updateUIViewController(_ controller: UICloudSharingController, context: Context) {}

    final class Coordinator: NSObject, UICloudSharingControllerDelegate {
        let parent: FamilyCloudSharingView
        init(parent: FamilyCloudSharingView) { self.parent = parent }
        func itemTitle(for csc: UICloudSharingController) -> String? {
            parent.share[CKShare.SystemFieldKey.title] as? String
        }
        func cloudSharingController(_ csc: UICloudSharingController, failedToSaveShareWithError error: Error) { parent.onError(error) }
        func cloudSharingControllerDidSaveShare(_ csc: UICloudSharingController) { parent.onChange() }
        func cloudSharingControllerDidStopSharing(_ csc: UICloudSharingController) { parent.onChange() }
    }
}
