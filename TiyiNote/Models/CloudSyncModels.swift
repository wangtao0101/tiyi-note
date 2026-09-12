import Foundation

/// The independently synchronized entity types in the private CloudKit record zone.
enum CloudLibraryEntityKind: String, Codable, Sendable {
    case folder
    case document
    /// A per-iCloud-account pointer to shared content. It contains only personal organization
    /// state and lives in the user's private library zone, never in the CKShare zone.
    case documentReference
    case page
    case operation
    case acknowledgement
    /// Read-only compatibility for schema-v2 annotation records.
    case pageAnnotation
}

/// One causal register inside a per-user shared-document reference. Using a register per field
/// means an offline move on one device and an offline favorite toggle on another both survive.
struct LibraryDocumentReferenceRegister<Value: Codable & Hashable & Sendable>:
    Codable, Hashable, Sendable {
    var value: Value
    var stamp: CollaborationStamp

    static func merged(
        _ lhs: LibraryDocumentReferenceRegister<Value>,
        _ rhs: LibraryDocumentReferenceRegister<Value>
    ) -> LibraryDocumentReferenceRegister<Value> {
        switch lhs.stamp.causalRelation(to: rhs.stamp) {
        case .after:
            return lhs
        case .before:
            return rhs
        case .same, .concurrent:
            if lhs.stamp != rhs.stamp {
                return lhs.stamp.deterministicallyPrecedes(rhs.stamp) ? rhs : lhs
            }
            guard lhs.value != rhs.value else { return lhs }
            return canonicalBytes(lhs.value).lexicographicallyPrecedes(canonicalBytes(rhs.value))
                ? rhs
                : lhs
        }
    }

    private static func canonicalBytes(_ value: Value) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(value)) ?? Data()
    }
}

/// The causal versions visible when a folder editor was opened. Each editable field keeps its
/// own slot so saving one field never borrows a newer, unseen revision from another field.
struct FolderEditorCollaborationContext: Hashable, Sendable {
    let title: CollaborationVersionVector
    let color: CollaborationVersionVector
    let icon: CollaborationVersionVector

    init(
        title: CollaborationVersionVector,
        color: CollaborationVersionVector,
        icon: CollaborationVersionVector
    ) {
        self.title = title
        self.color = color
        self.icon = icon
    }

    init(frontier: CollaborationVersionVector) {
        self.init(title: frontier, color: frontier, icon: frontier)
    }
}

/// Parent-field versions visible while a destination picker is open. A dictionary entry exists
/// even for legacy fields with no stamp (its value is the empty frontier), so a later download
/// cannot accidentally be treated as something the user had already observed.
struct LibraryMoveCollaborationContext: Hashable, Sendable {
    let folderParents: [String: CollaborationVersionVector]
    let documentParents: [String: CollaborationVersionVector]
}

/// Personal placement of a collaborative document. Content is addressed by `documentID` in the
/// shared zone; folder, favorite, and personal-trash state converge only among this user's devices.
struct LibraryDocumentReference: Identifiable, Codable, Hashable, Sendable {
    var id: String { documentID }

    let documentID: String
    var parent: LibraryDocumentReferenceRegister<String?>
    var favorite: LibraryDocumentReferenceRegister<Bool>
    var trash: LibraryDocumentReferenceRegister<Date?>

    func merged(with other: LibraryDocumentReference) -> LibraryDocumentReference {
        precondition(documentID == other.documentID)
        return LibraryDocumentReference(
            documentID: documentID,
            parent: .merged(parent, other.parent),
            favorite: .merged(favorite, other.favorite),
            trash: .merged(trash, other.trash)
        )
    }

    var frontier: CollaborationVersionVector {
        var result = CollaborationVersionVector()
        for stamp in [parent.stamp, favorite.stamp, trash.stamp] {
            result.formUnion(stamp.context)
            result.observe(stamp.dot)
        }
        return result
    }

    var latestDisplayDate: Date {
        [parent.stamp.createdAt, favorite.stamp.createdAt, trash.stamp.createdAt]
            .max() ?? .distantPast
    }
}

extension LibraryFolder {
    var causalStamps: [CollaborationStamp] {
        [
            titleRevision,
            parentRevision,
            colorRevision,
            iconRevision,
            favoriteRevision,
            trashRevision
        ].compactMap { $0 }
    }

    var hasCompleteCausalMetadata: Bool {
        titleRevision != nil
            && parentRevision != nil
            && colorRevision != nil
            && iconRevision != nil
            && favoriteRevision != nil
            && trashRevision != nil
    }

