import SwiftUI
import PencilKit
import CryptoKit

/// An embedded notebook. The host supplies an account/video-scoped directory; Note owns ink,
/// history, page files and camera coordinates, without mounting the full document workspace.
@MainActor public final class TiyiCourseNotebook: ObservableObject {
    let store: DrawingDocumentStore
    let defaults: UserDefaults
    let documentID: String
    static let pageSize = CGSize(width: 1000, height: 700)
    @Published var controller = CanvasController()
    @Published var viewport = CanvasViewport(referenceSize: pageSize)
    @Published var pageElements: [CanvasPageElement] = []
    private var submittedElements: [CanvasPageElement] = []
    @Published private(set) var pageIndex = 0
    @Published private(set) var pageCount = 1
    @Published public private(set) var error: String?
    @Published private(set) var hasUnsavedChanges = false
    @Published var tool = CanvasToolKind.pen { didSet { applyTool() } }
    @Published var color = InkPaletteColor.graphite { didSet { applyTool() } }
    @Published var width = 0.5 { didSet { applyTool() } }
    @Published var penVariant = CanvasToolKind.pen
    @Published var markerWidth = 10.0 { didSet { applyTool() } }
    @Published var eraserSize = CanvasEraserSize.small { didSet { applyTool() } }
    @Published var eraserMode = CanvasEraserMode.precision { didSet { applyTool() } }
    @Published var isMoving = false { didSet { applyTool() } }
    private var pendingSave: Task<Void, Never>?
    private var isDirty = false
    private var interactionID = UUID()

    public init(directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let key = SHA256.hash(data: Data(directory.path.utf8)).map { String(format: "%02x", $0) }.joined()
        defaults = UserDefaults(suiteName: "tiyi.course-notebook.\(key)")!
        store = DrawingDocumentStore(userDefaults: defaults, workspaceDirectoryOverride: directory, includesBundledSamples: false)
        if let existing = store.documents.first { documentID = existing.id }
        else {
            documentID = try store.createCanvas(named: "随堂笔记", in: nil, backgroundStyle: .dotted,
                                               backgroundColor: .ivory, size: Self.pageSize).id
        }
        store.openDocument(documentID)
        pageCount = store.pages(in: documentID).count
        let savedID = defaults.string(forKey: "activePage")
        let index = store.pages(in: documentID).firstIndex { $0.id == savedID } ?? 0
        loadPage(index)
    }

    private func loadPage(_ index: Int) {
        controller.onDrawingChanged = nil
        controller.onToolInteractionChanged = nil
        controller.onPageElementsUpdated = nil
        controller.pageElementsProvider = nil
        controller = CanvasController()
        pageIndex = index
        controller.installInitialDrawing(store.loadDrawing(forPage: index, in: documentID))
        pageElements = store.loadPageElements(forPage: index, in: documentID)
        submittedElements = pageElements
        controller.pageElementsProvider = { [weak self] in self?.pageElements ?? [] }
        controller.onPageElementsUpdated = { [weak self] elements, shouldPersist in
            guard let self else { return }
            self.pageElements = elements
            if shouldPersist { self.elementsChanged() }
        }
        if let id = store.pageID(at: index, in: documentID) {
            viewport = store.canvasViewport(forPageID: id, in: documentID, referenceSize: Self.pageSize)
            defaults.set(id, forKey: "activePage")
        }
        controller.onDrawingChanged = { [weak self] _ in self?.drawingChanged() }
        controller.onToolInteractionChanged = { [weak self] active in
            guard let self else { return }
            self.store.setDrawingInteractionActive(active, id: self.interactionID)
        }
        applyTool()
    }

    private func applyTool() {
        controller.configureAnnotationInput(isEditable: !isMoving)
        controller.updateTool(kind: tool, color: color, width: tool == .marker ? markerWidth : width,
                              eraserSize: eraserSize, eraserMode: eraserMode)
    }

