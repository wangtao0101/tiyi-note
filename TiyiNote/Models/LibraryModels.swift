import Foundation

enum LibraryFolderColor: String, CaseIterable, Codable, Identifiable, Sendable {
    case blue
    case purple
    case pink
    case red
    case orange
    case yellow
    case green
    case teal
    case gray

    var id: String { rawValue }

    var title: String {
        switch self {
        case .blue: "蓝色"
        case .purple: "紫色"
        case .pink: "粉色"
        case .red: "红色"
        case .orange: "橙色"
        case .yellow: "黄色"
        case .green: "绿色"
        case .teal: "青色"
        case .gray: "灰色"
        }
    }
}

enum LibraryFolderIcon: String, CaseIterable, Codable, Identifiable, Sendable {
    case folder
    case book
    case briefcase
    case graduationCap
    case heart
    case star
    case lightbulb
    case archive

    var id: String { rawValue }

    var title: String {
        switch self {
        case .folder: "文件夹"
        case .book: "书本"
        case .briefcase: "工作"
        case .graduationCap: "学习"
        case .heart: "爱心"
        case .star: "星标"
        case .lightbulb: "灵感"
        case .archive: "归档"
        }
    }

    var systemImageName: String {
        switch self {
        case .folder: "folder.fill"
        case .book: "book.closed.fill"
        case .briefcase: "briefcase.fill"
        case .graduationCap: "graduationcap.fill"
        case .heart: "heart.fill"
        case .star: "star.fill"
        case .lightbulb: "lightbulb.fill"
        case .archive: "archivebox.fill"
        }
    }
}

enum LibraryDocumentKind: String, CaseIterable, Codable, Identifiable, Sendable {
    case pdf
    case canvas

    var id: String { rawValue }
}

enum CanvasBackgroundStyle: String, CaseIterable, Codable, Identifiable, Sendable {
    case blank
    case ruled
    case grid
    case dotted

    var id: String { rawValue }

    var title: String {
        switch self {
        case .blank: "空白"
        case .ruled: "横线"
        case .grid: "方格"
        case .dotted: "点阵"
        }
    }

    var systemImageName: String {
        switch self {
        case .blank: "rectangle"
        case .ruled: "line.3.horizontal"
        case .grid: "grid"
        case .dotted: "circle.grid.3x3.fill"
        }
    }
}

enum CanvasBackgroundColor: String, CaseIterable, Codable, Identifiable, Sendable {
    case white
    case ivory
    case yellow
    case blue
    case green
    case dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .white: "白色"
        case .ivory: "米白"
        case .yellow: "浅黄"
        case .blue: "浅蓝"
        case .green: "浅绿"
        case .dark: "深色"
        }
    }
}

/// A user-created folder in the Tiyi Note library. `nil` parent means library root.
struct LibraryFolder: Identifiable, Codable, Hashable, Sendable {
    let id: String
    var title: String
    var parentID: String?
    let createdAt: Date
    var modifiedAt: Date
    var color: LibraryFolderColor
    var icon: LibraryFolderIcon
    var isFavorite: Bool
    var trashedAt: Date?
    /// Private-library metadata is merged one field at a time. Wall-clock dates remain useful for
    /// display, but these causal revisions are the source of truth when two devices edit offline.
    var titleRevision: CollaborationStamp?
    var parentRevision: CollaborationStamp?
    var colorRevision: CollaborationStamp?
    var iconRevision: CollaborationStamp?
    var favoriteRevision: CollaborationStamp?
    var trashRevision: CollaborationStamp?

    init(
        id: String = UUID().uuidString.lowercased(),
        title: String,
        parentID: String?,
        createdAt: Date = Date(),
        modifiedAt: Date = Date(),
        color: LibraryFolderColor = .blue,
        icon: LibraryFolderIcon = .folder,
        isFavorite: Bool = false,
        trashedAt: Date? = nil,
        titleRevision: CollaborationStamp? = nil,
        parentRevision: CollaborationStamp? = nil,
        colorRevision: CollaborationStamp? = nil,
        iconRevision: CollaborationStamp? = nil,
        favoriteRevision: CollaborationStamp? = nil,
        trashRevision: CollaborationStamp? = nil
    ) {
        self.id = id
        self.title = title
        self.parentID = parentID
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
        self.color = color
        self.icon = icon
        self.isFavorite = isFavorite
        self.trashedAt = trashedAt
        self.titleRevision = titleRevision
        self.parentRevision = parentRevision
        self.colorRevision = colorRevision
        self.iconRevision = iconRevision
        self.favoriteRevision = favoriteRevision
        self.trashRevision = trashRevision
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, parentID, createdAt, modifiedAt
        case color, icon, isFavorite, trashedAt
        case titleRevision, parentRevision, colorRevision, iconRevision
        case favoriteRevision, trashRevision
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        parentID = try container.decodeIfPresent(String.self, forKey: .parentID)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        modifiedAt = try container.decode(Date.self, forKey: .modifiedAt)
        color = try container.decodeIfPresent(LibraryFolderColor.self, forKey: .color) ?? .blue
        icon = try container.decodeIfPresent(LibraryFolderIcon.self, forKey: .icon) ?? .folder
        isFavorite = try container.decodeIfPresent(Bool.self, forKey: .isFavorite) ?? false
        trashedAt = try container.decodeIfPresent(Date.self, forKey: .trashedAt)
        titleRevision = try container.decodeIfPresent(
            CollaborationStamp.self,
            forKey: .titleRevision
        )
        parentRevision = try container.decodeIfPresent(
            CollaborationStamp.self,
            forKey: .parentRevision
        )
        colorRevision = try container.decodeIfPresent(
            CollaborationStamp.self,
            forKey: .colorRevision
        )
        iconRevision = try container.decodeIfPresent(
            CollaborationStamp.self,
            forKey: .iconRevision
        )
        favoriteRevision = try container.decodeIfPresent(
            CollaborationStamp.self,
            forKey: .favoriteRevision
        )
        trashRevision = try container.decodeIfPresent(
            CollaborationStamp.self,
            forKey: .trashRevision
        )
    }
}

