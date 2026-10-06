#if !targetEnvironment(macCatalyst)
import SwiftUI
import PhotosUI
import AVFoundation

@MainActor final class DocumentScanModel: ObservableObject {
    enum Stage { case drafts, capture, review }
    @Published var stage = Stage.drafts
    @Published var draft: DocumentScanDraft?
    @Published var drafts: [DocumentScanDraft] = []
    @Published var busy = false
    @Published var status = ""
    @Published var errorMessage: String?
    @Published var replacingPageID: UUID?
    @Published var editingPage: DocumentScanPage?
    let store: DocumentScanStore
    let libraryID: String
    let folderID: String?

    init(libraryID: String, folderID: String?, store: DocumentScanStore = DocumentScanStore()) {
        self.libraryID = libraryID; self.folderID = folderID; self.store = store
    }
    func load() async {
        busy = true
        defer { busy = false }
        do {
            drafts = try await store.drafts(libraryID: libraryID, folderID: folderID)
            if drafts.isEmpty { draft = try await store.create(libraryID: libraryID, folderID: folderID); stage = .capture }
        } catch { errorMessage = error.localizedDescription }
    }
    func create() async {
        await change { try await self.store.create(libraryID: self.libraryID, folderID: self.folderID) }
        if draft != nil { stage = .capture }
    }
    func resume(_ selected: DocumentScanDraft) async {
        await change { try await self.store.load(selected.id) }
        if draft != nil { stage = .review }
    }
    func discard(_ selected: DocumentScanDraft) async {
        busy = true
        defer { busy = false }
        do { try await store.discard(selected.id); drafts.removeAll { $0.id == selected.id } }
        catch { errorMessage = error.localizedDescription }
    }
    func change(_ operation: () async throws -> DocumentScanDraft) async {
        guard !busy else { return }
        busy = true
        defer { busy = false; status = "" }
        do { draft = try await operation() }
        catch { errorMessage = error.localizedDescription }
    }
    func add(_ data: Data, selection: DocumentScanSelection? = nil, cameraCapture: Bool = false) async {
        guard !busy, let draft else { return }
        let replacing = replacingPageID
        var saved = false
        await change {
            self.status = "正在裁剪并保存页面…"
            let updated = try await self.store.append(data, to: draft.id, replacing: replacing, automaticallyCrop: !cameraCapture, selection: selection)
            saved = true
            return updated
        }
        if let replacing, saved { finishRetake(replacing) }
    }
    @discardableResult func beginRetake(_ pageID: UUID) -> Bool {
        guard !busy, draft?.pages.contains(where: { $0.id == pageID }) == true else { return false }
        replacingPageID = pageID
        editingPage = nil
        stage = .capture
        return true
    }
    func cancelRetake() -> DocumentScanPage? {
        guard !busy, let pageID = replacingPageID else { return nil }
        finishRetake(pageID)
        return editingPage
    }
    func finishRetake(_ pageID: UUID) {
        replacingPageID = nil
        stage = .review
        editingPage = draft?.pages.first(where: { $0.id == pageID })
    }
}

