import SwiftUI
import UIKit

struct PDFDocumentTabBar: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var draggedDocumentID: String?
    @State private var dragOriginIndex: Int?
    @State private var dragTranslationX: CGFloat = 0

    let openDocuments: [PDFWorkspaceDocument]
    let activeDocumentID: String
    let onSelectDocument: (String) -> Void
    let onCloseDocument: (String) -> Void
    let onMoveDocument: (String, String) -> Void
    let onShowLibrary: () -> Void

    private var isCompact: Bool { horizontalSizeClass == .compact }

    var body: some View {
        HStack(spacing: 0) {
            Button(action: onShowLibrary) {
                Image(systemName: "house")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(TiyiNoteTheme.documentChromeForeground)
                    .frame(width: 46, height: 42)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("返回文稿")
            .accessibilityIdentifier("home-button")

            Rectangle()
                .fill(Color.white.opacity(0.14))
                .frame(width: 1, height: 22)

            GeometryReader { geometry in
                let minimumTabWidth: CGFloat = isCompact ? 144 : 168
                let tabWidth = min(240, max(minimumTabWidth,
                    (geometry.size.width - 12) / CGFloat(max(openDocuments.count, 1))
                ))
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 0) {
                            ForEach(Array(openDocuments.enumerated()), id: \.element.id) { index, document in
                                reorderableTab(document, width: tabWidth)
                                    .overlay(alignment: .trailing) {
                                        if document.id != activeDocumentID,
                                           document.id != draggedDocumentID,
                                           index < openDocuments.count - 1,
                                           openDocuments[index + 1].id != activeDocumentID {
                                            Rectangle()
                                                .fill(TiyiNoteTheme.documentChromeMuted.opacity(0.24))
                                                .frame(width: 1, height: 18)
                                                .allowsHitTesting(false)
                                        }
                                    }
                            }
                        }
                        .padding(.horizontal, 6)
                        .padding(.top, 4)
                    }
                    .accessibilityIdentifier("document-tab-scroll")
                    .onAppear {
                        scrollActiveTab(with: proxy, animated: false)
                    }
                    .onChange(of: activeDocumentID) { _, documentID in
                        guard draggedDocumentID == nil else { return }
                        withAnimation(.easeInOut(duration: 0.2)) {
                            proxy.scrollTo(documentID, anchor: .center)
                        }
                    }
                    .onChange(of: openDocuments.map(\.id)) { _, _ in
                        guard draggedDocumentID == nil else { return }
                        scrollActiveTab(with: proxy, animated: false)
                    }
                }
            }
            .frame(maxWidth: .infinity)
        }
        .frame(height: 44)
        .background {
            ZStack(alignment: .bottom) {
                TiyiNoteTheme.documentChrome
                    .ignoresSafeArea(edges: .top)
                Rectangle()
                    .fill(Color.white.opacity(0.10))
                    .frame(height: 1)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("document-tab-bar")
    }

    private func scrollActiveTab(with proxy: ScrollViewProxy, animated: Bool) {
        guard openDocuments.contains(where: { $0.id == activeDocumentID }) else { return }
        DispatchQueue.main.async {
            if animated {
                withAnimation(.easeInOut(duration: 0.2)) {
                    proxy.scrollTo(activeDocumentID, anchor: .center)
                }
            } else {
                proxy.scrollTo(activeDocumentID, anchor: .center)
            }
        }
    }

    @ViewBuilder
    private func reorderableTab(_ document: PDFWorkspaceDocument, width: CGFloat) -> some View {
        let tab = PDFDocumentTab(
            document: document,
            isActive: document.id == activeDocumentID,
            width: width,
            onSelect: {
                guard draggedDocumentID == nil else { return }
                onSelectDocument(document.id)
            },
            onClose: { onCloseDocument(document.id) }
        )
        .disabled(draggedDocumentID != nil)
        .id(document.id)
        .offset(x: horizontalDragOffset(for: document.id, stride: width))
        .zIndex(tabZIndex(for: document.id))

        #if targetEnvironment(macCatalyst)
        tab.highPriorityGesture(macDocumentDragGesture(for: document.id, stride: width))
        #else
        if UIDevice.current.userInterfaceIdiom == .phone {
            tab
        } else {
            tab.background {
                DocumentTabDragBridge(
                    onBegan: { beginDocumentDrag(document.id) },
                    onChanged: { updateDocumentDrag(document.id, translationX: $0, stride: width) },
                    onEnded: finishDocumentDrag
                )
            }
        }
        #endif
    }

    private func horizontalDragOffset(for documentID: String, stride: CGFloat) -> CGFloat {
        guard documentID == draggedDocumentID,
              let dragOriginIndex,
              let currentIndex = openDocuments.firstIndex(where: { $0.id == documentID }) else {
            return 0
        }

        let reorderedDistance = CGFloat(currentIndex - dragOriginIndex) * stride
        return dragTranslationX - reorderedDistance
    }

    private func tabZIndex(for documentID: String) -> Double {
        if documentID == draggedDocumentID { return 2 }
        return documentID == activeDocumentID ? 1 : 0
    }

    private func beginDocumentDrag(_ documentID: String) {
        guard draggedDocumentID == nil,
              let originIndex = openDocuments.firstIndex(where: { $0.id == documentID }) else {
            return
        }

        draggedDocumentID = documentID
        dragOriginIndex = originIndex
        dragTranslationX = 0
    }

    private func updateDocumentDrag(_ documentID: String, translationX: CGFloat, stride: CGFloat) {
        beginDocumentDrag(documentID)
        guard draggedDocumentID == documentID,
              let dragOriginIndex,
              let currentIndex = openDocuments.firstIndex(where: { $0.id == documentID }),
              !openDocuments.isEmpty else {
            return
        }

        dragTranslationX = translationX
        let projectedIndex = CGFloat(dragOriginIndex) + translationX / stride
        let destinationIndex = min(
            max(Int(projectedIndex.rounded()), 0),
            openDocuments.count - 1
        )
        guard destinationIndex != currentIndex else { return }

        let destinationDocumentID = openDocuments[destinationIndex].id
        withAnimation(.easeInOut(duration: 0.16)) {
            onMoveDocument(documentID, destinationDocumentID)
        }
    }

    private func finishDocumentDrag() {
        withAnimation(.easeOut(duration: 0.16)) {
            draggedDocumentID = nil
            dragOriginIndex = nil
            dragTranslationX = 0
        }
    }

    #if targetEnvironment(macCatalyst)
    private func macDocumentDragGesture(for documentID: String, stride: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .global)
            .onChanged { value in
                updateDocumentDrag(documentID, translationX: value.translation.width, stride: stride)
            }
            .onEnded { _ in
                finishDocumentDrag()
            }
    }
    #endif
}