/// Codable document metadata. The PDF itself remains a separate, replaceable asset.
struct LibraryDocumentMetadata: Identifiable, Codable, Hashable, Sendable {
    let id: String
    var title: String
    var titleRevision: CollaborationStamp? = nil
    var parentID: String?
    var fileName: String
    /// Immutable source identity and default page sequence. No per-page rows on import.
    var sourcePageCount: Int?
    var sourceResourceID: String?
    var isBundled: Bool
    let createdAt: Date
    var modifiedAt: Date
    /// Collaborative content and per-user library placement advance independently. `modifiedAt`
    /// remains the user-facing aggregate timestamp, while shared zones use this value so moving a
    /// shared document between personal folders never looks like a content edit.
    var contentModifiedAt: Date
    var kind: LibraryDocumentKind
    var canvasBackgroundStyle: CanvasBackgroundStyle?
    var canvasBackgroundColor: CanvasBackgroundColor?
    var isFavorite: Bool
    var trashedAt: Date?
    /// Per-field causal revisions for the private, per-user document reference. They are optional
    /// only for registries written before schema v4 and are initialized before first upload.
    var parentRevision: CollaborationStamp?
    var favoriteRevision: CollaborationStamp?
    var trashRevision: CollaborationStamp?

    init(
        id: String,
        title: String,
        parentID: String?,
        fileName: String,
        isBundled: Bool,
        sourcePageCount: Int? = nil,
        sourceResourceID: String? = nil,
        createdAt: Date = Date(),
        modifiedAt: Date = Date(),
        contentModifiedAt: Date? = nil,
        kind: LibraryDocumentKind = .pdf,
        canvasBackgroundStyle: CanvasBackgroundStyle? = nil,
        canvasBackgroundColor: CanvasBackgroundColor? = nil,
        isFavorite: Bool = false,
        trashedAt: Date? = nil,
        parentRevision: CollaborationStamp? = nil,
        favoriteRevision: CollaborationStamp? = nil,
        trashRevision: CollaborationStamp? = nil
    ) {
        self.id = id
        self.title = title
        self.parentID = parentID
        self.fileName = fileName
        self.sourcePageCount = sourcePageCount
        self.sourceResourceID = sourceResourceID ?? (sourcePageCount == nil ? nil : id)
        self.isBundled = isBundled
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
        self.contentModifiedAt = contentModifiedAt ?? modifiedAt
        self.kind = kind
        self.canvasBackgroundStyle = canvasBackgroundStyle
        self.canvasBackgroundColor = canvasBackgroundColor
        self.isFavorite = isFavorite
        self.trashedAt = trashedAt
        self.parentRevision = parentRevision
        self.favoriteRevision = favoriteRevision
        self.trashRevision = trashRevision
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, parentID, fileName, isBundled, createdAt, modifiedAt, contentModifiedAt
        case titleRevision
        case sourcePageCount, sourceResourceID
        case kind, canvasBackgroundStyle, canvasBackgroundColor, isFavorite, trashedAt
        case parentRevision, favoriteRevision, trashRevision
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        titleRevision = try container.decodeIfPresent(CollaborationStamp.self, forKey: .titleRevision)
        parentID = try container.decodeIfPresent(String.self, forKey: .parentID)
        fileName = try container.decode(String.self, forKey: .fileName)
        sourcePageCount = try container.decodeIfPresent(Int.self, forKey: .sourcePageCount)
        sourceResourceID = try container.decodeIfPresent(String.self, forKey: .sourceResourceID)
        isBundled = try container.decode(Bool.self, forKey: .isBundled)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        modifiedAt = try container.decode(Date.self, forKey: .modifiedAt)
        contentModifiedAt = try container.decodeIfPresent(
            Date.self,
            forKey: .contentModifiedAt
        ) ?? modifiedAt
        kind = try container.decodeIfPresent(LibraryDocumentKind.self, forKey: .kind) ?? .pdf
        canvasBackgroundStyle = try container.decodeIfPresent(
            CanvasBackgroundStyle.self,
            forKey: .canvasBackgroundStyle
        )
        canvasBackgroundColor = try container.decodeIfPresent(
            CanvasBackgroundColor.self,
            forKey: .canvasBackgroundColor
        )
        isFavorite = try container.decodeIfPresent(Bool.self, forKey: .isFavorite) ?? false
        trashedAt = try container.decodeIfPresent(Date.self, forKey: .trashedAt)
        parentRevision = try container.decodeIfPresent(
            CollaborationStamp.self,
            forKey: .parentRevision
        )
        favoriteRevision = try container.decodeIfPresent(
            CollaborationStamp.self,
            forKey: .favoriteRevision
        )
        trashRevision = try container.decodeIfPresent(
            CollaborationStamp.self,
            forKey: .trashRevision
        )
    }
}

