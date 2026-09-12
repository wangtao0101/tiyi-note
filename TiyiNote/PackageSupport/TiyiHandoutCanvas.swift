import SwiftUI
import PencilKit
import WebKit
import CryptoKit

public struct TiyiHandoutPageSource {
    public let id: String
    public let title: String
    public let legacyAnnotationURL: URL?
    public init(id: String, title: String, legacyAnnotationURL: URL? = nil) {
        self.id = id; self.title = title; self.legacyAnnotationURL = legacyAnnotationURL
    }
}

/// The host supplies authenticated live HTML. Note owns every editing and persistence surface.
@MainActor public final class TiyiHandoutPageSession: ObservableObject {
    public let webView: WKWebView
    @Published public var height: CGFloat?
    @Published public var signature: String?
    @Published public var error: String?
    @Published private(set) var validatedSignature: String?
    var isReady: Bool { signature != nil && signature == validatedSignature && error == nil }
    func acceptLayout() { validatedSignature = signature }
    public var load: () -> Void = {}
    public var stop: () -> Void = {}
    public init(webView: WKWebView) { self.webView = webView }
}

enum HandoutAttachmentError: LocalizedError {
    case message(String)
    var errorDescription: String? { switch self { case .message(let value): return value } }
}

@MainActor public final class TiyiHandoutWorkspace: ObservableObject {
    let store: DrawingDocumentStore
    let defaults: UserDefaults
    public let documentID: String
    private let sources: [TiyiHandoutPageSource]
    private let makeSession: (String) -> TiyiHandoutPageSession
    private var sessions: [String: TiyiHandoutPageSession] = [:]
    private var mountedPageIDs: Set<String> = []
    private var sessionOrder: [String] = []
    var cachedSessionCount: Int { sessions.count }
    private let signaturesURL: URL
    private var signatures: [String: String]
    @Published public var errorMessage: String?
    @Published var requestedPageID: String?
    public var onInteract: ((String) -> Void)?