/// Native long press leaves short swipes to the tab strip's scroll view. A SwiftUI sequenced
/// long-press/drag on every tab can claim those swipes before the scroll view starts scrolling.
private struct DocumentTabDragBridge: UIViewRepresentable {
    let onBegan: () -> Void
    let onChanged: (CGFloat) -> Void
    let onEnded: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeUIView(context: Context) -> DocumentTabDragAnchor {
        let view = DocumentTabDragAnchor()
        let coordinator = context.coordinator
        view.onMoved = { [weak view, weak coordinator] in
            guard let view else { return }
            coordinator?.attach(to: view)
        }
        return view
    }

    func updateUIView(_ uiView: DocumentTabDragAnchor, context: Context) {
        context.coordinator.parent = self
        context.coordinator.attach(to: uiView)
    }

    static func dismantleUIView(_ uiView: DocumentTabDragAnchor, coordinator: Coordinator) {
        coordinator.detach()
        uiView.onMoved = nil
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var parent: DocumentTabDragBridge
        private weak var anchor: UIView?
        private weak var scrollView: UIScrollView?
        private weak var gestureHost: UIView?
        private var recognizer: UILongPressGestureRecognizer?
        private var originX: CGFloat = 0
        private var isDragging = false
        private var restoresPan = false

        init(parent: DocumentTabDragBridge) { self.parent = parent }

        func attach(to anchor: UIView) {
            self.anchor = anchor
            var ancestor = anchor.superview
            var contentHost = anchor
            while let view = ancestor {
                if let scrollView = view as? UIScrollView {
                    guard self.gestureHost !== contentHost else { return }
                    detach()
                    self.anchor = anchor
                    self.scrollView = scrollView
                    gestureHost = contentHost
                    let gesture = UILongPressGestureRecognizer(target: self, action: #selector(handleDrag(_:)))
                    gesture.minimumPressDuration = 0.28
                    gesture.allowableMovement = 12
                    gesture.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
                    gesture.delaysTouchesBegan = false
                    gesture.delaysTouchesEnded = false
                    gesture.delegate = self
                    // Keep this recognizer in the scroll content; HostingScrollView owns
                    // the lifecycle and arbitration of the recognizers installed on itself.
                    contentHost.addGestureRecognizer(gesture)
                    recognizer = gesture
                    return
                }
                contentHost = view
                ancestor = view.superview
            }
        }

        func detach() {
            finishDrag()
            if let recognizer { gestureHost?.removeGestureRecognizer(recognizer) }
            recognizer = nil
            scrollView = nil
            gestureHost = nil
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            guard let anchor, anchor.window != nil else { return false }
            let point = touch.location(in: anchor)
            // A close button remains an ordinary button, even while the finger rests on it.
            guard anchor.bounds.contains(point), point.x < anchor.bounds.width - 38 else { return false }
            originX = touch.location(in: anchor.window).x
            return true
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            // SwiftUI's button responder begins on touch-down. Let the long press observe
            // the same contact; an actual drag temporarily pauses the scroll view's pan.
            return true
        }

        @objc private func handleDrag(_ gesture: UILongPressGestureRecognizer) {
            guard let anchor else { return }
            switch gesture.state {
            case .began:
                isDragging = true
                restoresPan = scrollView?.panGestureRecognizer.isEnabled == true
                scrollView?.panGestureRecognizer.isEnabled = false
                parent.onBegan()
            case .changed:
                parent.onChanged(gesture.location(in: anchor.window).x - originX)
            case .ended, .cancelled, .failed:
                finishDrag()
            default:
                break
            }
        }

        private func finishDrag() {
            if restoresPan { scrollView?.panGestureRecognizer.isEnabled = true }
            restoresPan = false
            if isDragging {
                isDragging = false
                parent.onEnded()
            }
        }
    }
}

private final class DocumentTabDragAnchor: UIView {
    var onMoved: (() -> Void)?

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? { nil }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        onMoved?()
        DispatchQueue.main.async { [weak self] in self?.onMoved?() }
    }
}

