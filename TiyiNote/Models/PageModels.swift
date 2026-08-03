import CoreGraphics
import Foundation
import UniformTypeIdentifiers

extension UTType {
    static let tiyiNoteDocument = UTType(
        exportedAs: "com.tiyi.note.editable-document",
        conformingTo: .data
    )
}

enum LibraryPageSourceKind: String, Codable, CaseIterable, Sendable {
    case pdf
    case template
    case image
}

/// A Logoot-style fractional position. Concurrent inserts can choose the same numeric path;
/// `actorID` and `sequence` provide a stable, deterministic tie-break without renumbering peers.
struct CollaborativePositionComponent: Codable, Hashable, Comparable, Sendable {
    let digit: UInt16
    let actorID: String
    let sequence: UInt64

    static func < (
        lhs: CollaborativePositionComponent,
        rhs: CollaborativePositionComponent
    ) -> Bool {
        if lhs.digit != rhs.digit { return lhs.digit < rhs.digit }
        if lhs.actorID != rhs.actorID { return lhs.actorID < rhs.actorID }
        return lhs.sequence < rhs.sequence
    }
}

struct CollaborativePosition: Codable, Hashable, Comparable, Sendable {
    private static let minimumDigit: UInt16 = 0
    private static let maximumDigit: UInt16 = .max

    let components: [CollaborativePositionComponent]

    init(digits: [UInt16], actorID: String, sequence: UInt64) {
        let normalizedDigits = digits.isEmpty ? [Self.maximumDigit / 2] : digits
        components = normalizedDigits.map {
            CollaborativePositionComponent(digit: $0, actorID: actorID, sequence: sequence)
        }
    }

    private init(components: [CollaborativePositionComponent]) {
        self.components = components
    }

    static func legacy(orderIndex: Int) -> CollaborativePosition {
        let value = UInt64(max(orderIndex, 0))
        return CollaborativePosition(
            digits: [
                Self.maximumDigit / 2,
                UInt16((value >> 48) & 0xffff),
                UInt16((value >> 32) & 0xffff),
                UInt16((value >> 16) & 0xffff),
                UInt16(value & 0xffff)
            ],
            actorID: "legacy",
            sequence: value
        )
    }

    static func between(
        _ lower: CollaborativePosition?,
        _ upper: CollaborativePosition?,
        actorID: String,
        sequence: UInt64
    ) -> CollaborativePosition {
        precondition(lower == nil || upper == nil || lower! < upper!)
        var result: [CollaborativePositionComponent] = []
        var depth = 0
        while true {
            let low = lower?.components.indices.contains(depth) == true
                ? lower!.components[depth]
                : CollaborativePositionComponent(
                    digit: Self.minimumDigit,
                    actorID: "",
                    sequence: 0
                )
            let high = upper?.components.indices.contains(depth) == true
                ? upper!.components[depth]
                : CollaborativePositionComponent(
                    digit: Self.maximumDigit,
                    actorID: "\u{10ffff}",
                    sequence: .max
                )
            if UInt32(high.digit) > UInt32(low.digit) + 1 {
                result.append(
                    CollaborativePositionComponent(
                        digit: UInt16((UInt32(low.digit) + UInt32(high.digit)) / 2),
                        actorID: actorID,
                        sequence: sequence
                    )
                )
                break
            }
            result.append(low)
            depth += 1
        }
        return CollaborativePosition(components: result)
    }

    static func < (lhs: CollaborativePosition, rhs: CollaborativePosition) -> Bool {
        for index in 0..<min(lhs.components.count, rhs.components.count) {
            if lhs.components[index] != rhs.components[index] {
                return lhs.components[index] < rhs.components[index]
            }
        }
        return lhs.components.count < rhs.components.count
    }
}