struct DocumentScanView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var model: DocumentScanModel
    @StateObject private var camera = DocumentScanCamera()
    @State private var photos: [PhotosPickerItem] = []
    @State private var discardDraft: DocumentScanDraft?
    @State private var pageToDelete: DocumentScanPage?
    @State private var title = ""
    @State private var saving = false
    private let onSave: (URL, DocumentScanDraft) async throws -> Void
    private let destinationName: String

    init(libraryID: String, folderID: String?, destinationName: String, onSave: @escaping (URL, DocumentScanDraft) async throws -> Void) {
        _model = StateObject(wrappedValue: DocumentScanModel(libraryID: libraryID, folderID: folderID))
        self.onSave = onSave; self.destinationName = destinationName
    }
    init(model: DocumentScanModel, destinationName: String, onSave: @escaping (URL, DocumentScanDraft) async throws -> Void) {
        _model = StateObject(wrappedValue: model)
        self.onSave = onSave; self.destinationName = destinationName
    }

    var body: some View {
        NavigationStack {
            Group {
                switch model.stage {
                case .drafts: draftList
                case .capture: captureSurface
                case .review: reviewSurface
                }
            }
            .navigationTitle(model.stage == .drafts ? "扫描草稿" : "扫描文稿")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(model.draft?.pages.isEmpty == false ? "保留并退出" : "关闭") {
                        Task { await retainTitle(); if model.errorMessage == nil { camera.stop(); dismiss() } }
                    }
                        .disabled(model.busy || saving)
                        .accessibilityIdentifier("scan-close")
                }
                if model.stage == .capture {
                    ToolbarItem(placement: .confirmationAction) {
                        if model.replacingPageID != nil {
                            Button("取消重拍") { _ = model.cancelRetake() }
                                .disabled(model.busy).accessibilityIdentifier("scan-cancel-retake")
                        } else {
                            Button("整理（\(model.draft?.pages.count ?? 0)）") { model.stage = .review }
                                .disabled(model.busy || model.draft?.pages.isEmpty != false)
                                .accessibilityIdentifier("scan-review")
                        }
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                if model.busy || saving {
                    HStack(spacing: 10) { ProgressView(); Text(model.status.isEmpty ? "正在处理…" : model.status).font(.callout) }
                        .frame(maxWidth: .infinity).padding().background(.regularMaterial)
                }
            }
            .background(TiyiNoteTheme.workspace)
        }
        .interactiveDismissDisabled(model.busy || saving)
        .task { await model.load(); title = model.draft?.title ?? ""; updateCamera() }
        .onChange(of: model.stage) { _, _ in updateCamera() }
        .onChange(of: model.draft?.id) { _, _ in title = model.draft?.title ?? "" }
        .onChange(of: scenePhase) { _, _ in updateCamera() }
        .onChange(of: model.editingPage?.id) { _, _ in updateCamera() }
        .onDisappear { camera.stop() }
        .onChange(of: photos) { _, selection in
            guard !selection.isEmpty else { return }
            Task {
                guard !model.busy, let draft = model.draft else { photos = []; return }
                model.busy = true
                model.status = "正在导入扫描页…"
                defer { model.busy = false; model.status = ""; photos = [] }
                let replacing = model.replacingPageID
                // Load and persist each asset separately, regardless of selection count.
                for item in selection {
                    do {
                        guard let data = try await item.loadTransferable(type: Data.self) else { throw DocumentScanError.invalidImage }
                        model.draft = try await model.store.append(data, to: draft.id, replacing: replacing)
                        if let replacing { model.finishRetake(replacing); break }
                    } catch { model.errorMessage = error.localizedDescription; break }
                }
            }
        }
        .sheet(item: $model.editingPage, onDismiss: updateCamera) { page in
            if let draft = model.draft {
                DocumentScanCropPager(pages: draft.pages, initialPageID: page.id, draftID: draft.id, store: model.store,
                    onRetake: { pageID in
                        model.beginRetake(pageID)
                    }) { crop, pageID in
                    model.busy = true
                    defer { model.busy = false }
                    let updated = try await model.store.setCrop(crop, pageID: pageID, draftID: draft.id)
                    model.draft = updated
                    return updated
                }
            }
        }
        .alert("扫描文稿", isPresented: Binding(get: { model.errorMessage != nil || camera.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil; camera.errorMessage = nil } })) {
            Button("好") { model.errorMessage = nil; camera.errorMessage = nil }
        } message: { Text(model.errorMessage ?? camera.errorMessage ?? "") }
        .confirmationDialog("删除这个扫描草稿？", isPresented: Binding(get: { discardDraft != nil }, set: { if !$0 { discardDraft = nil } }), titleVisibility: .visible) {
            Button("删除草稿", role: .destructive) { if let draft = discardDraft { Task { await model.discard(draft) } }; discardDraft = nil }
        } message: { Text("草稿中的扫描页面将被删除。") }
        .confirmationDialog("删除这一页？", isPresented: Binding(get: { pageToDelete != nil }, set: { if !$0 { pageToDelete = nil } }), titleVisibility: .visible) {
            Button("删除页面", role: .destructive) {
                if let page = pageToDelete, let draft = model.draft { Task { await model.change { try await model.store.remove(pageID: page.id, draftID: draft.id) } } }
                pageToDelete = nil
            }
        }
    }

    private var draftList: some View {
        List {
            Section { Button { Task { await model.create() } } label: { Label("开始新的扫描", systemImage: "doc.viewfinder") } }
            Section("\(destinationName) · 未完成的扫描") {
                ForEach(model.drafts) { draft in
                    Button { Task { await model.resume(draft) } } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(draft.title).foregroundStyle(TiyiNoteTheme.textPrimary)
                            Text("\(draft.pages.count) 页 · \(draft.updatedAt.formatted(date: .abbreviated, time: .shortened))").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .swipeActions { Button("删除", role: .destructive) { discardDraft = draft } }
                }
            }
        }
        .disabled(model.busy)
    }

    private var captureSurface: some View {
        VStack(spacing: 0) {
            ZStack {
                ScanCameraPreview(camera: camera)
                    .overlay {
                        if let selection = camera.liveSelection {
                            DocumentScanBoundaryOverlay(selection: selection, isStable: camera.isBoundaryStable)
                                .allowsHitTesting(false)
                        }
                    }
                if !camera.isReady {
                    VStack(spacing: 16) {
                        Image(systemName: camera.isDenied ? "camera.fill" : "camera").font(.system(size: 40))
                        Text(camera.isDenied ? "请允许 tiyi 使用相机" : camera.isUnavailable ? "相机暂不可用，可从相册添加图片" : "相机准备中，可先从相册导入").multilineTextAlignment(.center)
                        if camera.isDenied {
                            Button("打开设置") { if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) } }
                        }
                    }.foregroundStyle(.white).padding(28)
                }
                VStack {
                    Text(model.replacingPageID == nil ? "已保存 \(model.draft?.pages.count ?? 0) 页" : "重拍这一页")
                        .font(.callout.weight(.semibold)).padding(10).background(.black.opacity(0.6), in: Capsule()).padding(.top, 18)
                    Spacer()
                    Text(camera.liveSelection == nil ? "未识别纸张 · 调整位置或拍后手动裁剪" : camera.isBoundaryStable ? "边框已稳定 · 点击拍摄" : "已识别纸张 · 请保持手机稳定")
                        .font(.callout).multilineTextAlignment(.center).padding(12)
                        .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 18)).padding(.horizontal, 16).padding(.bottom, 20)
                }.foregroundStyle(.white).allowsHitTesting(false)
            }.background(.black).clipped()
            HStack {
                PhotosPicker(selection: $photos, maxSelectionCount: model.replacingPageID == nil ? nil : 1, matching: .images, photoLibrary: .shared()) {
                    Image(systemName: "photo.on.rectangle").font(.title2).frame(width: 64, height: 64)
                }.accessibilityLabel("从相册添加扫描页").disabled(model.busy)
                Spacer()
                Button {
                    Task {
                        guard !model.busy else { return }
                        model.busy = true
                        do {
                            let capture = try await camera.capture()
                            model.busy = false
                            await model.add(capture.data, selection: capture.selection, cameraCapture: true)
                        } catch { model.busy = false; model.errorMessage = error.localizedDescription }
                    }
                } label: {
                    Circle().fill(.white).frame(width: 64, height: 64).padding(5).overlay(Circle().stroke(.white, lineWidth: 3))
                }
                .disabled(!camera.isReady || model.busy).opacity(camera.isReady && !model.busy ? 1 : 0.4)
                .accessibilityLabel("扫描一页").accessibilityIdentifier("scan-shutter")
                Spacer()
                if let draft = model.draft,
                   let page = draft.pages.first(where: { $0.id == model.replacingPageID }) ?? draft.pages.last {
                    Button { model.editingPage = page } label: {
                        DocumentScanThumbnail(page: page, draftID: draft.id, store: model.store).frame(width: 56, height: 64).clipShape(RoundedRectangle(cornerRadius: 8))
                    }.accessibilityLabel("查看已扫描页面").disabled(model.busy)
                } else { Color.clear.frame(width: 64, height: 64) }
            }.foregroundStyle(.white).padding(.horizontal, 24).padding(.vertical, 18).background(.black)
        }
    }

    private var reviewSurface: some View {
        VStack(spacing: 0) {
            if let draft = model.draft {
                List {
                    Section {
                        TextField("文稿名称", text: $title).accessibilityIdentifier("scan-title")
                        Label(destinationName, systemImage: "folder").foregroundStyle(.secondary)
                    }
                    Section {
                        ForEach(Array(draft.pages.enumerated()), id: \.element.id) { index, page in
                            HStack(spacing: 14) {
                                Button { model.editingPage = page } label: {
                                    DocumentScanThumbnail(page: page, draftID: draft.id, store: model.store).frame(width: 64, height: 86)
                                }.buttonStyle(.plain).accessibilityLabel("调整第 \(index + 1) 页裁剪")
                                VStack(alignment: .leading, spacing: 6) {
                                    Text("第 \(index + 1) 页").font(.headline)
                                    Text(page.crop == .full ? "整张照片 · 可调整裁剪" : page.detectedEdges ? "已裁剪 · 可调整" : "已手动裁剪").font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Menu {
                                    Button("调整裁剪", systemImage: "crop") { model.editingPage = page }
                                    Button("顺时针旋转", systemImage: "rotate.right") { Task { await model.change { try await model.store.rotate(pageID: page.id, draftID: draft.id) } } }
                                    Button("重拍", systemImage: "camera") { model.beginRetake(page.id) }
                                    if index > 0 { Button("向前移一页", systemImage: "arrow.up") { move(index, to: index - 1, draft: draft) } }
                                    if index + 1 < draft.pages.count { Button("向后移一页", systemImage: "arrow.down") { move(index, to: index + 1, draft: draft) } }
                                    Button("删除", systemImage: "trash", role: .destructive) { pageToDelete = page }
                                } label: { Image(systemName: "ellipsis").frame(width: 44, height: 44) }.accessibilityLabel("第 \(index + 1) 页操作")
                            }.padding(.vertical, 4)
                        }
                    } header: { Text("已保存 \(draft.pages.count) 页") } footer: { Text("每页已保存在设备上，可以退出后继续扫描。") }
                }
                HStack(spacing: 16) {
                    Button("继续扫描", systemImage: "camera") {
                        Task { await retainTitle(); if model.errorMessage == nil { model.replacingPageID = nil; model.stage = .capture } }
                    }.buttonStyle(.bordered)
                    Button("保存 PDF") { Task { await save() } }.buttonStyle(.borderedProminent)
                        .disabled(draft.pages.isEmpty || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityIdentifier("scan-save")
                }.padding().frame(maxWidth: .infinity).background(TiyiNoteTheme.chrome)
            }
        }.disabled(model.busy || saving)
    }

    private func move(_ source: Int, to destination: Int, draft: DocumentScanDraft) {
        Task { await model.change { try await model.store.move(from: source, to: destination, draftID: draft.id) } }
    }
    private func retainTitle() async {
        guard let draft = model.draft, title != draft.title else { return }
        await model.change { try await model.store.rename(title, draftID: draft.id) }
    }
    private func updateCamera() {
        if scenePhase == .active && model.stage == .capture && model.editingPage == nil { camera.start() } else { camera.stop() }
    }
    private func save() async {
        guard let draft = model.draft, !saving, !model.busy else { return }
        saving = true
        defer { saving = false; model.status = "" }
        do {
            let updated = try await model.store.rename(title, draftID: draft.id)
            model.draft = updated
            model.status = "正在生成 \(updated.pages.count) 页 PDF…"
            let url = try await model.store.exportPDF(draft.id)
            do {
                model.status = "正在保存到文稿…"
                try await onSave(url, updated)
            } catch {
                try? FileManager.default.removeItem(at: url)
                throw error
            }
            // Import is committed. A cleanup failure must never offer a duplicate import retry.
            try? await model.store.discard(draft.id)
            dismiss()
        } catch { model.errorMessage = error.localizedDescription }
    }
}

private struct ScanCameraPreview: UIViewRepresentable {
    let camera: DocumentScanCamera
    func makeUIView(context: Context) -> DocumentScanPreviewView {
        let view = DocumentScanPreviewView()
        view.preview.session = camera.session
        view.preview.videoGravity = .resizeAspect
        view.onRotation = camera.setRotation
        view.backgroundColor = .black
        return view
    }
    func updateUIView(_ view: DocumentScanPreviewView, context: Context) { view.setNeedsLayout() }
}

struct DocumentScanBoundaryOverlay: View {
    let selection: DocumentScanSelection
    let isStable: Bool
    var body: some View {
        GeometryReader { geometry in
            let rect = DocumentScanPDFRenderer.aspectFitRect(for: selection.imageSize, in: geometry.size)
            let points = selection.crop.points.map { CGPoint(x: rect.minX + $0.x * rect.width, y: rect.minY + $0.y * rect.height) }
            let color: Color = isStable ? .green : .yellow
            let outline = Path { path in
                path.addLines(points)
                path.closeSubpath()
            }
            ZStack(alignment: .topLeading) {
                outline.fill(color.opacity(0.16))
                outline.stroke(color, lineWidth: 3)
                ForEach(points.indices, id: \.self) { index in
                    Circle().fill(color).frame(width: 9, height: 9).position(points[index])
                }
            }
        }.accessibilityLabel(isStable ? "纸张边框已稳定" : "已识别纸张边框")
    }
}

private struct DocumentScanThumbnail: View {
    let page: DocumentScanPage
    let draftID: UUID
    let store: DocumentScanStore
    @State private var image: UIImage?
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color(uiColor: .secondarySystemBackground)
                if let image {
                    let rotated = page.quarterTurns % 2 != 0
                    Image(uiImage: image).resizable().scaledToFit()
                        .frame(width: rotated ? geometry.size.height : geometry.size.width, height: rotated ? geometry.size.width : geometry.size.height)
                        .rotationEffect(.degrees(Double(page.quarterTurns) * 90))
                } else { Image(systemName: "doc").foregroundStyle(.secondary) }
            }.frame(width: geometry.size.width, height: geometry.size.height).clipped()
        }
        .task(id: page.imageName) { image = try? await store.preview(page, draftID: draftID, thumbnail: true) }
    }
}