/// The trailing document commands in Goodnotes' writing-tool row. Only actions that Tiyi already
/// implements are surfaced here; unfinished placeholders never enter the workspace chrome.
struct DocumentToolbarActions: View {
    let hasActiveDocument: Bool
    let canClearPage: Bool
    let onDocumentAction: (DocumentOutputAction) -> Void
    let onClearPage: () -> Void

    var body: some View {
        HStack(spacing: 1) {
            Menu {
                Button { onDocumentAction(.flattenedPDF) } label: {
                    Label("分享扁平 PDF", systemImage: "doc.richtext")
                }
            } label: {
                DocumentToolbarIcon(symbol: "square.and.arrow.up")
            }
            .disabled(!hasActiveDocument)
            .accessibilityLabel("导出和分享")

            Menu {
                Button { onDocumentAction(.conflictVersions) } label: {
                    Label("冲突版本", systemImage: "arrow.triangle.branch")
                }
                Button { onDocumentAction(.printDocument) } label: {
                    Label("打印", systemImage: "printer")
                }
                if canClearPage {
                    Divider()
                    Button(role: .destructive, action: onClearPage) {
                        Label("清空当前页批注", systemImage: "trash")
                    }
                }
            } label: {
                DocumentToolbarIcon(symbol: "ellipsis.circle")
            }
            .disabled(!hasActiveDocument)
            .accessibilityLabel("更多文稿操作")
        }
    }
}

