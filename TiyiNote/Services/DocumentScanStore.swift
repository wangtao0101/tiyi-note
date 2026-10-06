import Foundation
import UIKit
import ImageIO
import Vision
import CoreImage

/// Coordinates are normalized in the upright original image, with the origin at top left.
struct DocumentScanCrop: Codable, Equatable, Sendable {
    var topLeft: CGPoint
    var topRight: CGPoint
    var bottomRight: CGPoint
    var bottomLeft: CGPoint

    static let full = Self(topLeft: .zero, topRight: CGPoint(x: 1, y: 0),
                           bottomRight: CGPoint(x: 1, y: 1), bottomLeft: CGPoint(x: 0, y: 1))
    var points: [CGPoint] { [topLeft, topRight, bottomRight, bottomLeft] }
    var isValid: Bool {
        let p = points
        guard p.allSatisfy({ $0.x.isFinite && $0.y.isFinite && (0...1).contains($0.x) && (0...1).contains($0.y) }) else { return false }
        // Convex, clockwise and large enough to avoid crossed or collapsed crop handles.
        let crosses = (0..<4).map { i in
            let a = p[i], b = p[(i + 1) % 4], c = p[(i + 2) % 4]
            return (b.x - a.x) * (c.y - b.y) - (b.y - a.y) * (c.x - b.x)
        }
        let area = abs((0..<4).reduce(CGFloat.zero) { sum, i in
            sum + p[i].x * p[(i + 1) % 4].y - p[(i + 1) % 4].x * p[i].y
        }) / 2
        return crosses.allSatisfy { $0 > 0.0001 } && area > 0.01
    }
}

/// A shutter-time selection from the upright video frame. Photo and video can have different
/// aspect ratios; map the preview's centered field of view into the upright original photo.
struct DocumentScanSelection: Equatable, Sendable {
    var crop: DocumentScanCrop
    var imageSize: CGSize
    func crop(in photoSize: CGSize) -> DocumentScanCrop {
        let sourceAspect = imageSize.width / max(imageSize.height, 1)
        let targetAspect = photoSize.width / max(photoSize.height, 1)
        let scaleX = min(1, sourceAspect / targetAspect)
        let scaleY = min(1, targetAspect / sourceAspect)
        if scaleX == 1 && scaleY == 1 { return crop }
        func map(_ point: CGPoint) -> CGPoint {
            CGPoint(x: 0.5 + (point.x - 0.5) * scaleX, y: 0.5 + (point.y - 0.5) * scaleY)
        }
        return DocumentScanCrop(topLeft: map(crop.topLeft), topRight: map(crop.topRight),
            bottomRight: map(crop.bottomRight), bottomLeft: map(crop.bottomLeft))
    }
}

struct DocumentScanPage: Codable, Identifiable, Equatable, Sendable {
    var id: UUID
    var assetID: UUID
    var imageName: String
    var thumbnailName: String
    var crop: DocumentScanCrop
    var quarterTurns = 0
    var detectedEdges: Bool
}

struct DocumentScanDraft: Codable, Identifiable, Equatable, Sendable {
    var id: UUID
    var libraryID: String
    var folderID: String?
    var title: String
    var updatedAt: Date
    var pages: [DocumentScanPage]
}

enum DocumentScanError: LocalizedError {
    case invalidImage, invalidCrop, empty, missingPage, lowStorage
    var errorDescription: String? {
        switch self {
        case .invalidImage: "无法读取这张照片，请重拍。"
        case .invalidCrop: "裁剪范围无效，请调整四个角。"
        case .empty: "请先扫描至少一页。"
        case .missingPage: "扫描页面文件不完整，草稿已保留，请重拍这一页。"
        case .lowStorage: "设备可用空间不足，请释放空间后继续。已有页面已保留。"
        }
    }
}