    /// Everything about this folder that the current UI snapshot has actually observed.
    var causalFrontier: CollaborationVersionVector {
        var result = CollaborationVersionVector()
        for stamp in causalStamps {
            result.formUnion(stamp.context)
            result.observe(stamp.dot)
        }
        return result
    }

    /// Merges independent folder fields without consulting device time. `modifiedAt` is retained
    /// only as a display value and as a compatibility fallback for pre-schema-v5 records.
    func merged(with other: LibraryFolder) -> LibraryFolder {
        precondition(id == other.id)
        let titleField = Self.mergeFolderField(
            title,
            stamp: titleRevision,
            other.title,
            otherStamp: other.titleRevision,
            legacyDate: modifiedAt,
            otherLegacyDate: other.modifiedAt
        )
        let parentField = Self.mergeFolderField(
            parentID,
            stamp: parentRevision,
            other.parentID,
            otherStamp: other.parentRevision,
            legacyDate: modifiedAt,
            otherLegacyDate: other.modifiedAt
        )
        let colorField = Self.mergeFolderField(
            color,
            stamp: colorRevision,
            other.color,
            otherStamp: other.colorRevision,
            legacyDate: modifiedAt,
            otherLegacyDate: other.modifiedAt
        )
        let iconField = Self.mergeFolderField(
            icon,
            stamp: iconRevision,
            other.icon,
            otherStamp: other.iconRevision,
            legacyDate: modifiedAt,
            otherLegacyDate: other.modifiedAt
        )
        let favoriteField = Self.mergeFolderField(
            isFavorite,
            stamp: favoriteRevision,
            other.isFavorite,
            otherStamp: other.favoriteRevision,
            legacyDate: modifiedAt,
            otherLegacyDate: other.modifiedAt
        )
        let trashField = Self.mergeFolderField(
            trashedAt,
            stamp: trashRevision,
            other.trashedAt,
            otherStamp: other.trashRevision,
            legacyDate: modifiedAt,
            otherLegacyDate: other.modifiedAt
        )
        let displayDate = ([modifiedAt, other.modifiedAt] + [
            titleField.stamp,
            parentField.stamp,
            colorField.stamp,
            iconField.stamp,
            favoriteField.stamp,
            trashField.stamp
        ].compactMap { $0?.createdAt }).max() ?? max(modifiedAt, other.modifiedAt)
        return LibraryFolder(
            id: id,
            title: titleField.value,
            parentID: parentField.value,
            createdAt: min(createdAt, other.createdAt),
            modifiedAt: displayDate,
            color: colorField.value,
            icon: iconField.value,
            isFavorite: favoriteField.value,
            trashedAt: trashField.value,
            titleRevision: titleField.stamp,
            parentRevision: parentField.stamp,
            colorRevision: colorField.stamp,
            iconRevision: iconField.stamp,
            favoriteRevision: favoriteField.stamp,
            trashRevision: trashField.stamp
        )
    }

    private static func mergeFolderField<Value: Codable & Hashable & Sendable>(
        _ value: Value,
        stamp: CollaborationStamp?,
        _ otherValue: Value,
        otherStamp: CollaborationStamp?,
        legacyDate: Date,
        otherLegacyDate: Date
    ) -> (value: Value, stamp: CollaborationStamp?) {
        switch (stamp, otherStamp) {
        case let (lhs?, rhs?):
            let merged = LibraryDocumentReferenceRegister<Value>.merged(
                LibraryDocumentReferenceRegister(value: value, stamp: lhs),
                LibraryDocumentReferenceRegister(value: otherValue, stamp: rhs)
            )
            return (merged.value, merged.stamp)
        case (.some, .none):
            return (value, stamp)
        case (.none, .some):
            return (otherValue, otherStamp)
        case (.none, .none):
            if legacyDate != otherLegacyDate {
                return legacyDate > otherLegacyDate ? (value, nil) : (otherValue, nil)
            }
            if value == otherValue { return (value, nil) }
            return causalCanonicalBytes(value).lexicographicallyPrecedes(
                causalCanonicalBytes(otherValue)
            ) ? (otherValue, nil) : (value, nil)
        }
    }
}

extension LibraryDocumentMetadata {
    var personalReference: LibraryDocumentReference? {
        guard let parentRevision, let favoriteRevision, let trashRevision else { return nil }
        return LibraryDocumentReference(
            documentID: id,
            parent: LibraryDocumentReferenceRegister(value: parentID, stamp: parentRevision),
            favorite: LibraryDocumentReferenceRegister(value: isFavorite, stamp: favoriteRevision),
            trash: LibraryDocumentReferenceRegister(value: trashedAt, stamp: trashRevision)
        )
    }

