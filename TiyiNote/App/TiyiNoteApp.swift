import CloudKit
import SwiftUI
import UIKit

extension Notification.Name {
    static let tiyiCloudKitShareAccepted = Notification.Name("TiyiNote.CloudKitShareAccepted")
    static let tiyiCloudKitShareAcceptanceFailed = Notification.Name(
        "TiyiNote.CloudKitShareAcceptanceFailed"
    )
    static let tiyiCloudKitRemoteChange = Notification.Name("TiyiNote.CloudKitRemoteChange")
}

final class TiyiNoteAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        application.registerForRemoteNotifications()
        return true
    }

    func application(
        _ application: UIApplication,
        userDidAcceptCloudKitShareWith cloudKitShareMetadata: CKShare.Metadata
    ) {
        Task {
            do {
                try await CloudDocumentShareService.accept(cloudKitShareMetadata)
                await MainActor.run {
                    NotificationCenter.default.post(
                        name: .tiyiCloudKitShareAccepted,
                        object: cloudKitShareMetadata
                    )
                }
            } catch {
                await MainActor.run {
                    NotificationCenter.default.post(
                        name: .tiyiCloudKitShareAcceptanceFailed,
                        object: error
                    )
                }
            }
        }
    }

    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        guard CKNotification(fromRemoteNotificationDictionary: userInfo) != nil else {
            completionHandler(.noData)
            return
        }
        NotificationCenter.default.post(name: .tiyiCloudKitRemoteChange, object: nil)
        // Zone tokens make this notification merely a wake-up signal; the view-owned sync pass
        // performs the authoritative download and remains safe if pushes are coalesced.
        completionHandler(.newData)
    }
}

@main
struct TiyiNoteApp: App {
    @UIApplicationDelegateAdaptor(TiyiNoteAppDelegate.self) private var appDelegate
    @StateObject private var documentStore = DrawingDocumentStore()

    var body: some Scene {
        WindowGroup {
#if DEBUG
            if let interactionConfiguration = TextInteractionUITestConfiguration() {
                TextInteractionUITestHost(configuration: interactionConfiguration)
            } else if let libraryConfiguration = LibraryFeatureSmokeConfiguration() {
                LibraryFeatureSmokeHarnessView(configuration: libraryConfiguration)
            } else if let smokeConfiguration = CloudKitSmokeConfiguration() {
                CloudKitSmokeHarnessView(configuration: smokeConfiguration)
            } else {
                RootWorkspaceView(documentStore: documentStore)
            }
#else
            RootWorkspaceView(documentStore: documentStore)
#endif
        }
    }
}

#if DEBUG
private struct TextInteractionUITestConfiguration {
    static let argument = "--text-interaction-ui-test"
    static let reuseWorkspaceArgument = "--reuse-text-interaction-ui-test-workspace"
    let token: String
    let reuseExistingWorkspace: Bool

    init?(arguments: [String] = ProcessInfo.processInfo.arguments) {
        guard let index = arguments.firstIndex(of: Self.argument),
              arguments.indices.contains(index + 1) else {
            return nil
        }
        let safeToken = arguments[index + 1]
            .filter { $0.isLetter || $0.isNumber || $0 == "-" }
        guard !safeToken.isEmpty else { return nil }
        token = String(safeToken.prefix(48))
        reuseExistingWorkspace = arguments.contains(Self.reuseWorkspaceArgument)
    }
}

@MainActor
private struct TextInteractionUITestHost: View {
    @StateObject private var documentStore: DrawingDocumentStore
    @State private var libraryBrowsingState = LibraryBrowserState()
    @State private var showsWorkspace: Bool
    private let configurationToken: String