/// Only the current page's full preview is mounted. A page turn checkpoints its crop before
/// changing selection, and a failed write keeps the current page and handles visible.
@MainActor final class DocumentScanCropPagerModel: ObservableObject {
    @Published private(set) var pages: [DocumentScanPage]
    @Published private(set) var selectedIndex: Int
    private var isMoving = false
    init(pages: [DocumentScanPage], initialPageID: UUID) {
        self.pages = pages
        selectedIndex = pages.firstIndex { $0.id == initialPageID } ?? 0
    }
    func move(_ direction: Int, crop: DocumentScanCrop,
              save: (DocumentScanCrop, UUID) async throws -> DocumentScanDraft) async throws {
        guard !isMoving, abs(direction) == 1, pages.indices.contains(selectedIndex),
              pages.indices.contains(selectedIndex + direction) else { return }
        guard crop.isValid else { throw DocumentScanError.invalidCrop }
        isMoving = true
        defer { isMoving = false }
        let current = pages[selectedIndex]
        let targetID = pages[selectedIndex + direction].id
        if crop != current.crop {
            let updated = try await save(crop, current.id)
            guard updated.pages.contains(where: { $0.id == current.id }), updated.pages.contains(where: { $0.id == targetID }) else {
                throw DocumentScanError.missingPage
            }
            pages = updated.pages
        }
        if let index = pages.firstIndex(where: { $0.id == targetID }) { selectedIndex = index }
    }
}