/// Stable page identity. `orderIndex` is presentation state and may change without renaming
/// the page's drawing or element assets.
struct LibraryPage: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let documentID: String
    var orderIndex: Int
    var position: CollaborativePosition
    let createdAt: Date
    var modifiedAt: Date
    var width: Double
    var height: Double
    var rotation: Int
    var sourceKind: LibraryPageSourceKind
    var backgroundStyle: CanvasBackgroundStyle?
    var backgroundColor: CanvasBackgroundColor?
    var isBookmarked: Bool

    init(
        id: String = UUID().uuidString.lowercased(),
        documentID: String,
        orderIndex: Int,
        position: CollaborativePosition? = nil,
        createdAt: Date = Date(),
        modifiedAt: Date = Date(),
        width: Double,
        height: Double,
        rotation: Int = 0,
        sourceKind: LibraryPageSourceKind = .pdf,
        backgroundStyle: CanvasBackgroundStyle? = nil,
        backgroundColor: CanvasBackgroundColor? = nil,
        isBookmarked: Bool = false
    ) {
        self.id = id
        self.documentID = documentID
        self.orderIndex = orderIndex
        self.position = position ?? .legacy(orderIndex: orderIndex)
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
        self.width = width
        self.height = height
        self.rotation = rotation
        self.sourceKind = sourceKind
        self.backgroundStyle = backgroundStyle
        self.backgroundColor = backgroundColor
        self.isBookmarked = isBookmarked
    }

    private enum CodingKeys: String, CodingKey {
        case id, documentID, orderIndex, position, createdAt, modifiedAt
        case width, height, rotation, sourceKind, backgroundStyle, backgroundColor, isBookmarked
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        documentID = try container.decode(String.self, forKey: .documentID)
        orderIndex = try container.decode(Int.self, forKey: .orderIndex)
        position = try container.decodeIfPresent(
            CollaborativePosition.self,
            forKey: .position
        ) ?? .legacy(orderIndex: orderIndex)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        modifiedAt = try container.decode(Date.self, forKey: .modifiedAt)
        width = try container.decode(Double.self, forKey: .width)
        height = try container.decode(Double.self, forKey: .height)
        rotation = try container.decodeIfPresent(Int.self, forKey: .rotation) ?? 0
        sourceKind = try container.decodeIfPresent(
            LibraryPageSourceKind.self,
            forKey: .sourceKind
        ) ?? .pdf
        backgroundStyle = try container.decodeIfPresent(
            CanvasBackgroundStyle.self,
            forKey: .backgroundStyle
        )
        backgroundColor = try container.decodeIfPresent(
            CanvasBackgroundColor.self,
            forKey: .backgroundColor
        )
        isBookmarked = try container.decodeIfPresent(Bool.self, forKey: .isBookmarked) ?? false
    }
}

enum PageTextAlignment: String, Codable, CaseIterable, Sendable {
    case leading
    case center
    case trailing
}

enum PageTextFontPreset: String, Codable, CaseIterable, Identifiable, Sendable {
    case system = "System"
    case rounded = "Rounded"
    case serif = "Serif"
    case monospaced = "Monospaced"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: "系统"
        case .rounded: "圆体"
        case .serif: "衬线"
        case .monospaced: "等宽"
        }
    }

    init(storedName: String) {
        self = Self(rawValue: storedName) ?? .system
    }
}

struct PageTextPayload: Codable, Hashable, Sendable {
    var text: String
    var fontName: String
    var fontSize: Double
    var colorHex: String
    var isBold: Bool
    var isItalic: Bool
    var isUnderlined: Bool
    var alignment: PageTextAlignment

    init(
        text: String = "文本",
        fontName: String = "System",
        fontSize: Double = 22,
        colorHex: String = "#111111FF",
        isBold: Bool = false,
        isItalic: Bool = false,
        isUnderlined: Bool = false,
        alignment: PageTextAlignment = .leading
    ) {
        self.text = text
        self.fontName = fontName
        self.fontSize = fontSize
        self.colorHex = colorHex
        self.isBold = isBold
        self.isItalic = isItalic
        self.isUnderlined = isUnderlined
        self.alignment = alignment
    }