    func applyingPersonalReference(_ reference: LibraryDocumentReference) -> Self {
        precondition(id == reference.documentID)
        var result = self
        result.parentID = reference.parent.value
        result.isFavorite = reference.favorite.value
        result.trashedAt = reference.trash.value
        result.parentRevision = reference.parent.stamp
        result.favoriteRevision = reference.favorite.stamp
        result.trashRevision = reference.trash.stamp
        result.modifiedAt = max(result.contentModifiedAt, reference.latestDisplayDate)
        return result
    }

    /// Private document content and the user's organization state have separate causal domains.
    /// Content operations eventually materialize the title/pages; this method prevents an
    /// unrelated move/favorite/trash edit from overwriting those bytes while records cross.
    func mergedPrivateRecord(with other: LibraryDocumentMetadata) -> LibraryDocumentMetadata {
        precondition(id == other.id)
        var content: LibraryDocumentMetadata
        if contentModifiedAt != other.contentModifiedAt {
            content = contentModifiedAt > other.contentModifiedAt ? self : other
        } else {
            let lhs = privateDocumentContentBytes
            let rhs = other.privateDocumentContentBytes
            content = lhs.lexicographicallyPrecedes(rhs) ? other : self
        }

        if let a = titleRevision, let b = other.titleRevision {
            let title = LibraryDocumentReferenceRegister<String>.merged(
                .init(value: self.title, stamp: a), .init(value: other.title, stamp: b))
            content.title = title.value; content.titleRevision = title.stamp
        } else if let revision = titleRevision {
            content.title = title; content.titleRevision = revision
        } else if let revision = other.titleRevision {
            content.title = other.title; content.titleRevision = revision
        }

        let reference: LibraryDocumentReference?
        switch (personalReference, other.personalReference) {
        case let (lhs?, rhs?): reference = lhs.merged(with: rhs)
        case let (lhs?, nil): reference = lhs
        case let (nil, rhs?): reference = rhs
        case (nil, nil): reference = nil
        }
        guard let reference else { return content }
        return content.applyingPersonalReference(reference)
    }

    private var privateDocumentContentBytes: Data {
        struct Projection: Codable {
            let title: String
            let fileName: String
            let isBundled: Bool
            let createdAt: Date
            let kind: LibraryDocumentKind
            let backgroundStyle: CanvasBackgroundStyle?
            let backgroundColor: CanvasBackgroundColor?
        }
        return causalCanonicalBytes(
            Projection(
                title: title,
                fileName: fileName,
                isBundled: isBundled,
                createdAt: createdAt,
                kind: kind,
                backgroundStyle: canvasBackgroundStyle,
                backgroundColor: canvasBackgroundColor
            )
        )
    }
}

private func causalCanonicalBytes<Value: Encodable>(_ value: Value) -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return (try? encoder.encode(value)) ?? Data()
}

/// A stable app-owned identity. CloudKit record names are derived from this value.
struct CloudLibraryEntityReference: Hashable, Codable, Sendable {
    let kind: CloudLibraryEntityKind
    let entityID: String

    init(kind: CloudLibraryEntityKind, entityID: String) {
        self.kind = kind
        self.entityID = entityID
    }
}

/// A grow-only, remove-wins permanent-deletion ledger entry. Concurrent delete events are kept as
/// a small causal antichain instead of collapsed by device time; their contexts therefore remain
/// available when a long-offline replica reconnects. Live records never beat this value. Restoring
/// a backup creates fresh document/page IDs, so a deliberate recovery cannot resurrect an old ID.
struct LibraryEntityDeletionTombstone: Codable, Hashable, Sendable {
    let reference: CloudLibraryEntityReference
    /// Required for page scoping after its parent document metadata has already been removed.
    let ownerDocumentID: String?
    var stamps: [CollaborationStamp]

    init(
        reference: CloudLibraryEntityReference,
        ownerDocumentID: String? = nil,
        stamp: CollaborationStamp
    ) {
        self.reference = reference
        self.ownerDocumentID = ownerDocumentID
        stamps = [stamp]
    }

    init(
        reference: CloudLibraryEntityReference,
        ownerDocumentID: String? = nil,
        stamps: [CollaborationStamp]
    ) {
        self.reference = reference
        self.ownerDocumentID = ownerDocumentID
        self.stamps = Self.causalAntichain(stamps)
    }

    var deletedAt: Date {
        stamps.map(\.createdAt).max() ?? .distantPast
    }