    private func drawingChanged() {
        isDirty = true
        hasUnsavedChanges = true
        pendingSave?.cancel()
        pendingSave = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .milliseconds(650)) } catch { return }
            guard let self else { return }
            // Never serialize the live drawing while PencilKit still owns a contact.
            while self.controller.isUsingTool {
                do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
            }
            self.checkpoint()
        }
    }

    func elementsChanged() {
        store.scheduleSave(pageElements, replacing: submittedElements, forPage: pageIndex, in: documentID)
        submittedElements = pageElements
        drawingChanged()
    }

    @discardableResult public func checkpoint() -> Bool {
        controller.finishEndedInteractionForCheckpoint()
        pendingSave?.cancel(); pendingSave = nil
        store.setDrawingInteractionActive(false, id: interactionID)
        if isDirty { store.flush(controller.drawing, forPage: pageIndex, in: documentID) }
        if case .failed(let message) = store.saveState { error = "笔记保存失败：\(message)"; return false }
        guard store.flushAllPendingSaves() else { error = "笔记保存失败，请重试。"; return false }
        saveViewport()
        isDirty = false; hasUnsavedChanges = false; error = nil
        return true
    }

    func selectPage(_ index: Int) {
        guard index != pageIndex, (0..<pageCount).contains(index), checkpoint() else { return }
        loadPage(index)
    }

    func addPage() {
        guard checkpoint() else { return }
        do {
            let page = try store.insertTemplatePage(after: store.pages(in: documentID).last?.id,
                                                    in: documentID, style: .dotted, color: .ivory, size: Self.pageSize)
            pageCount = store.pages(in: documentID).count
            loadPage(store.pageIndex(for: page.id, in: documentID) ?? pageCount - 1)
        } catch { self.error = "新增笔记页失败：\(error.localizedDescription)" }
    }

    var backgroundPage: LibraryPage {
        // Apply the course paper style to existing notebooks without touching their ink.
        var page = store.pages(in: documentID)[pageIndex]
        page.backgroundStyle = .dotted
        page.backgroundColor = .ivory
        return page
    }

    var zoomPercentage: Int { Int((viewport.zoomScale * 100).rounded()) }

    func resetZoom() {
        // Keep the current center; this control changes scale without losing one's place.
        viewport.zoomScale = 1
        saveViewport()
    }

    func saveViewport() {
        guard let id = store.pageID(at: pageIndex, in: documentID) else { return }
        store.saveCanvasViewport(viewport, forPageID: id, in: documentID)
    }

    func navigate(_ change: CanvasNavigationChange, size: CGSize) {
        switch change {
        case .pan(let translation): viewport.pan(by: translation, in: size, referenceSize: Self.pageSize)
        case .zoom(let scale, let anchor): viewport.zoom(by: scale, around: anchor, in: size, referenceSize: Self.pageSize)
        case .finished: saveViewport()
        }
    }
}