/// Versioned, transport-safe metadata used by the CloudKit layer.
struct LibrarySnapshot: Codable, Hashable, Sendable {
    static let currentSchemaVersion = 5

    let schemaVersion: Int
    var folders: [LibraryFolder]
    var documents: [LibraryDocumentMetadata]
    var pages: [LibraryPage]
    var generatedAt: Date

    init(
        schemaVersion: Int = LibrarySnapshot.currentSchemaVersion,
        folders: [LibraryFolder],
        documents: [LibraryDocumentMetadata],
        pages: [LibraryPage] = [],
        generatedAt: Date = Date()
    ) {
        self.schemaVersion = schemaVersion
        self.folders = folders
        self.documents = documents
        self.pages = pages
        self.generatedAt = generatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, folders, documents, pages, generatedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        folders = try container.decode([LibraryFolder].self, forKey: .folders)
        documents = try container.decode([LibraryDocumentMetadata].self, forKey: .documents)
        pages = try container.decodeIfPresent([LibraryPage].self, forKey: .pages) ?? []
        generatedAt = try container.decodeIfPresent(Date.self, forKey: .generatedAt) ?? Date()
    }
}

/// A concrete asset that can be uploaded or downloaded independently.
enum LibraryAssetKind: Codable, Hashable, Sendable {
    case pdf
    case pageBackground(pageID: String)
    case pageDrawing(pageID: String)
    case pageElements(pageID: String)
    // Schema v2 compatibility. New snapshots never export these cases.
    case drawing(pageIndex: Int)
    case imageAnnotations(pageIndex: Int)
}

struct LibraryAssetReference: Codable, Hashable, Sendable {
    let documentID: String
    let kind: LibraryAssetKind

    init(documentID: String, kind: LibraryAssetKind) {
        self.documentID = documentID
        self.kind = kind
    }
}

/// Stable key used by views to observe drawing/image assets changing underneath a visible page.
struct LibraryPageReference: Codable, Hashable, Sendable {
    let documentID: String
    let pageID: String

    init(documentID: String, pageID: String) {
        self.documentID = documentID
        self.pageID = pageID
    }
}

/// Runtime representation consumed by the reader, library cards, and tab UI.
struct PDFWorkspaceDocument: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let fileURL: URL
    let isBundled: Bool
    let parentID: String?
    let createdAt: Date
    let modifiedAt: Date
    let kind: LibraryDocumentKind
    let canvasBackgroundStyle: CanvasBackgroundStyle?
    let canvasBackgroundColor: CanvasBackgroundColor?
    let isFavorite: Bool
    let trashedAt: Date?
}

enum LibraryStoreError: LocalizedError, Equatable {
    case invalidName
    case nameConflict(String)
    case folderNotFound(String)
    case documentNotFound(String)
    case pageNotFound(String)
    case cannotDeleteLastPage
    case folderCycle
    case invalidSnapshot(String)
    case cannotApplyAsset(String)
    case itemIsInTrash
    case readOnlySharedDocument

    var errorDescription: String? {
        switch self {
        case .invalidName:
            "名称不能为空。"
        case .nameConflict(let title):
            "“\(title)”已存在于这个文件夹中。"
        case .folderNotFound:
            "找不到目标文件夹。"
        case .documentNotFound:
            "找不到该文稿。"
        case .pageNotFound:
            "找不到该页面。"
        case .cannotDeleteLastPage:
            "文稿至少需要保留一页。"
        case .folderCycle:
            "文件夹不能移动到自身或其子文件夹中。"
        case .invalidSnapshot(let reason):
            "资料库同步数据无效：\(reason)"
        case .cannotApplyAsset(let name):
            "无法保存同步文件：\(name)"
        case .itemIsInTrash:
            "回收站中的项目需要先恢复。"
        case .readOnlySharedDocument:
            "你只有这个共享文稿的只读权限。"
        }
    }
}