    public init(directory: URL, title: String, sources: [TiyiHandoutPageSource], makeSession: @escaping (String) -> TiyiHandoutPageSession) throws {
        guard !sources.isEmpty else { throw HandoutAttachmentError.message("讲义中没有页面") }
        self.sources = sources; self.makeSession = makeSession
        let key = SHA256.hash(data: Data(directory.path.utf8)).map { String(format: "%02x", $0) }.joined()
        defaults = UserDefaults(suiteName: "tiyi.handout.\(key)")!
        store = DrawingDocumentStore(userDefaults: defaults, workspaceDirectoryOverride: directory, includesBundledSamples: false)
        signaturesURL = directory.appendingPathComponent("handout-layouts.json")
        signatures = FileManager.default.fileExists(atPath: signaturesURL.path)
            ? try JSONDecoder().decode([String: String].self, from: Data(contentsOf: signaturesURL)) : [:]
        if let existing = store.documents.first {
            documentID = existing.id
        } else {
            documentID = try store.createCanvas(named: title.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-"), in: nil, backgroundStyle: .blank, backgroundColor: .white, size: CGSize(width: 900, height: 700)).id
        }
        // Mapping lives with Note's stable page metadata, so reorder/delete/restore/duplicate
        // preserve attachments with exactly the same lifecycle as ink and page objects.
        for source in sources {
            let all = store.pages(in: documentID) + store.deletedPages(in: documentID)
            if all.contains(where: { $0.handoutSourceID == source.id }) { continue }
            let pages = store.pages(in: documentID)
            let page = all.count == 1 && all[0].handoutSourceID == nil
                ? all[0] : try store.insertTemplatePage(after: pages.last?.id, in: documentID, size: CGSize(width: 900, height: 700))
            if let url = source.legacyAnnotationURL, FileManager.default.fileExists(atPath: url.path) {
                let state = try JSONDecoder().decode(LegacyCheckpoint.self, from: Data(contentsOf: url))
                guard state.version == 1 else { throw CocoaError(.fileReadCorruptFile) }
                let drawing = try PKDrawing(data: state.drawing)
                store.flush(drawing, forPage: page.orderIndex, in: documentID)
                guard store.flushAllPendingSaves() else { throw CocoaError(.fileWriteUnknown) }
                store.saveCanvasViewport(state.viewport, forPageID: page.id, in: documentID)
                if !drawing.strokes.isEmpty { signatures[source.id] = state.signature }
                try JSONEncoder().encode(signatures).write(to: signaturesURL, options: .atomic)
            }
            try store.setHandoutSource(source.id, for: page.id, in: documentID)
        }
        defaults.set(documentID, forKey: "pdfWorkspace.activeDocumentID")
        store.allowsPracticeFingerDrawing = UIDevice.current.userInterfaceIdiom == .phone
        store.openDocument(documentID)
        store.handoutWorkspace = self
    }
    private struct LegacyCheckpoint: Decodable {
        var version: Int; var signature: String; var drawing: Data; var viewport: CanvasViewport
    }
    func sourceID(for pageID: String) -> String? {
        // This is called on every camera update. Never enumerate collaboration files for an
        // active page: deletedPages materializes the archive from disk.
        if let page = store.pages(in: documentID).first(where: { $0.id == pageID }) { return page.handoutSourceID }
        return store.deletedPages(in: documentID).first { $0.id == pageID }?.handoutSourceID
    }
    func title(for pageID: String) -> String? { sources.first { $0.id == sourceID(for: pageID) }?.title }
    func cachedSession(for pageID: String) -> TiyiHandoutPageSession? { sessions[pageID] }
    func session(for pageID: String) -> TiyiHandoutPageSession? {
        guard let source = sourceID(for: pageID) else { return nil }
        sessionOrder.removeAll { $0 == pageID }; sessionOrder.append(pageID)
        if let existing = sessions[pageID] { return existing }
        let session = makeSession(source); sessions[pageID] = session
        return session
    }
    func mountPage(_ pageID: String) -> TiyiHandoutPageSession? {
        mountedPageIDs.insert(pageID)
        let value = session(for: pageID)
        trimSessions()
        return value
    }
    func unmountPage(_ pageID: String) {
        mountedPageIDs.remove(pageID)
        trimSessions()
    }
    private func trimSessions() {
        // Keep recent chapters warm, but do not retain a WebKit process for every visited page.
        for id in sessionOrder where sessions.count > 4 && !mountedPageIDs.contains(id) {
            sessions.removeValue(forKey: id)?.stop()
        }
        sessionOrder.removeAll { sessions[$0] == nil }
    }
    func validate(_ session: TiyiHandoutPageSession, pageID: String) throws {
        if session.isReady { return }
        guard let signature = session.signature, let source = sourceID(for: pageID) else { throw CocoaError(.fileReadCorruptFile) }
        if let old = signatures[source], old != signature {
            let archived = store.deletedPages(in: documentID).contains { $0.handoutSourceID == source }
            let annotated = archived || store.pages(in: documentID).filter { $0.handoutSourceID == source }.contains {
                !store.loadDrawing(forPage: $0.orderIndex, in: documentID).strokes.isEmpty || !store.loadPageElements(forPage: $0.orderIndex, in: documentID).isEmpty
            }
            guard !annotated else { throw HandoutAttachmentError.message("讲义排版与保存笔迹时不同。原有笔迹已保留，请使用原排版版本继续书写。") }
        }
        if signatures[source] != signature {
            var updated = signatures
            updated[source] = signature
            try JSONEncoder().encode(updated).write(to: signaturesURL, options: .atomic)
            signatures = updated
        }
        session.acceptLayout()
    }
    public func selectChapter(_ sourceID: String) {
        requestedPageID = store.pages(in: documentID).first { $0.handoutSourceID == sourceID }?.id
    }
    func interact(at index: Int) {
        guard let id = store.pageID(at: index, in: documentID), let source = sourceID(for: id) else { return }
        do { try checkpoint(); onInteract?(source) } catch { errorMessage = error.localizedDescription }
    }
    public func checkpoint() throws {
        NotificationCenter.default.post(name: .tiyiPracticeCheckpoint, object: store)
        guard store.flushAllPendingSaves() else { throw CocoaError(.fileWriteUnknown) }
    }
    public func stop() { sessions.values.forEach { $0.stop() } }
}

public struct TiyiHandoutEditor: View {
    @ObservedObject private var workspace: TiyiHandoutWorkspace
    private let onExit: () -> Void
    public init(workspace: TiyiHandoutWorkspace, onExit: @escaping () -> Void) { self.workspace = workspace; self.onExit = onExit }
    public var body: some View {
        CanvasScreen(documentStore: workspace.store, onShowLibrary: {
            do { try workspace.checkpoint(); onExit() } catch { workspace.errorMessage = error.localizedDescription }
        }, handout: workspace)
        .defaultAppStorage(workspace.defaults)
        .alert("讲义保存", isPresented: Binding(get: { workspace.errorMessage != nil }, set: { if !$0 { workspace.errorMessage = nil } })) {
            Button("好", role: .cancel) { workspace.errorMessage = nil }
        } message: { Text(workspace.errorMessage ?? "") }
    }
}

/// LazyVStack can evaluate intervening page bodies to locate a distant target. Create WebKit
/// only when a page actually appears, and release the view's reference when it leaves the pager.
struct HandoutPageHost<Content: View>: View {
    let workspace: TiyiHandoutWorkspace
    let pageID: String
    @ViewBuilder var content: (TiyiHandoutPageSession) -> Content
    @State private var session: TiyiHandoutPageSession?
    var body: some View {
        Group {
            if let session {
                HandoutPageGate(session: session, workspace: workspace, pageID: pageID) { content(session) }
            } else { ProgressView("正在准备讲义…") }
        }
        .onAppear { session = workspace.mountPage(pageID) }
        .onDisappear { session = nil; workspace.unmountPage(pageID) }
    }
}

/// Do not mount the shared writable editor until fonts/assets and the saved layout are verified.
struct HandoutPageGate<Content: View>: View {
    @ObservedObject var session: TiyiHandoutPageSession
    let workspace: TiyiHandoutWorkspace
    let pageID: String
    @ViewBuilder var content: () -> Content
    @State private var failure: String?
    var body: some View {
        Group {
            if session.isReady { content() }
            else {
                ZStack {
                    HandoutLoadingWebView(webView: session.webView).frame(width: 900, height: 700).opacity(0).allowsHitTesting(false)
                    if let error = failure ?? session.error {
                        VStack { ContentUnavailableView("讲义暂时无法显示", systemImage: "exclamationmark.document", description: Text(error)); Button("重新加载") { failure = nil; session.load() } }
                    } else { ProgressView("正在准备讲义和配图…") }
                }.clipped()
            }
        }
        .onAppear { session.load(); validate() }
        .onChange(of: session.signature) { _, _ in validate() }
    }
    private func validate() {
        guard session.signature != nil else { return }
        do { try workspace.validate(session, pageID: pageID); failure = nil }
        catch { failure = error.localizedDescription }
    }
}
private struct HandoutLoadingWebView: UIViewRepresentable {
    let webView: WKWebView
    func makeUIView(context: Context) -> WKWebView { webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

struct HandoutPageBackground: UIViewRepresentable {
    let session: TiyiHandoutPageSession
    let viewport: CGRect
    func makeUIView(context: Context) -> HandoutProjectedWebView { HandoutProjectedWebView(webView: session.webView) }
    func updateUIView(_ view: HandoutProjectedWebView, context: Context) {
        view.viewport = viewport; view.contentHeight = session.height ?? 700; view.setNeedsLayout()
    }
}

/// Only projects HTML into the existing canvas camera. No tools, ink, gestures or persistence here.
@MainActor final class HandoutProjectedWebView: UIView {
    let webView: WKWebView
    var viewport = CGRect(x: 0, y: 0, width: 900, height: 700)
    var contentHeight: CGFloat = 700
    private var offsetObservation: NSKeyValueObservation?
    init(webView: WKWebView) {
        self.webView = webView
        super.init(frame: .zero)
        clipsToBounds = true; isUserInteractionEnabled = false
        webView.removeFromSuperview()
        webView.autoresizingMask = []
        addSubview(webView)
        webView.isUserInteractionEnabled = false; webView.scrollView.isScrollEnabled = false
        webView.scrollView.bounces = false
        offsetObservation = webView.scrollView.observe(\.contentOffset, options: [.new]) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.alignOrigin() }
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.width > 0, viewport.width > 0, viewport.height > 0 else { return }
        let scale = bounds.width / viewport.width
        webView.isHidden = viewport.minY >= contentHeight || viewport.maxY <= 0 || viewport.maxX <= 0 || viewport.minX >= 900
        let transform = CGAffineTransform(scaleX: scale, y: scale)
        if webView.transform != transform {
            webView.transform = transform
            webView.setNeedsLayout()
        }
        let centerX = (450 - viewport.minX) * scale
        if webView.center.x != centerX {
            webView.center.x = centerX
            webView.setNeedsLayout()
        }
        guard !webView.isHidden else { alignOrigin(); return }

        // Keep an overscanned live HTML window. Most pan/pinch samples only move its native
        // layer; changing WK bounds or scrolling at every sample forces WebKit layout/IPC.
        // Grow in buckets when zooming far out, rather than resizing on every gesture tick.
        let requiredHeight = min(contentHeight, max(2048, pow(2, ceil(log2(viewport.height * 1.5)))))
        let height = min(contentHeight, max(webView.bounds.height, requiredHeight))
        let resized = webView.bounds.width != 900 || webView.bounds.height != height
        if resized { webView.bounds = CGRect(x: 0, y: 0, width: 900, height: height) }
        let offset = webView.scrollView.contentOffset.y
        let visibleTop = max(0, viewport.minY)
        let visibleBottom = min(contentHeight, viewport.maxY)
        if resized || visibleTop < offset || visibleBottom > offset + height {
            let top = max(0, min(contentHeight - height, viewport.midY - height / 2))
            if abs(top - offset) > 0.5 { webView.scrollView.setContentOffset(CGPoint(x: 0, y: top), animated: false) }
        }
        alignOrigin()
    }
    private func alignOrigin() {
        guard viewport.width > 0 else { return }
        let centerY = (webView.scrollView.contentOffset.y - viewport.minY + webView.bounds.height / 2) * bounds.width / viewport.width
        if webView.center.y != centerY {
            webView.center.y = centerY
            // A transform/position change does not invalidate WKWebView's layout by itself.
            // WebKit otherwise keeps tiles for the previous clipped viewport, leaving a hard
            // blank edge even when bounds/contentSize already cover the entire chapter.
            // Its native layout refreshes visible tiles without changing HTML layout or size.
            webView.setNeedsLayout()
        }
    }
}