    private enum CodingKeys: String, CodingKey {
        case text, fontName, fontSize, colorHex, isBold, isItalic, isUnderlined, alignment
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        text = try container.decodeIfPresent(String.self, forKey: .text) ?? "文本"
        fontName = try container.decodeIfPresent(String.self, forKey: .fontName) ?? "System"
        fontSize = try container.decodeIfPresent(Double.self, forKey: .fontSize) ?? 22
        colorHex = try container.decodeIfPresent(String.self, forKey: .colorHex) ?? "#111111FF"
        isBold = try container.decodeIfPresent(Bool.self, forKey: .isBold) ?? false
        isItalic = try container.decodeIfPresent(Bool.self, forKey: .isItalic) ?? false
        isUnderlined = try container.decodeIfPresent(Bool.self, forKey: .isUnderlined) ?? false
        alignment = try container.decodeIfPresent(PageTextAlignment.self, forKey: .alignment)
            ?? .leading
    }
}

struct PageImagePayload: Codable, Hashable, Sendable {
    var pngData: Data
    var opacity: Double

    init(pngData: Data, opacity: Double = 1) {
        self.pngData = pngData
        self.opacity = opacity
    }
}

enum PageShapeKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case line
    case arrow
    case rectangle
    case ellipse
    case triangle
    case diamond

    var id: String { rawValue }

    var title: String {
        switch self {
        case .line: "直线"
        case .arrow: "箭头"
        case .rectangle: "矩形"
        case .ellipse: "圆形"
        case .triangle: "三角形"
        case .diamond: "菱形"
        }
    }

    var symbolName: String {
        switch self {
        case .line: "line.diagonal"
        case .arrow: "arrow.right"
        case .rectangle: "rectangle"
        case .ellipse: "circle"
        case .triangle: "triangle"
        case .diamond: "diamond"
        }
    }
}

struct PageShapePayload: Codable, Hashable, Sendable {
    var kind: PageShapeKind
    var strokeColorHex: String
    var fillColorHex: String?
    var lineWidth: Double
    var isDashed: Bool

    init(
        kind: PageShapeKind,
        strokeColorHex: String = "#111111FF",
        fillColorHex: String? = nil,
        lineWidth: Double = 3,
        isDashed: Bool = false
    ) {
        self.kind = kind
        self.strokeColorHex = strokeColorHex
        self.fillColorHex = fillColorHex
        self.lineWidth = lineWidth
        self.isDashed = isDashed
    }
}

enum PageElementPayload: Codable, Hashable, Sendable {
    case text(PageTextPayload)
    case image(PageImagePayload)
    case shape(PageShapePayload)
}

/// Editable, object-level content stored next to the page's PencilKit drawing.
struct CanvasPageElement: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var logicalBounds: CGRect
    var rotationRadians: Double
    var zIndex: Int
    var isLocked: Bool
    var groupID: UUID?
    var payload: PageElementPayload

    init(
        id: UUID = UUID(),
        logicalBounds: CGRect,
        rotationRadians: Double = 0,
        zIndex: Int = 0,
        isLocked: Bool = false,
        groupID: UUID? = nil,
        payload: PageElementPayload
    ) {
        self.id = id
        self.logicalBounds = logicalBounds
        self.rotationRadians = rotationRadians
        self.zIndex = zIndex
        self.isLocked = isLocked
        self.groupID = groupID
        self.payload = payload
    }

    private enum CodingKeys: String, CodingKey {
        case id, logicalBounds, rotationRadians, zIndex, isLocked, groupID, payload
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        logicalBounds = try container.decode(CGRect.self, forKey: .logicalBounds)
        rotationRadians = try container.decodeIfPresent(Double.self, forKey: .rotationRadians) ?? 0
        zIndex = try container.decodeIfPresent(Int.self, forKey: .zIndex) ?? 0
        isLocked = try container.decodeIfPresent(Bool.self, forKey: .isLocked) ?? false
        groupID = try container.decodeIfPresent(UUID.self, forKey: .groupID)
        payload = try container.decode(PageElementPayload.self, forKey: .payload)
    }
}