private struct DocumentScanCropPager: View {
    @StateObject private var model: DocumentScanCropPagerModel
    let draftID: UUID
    let store: DocumentScanStore
    let onRetake: (UUID) -> Void
    let onSave: (DocumentScanCrop, UUID) async throws -> DocumentScanDraft
    init(pages: [DocumentScanPage], initialPageID: UUID, draftID: UUID, store: DocumentScanStore,
         onRetake: @escaping (UUID) -> Void,
         onSave: @escaping (DocumentScanCrop, UUID) async throws -> DocumentScanDraft) {
        _model = StateObject(wrappedValue: DocumentScanCropPagerModel(pages: pages, initialPageID: initialPageID))
        self.draftID = draftID; self.store = store; self.onRetake = onRetake; self.onSave = onSave
    }
    var body: some View {
        if model.pages.indices.contains(model.selectedIndex) {
            let page = model.pages[model.selectedIndex]
            DocumentScanCropEditor(page: page, draftID: draftID, store: store,
                pageIndex: model.selectedIndex, pageCount: model.pages.count,
                onNavigate: { direction, crop in try await model.move(direction, crop: crop, save: onSave) },
                onRetake: { onRetake(page.id) }) { crop in
                    _ = try await onSave(crop, page.id)
                }
                .id(page.id)
        }
    }
}

