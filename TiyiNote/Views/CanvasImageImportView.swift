import SwiftUI
import PhotosUI
import UIKit

enum CanvasImageSource { case camera, photos, file(Data) }

struct CanvasImageImportSession: Identifiable {
    let id = UUID()
    let documentID: String
    let pageID: String
    let source: CanvasImageSource
}

/// Focused surface: a stable action bar and one image workspace, with no nested scrolling panes.
struct CanvasImageImportView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    let source: CanvasImageSource
    let onInsert: (Data) throws -> Void
    @State private var processor = CanvasImageProcessor()
#if !targetEnvironment(macCatalyst)
    @StateObject private var camera = DocumentScanCamera(detectsDocumentEdges: false)
#endif
    @State private var preview: UIImage?
    @State private var selection = CanvasImageCropGeometry.full
    @State private var photo: PhotosPickerItem?
    @State private var showsPhotos = false
    @State private var busy = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                if let preview {
                    Text("拖动框选，拖动边角调整范围，拖动框内移动选区")
                        .font(.callout).foregroundStyle(TiyiNoteTheme.textSecondary)
                        .padding(.horizontal)
                    CanvasImageCropSurface(image: preview, selection: $selection)
                        .padding(.horizontal, 24).padding(.vertical, 12)
                        .allowsHitTesting(!busy)
                    cropActions
                } else {
                    captureSurface
                }
            }
            .background(TiyiNoteTheme.workspace)
            .navigationTitle(preview == nil ? "添加图片" : "框选图片")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }.disabled(busy).accessibilityIdentifier("canvas-image-cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    if preview != nil {
                        Button("插入画板", action: insert).fontWeight(.semibold).disabled(busy)
                            .accessibilityIdentifier("canvas-image-insert")
                    }
                }
            }
            .overlay {
                if busy {
                    ProgressView("正在处理图片…").padding(24)
                        .background(TiyiNoteTheme.surface, in: RoundedRectangle(cornerRadius: 12))
                }
            }
        }
        .interactiveDismissDisabled(busy)
        .photosPicker(isPresented: $showsPhotos, selection: $photo, matching: .images)
        .task {
            switch source {
            case .camera: updateCamera()
            case .photos: showsPhotos = true
            case .file(let data): await load(data)
            }
        }
        .onChange(of: photo) { _, item in
            guard let item, !busy else { return }
            busy = true
            Task {
                defer { busy = false; photo = nil; updateCamera() }
                do {
                    guard let data = try await item.loadTransferable(type: Data.self) else {
                        throw CanvasImageImportError.invalidImage
                    }
                    preview = try await decodedPreview(data)
                    selection = CanvasImageCropGeometry.full
                } catch { errorMessage = error.localizedDescription }
            }
        }
        .onChange(of: showsPhotos) { _, _ in updateCamera() }
        .onChange(of: scenePhase) { _, _ in updateCamera() }
        .onDisappear { stopCamera() }
        .alert("无法添加图片", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("好", role: .cancel) { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
    }

    private var cropActions: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 20) { cropButtons }
            HStack(spacing: 8) { cropButtons }.font(.caption)
        }
        .buttonStyle(.bordered).disabled(busy)
        .padding(.horizontal).padding(.bottom, 16)
    }

    @ViewBuilder private var cropButtons: some View {
        if case .camera = source {
            Button("重拍", systemImage: "camera") { preview = nil; updateCamera() }
                .accessibilityIdentifier("canvas-image-retake")
        }
        Button("旋转", systemImage: "rotate.right") {
            busy = true
            Task {
                defer { busy = false }
                do {
                    guard let rotated = UIImage(data: try await processor.rotate()) else {
                        throw CanvasImageImportError.invalidImage
                    }
                    preview = rotated
                    selection = CGRect(x: 1 - selection.maxY, y: selection.minX,
                                       width: selection.height, height: selection.width)
                } catch { errorMessage = error.localizedDescription }
            }
        }.accessibilityIdentifier("canvas-image-rotate")
        Button("重置", systemImage: "arrow.counterclockwise") { selection = CanvasImageCropGeometry.full }
            .accessibilityIdentifier("canvas-image-reset")
        Button("选择照片", systemImage: "photo") { showsPhotos = true }
            .accessibilityIdentifier("canvas-image-photos")
    }

    @ViewBuilder private var captureSurface: some View {
#if !targetEnvironment(macCatalyst)
        if case .camera = source {
            ZStack {
                CanvasPhotoPreview(camera: camera)
                if !camera.isReady && !usesFixture {
                    VStack(spacing: 16) {
                        Image(systemName: "camera").font(.largeTitle)
                        Text(camera.isDenied ? "请允许 Tiyi 使用相机" : camera.isUnavailable ? "相机暂不可用" : "正在准备相机…")
                        if camera.isDenied {
                            Button("打开设置") {
                                if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                            }
                        }
                        if let message = camera.errorMessage { Text(message).font(.caption) }
                    }.padding().frame(maxWidth: .infinity, maxHeight: .infinity).background(TiyiNoteTheme.workspace)
                }
            }
            .clipped()
            HStack(spacing: 32) {
                Button("从相册选择", systemImage: "photo") { showsPhotos = true }
                Button(action: capture) {
                    Image(systemName: "camera.fill").font(.title2).frame(width: 64, height: 64)
                }
                .buttonStyle(.borderedProminent).clipShape(Circle())
                .disabled((!camera.isReady && !usesFixture) || busy)
                .accessibilityLabel("拍照").accessibilityIdentifier("canvas-image-shutter")
            }.disabled(busy).padding(.bottom, 16)
        } else {
            photoPlaceholder
        }
#else
        photoPlaceholder
#endif
    }

    private var photoPlaceholder: some View {
        VStack(spacing: 20) {
            Image(systemName: "photo").font(.largeTitle).foregroundStyle(TiyiNoteTheme.textSecondary)
            Text("选择图片后，框选需要放到画板的部分")
            Button("从相册选择") { showsPhotos = true }.buttonStyle(.borderedProminent)
            if case .file(let data) = source {
                Button("重新读取图片") { Task { await load(data) } }.disabled(busy)
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func decodedPreview(_ data: Data) async throws -> UIImage {
        guard let image = UIImage(data: try await processor.load(data)) else { throw CanvasImageImportError.invalidImage }
        return image
    }

    private func load(_ data: Data) async {
        guard !busy else { return }
        busy = true
        defer { busy = false; updateCamera() }
        do {
            preview = try await decodedPreview(data)
            selection = CanvasImageCropGeometry.full
        } catch { errorMessage = error.localizedDescription }
    }

    private func insert() {
        guard !busy, preview != nil else { return }
        busy = true
        Task {
            defer { busy = false }
            do {
                let data = try await processor.crop(selection)
                try onInsert(data)
                dismiss()
            } catch { errorMessage = error.localizedDescription }
        }
    }

    private var usesFixture: Bool {
#if DEBUG && targetEnvironment(simulator)
        ProcessInfo.processInfo.arguments.contains("--canvas-photo-ui-test")
#else
        false
#endif
    }

    private func capture() {
#if !targetEnvironment(macCatalyst)
        guard !busy else { return }
        busy = true
        Task {
            defer { busy = false; updateCamera() }
            do {
                let data: Data
#if DEBUG && targetEnvironment(simulator)
                if usesFixture {
                    data = CanvasPhotoTestFixture.data()
                } else { data = try await camera.capture().data }
#else
                data = try await camera.capture().data
#endif
                stopCamera()
                preview = try await decodedPreview(data)
                selection = CanvasImageCropGeometry.full
            } catch { errorMessage = error.localizedDescription }
        }
#endif
    }

    private func updateCamera() {
#if !targetEnvironment(macCatalyst)
        guard case .camera = source else { return }
        if preview == nil && !showsPhotos && !busy && scenePhase == .active && !usesFixture { camera.start() }
        else { camera.stop() }
#endif
    }

    private func stopCamera() {
#if !targetEnvironment(macCatalyst)
        camera.stop()
#endif
    }
}

private struct CanvasImageCropSurface: View {
    let image: UIImage
    @Binding var selection: CGRect
    @State private var dragOrigin: CGRect?
    @State private var movesSelection = false
    @State private var resizeOrigin: CGRect?

    var body: some View {
        GeometryReader { geometry in
            let imageRect = CanvasImageCropGeometry.aspectFit(image.size, in: geometry.size)
            let box = CGRect(x: imageRect.minX + selection.minX * imageRect.width,
                             y: imageRect.minY + selection.minY * imageRect.height,
                             width: selection.width * imageRect.width, height: selection.height * imageRect.height)
            ZStack(alignment: .topLeading) {
                Image(uiImage: image).resizable().frame(width: imageRect.width, height: imageRect.height)
                    .position(x: imageRect.midX, y: imageRect.midY)
                    .accessibilityHidden(true)
                Path { path in path.addRect(imageRect); path.addRect(box) }
                    .fill(.black.opacity(0.45), style: FillStyle(eoFill: true)).allowsHitTesting(false)
                Color.clear.contentShape(Rectangle())
                    .frame(width: imageRect.width, height: imageRect.height)
                    .position(x: imageRect.midX, y: imageRect.midY)
                    .gesture(DragGesture(minimumDistance: 2, coordinateSpace: .named("canvas-image-crop")).onChanged { value in
                        let start = CanvasImageCropGeometry.point(value.startLocation, in: imageRect)
                        if dragOrigin == nil {
                            dragOrigin = selection
                            movesSelection = selection != CanvasImageCropGeometry.full && selection.contains(start)
                        }
                        if movesSelection, let origin = dragOrigin {
                            selection = CanvasImageCropGeometry.moved(origin, by: CGSize(
                                width: value.translation.width / max(imageRect.width, 1),
                                height: value.translation.height / max(imageRect.height, 1)))
                        } else {
                            selection = CanvasImageCropGeometry.selection(from: start,
                                to: CanvasImageCropGeometry.point(value.location, in: imageRect))
                        }
                    }.onEnded { _ in dragOrigin = nil })
                    .accessibilityElement()
                    .accessibilityLabel("照片框选区域")
                    .accessibilityIdentifier("canvas-image-crop-surface")
                Rectangle().stroke(TiyiNoteTheme.selectionBlue, lineWidth: 2)
                    .frame(width: box.width, height: box.height).position(x: box.midX, y: box.midY)
                    .allowsHitTesting(false)
                ForEach(0..<8, id: \.self) { handle in
                    Circle().fill(.white).frame(width: 12, height: 12)
                        .overlay(Circle().stroke(TiyiNoteTheme.selectionBlue, lineWidth: 2))
                        .frame(width: 44, height: 44).contentShape(Rectangle())
                        .position(CanvasImageCropGeometry.handlePoint(handle, in: box))
                        .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("canvas-image-crop")).onChanged { value in
                            if resizeOrigin == nil { resizeOrigin = selection }
                            guard let origin = resizeOrigin else { return }
                            let point = CanvasImageCropGeometry.handlePoint(handle, in: origin)
                            selection = CanvasImageCropGeometry.resized(origin, handle: handle,
                                to: CGPoint(x: point.x + value.translation.width / max(imageRect.width, 1),
                                            y: point.y + value.translation.height / max(imageRect.height, 1)))
                        }.onEnded { _ in resizeOrigin = nil })
                        .accessibilityLabel(["左上角", "上边", "右上角", "右边", "右下角", "下边", "左下角", "左边"][handle])
                        .accessibilityIdentifier("canvas-image-crop-handle-\(handle)")
                }
            }
            .coordinateSpace(name: "canvas-image-crop")
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("canvas-image-crop-workspace")
            .accessibilityValue("范围 \(Int((selection.minX * 100).rounded())),\(Int((selection.minY * 100).rounded())),\(Int((selection.width * 100).rounded())),\(Int((selection.height * 100).rounded()))")
        }
    }
}

