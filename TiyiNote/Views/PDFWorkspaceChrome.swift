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
    private var tabStride: CGFloat { (isCompact ? 196 : 248) + 2 }

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

            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 2) {
                        ForEach(openDocuments) { document in
                            reorderableTab(document)
                        }
                    }
                    .padding(.horizontal, 6)
                }
                .accessibilityIdentifier("document-tab-scroll")
                .onAppear {
                    scrollActiveTab(with: proxy, animated: false)
                }
                .onChange(of: activeDocumentID) { _, documentID in
                    withAnimation(.easeInOut(duration: 0.2)) {
                        proxy.scrollTo(documentID, anchor: .center)
                    }
                }
                .onChange(of: openDocuments.map(\.id)) { _, _ in
                    scrollActiveTab(with: proxy, animated: false)
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
    private func reorderableTab(_ document: PDFWorkspaceDocument) -> some View {
        let tab = PDFDocumentTab(
            document: document,
            isActive: document.id == activeDocumentID,
            canClose: openDocuments.count > 1,
            isCompact: isCompact,
            onSelect: { onSelectDocument(document.id) },
            onClose: { onCloseDocument(document.id) }
        )
        .id(document.id)
        .offset(x: horizontalDragOffset(for: document.id))
        .zIndex(tabZIndex(for: document.id))

        #if targetEnvironment(macCatalyst)
        tab.highPriorityGesture(macDocumentDragGesture(for: document.id))
        #else
        if UIDevice.current.userInterfaceIdiom == .phone {
            // On iPhone the tab strip is narrower than two tabs. A long-press
            // reorder recognizer on every tab prevents the horizontal scroll view
            // from taking ownership of swipes, making off-screen tabs unreachable.
            // Phone is read-only and prioritizes reliable tab navigation; iPad
            // keeps drag-to-reorder below.
            tab
        } else {
            tab.simultaneousGesture(touchDocumentDragGesture(for: document.id))
        }
        #endif
    }

    private func horizontalDragOffset(for documentID: String) -> CGFloat {
        guard documentID == draggedDocumentID,
              let dragOriginIndex,
              let currentIndex = openDocuments.firstIndex(where: { $0.id == documentID }) else {
            return 0
        }

        let reorderedDistance = CGFloat(currentIndex - dragOriginIndex) * tabStride
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

    private func updateDocumentDrag(_ documentID: String, translationX: CGFloat) {
        beginDocumentDrag(documentID)
        guard draggedDocumentID == documentID,
              let dragOriginIndex,
              let currentIndex = openDocuments.firstIndex(where: { $0.id == documentID }),
              !openDocuments.isEmpty else {
            return
        }

        dragTranslationX = translationX
        let projectedIndex = CGFloat(dragOriginIndex) + translationX / tabStride
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
    private func macDocumentDragGesture(for documentID: String) -> some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .global)
            .onChanged { value in
                updateDocumentDrag(documentID, translationX: value.translation.width)
            }
            .onEnded { _ in
                finishDocumentDrag()
            }
    }
    #else
    private func touchDocumentDragGesture(for documentID: String) -> some Gesture {
        LongPressGesture(minimumDuration: 0.25, maximumDistance: 12)
            .sequenced(
                before: DragGesture(minimumDistance: 0, coordinateSpace: .global)
            )
            .onChanged { value in
                switch value {
                case .first(true):
                    beginDocumentDrag(documentID)
                case .second(true, let dragValue):
                    if let dragValue {
                        updateDocumentDrag(
                            documentID,
                            translationX: dragValue.translation.width
                        )
                    }
                default:
                    break
                }
            }
            .onEnded { _ in
                finishDocumentDrag()
            }
    }
    #endif
}

/// The trailing document commands in Goodnotes' writing-tool row. Only actions that Tiyi already
/// implements are surfaced here; unfinished placeholders never enter the workspace chrome.
struct DocumentToolbarActions: View {
    let hasActiveDocument: Bool
    let canImportPDF: Bool
    let canClearPage: Bool
    let onImportPDF: () -> Void
    let onDocumentAction: (DocumentOutputAction) -> Void
    let onClearPage: () -> Void

    var body: some View {
        HStack(spacing: 1) {
            if canImportPDF {
                Button(action: onImportPDF) {
                    DocumentTopBarIcon(symbol: "doc.badge.plus")
                }
                .buttonStyle(DocumentTopBarPressedStyle())
                .accessibilityLabel("导入 PDF 或可编辑文稿")
                .accessibilityIdentifier("document-import-button")
            }

            Menu {
                Button { onDocumentAction(.flattenedPDF) } label: {
                    Label("分享扁平 PDF", systemImage: "doc.richtext")
                }
                Button { onDocumentAction(.pageImages) } label: {
                    Label("导出页面图片", systemImage: "photo.on.rectangle.angled")
                }
                Button { onDocumentAction(.editablePackage) } label: {
                    Label("导出可编辑文稿", systemImage: "shippingbox")
                }
                Divider()
                Button { onDocumentAction(.collaboration) } label: {
                    Label("多人协作", systemImage: "person.2.badge.plus")
                }
            } label: {
                DocumentTopBarIcon(symbol: "square.and.arrow.up")
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
                DocumentTopBarIcon(symbol: "ellipsis.circle")
            }
            .disabled(!hasActiveDocument)
            .accessibilityLabel("更多文稿操作")
        }
    }
}

private struct DocumentTopBarIcon: View {
    let symbol: String

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(TiyiNoteTheme.documentChromeForeground)
            .frame(width: 38, height: 38)
            .contentShape(Rectangle())
    }
}

private struct DocumentTopBarPressedStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                Color.white.opacity(configuration.isPressed ? 0.13 : 0),
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
    }
}

private struct PDFDocumentTab: View {
    let document: PDFWorkspaceDocument
    let isActive: Bool
    let canClose: Bool
    let isCompact: Bool
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
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("document-tab-\(document.title)")
            .accessibilityValue(isActive ? "active" : "inactive")

            if canClose {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(
                            isActive
                                ? TiyiNoteTheme.documentChromeForeground.opacity(0.76)
                                : TiyiNoteTheme.documentChromeMuted.opacity(0.74)
                        )
                        .frame(width: 24, height: 30)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("关闭 \(document.title)")
            }
        }
        .padding(.leading, 12)
        .padding(.trailing, 8)
        .frame(
            width: isCompact ? 196 : 248,
            height: 42
        )
        .background {
            if isActive {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(TiyiNoteTheme.documentToolbar)
            }
        }
        .overlay(alignment: .bottom) {
            if isActive {
                Capsule()
                    .fill(Color.white.opacity(0.88))
                    .frame(height: 2)
                    .padding(.horizontal, 14)
            }
        }
        .contentShape(Rectangle())
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