public struct TiyiCourseNotebookEditor: View {
    @ObservedObject private var notebook: TiyiCourseNotebook
    @Environment(\.scenePhase) private var scenePhase
    public init(notebook: TiyiCourseNotebook) { self.notebook = notebook }
    public var body: some View {
        VStack(spacing: 0) {
            if let error = notebook.error {
                HStack {
                    Text(error).font(.caption).foregroundStyle(.red)
                    Button("重试保存") { notebook.checkpoint() }
                }.padding(8)
            }
            GeometryReader { geometry in
                PencilCanvasView(controller: notebook.controller, logicalPageSize: TiyiCourseNotebook.pageSize,
                                 logicalViewport: notebook.viewport.logicalBounds(in: geometry.size, referenceSize: TiyiCourseNotebook.pageSize),
                                 isCurrentPage: true, pagesNavigateFromSidebarOnly: true,
                                 isAnnotationEditingEnabled: !notebook.isMoving, confinesNavigationToCanvas: true,
                                 onFingerPinchChanged: { _ in }, onFingerPinchEnded: { _ in }, onFingerPinchCancelled: {},
                                 onCanvasNavigation: { notebook.navigate($0, size: geometry.size) })
                    .id(notebook.pageIndex)
                    .accessibilityLabel("随堂笔记画板")
                    .accessibilityIdentifier("course-notebook-canvas")
                    .background {
                        CanvasBackgroundView(
                            viewport: notebook.viewport.logicalBounds(in: geometry.size, referenceSize: TiyiCourseNotebook.pageSize),
                            page: notebook.backgroundPage)
                    }
                    .overlay {
                        CourseInkSelectionOverlay(
                            controller: notebook.controller,
                            page: notebook.store.page(at: notebook.pageIndex, in: notebook.documentID),
                            logicalPageSize: TiyiCourseNotebook.pageSize,
                            logicalViewport: notebook.viewport.logicalBounds(in: geometry.size, referenceSize: TiyiCourseNotebook.pageSize),
                            background: notebook.backgroundPage,
                            isActive: notebook.tool == .lasso && !notebook.isMoving,
                            pageElements: $notebook.pageElements,
                            onPageElementsChanged: notebook.elementsChanged,
                            onNavigation: { notebook.navigate($0, size: geometry.size) })
                        .id("selection-\(notebook.pageIndex)-\(notebook.tool.rawValue)")
                    }
                    .overlay { CourseNotebookPalette(notebook: notebook).padding(.bottom, 48) }
                    .overlay(alignment: .bottomTrailing) {
                        Button { notebook.resetZoom() } label: {
                            Text("\(notebook.zoomPercentage)%")
                                .font(.system(size: 13, weight: .medium)).monospacedDigit()
                                .foregroundStyle(Color.black.opacity(0.7))
                                .frame(minWidth: 52, minHeight: 36)
                                .background(.white.opacity(0.9), in: Capsule())
                                .overlay(Capsule().stroke(Color.black.opacity(0.08), lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("画板缩放，点击恢复 100%")
                        .accessibilityValue("\(notebook.zoomPercentage)%")
                        .accessibilityIdentifier("course-notebook-zoom")
                        .padding(12)
                    }
            }.clipped()
        }
        .background(Color.white)
        .onDisappear { notebook.checkpoint() }
        .onChange(of: scenePhase) { _, phase in if phase != .active { notebook.checkpoint() } }
    }

}

private struct CourseNotebookPalette: View {
    @ObservedObject var notebook: TiyiCourseNotebook
    @AppStorage("tiyi.courses.palette.edge") private var edge = ToolPaletteDockEdge.leading
    @AppStorage("tiyi.courses.palette.progress") private var progress = 0.24
    @State private var showsPenSettings = false
    @State private var showsEraserSettings = false

    var body: some View {
        DockableToolPaletteView(selectedTool: $notebook.tool, selectedPenVariant: notebook.penVariant,
                                selectedColor: $notebook.color, penWidth: $notebook.width,
                                markerWidth: $notebook.markerWidth, eraserSize: $notebook.eraserSize,
                                dockEdge: $edge, dockProgress: $progress, commands: AnyView(commands), commandCount: 6,
                                selectionStyle: notebook.controller.selectionStyle)
    }

    @ViewBuilder private var commands: some View {
        DockPaletteButton(symbol: notebook.penVariant.symbolName, title: "画笔",
                          isSelected: notebook.tool.isPenVariant && !notebook.isMoving) {
            if notebook.tool.isPenVariant && !notebook.isMoving { showsPenSettings = true }
            else { notebook.tool = notebook.penVariant; notebook.isMoving = false }
        }
        .accessibilityIdentifier("tool-pen")
        .popover(isPresented: $showsPenSettings) {
            penSettings().presentationCompactAdaptation(.popover)
        }
        DockPaletteButton(symbol: CanvasToolKind.eraser.symbolName, title: "橡皮擦",
                          isSelected: notebook.tool == .eraser && !notebook.isMoving) {
            if notebook.tool == .eraser && !notebook.isMoving { showsEraserSettings = true }
            else { notebook.tool = .eraser; notebook.isMoving = false }
        }
        .accessibilityIdentifier("tool-eraser")
        .popover(isPresented: $showsEraserSettings) {
            VStack(alignment: .leading, spacing: 16) {
                Text("橡皮擦").font(.headline)
                Picker("擦除方式", selection: $notebook.eraserMode) {
                    ForEach(CanvasEraserMode.allCases) { mode in Text(mode.title).tag(mode) }
                }.pickerStyle(.segmented)
                Picker("橡皮大小", selection: $notebook.eraserSize) {
                    ForEach(CanvasEraserSize.allCases) { size in Text(size.title).tag(size) }
                }.pickerStyle(.segmented).disabled(notebook.eraserMode == .stroke)
            }.padding(16).frame(width: 280).presentationCompactAdaptation(.popover)
        }
        DockPaletteButton(symbol: CanvasToolKind.lasso.symbolName, title: "套索", isSelected: notebook.tool == .lasso) {
            notebook.tool = .lasso
            notebook.isMoving = false
        }
        .accessibilityIdentifier("tool-lasso")
        CourseNotebookHistory(controller: notebook.controller)
        Menu {
            Button("新增笔记页", systemImage: "plus.square") { notebook.addPage() }
            Section("笔记页面") {
                ForEach(0..<notebook.pageCount, id: \.self) { page in
                    Button { notebook.selectPage(page) } label: {
                        Label("第 \(page + 1) 页", systemImage: notebook.pageIndex == page ? "checkmark" : "doc")
                    }
                }
            }
            Button("复位画布", systemImage: "arrow.up.left.and.arrow.down.right") {
                notebook.viewport = CanvasViewport(referenceSize: TiyiCourseNotebook.pageSize)
                notebook.saveViewport()
            }
        } label: {
            DockPaletteIcon {
                VStack(spacing: 1) {
                    Image(systemName: "rectangle.on.rectangle").font(.system(size: 16, weight: .semibold))
                    Text("\(notebook.pageIndex + 1)/\(notebook.pageCount)").font(.system(size: 9)).monospacedDigit()
                }
            }
        }
        .accessibilityLabel("笔记页面，当前第 \(notebook.pageIndex + 1) 页，共 \(notebook.pageCount) 页")
        .accessibilityIdentifier("course-notebook-pages")
    }

    private func penSettings() -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("画笔").font(.headline)
            Picker("笔型", selection: $notebook.penVariant) {
                ForEach([CanvasToolKind.pen, .fountainPen, .pencil]) { variant in Text(variant.title).tag(variant) }
            }.pickerStyle(.segmented)
                .onChange(of: notebook.penVariant) { _, value in notebook.tool = value }
            HStack {
                Text("粗细")
                Slider(value: $notebook.width, in: 0.5...6, step: 0.5)
                    .accessibilityLabel("画笔粗细")
                Text(String(format: "%.1f", notebook.width)).monospacedDigit().frame(width: 34)
            }.font(.caption)
            HStack(spacing: 10) {
                ForEach(InkPaletteColor.allCases) { color in
                    Button { notebook.color = color } label: {
                        Circle().fill(color.color).frame(width: 26, height: 26)
                            .padding(3)
                            .overlay(Circle().stroke(notebook.color == color ? Color.primary : Color.clear, lineWidth: 1.5))
                    }.buttonStyle(.plain).accessibilityLabel(color.title)
                        .accessibilityAddTraits(notebook.color == color ? .isSelected : [])
                }
            }
        }.padding(16).frame(width: 280)
    }
}

private struct CourseNotebookHistory: View {
    @ObservedObject var controller: CanvasController
    var body: some View {
        DockPaletteButton(symbol: "arrow.uturn.backward", title: "撤销笔记", isEnabled: controller.canUndo, action: controller.undo)
        DockPaletteButton(symbol: "arrow.uturn.forward", title: "重做笔记", isEnabled: controller.canRedo, action: controller.redo)
    }
}
