import Foundation
import CoreGraphics
import CoreImage
import ImageIO
import UniformTypeIdentifiers

/// Rectangles use the displayed image's top-left origin, independent of screen size and rotation.
enum CanvasImageCropGeometry {
    static let full = CGRect(x: 0, y: 0, width: 1, height: 1)

    static func aspectFit(_ size: CGSize, in container: CGSize) -> CGRect {
        let scale = min(container.width / max(size.width, 1), container.height / max(size.height, 1))
        let fitted = CGSize(width: size.width * scale, height: size.height * scale)
        return CGRect(x: (container.width - fitted.width) / 2, y: (container.height - fitted.height) / 2,
                      width: fitted.width, height: fitted.height)
    }

    static func point(_ point: CGPoint, in imageRect: CGRect) -> CGPoint {
        CGPoint(x: min(1, max(0, (point.x - imageRect.minX) / max(imageRect.width, 1))),
                y: min(1, max(0, (point.y - imageRect.minY) / max(imageRect.height, 1))))
    }

    static func selection(from start: CGPoint, to end: CGPoint) -> CGRect {
        let width = min(1, max(0.02, abs(end.x - start.x)))
        let height = min(1, max(0.02, abs(end.y - start.y)))
        return CGRect(x: max(0, min(1 - width, min(start.x, end.x))),
                      y: max(0, min(1 - height, min(start.y, end.y))), width: width, height: height)
    }

    static func moved(_ rect: CGRect, by delta: CGSize) -> CGRect {
        CGRect(x: min(1 - rect.width, max(0, rect.minX + delta.width)),
               y: min(1 - rect.height, max(0, rect.minY + delta.height)),
               width: rect.width, height: rect.height)
    }

    static func resized(_ rect: CGRect, handle: Int, to point: CGPoint) -> CGRect {
        // Clockwise: TL, top, TR, right, BR, bottom, BL, left.
        var left = rect.minX, right = rect.maxX, top = rect.minY, bottom = rect.maxY
        if [0, 6, 7].contains(handle) { left = min(right - 0.02, max(0, point.x)) }
        if [2, 3, 4].contains(handle) { right = max(left + 0.02, min(1, point.x)) }
        if [0, 1, 2].contains(handle) { top = min(bottom - 0.02, max(0, point.y)) }
        if [4, 5, 6].contains(handle) { bottom = max(top + 0.02, min(1, point.y)) }
        return CGRect(x: left, y: top, width: right - left, height: bottom - top)
    }

    static func handlePoint(_ handle: Int, in rect: CGRect) -> CGPoint {
        [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.midX, y: rect.minY),
         CGPoint(x: rect.maxX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.midY),
         CGPoint(x: rect.maxX, y: rect.maxY), CGPoint(x: rect.midX, y: rect.maxY),
         CGPoint(x: rect.minX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.midY)][handle]
    }
}

enum CanvasImageImportError: LocalizedError {
    case invalidImage, invalidCrop, destinationChanged
    var errorDescription: String? {
        switch self {
        case .invalidImage: "无法读取图片，请重新拍照或选择其他图片。"
        case .invalidCrop: "裁剪范围无效，请重新框选。"
        case .destinationChanged: "原画板页面已不可编辑或已被移除。请取消后重新打开图片入口。"
        }
    }
}

/// ImageIO applies EXIF orientation before any selection. Decoding, rotation and encoding stay
/// off the main actor; one bounded full-resolution image and a small preview are retained.
actor CanvasImageProcessor {
    private var image: CGImage?

    func load(_ data: Data) throws -> Data {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let decoded = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 4096,
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) else { throw CanvasImageImportError.invalidImage }
        let preview = try preview(of: decoded)
        image = decoded
        return preview
    }

    func rotate() throws -> Data {
        guard let image else { throw CanvasImageImportError.invalidImage }
        let rotated = CIImage(cgImage: image).oriented(.right)
        guard let result = CIContext().createCGImage(rotated, from: rotated.extent) else {
            throw CanvasImageImportError.invalidImage
        }
        let preview = try preview(of: result)
        self.image = result
        return preview
    }

    func crop(_ selection: CGRect) throws -> Data {
        guard let image else { throw CanvasImageImportError.invalidImage }
        guard [selection.minX, selection.minY, selection.width, selection.height].allSatisfy(\.isFinite),
              selection.width > 0, selection.height > 0 else { throw CanvasImageImportError.invalidCrop }
        let normalized = selection.intersection(CanvasImageCropGeometry.full)
        guard !normalized.isNull, normalized.width > 0, normalized.height > 0 else {
            throw CanvasImageImportError.invalidCrop
        }
        let pixels = CGRect(x: normalized.minX * CGFloat(image.width), y: normalized.minY * CGFloat(image.height),
                            width: normalized.width * CGFloat(image.width), height: normalized.height * CGFloat(image.height))
            .integral.intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard let cropped = image.cropping(to: pixels) else { throw CanvasImageImportError.invalidCrop }
        return try encode(cropped, type: UTType.png)
    }

    private func preview(of image: CGImage) throws -> Data {
        let size = CGSize(width: image.width, height: image.height)
        let scale = min(1, 1400 / max(size.width, size.height))
        guard let context = CGContext(data: nil, width: max(1, Int(size.width * scale)),
                                      height: max(1, Int(size.height * scale)), bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw CanvasImageImportError.invalidImage
        }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: context.width, height: context.height))
        guard let preview = context.makeImage() else { throw CanvasImageImportError.invalidImage }
        return try encode(preview, type: .png)
    }

    private func encode(_ image: CGImage, type: UTType) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else {
            throw CanvasImageImportError.invalidImage
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw CanvasImageImportError.invalidImage }
        return data as Data
    }
}