#if !targetEnvironment(macCatalyst)
private struct CanvasPhotoPreview: UIViewRepresentable {
    let camera: DocumentScanCamera
    func makeUIView(context: Context) -> DocumentScanPreviewView {
        let view = DocumentScanPreviewView()
        view.preview.session = camera.session
        view.preview.videoGravity = .resizeAspectFill
        view.onRotation = { camera.setRotation($0) }
        return view
    }
    func updateUIView(_ view: DocumentScanPreviewView, context: Context) {}
}
#endif

#if DEBUG && targetEnvironment(simulator)
enum CanvasPhotoTestFixture {
    static func data() -> Data {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
        return UIGraphicsImageRenderer(size: CGSize(width: 1200, height: 900), format: format).image { context in
            UIColor.white.setFill(); context.fill(CGRect(x: 0, y: 0, width: 1200, height: 900))
            UIColor.systemBlue.setFill(); context.fill(CGRect(x: 0, y: 0, width: 600, height: 450))
            UIColor.systemOrange.setFill(); context.fill(CGRect(x: 600, y: 450, width: 600, height: 450))
            ("已知 x² + 1 = 5，求 x 的值。" as NSString).draw(at: CGPoint(x: 100, y: 520),
                withAttributes: [.font: UIFont.systemFont(ofSize: 38), .foregroundColor: UIColor.black])
        }.pngData()!
    }
}
#endif