struct DocumentScanCropEditor: View {
    @Environment(\.dismiss) private var dismiss
    let page: DocumentScanPage
    let draftID: UUID
    let store: DocumentScanStore
    let onSave: (DocumentScanCrop) async throws -> Void
    @State private var image: UIImage?
    @State private var correctedImage: UIImage?
    @State private var showsCorrected: Bool
    private let checksCapture: Bool
    private let pageIndex: Int
    private let pageCount: Int
    private let onNavigate: ((Int, DocumentScanCrop) async throws -> Void)?
    private let onRetake: (() -> Void)?
    @State private var points: [CGPoint] = []
    @State private var isDraggingCorner = false
    @State private var busy = false
    @State private var errorMessage: String?
    init(page: DocumentScanPage, draftID: UUID, store: DocumentScanStore, initiallyShowsResult: Bool = false,
         pageIndex: Int = 0, pageCount: Int = 1,
         onNavigate: ((Int, DocumentScanCrop) async throws -> Void)? = nil,
         onRetake: (() -> Void)? = nil,
         onSave: @escaping (DocumentScanCrop) async throws -> Void) {
        self.page = page; self.draftID = draftID; self.store = store; self.onSave = onSave
        checksCapture = initiallyShowsResult
        _showsCorrected = State(initialValue: initiallyShowsResult)
        self.pageIndex = pageIndex; self.pageCount = pageCount; self.onNavigate = onNavigate
        self.onRetake = onRetake
    }
    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                Picker("检查扫描", selection: $showsCorrected) {
                    Text("裁剪范围").tag(false)
                    Text("裁剪结果").tag(true)
                }.pickerStyle(.segmented).padding(.horizontal)
                Text(showsCorrected ? "检查文字和图形是否完整" : "拖动四个角，保留纸张内容").font(.callout).foregroundStyle(.secondary)
                GeometryReader { geometry in
                    Group {
                        if showsCorrected {
                            if let correctedImage {
                                Image(uiImage: correctedImage).resizable().scaledToFit()
                                    .frame(width: geometry.size.width, height: geometry.size.height)
                            } else { ProgressView().tint(.white).frame(maxWidth: .infinity, maxHeight: .infinity) }
                        } else if let image {
                            let rect = DocumentScanPDFRenderer.aspectFitRect(for: image.size, in: geometry.size)
                            ZStack(alignment: .topLeading) {
                                Image(uiImage: image).resizable().frame(width: rect.width, height: rect.height).position(x: rect.midX, y: rect.midY)
                                Path { path in
                                    for (index, point) in points.enumerated() {
                                        let p = CGPoint(x: rect.minX + point.x * rect.width, y: rect.minY + point.y * rect.height)
                                        if index == 0 { path.move(to: p) } else { path.addLine(to: p) }
                                    }
                                    path.closeSubpath()
                                }.stroke(.blue, lineWidth: 2)
                                ForEach(points.indices, id: \.self) { index in
                                    Circle().fill(.white).frame(width: 22, height: 22).overlay(Circle().stroke(.blue, lineWidth: 3))
                                        .frame(width: 44, height: 44).contentShape(Rectangle())
                                        .position(x: rect.minX + points[index].x * rect.width, y: rect.minY + points[index].y * rect.height)
                                        .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("scan-crop")).onChanged { value in
                                            isDraggingCorner = true
                                            points[index] = CGPoint(x: min(1, max(0, (value.location.x - rect.minX) / rect.width)),
                                                                    y: min(1, max(0, (value.location.y - rect.minY) / rect.height)))
                                        }.onEnded { _ in
                                            // Both simultaneous recognizers finish in the same event.
                                            // Keep this flag until the page-swipe recognizer has ended.
                                            DispatchQueue.main.async { isDraggingCorner = false }
                                        })
                                        .accessibilityLabel("裁剪角 \(index + 1)")
                                }
                            }
                        } else { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
                    }
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .coordinateSpace(name: "scan-crop")
                    .simultaneousGesture(DragGesture(minimumDistance: 25, coordinateSpace: .named("scan-crop")).onEnded { value in
                        guard let image, !busy, !isDraggingCorner, abs(value.translation.width) > 60,
                              abs(value.translation.width) > abs(value.translation.height) * 1.5 else { return }
                        let rect = DocumentScanPDFRenderer.aspectFitRect(for: image.size, in: geometry.size)
                        if !showsCorrected, points.contains(where: { point in
                            hypot(value.startLocation.x - rect.minX - point.x * rect.width,
                                  value.startLocation.y - rect.minY - point.y * rect.height) < 34
                        }) { return } // Moving a crop handle must never turn the page.
                        navigate(value.translation.width < 0 ? 1 : -1)
                    })
                    .disabled(busy)
                }.padding(24).background(Color.black.opacity(0.92))
                if onNavigate != nil {
                    HStack {
                        Button { navigate(-1) } label: { Image(systemName: "chevron.left").frame(width: 44, height: 36) }
                            .disabled(pageIndex == 0 || busy || image == nil).accessibilityLabel("上一页")
                        Spacer()
                        Text("第 \(pageIndex + 1) / \(pageCount) 页").font(.callout.monospacedDigit())
                        Spacer()
                        Button { navigate(1) } label: { Image(systemName: "chevron.right").frame(width: 44, height: 36) }
                            .disabled(pageIndex + 1 >= pageCount || busy || image == nil).accessibilityLabel("下一页")
                    }.padding(.horizontal)
                }
                HStack {
                    Button("恢复上次裁剪") { points = page.crop.points }
                    Spacer()
                    Button("保留整张照片") { points = DocumentScanCrop.full.points }
                }.font(.callout).padding(.horizontal).disabled(busy)
                if let onRetake {
                    Button("重拍这一页", systemImage: "camera") { onRetake() }
                        .buttonStyle(.bordered).disabled(busy)
                        .accessibilityIdentifier("scan-crop-retake")
                }
            }.padding(.vertical)
            .navigationTitle(checksCapture ? "检查扫描" : "调整裁剪").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(checksCapture ? "保留当前页" : "取消") { dismiss() }.disabled(busy) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") {
                        guard points.count == 4 else { return }
                        let crop = DocumentScanCrop(topLeft: points[0], topRight: points[1], bottomRight: points[2], bottomLeft: points[3])
                        guard crop.isValid else { errorMessage = DocumentScanError.invalidCrop.localizedDescription; return }
                        Task {
                            busy = true
                            defer { busy = false }
                            do { try await onSave(crop); dismiss() }
                            catch { errorMessage = error.localizedDescription }
                        }
                    }.disabled(busy || image == nil)
                }
            }
            .overlay { if busy { ProgressView("正在保存裁剪…").padding(24).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16)) } }
        }
        .interactiveDismissDisabled(busy)
        .task {
            points = page.crop.points
            do { image = try await store.preview(page, draftID: draftID, original: true) }
            catch { errorMessage = error.localizedDescription }
        }
        .task(id: showsCorrected ? points : []) {
            guard showsCorrected, points.count == 4 else { return }
            let crop = DocumentScanCrop(topLeft: points[0], topRight: points[1], bottomRight: points[2], bottomLeft: points[3])
            correctedImage = nil
            guard crop.isValid else { errorMessage = DocumentScanError.invalidCrop.localizedDescription; return }
            do {
                let preview = try await store.previewCrop(crop, page: page, draftID: draftID)
                guard !Task.isCancelled else { return }
                correctedImage = preview
            } catch { if !Task.isCancelled { errorMessage = error.localizedDescription } }
        }
        .alert("裁剪失败", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("好") { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
    }

    private func navigate(_ direction: Int) {
        guard !busy, image != nil, let onNavigate,
              (0..<pageCount).contains(pageIndex + direction), points.count == 4 else { return }
        let crop = DocumentScanCrop(topLeft: points[0], topRight: points[1], bottomRight: points[2], bottomLeft: points[3])
        Task {
            busy = true
            defer { busy = false }
            do { try await onNavigate(direction, crop) }
            catch { errorMessage = error.localizedDescription }
        }
    }
}
#endif