    init(configuration: TextInteractionUITestConfiguration) {
        configurationToken = configuration.token
        let fileManager = FileManager.default
        let workspace = fileManager.temporaryDirectory
            .appendingPathComponent("TiyiNoteTextInteractionUITest", isDirectory: true)
            .appendingPathComponent(configuration.token, isDirectory: true)
        let defaultsName = "com.tiyi.note.text-interaction-ui-test.\(configuration.token)"
        let defaults = UserDefaults(suiteName: defaultsName)!
        if !configuration.reuseExistingWorkspace {
            try? fileManager.removeItem(at: workspace)
            defaults.removePersistentDomain(forName: defaultsName)
            for key in [
                "canvas.color",
                "canvas.penWidth.v2",
                "canvas.markerWidth",
                "canvas.eraserSize",
                "canvas.eraserMode",
                "canvas.toolPaletteDockEdge",
                "canvas.toolPaletteDockProgress",
                "pdfWorkspace.showsThumbnails"
            ] {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }

        let store = DrawingDocumentStore(
            userDefaults: defaults,
            workspaceDirectoryOverride: workspace
        )
        let firstDocument: PDFWorkspaceDocument
        let secondDocument: PDFWorkspaceDocument
        if configuration.reuseExistingWorkspace,
           let existingFirst = store.documents(in: nil).first(where: { $0.title == "UITest One" }),
           let existingSecond = store.documents(in: nil).first(where: { $0.title == "UITest Two" }) {
            firstDocument = existingFirst
            secondDocument = existingSecond
        } else {
            firstDocument = try! store.createCanvas(
                named: "UITest One",
                in: nil,
                backgroundStyle: .blank,
                backgroundColor: .white
            )
            secondDocument = try! store.createCanvas(
                named: "UITest Two",
                in: nil,
                backgroundStyle: .blank,
                backgroundColor: .white
            )
        }
        var workspacePDFDocument: PDFWorkspaceDocument?
        if configuration.token.hasPrefix("library-")
            || configuration.token.hasPrefix("pdf-") {
            let isSearchFixture = configuration.token.hasPrefix("pdf-")
            let pdfURL = workspace.appendingPathComponent(
                isSearchFixture ? "UITest Search.pdf" : "UITest PDF.pdf"
            )
            let renderer = UIGraphicsPDFRenderer(
                bounds: CGRect(x: 0, y: 0, width: 612, height: 792)
            )
            try! renderer.writePDF(to: pdfURL) { context in
                context.beginPage()
                ((isSearchFixture ? "First page searchable text" : "UITest PDF") as NSString).draw(
                    at: CGPoint(x: 72, y: 96),
                    withAttributes: [
                        .font: UIFont.systemFont(ofSize: 28, weight: .semibold),
                        .foregroundColor: UIColor.black
                    ]
                )
                if isSearchFixture {
                    context.beginPage()
                    ("Second page contains NeedleTarget for search verification" as NSString).draw(
                        at: CGPoint(x: 72, y: 96),
                        withAttributes: [
                            .font: UIFont.systemFont(ofSize: 24),
                            .foregroundColor: UIColor.black
                        ]
                    )
                }
            }
            workspacePDFDocument = try! store.importPDFs(from: [pdfURL]).first
            try? fileManager.removeItem(at: pdfURL)
        }
        let activeDocumentID = workspacePDFDocument?.id ?? firstDocument.id
        if configuration.token.hasPrefix("library-return-context") {
            let folder = try! store.createFolder(named: "返回目录", in: nil)
            for index in 0..<24 {
                _ = try! store.createCanvas(
                    named: String(format: "返回画板 %02d", index),
                    in: folder.id,
                    backgroundStyle: .blank,
                    backgroundColor: .white
                )
            }
        }
        var retainedOpenDocumentIDs = Set(
            [firstDocument.id, secondDocument.id, workspacePDFDocument?.id]
                .compactMap { $0 }
        )
        if configuration.token.hasPrefix("tabs-overflow-") {
            for index in 3...8 {
                let document = try! store.createCanvas(
                    named: "UITest Tab \(index)", in: nil,
                    backgroundStyle: .blank, backgroundColor: .white
                )
                retainedOpenDocumentIDs.insert(document.id)
            }
        }
        for documentID in store.openDocumentIDs
        where !retainedOpenDocumentIDs.contains(documentID) {
            store.closeDocument(documentID)
        }
        UserDefaults.standard.set(
            activeDocumentID,
            forKey: "pdfWorkspace.activeDocumentID"
        )
        _documentStore = StateObject(wrappedValue: store)
        _showsWorkspace = State(
            initialValue: !configuration.token.hasPrefix("library-")
        )
    }

    var body: some View {
        Group {
            if showsWorkspace {
                CanvasScreen(
                    documentStore: documentStore,
                    onShowLibrary: { showsWorkspace = false },
                    initialPageElementInsertionRequest: initialInsertionRequest
                )
            } else {
                LibraryBrowserView(
                    documentStore: documentStore,
                    browsingState: libraryBrowsingState,
                    onExit: nil,
                    onSyncNow: {
                        documentStore.cloudSyncDidUpdateStatus(.syncing)
                        try? await Task.sleep(nanoseconds: 150_000_000)
                        documentStore.cloudSyncDidUpdateStatus(.succeeded(Date()))
                    },
                    onOpenDocument: { documentID in
                        documentStore.openDocument(documentID)
                        UserDefaults.standard.set(
                            documentID,
                            forKey: "pdfWorkspace.activeDocumentID"
                        )
                        showsWorkspace = true
                    },
                    canEditDocument: { _ in true },
                    onCollaborateDocument: { _ in }
                )
            }
        }
    }

    private var initialInsertionRequest: PageElementInsertionRequest? {
        guard configurationToken.hasPrefix("image-object-") else { return nil }
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 160, height: 100))
        let image = renderer.image { context in
            UIColor.systemBlue.setFill()
            context.cgContext.fill(CGRect(x: 0, y: 0, width: 160, height: 100))
            UIColor.systemOrange.setFill()
            context.cgContext.fill(CGRect(x: 24, y: 18, width: 112, height: 64))
        }
        guard let data = image.pngData() else { return nil }
        return PageElementInsertionRequest(
            pageIndex: 0,
            payload: .image(PageImagePayload(pngData: data))
        )
    }

}
#endif