private struct PDFDocumentTab: View {
    let document: PDFWorkspaceDocument
    let isActive: Bool
    let width: CGFloat
    let onSelect: () -> Void
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Button(action: onSelect) {
                HStack(spacing: 8) {
                    Image(systemName: "doc.richtext")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(
                            isActive
                                ? TiyiNoteTheme.documentChromeForeground
                                : TiyiNoteTheme.documentChromeMuted
                        )
                    Text(document.title)
                        .font(.system(size: 13, weight: isActive ? .semibold : .medium))
                        .lineLimit(1)
                        .foregroundStyle(
                            isActive
                                ? TiyiNoteTheme.documentChromeForeground
                                : TiyiNoteTheme.documentChromeMuted
                        )
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("document-tab-\(document.title)")
            .accessibilityValue(isActive ? "active" : "inactive")

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(
                        isActive
                            ? TiyiNoteTheme.documentChromeForeground.opacity(0.76)
                            : TiyiNoteTheme.documentChromeMuted.opacity(0.74)
                    )
                    .frame(width: 28, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("关闭 \(document.title)")
        }
        .padding(.leading, 16)
        .padding(.trailing, 10)
        .frame(width: width, height: 40)
        .background {
            if isActive {
                BrowserDocumentTabShape()
                    .fill(TiyiNoteTheme.documentToolbar)
            }
        }
        .contentShape(Rectangle())
    }
}

/// Rounded shoulders connect the active tab to the command row, like a browser tab strip.
private struct BrowserDocumentTabShape: Shape {
    func path(in rect: CGRect) -> Path {
        let shoulder: CGFloat = 7
        let corner: CGFloat = 11
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.addQuadCurve(to: CGPoint(x: rect.minX + shoulder, y: rect.maxY - shoulder),
                          control: CGPoint(x: rect.minX + shoulder, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX + shoulder, y: rect.minY + corner))
        path.addQuadCurve(to: CGPoint(x: rect.minX + shoulder + corner, y: rect.minY),
                          control: CGPoint(x: rect.minX + shoulder, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - shoulder - corner, y: rect.minY))
        path.addQuadCurve(to: CGPoint(x: rect.maxX - shoulder, y: rect.minY + corner),
                          control: CGPoint(x: rect.maxX - shoulder, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - shoulder, y: rect.maxY - shoulder))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.maxY),
                          control: CGPoint(x: rect.maxX - shoulder, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

struct PDFTextSearchSheet: View {
    @ObservedObject var documentStore: DrawingDocumentStore
    let document: PDFWorkspaceDocument
    let onSelect: (PDFTextSearchResult) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var results: [PDFTextSearchResult] = []
    @State private var hasSearched = false
    @State private var searchTask: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            Group {
                if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    ContentUnavailableView(
                        "搜索 PDF",
                        systemImage: "doc.text.magnifyingglass",
                        description: Text("输入文字，搜索 PDF 自带的文本内容。扫描图片不会被识别。")
                    )
                } else if results.isEmpty, hasSearched {
                    ContentUnavailableView.search(text: query)
                } else {
                    List(results) { result in
                        Button {
                            onSelect(result)
                        } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("第 \(result.pageIndex + 1) 页")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(TiyiNoteTheme.selectionForeground)
                                Text(result.excerpt.isEmpty ? query : result.excerpt)
                                    .font(.body)
                                    .foregroundStyle(TiyiNoteTheme.textPrimary)
                                    .lineLimit(3)
                                    .multilineTextAlignment(.leading)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 4)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("第 \(result.pageIndex + 1) 页，\(result.excerpt)")
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle(document.title)
            .navigationBarTitleDisplayMode(.inline)
            .searchable(
                text: $query,
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: "搜索 PDF 文本"
            )
            .onSubmit(of: .search, performSearchImmediately)
            .onChange(of: query) { _, _ in scheduleSearch() }
            .onDisappear { searchTask?.cancel() }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func scheduleSearch() {
        searchTask?.cancel()
        hasSearched = false
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedQuery.isEmpty else {
            results = []
            return
        }
        searchTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled, normalizedQuery == query.trimmingCharacters(in: .whitespacesAndNewlines)
            else { return }
            results = documentStore.searchPDF(normalizedQuery, in: document.id)
            hasSearched = true
        }
    }

    private func performSearchImmediately() {
        searchTask?.cancel()
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedQuery.isEmpty else {
            results = []
            hasSearched = false
            return
        }
        results = documentStore.searchPDF(normalizedQuery, in: document.id)
        hasSearched = true
    }
}

struct CollaborationConflictSheet: View {
    @ObservedObject var documentStore: DrawingDocumentStore
    let document: PDFWorkspaceDocument
    let onLocate: (CollaborationConflictItem) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var errorMessage: String?

    private var conflicts: [CollaborationConflictItem] {
        documentStore.collaborationConflicts(in: document.id)
    }

    var body: some View {
        NavigationStack {
            Group {
                if conflicts.isEmpty {
                    ContentUnavailableView(
                        "没有待处理冲突",
                        systemImage: "checkmark.shield",
                        description: Text("并发修改已经自动合并，没有需要人工恢复的版本。")
                    )
                } else {
                    List(conflicts) { item in
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                Label(
                                    item.pageIndex.map { "第 \($0 + 1) 页" } ?? "已删除页面",
                                    systemImage: "doc.text"
                                )
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(TiyiNoteTheme.selectionForeground)
                                Spacer()
                                Text(conflictKind(item.conflict.payload))
                                    .font(.caption)
                                    .foregroundStyle(TiyiNoteTheme.textTertiary)
                            }
                            Text(item.conflict.reason)
                                .font(.subheadline)
                                .foregroundStyle(TiyiNoteTheme.textSecondary)
                            conflictPreview(item.conflict.payload)

                            HStack(spacing: 12) {
                                if item.pageIndex != nil {
                                    Button("定位") { onLocate(item) }
                                        .buttonStyle(.bordered)
                                }
                                Button("忽略") { resolve(item, restores: false) }
                                    .buttonStyle(.bordered)
                                Button("恢复为副本") { resolve(item, restores: true) }
                                    .buttonStyle(.borderedProminent)
                            }
                            .font(.system(size: 12, weight: .semibold))
                        }
                        .padding(.vertical, 6)
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("冲突版本")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .alert("处理失败", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("好", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "请稍后重试。")
        }
    }

    @ViewBuilder
    private func conflictPreview(_ payload: CollaborationOperationPayload) -> some View {
        switch payload {
        case .elementUpsert(let element), .elementPatch(let element, _):
            switch element.payload {
            case .text(let text):
                Text(text.text)
                    .lineLimit(3)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(TiyiNoteTheme.surfaceRaised, in: RoundedRectangle(cornerRadius: 8))
            case .image(let imagePayload):
                if let image = UIImage(data: imagePayload.pngData) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxHeight: 120)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            case .question(let question):
                Label(question.isCompleted ? "圈题作答（已完成）" : "圈题作答", systemImage: "questionmark.square.dashed")
            case .shape(let shape):
                Label(shape.kind.title, systemImage: shape.kind.symbolName)
            }
        case .strokeUpsert:
            Label("保留的手写笔迹", systemImage: "pencil.tip.crop.circle")
        case .metadataSet(let field, let value):
            if field == "document.title",
               let value,
               let title = try? JSONDecoder().decode(String.self, from: value) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("文稿标题版本")
                        .font(.caption)
                        .foregroundStyle(TiyiNoteTheme.textSecondary)
                    Text(title)
                }
            } else {
                Text("字段：\(field)").font(.caption.monospaced())
            }
        case .pagePosition:
            Label("保留的页面位置", systemImage: "rectangle.2.swap")
        case .pageDelete, .pageRestore:
            Label("保留的页面状态", systemImage: "doc.badge.arrow.up")
        case .strokeDelete:
            Label("笔迹删除操作", systemImage: "eraser")
        case .elementDelete:
            Label("对象删除操作", systemImage: "trash")
        }
    }

    private func conflictKind(_ payload: CollaborationOperationPayload) -> String {
        switch payload {
        case .strokeUpsert, .strokeDelete: "笔迹"
        case .elementUpsert, .elementPatch, .elementDelete: "对象"
        case .pagePosition, .pageDelete, .pageRestore: "页面"
        case .metadataSet: "属性"
        }
    }

    private func resolve(_ item: CollaborationConflictItem, restores: Bool) {
        do {
            if restores {
                try documentStore.restoreCollaborationConflict(item)
            } else {
                try documentStore.dismissCollaborationConflict(item)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