/// Serializes disk transactions and processing. The manifest is committed only after its assets
/// are durable; UI page counts always represent saved pages. No array of full-resolution images.
actor DocumentScanStore {
    let root: URL
    private let context = CIContext(options: [.cacheIntermediates: false])

    init(root: URL = URL.applicationSupportDirectory.appendingPathComponent("TiyiDocumentScans", isDirectory: true)) {
        self.root = root
    }

    func drafts(libraryID: String, folderID: String?) throws -> [DocumentScanDraft] {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .compactMap { directory -> DocumentScanDraft? in
                guard let id = UUID(uuidString: directory.lastPathComponent) else { return nil }
                return try load(id)
            }
            .filter { $0.libraryID == libraryID && $0.folderID == folderID }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    func create(libraryID: String, folderID: String?) throws -> DocumentScanDraft {
        let draft = DocumentScanDraft(id: UUID(), libraryID: libraryID, folderID: folderID,
            title: "扫描文稿 " + Date().formatted(.dateTime.year().month().day()), updatedAt: Date(), pages: [])
        try persist(draft)
        return draft
    }

    func load(_ id: UUID) throws -> DocumentScanDraft {
        let draft = try JSONDecoder().decode(DocumentScanDraft.self, from: Data(contentsOf: directory(id).appendingPathComponent("draft.json")))
        guard draft.id == id else { throw DocumentScanError.missingPage }
        return draft
    }

    func append(_ data: Data, to id: UUID, replacing pageID: UUID? = nil, automaticallyCrop: Bool = true, selection: DocumentScanSelection? = nil) throws -> DocumentScanDraft {
        var draft = try load(id)
        if let pageID, !draft.pages.contains(where: { $0.id == pageID }) { throw DocumentScanError.missingPage }
        try checkStorage()
        let assetID = UUID()
        let asset = directory(id).appendingPathComponent(assetID.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: asset, withIntermediateDirectories: true)
        do {
            let original = asset.appendingPathComponent("original.photo")
            try data.write(to: original, options: .atomic)
            let page = try autoreleasepool { () throws -> DocumentScanPage in
                let image = try Self.decode(original, maximumDimension: 4096)
                let crop = selection?.crop(in: CGSize(width: image.width, height: image.height))
                    ?? (automaticallyCrop ? Self.detectCrop(image) : nil)
                if let crop, !crop.isValid { throw DocumentScanError.invalidCrop }
                let rendered = try render(image, crop: crop ?? .full, in: asset)
                return DocumentScanPage(id: pageID ?? UUID(), assetID: assetID,
                    imageName: rendered.0, thumbnailName: rendered.1,
                    crop: crop ?? .full, detectedEdges: crop != nil)
            }
            let previous = pageID.flatMap { target in draft.pages.first { $0.id == target } }
            if let index = draft.pages.firstIndex(where: { $0.id == pageID }) { draft.pages[index] = page }
            else { draft.pages.append(page) }
            try persist(draft)
            if let previous { try? FileManager.default.removeItem(at: assetDirectory(previous, draftID: id)) }
            return try load(id)
        } catch {
            try? FileManager.default.removeItem(at: asset)
            throw error
        }
    }

    func setCrop(_ crop: DocumentScanCrop, pageID: UUID, draftID: UUID) throws -> DocumentScanDraft {
        guard crop.isValid else { throw DocumentScanError.invalidCrop }
        var draft = try load(draftID)
        guard let index = draft.pages.firstIndex(where: { $0.id == pageID }) else { throw DocumentScanError.missingPage }
        let previous = draft.pages[index]
        let asset = assetDirectory(previous, draftID: draftID)
        try checkStorage()
        let rendered = try autoreleasepool {
            try render(Self.decode(asset.appendingPathComponent("original.photo"), maximumDimension: 4096), crop: crop, in: asset)
        }
        draft.pages[index].imageName = rendered.0
        draft.pages[index].thumbnailName = rendered.1
        draft.pages[index].crop = crop
        do { try persist(draft) }
        catch {
            try? FileManager.default.removeItem(at: asset.appendingPathComponent(rendered.0))
            try? FileManager.default.removeItem(at: asset.appendingPathComponent(rendered.1))
            throw error
        }
        try? FileManager.default.removeItem(at: asset.appendingPathComponent(previous.imageName))
        try? FileManager.default.removeItem(at: asset.appendingPathComponent(previous.thumbnailName))
        return try load(draftID)
    }

    func rotate(pageID: UUID, draftID: UUID) throws -> DocumentScanDraft {
        var draft = try load(draftID)
        guard let index = draft.pages.firstIndex(where: { $0.id == pageID }) else { throw DocumentScanError.missingPage }
        draft.pages[index].quarterTurns = (draft.pages[index].quarterTurns + 1) % 4
        try persist(draft)
        return try load(draftID)
    }

    func move(from source: Int, to destination: Int, draftID: UUID) throws -> DocumentScanDraft {
        var draft = try load(draftID)
        guard draft.pages.indices.contains(source), draft.pages.indices.contains(destination) else { throw DocumentScanError.missingPage }
        let page = draft.pages.remove(at: source)
        draft.pages.insert(page, at: destination)
        try persist(draft)
        return try load(draftID)
    }

    func remove(pageID: UUID, draftID: UUID) throws -> DocumentScanDraft {
        var draft = try load(draftID)
        guard let page = draft.pages.first(where: { $0.id == pageID }) else { throw DocumentScanError.missingPage }
        draft.pages.removeAll { $0.id == pageID }
        try persist(draft)
        try? FileManager.default.removeItem(at: assetDirectory(page, draftID: draftID))
        return try load(draftID)
    }

    func rename(_ title: String, draftID: UUID) throws -> DocumentScanDraft {
        var draft = try load(draftID)
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { draft.title = trimmed }
        try persist(draft)
        return try load(draftID)
    }

    func discard(_ id: UUID) throws { try FileManager.default.removeItem(at: directory(id)) }

    func preview(_ page: DocumentScanPage, draftID: UUID, original: Bool = false, thumbnail: Bool = false) throws -> UIImage {
        let name = original ? "original.photo" : thumbnail ? page.thumbnailName : page.imageName
        return UIImage(cgImage: try Self.decode(assetDirectory(page, draftID: draftID).appendingPathComponent(name), maximumDimension: thumbnail ? 320 : 1600))
    }

    func previewCrop(_ crop: DocumentScanCrop, page: DocumentScanPage, draftID: UUID) throws -> UIImage {
        guard crop.isValid else { throw DocumentScanError.invalidCrop }
        return try autoreleasepool {
            let original = try Self.decode(assetDirectory(page, draftID: draftID).appendingPathComponent("original.photo"), maximumDimension: 1600)
            return UIImage(cgImage: try applyCrop(original, crop: crop))
        }
    }

    /// Writes one page at a time to a file; Core Graphics embeds each JPEG without accumulating
    /// UIImage/PDFPage objects for the whole document. Partial output never enters the library.
    func exportPDF(_ id: UUID) throws -> URL {
        let draft = try load(id)
        guard !draft.pages.isEmpty else { throw DocumentScanError.empty }
        try checkStorage()
        let url = directory(id).appendingPathComponent("export-" + UUID().uuidString + ".pdf")
        guard let pdf = CGContext(url as CFURL, mediaBox: nil, nil) else { throw CocoaError(.fileWriteUnknown) }
        do {
            for page in draft.pages {
                try Task.checkCancellation()
                try autoreleasepool {
                    let imageURL = assetDirectory(page, draftID: id).appendingPathComponent(page.imageName)
                    guard let provider = CGDataProvider(url: imageURL as CFURL),
                          let image = CGImage(jpegDataProviderSource: provider, decode: nil,
                                              shouldInterpolate: true, intent: .defaultIntent) else { throw DocumentScanError.missingPage }
                    let rotated = page.quarterTurns % 2 != 0
                    let size = CGSize(width: rotated ? image.height : image.width, height: rotated ? image.width : image.height)
                    let paper = size.width > size.height ? CGSize(width: 842, height: 595) : CGSize(width: 595, height: 842)
                    let rect = DocumentScanPDFRenderer.aspectFitRect(for: size, in: paper)
                    pdf.beginPDFPage([kCGPDFContextMediaBox as String: NSData(bytes: [CGRect(origin: .zero, size: paper)], length: MemoryLayout<CGRect>.size)] as CFDictionary)
                    pdf.setFillColor(UIColor.white.cgColor)
                    pdf.fill(CGRect(origin: .zero, size: paper))
                    pdf.saveGState()
                    pdf.translateBy(x: rect.midX, y: rect.midY)
                    pdf.rotate(by: -CGFloat(page.quarterTurns) * .pi / 2)
                    let scale = rect.width / size.width
                    let w = CGFloat(image.width) * scale, h = CGFloat(image.height) * scale
                    pdf.draw(image, in: CGRect(x: -w / 2, y: -h / 2, width: w, height: h))
                    pdf.restoreGState()
                    pdf.endPDFPage()
                }
            }
            pdf.closePDF()
            guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) > 0 else { throw CocoaError(.fileWriteUnknown) }
            return url
        } catch {
            pdf.closePDF()
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }

    private func directory(_ id: UUID) -> URL { root.appendingPathComponent(id.uuidString, isDirectory: true) }
    private func assetDirectory(_ page: DocumentScanPage, draftID: UUID) -> URL { directory(draftID).appendingPathComponent(page.assetID.uuidString, isDirectory: true) }
    private func persist(_ value: DocumentScanDraft) throws {
        var draft = value
        draft.updatedAt = Date()
        try FileManager.default.createDirectory(at: directory(draft.id), withIntermediateDirectories: true)
        try JSONEncoder().encode(draft).write(to: directory(draft.id).appendingPathComponent("draft.json"), options: .atomic)
    }
    private func checkStorage() throws {
        if let available = try? root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage,
           available < 150 * 1024 * 1024 { throw DocumentScanError.lowStorage }
    }
    private static func decode(_ url: URL, maximumDimension: Int) throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maximumDimension,
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) else { throw DocumentScanError.invalidImage }
        return image
    }
    private static func detectCrop(_ image: CGImage) -> DocumentScanCrop? {
        let request = VNDetectDocumentSegmentationRequest()
        guard (try? VNImageRequestHandler(cgImage: image, options: [:]).perform([request])) != nil,
              let observation = request.results?.first, observation.confidence >= 0.5 else { return nil }
        func flip(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x, y: 1 - p.y) }
        let crop = DocumentScanCrop(topLeft: flip(observation.topLeft), topRight: flip(observation.topRight),
            bottomRight: flip(observation.bottomRight), bottomLeft: flip(observation.bottomLeft))
        return crop.isValid ? crop : nil
    }
    private func render(_ image: CGImage, crop: DocumentScanCrop, in asset: URL) throws -> (String, String) {
        let output = try applyCrop(image, crop: crop)
        let version = UUID().uuidString
        let imageName = version + ".jpg", thumbnailName = version + "-thumb.jpg"
        let imageURL = asset.appendingPathComponent(imageName)
        let thumbnailURL = asset.appendingPathComponent(thumbnailName)
        do {
            try Self.writeJPEG(output, to: imageURL)
            try Self.writeJPEG(Self.decode(imageURL, maximumDimension: 320), to: thumbnailURL)
            return (imageName, thumbnailName)
        } catch {
            try? FileManager.default.removeItem(at: imageURL)
            try? FileManager.default.removeItem(at: thumbnailURL)
            throw error
        }
    }
    private func applyCrop(_ image: CGImage, crop: DocumentScanCrop) throws -> CGImage {
        let input = CIImage(cgImage: image)
        let output: CGImage
        if crop == .full { output = image }
        else {
            func vector(_ p: CGPoint) -> CIVector { CIVector(x: p.x * CGFloat(image.width), y: (1 - p.y) * CGFloat(image.height)) }
            let adjusted = input.applyingFilter("CIPerspectiveCorrection", parameters: [
                "inputTopLeft": vector(crop.topLeft), "inputTopRight": vector(crop.topRight),
                "inputBottomRight": vector(crop.bottomRight), "inputBottomLeft": vector(crop.bottomLeft)
            ])
            guard let result = context.createCGImage(adjusted, from: adjusted.extent) else { throw DocumentScanError.invalidCrop }
            output = result
        }
        return output
    }
    private static func writeJPEG(_ image: CGImage, to url: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil) else { throw CocoaError(.fileWriteUnknown) }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.92] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
    }
}