struct CanvasPageElementsArchive: Codable, Hashable, Sendable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int
    var elements: [CanvasPageElement]

    init(
        schemaVersion: Int = CanvasPageElementsArchive.currentSchemaVersion,
        elements: [CanvasPageElement]
    ) {
        self.schemaVersion = schemaVersion
        self.elements = elements
    }
}

enum PageElementInsertionPayload {
    case text(PageTextPayload)
    case image(PageImagePayload)
    case shape(PageShapePayload)
}

struct PageElementInsertionRequest: Identifiable {
    let id = UUID()
    let pageIndex: Int
    let payload: PageElementInsertionPayload
}

struct PDFTextSearchResult: Identifiable, Hashable {
    let id: String
    let pageIndex: Int
    let excerpt: String
    let pageBounds: CGRect
}

struct PDFSearchHighlight: Hashable {
    let documentID: String
    let pageIndex: Int
    let pageBounds: CGRect
}

enum DocumentOutputAction: String, CaseIterable, Identifiable {
    case flattenedPDF
    case pageImages
    case editablePackage
    case printDocument
    case collaboration
    case conflictVersions

    var id: String { rawValue }
}

struct CollaborationConflictItem: Identifiable, Hashable {
    let documentID: String
    let pageID: String
    let pageIndex: Int?
    let conflict: CollaborationConflictCopy

    var id: String { "\(documentID)|\(pageID)|\(conflict.id)" }
}

struct EditableDocumentPageAssets: Codable, Hashable, Sendable {
    let pageID: String
    let backgroundPDFData: Data?
    let drawingData: Data?
    let elementsData: Data?
    let operations: [CollaborationOperation]
}

/// Self-contained native backup/export. JSON keeps the format inspectable and versioned while
/// preserving the original PDF, stable page IDs, editable assets, and collaboration history.
struct EditableDocumentPackage: Codable, Hashable, Sendable {
    static let currentSchemaVersion = 2

    let schemaVersion: Int
    let exportedAt: Date
    let document: LibraryDocumentMetadata
    let pages: [LibraryPage]
    let sourcePDFData: Data
    let pageAssets: [EditableDocumentPageAssets]
    /// Document-wide operations currently include the collaborative title register. Schema-v1
    /// packages decode with an empty list and remain importable.
    let documentOperations: [CollaborationOperation]

    init(
        schemaVersion: Int = EditableDocumentPackage.currentSchemaVersion,
        exportedAt: Date = Date(),
        document: LibraryDocumentMetadata,
        pages: [LibraryPage],
        sourcePDFData: Data,
        pageAssets: [EditableDocumentPageAssets],
        documentOperations: [CollaborationOperation] = []
    ) {
        self.schemaVersion = schemaVersion
        self.exportedAt = exportedAt
        self.document = document
        self.pages = pages
        self.sourcePDFData = sourcePDFData
        self.pageAssets = pageAssets
        self.documentOperations = documentOperations
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, exportedAt, document, pages, sourcePDFData, pageAssets
        case documentOperations
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        exportedAt = try container.decode(Date.self, forKey: .exportedAt)
        document = try container.decode(LibraryDocumentMetadata.self, forKey: .document)
        pages = try container.decode([LibraryPage].self, forKey: .pages)
        sourcePDFData = try container.decode(Data.self, forKey: .sourcePDFData)
        pageAssets = try container.decode(
            [EditableDocumentPageAssets].self,
            forKey: .pageAssets
        )
        documentOperations = try container.decodeIfPresent(
            [CollaborationOperation].self,
            forKey: .documentOperations
        ) ?? []
    }
}