    var frontier: CollaborationVersionVector {
        var result = CollaborationVersionVector()
        for stamp in stamps {
            result.formUnion(stamp.context)
            result.observe(stamp.dot)
        }
        return result
    }

    func merged(with other: Self) -> Self {
        precondition(reference == other.reference)
        return Self(
            reference: reference,
            ownerDocumentID: ownerDocumentID ?? other.ownerDocumentID,
            stamps: stamps + other.stamps
        )
    }

    static func legacy(
        reference: CloudLibraryEntityReference,
        ownerDocumentID: String? = nil,
        deletedAt: Date
    ) -> Self {
        let identity = "\(reference.kind.rawValue)|\(reference.entityID)"
        let stamp = CollaborationStamp(
            dot: CollaborationDot(actorID: "legacy-cloudkit|\(identity)", counter: 1),
            context: CollaborationVersionVector(),
            lamport: 1,
            operationID: "legacy-delete|\(identity)",
            createdAt: deletedAt
        )
        return Self(reference: reference, ownerDocumentID: ownerDocumentID, stamp: stamp)
    }

    private static func causalAntichain(
        _ source: [CollaborationStamp]
    ) -> [CollaborationStamp] {
        var byDot: [CollaborationDot: CollaborationStamp] = [:]
        for stamp in source {
            if let current = byDot[stamp.dot] {
                byDot[stamp.dot] = current.deterministicallyPrecedes(stamp) ? stamp : current
            } else {
                byDot[stamp.dot] = stamp
            }
        }
        let values = Array(byDot.values)
        return values.filter { candidate in
            !values.contains { other in
                candidate.dot != other.dot
                    && candidate.causalRelation(to: other) == .before
            }
        }.sorted { $0.deterministicallyPrecedes($1) }
    }
}

enum CloudLibrarySyncStatus: Equatable, Sendable {
    case idle
    case scheduled
    case syncing
    case waitingForAccount
    case waitingForNetwork
    case succeeded(Date)
    case failed(String)
}

/// The CloudKit layer consumes the shared library snapshot/asset types instead of defining a
/// second library model. Calls run on MainActor so DrawingDocumentStore can conform safely.
@MainActor
protocol CloudLibrarySyncDataSource: AnyObject {
    func exportLibrarySnapshot() -> LibrarySnapshot
    func availableAssetReferences(for documentID: String) -> [LibraryAssetReference]
    func assetURL(for reference: LibraryAssetReference) -> URL?

    /// Installs an already merged metadata graph atomically. Implementations must retain causal
    /// field revisions and deletion ledgers so bootstrap snapshots cannot become semantic truth.
    func applyRemoteSnapshot(_ snapshot: LibrarySnapshot) throws

    /// CKAsset URLs are temporary and must be copied before this method returns.
    func applyRemoteAsset(from sourceURL: URL, for reference: LibraryAssetReference) throws

    /// Removes a remotely deleted/cleared asset and publishes the same page revision signal as
    /// `applyRemoteAsset`, without enqueueing the deletion as a new local mutation.
    func removeRemoteAsset(for reference: LibraryAssetReference) throws

    /// Collaboration operations are immutable and merge by operation ID. Implementations must
    /// never replace a local log with a downloaded log.
    func exportCollaborationOperations() -> [CollaborationOperation]
    func applyRemoteCollaborationOperations(_ operations: [CollaborationOperation]) throws

    /// Shared content and personal library placement are intentionally separate CloudKit records.
    func exportDocumentReferences(for documentIDs: Set<String>) throws -> [LibraryDocumentReference]
    func applyRemoteDocumentReferences(_ references: [LibraryDocumentReference]) throws

    func exportDeletionTombstones() -> [LibraryEntityDeletionTombstone]
    func applyRemoteDeletionTombstones(
        _ tombstones: [LibraryEntityDeletionTombstone]
    ) throws

    func exportCollaborationAcknowledgements(
        for documentID: String
    ) -> [CollaborationAcknowledgement]
    func applyRemoteCollaborationAcknowledgements(
        _ acknowledgements: [CollaborationAcknowledgement]
    ) throws

    /// Rebuilds derived document caches after all page records/assets in one change batch land.
    func finalizeRemotePageChanges(for documentIDs: Set<String>) throws

    func cloudSyncDidUpdateStatus(_ status: CloudLibrarySyncStatus)
}

extension CloudLibrarySyncDataSource {
    func cloudSyncDidUpdateStatus(_ status: CloudLibrarySyncStatus) {}
}
