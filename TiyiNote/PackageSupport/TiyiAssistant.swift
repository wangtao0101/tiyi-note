import SwiftUI
import UIKit

public struct TiyiAssistantScope: Codable, Hashable, Sendable {
    public var kind: String
    public var sourceId: String
    public var questionId: String?
    public init(kind: String, sourceId: String, questionId: String? = nil) {
        self.kind = kind; self.sourceId = sourceId; self.questionId = questionId
    }
    public var key: String { "\(kind):\(sourceId):\(questionId ?? "")" }
}

public struct TiyiAssistantImage: Identifiable {
    public let id: String
    public let label: String
    public let data: Data
    public init(id: String, label: String, data: Data) { self.id = id; self.label = label; self.data = data }
}

@MainActor public struct TiyiAssistantContext {
    public let scope: TiyiAssistantScope
    public let title: String
    public let prompt: String
    public var selections: [TiyiAssistantImage] = []
    public let captureQuestion: () throws -> [TiyiAssistantImage]
    public let capture: () throws -> [TiyiAssistantImage]
    public init(scope: TiyiAssistantScope, title: String, prompt: String, selections: [TiyiAssistantImage] = [], captureQuestion: @escaping () throws -> [TiyiAssistantImage] = { [] }, capture: @escaping () throws -> [TiyiAssistantImage]) {
        self.scope = scope; self.title = title; self.prompt = prompt; self.selections = selections; self.captureQuestion = captureQuestion; self.capture = capture
    }
}

/// The host supplies its existing Chat UI. The document package has no chat/network dependency.
public struct TiyiAssistantIntegration {
    public let panel: @MainActor (TiyiAssistantContext, @escaping () -> Void) -> AnyView
    public init(panel: @escaping @MainActor (TiyiAssistantContext, @escaping () -> Void) -> AnyView) { self.panel = panel }
}
private struct TiyiAssistantIntegrationKey: EnvironmentKey {
    static let defaultValue: TiyiAssistantIntegration? = nil
}
public extension EnvironmentValues {
    var tiyiAssistant: TiyiAssistantIntegration? {
        get { self[TiyiAssistantIntegrationKey.self] }
        set { self[TiyiAssistantIntegrationKey.self] = newValue }
    }
}

extension DrawingDocumentStore {
    /// Uses the export renderer, including PDF, PencilKit and page elements in world coordinates.
    func assistantImage(documentID: String, pageIndex: Int, crop: CGRect? = nil, includesAnswer: Bool = true, preservesPageElements: Bool = false) throws -> Data {
        guard flushAllPendingSaves() else { throw CocoaError(.fileWriteUnknown) }
        let bounds = crop ?? (includesAnswer ? exportBounds(forPage: pageIndex, in: documentID) : CGRect(origin: .zero, size: pageSize(at: pageIndex, in: documentID)))
        guard bounds.width > 1, bounds.height > 1, bounds.width.isFinite, bounds.height.isFinite else { throw CocoaError(.fileReadCorruptFile) }
        let format = UIGraphicsImageRendererFormat()
        format.scale = min(2, 3072 / max(bounds.width, bounds.height)); format.opaque = true
        let image = UIGraphicsImageRenderer(size: bounds.size, format: format).image { renderer in
            renderFlattenedPage(documentID: documentID, pageIndex: pageIndex, bounds: bounds, context: renderer.cgContext, includesAnnotations: includesAnswer, preservesPageElements: preservesPageElements)
        }
        guard let data = image.jpegData(compressionQuality: 0.85) else { throw CocoaError(.fileReadCorruptFile) }
        return data
    }
}

extension TiyiPracticeWorkspace {
    public func assistantImages(includesAnswer: Bool = true) throws -> [TiyiAssistantImage] {
        try checkpoint()
        guard let section = currentSection else { return [] }
        let pageIDs = includesAnswer ? section.pageIDs : section.pageIDs.filter { id in
            guard let index = store.pageIndex(for: id, in: documentID) else { return false }
            return store.pageMetadata(at: index, in: documentID)?.sourceKind == .pdf
        }
        guard pageIDs.count <= 6 else {
            throw NSError(domain: "TiyiAssistant", code: 1, userInfo: [NSLocalizedDescriptionKey: "本题超过 6 页，请用套索分段附带作答。"])
        }
        return try pageIDs.enumerated().map { offset, id in
            guard let index = store.pageIndex(for: id, in: documentID) else { throw CocoaError(.fileNoSuchFile) }
            return TiyiAssistantImage(id: id, label: "\(section.label)·\(includesAnswer ? "作答" : "题面")第 \(offset + 1) 页", data: try store.assistantImage(documentID: documentID, pageIndex: index, includesAnswer: includesAnswer))
        }
    }
}

extension Notification.Name { static let tiyiAssistantSelection = Notification.Name("tiyi.assistant.selection") }
struct TiyiAssistantSelectionEvent {
    let documentID: String
    let image: TiyiAssistantImage
    let pageID: String
    let bounds: CGRect
}
