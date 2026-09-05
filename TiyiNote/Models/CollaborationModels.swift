import Foundation

enum CollaborationReservedID {
    /// Document-wide CRDT registers live in the same immutable operation stream without being
    /// confused with a real page identity.
    static let documentMetadata = "__document_metadata__"
}

enum CollaborationCausalRelation: Equatable, Sendable {
    case same
    case before
    case after
    case concurrent
}

struct CollaborationDot: Codable, Hashable, Comparable, Sendable {
    let actorID: String
    let counter: UInt64

    static func < (lhs: CollaborationDot, rhs: CollaborationDot) -> Bool {
        if lhs.counter != rhs.counter { return lhs.counter < rhs.counter }
        return lhs.actorID < rhs.actorID
    }
}

/// A compact version vector. It is the source of causal truth; wall-clock dates are display-only.
struct CollaborationVersionVector: Codable, Hashable, Sendable {
    private(set) var counters: [String: UInt64]

    init(counters: [String: UInt64] = [:]) {
        self.counters = counters.filter { !$0.key.isEmpty && $0.value > 0 }
    }

    subscript(actorID: String) -> UInt64 {
        counters[actorID, default: 0]
    }

    func contains(_ dot: CollaborationDot) -> Bool {
        self[dot.actorID] >= dot.counter
    }

    mutating func observe(_ dot: CollaborationDot) {
        counters[dot.actorID] = max(self[dot.actorID], dot.counter)
    }

    mutating func formUnion(_ other: CollaborationVersionVector) {
        for (actorID, counter) in other.counters {
            counters[actorID] = max(self[actorID], counter)
        }
    }

    func union(_ other: CollaborationVersionVector) -> CollaborationVersionVector {
        var result = self
        result.formUnion(other)
        return result
    }

    func dominates(_ other: CollaborationVersionVector) -> Bool {
        other.counters.allSatisfy { self[$0.key] >= $0.value }
    }
}

struct CollaborationStamp: Codable, Hashable, Sendable {
    let dot: CollaborationDot
    let context: CollaborationVersionVector
    let lamport: UInt64
    let operationID: String
    /// Informational only. Never used to resolve a conflict.
    let createdAt: Date

    var inclusiveFrontier: CollaborationVersionVector {
        var result = context
        result.observe(dot)
        return result
    }

    func causalRelation(to other: CollaborationStamp) -> CollaborationCausalRelation {
        if dot == other.dot { return .same }
        let seesOther = context.contains(other.dot)
        let otherSeesSelf = other.context.contains(dot)
        switch (seesOther, otherSeesSelf) {
        case (true, false): return .after
        case (false, true): return .before
        case (true, true): return .same
        case (false, false): return .concurrent
        }
    }

    /// A total order used only after causality says two edits are concurrent.
    func deterministicallyPrecedes(_ other: CollaborationStamp) -> Bool {
        if lamport != other.lamport { return lamport < other.lamport }
        if dot.actorID != other.dot.actorID { return dot.actorID < other.dot.actorID }
        if dot.counter != other.dot.counter { return dot.counter < other.dot.counter }
        return operationID < other.operationID
    }
}

struct CollaborationReplicaClock: Codable, Hashable, Sendable {
    let actorID: String
    private(set) var version: CollaborationVersionVector
    private(set) var lamport: UInt64
    /// The last event emitted by this process, including a temporary stale-editor branch. These
    /// fields let the next event preserve transitive causal context without treating remote changes
    /// received behind an already-open editor as observed by that editor.
    private var lastLocalDot: CollaborationDot?
    private var lastLocalContext: CollaborationVersionVector?

    init(
        actorID: String,
        version: CollaborationVersionVector = CollaborationVersionVector(),
        lamport: UInt64 = 0
    ) {
        precondition(!actorID.isEmpty)
        self.actorID = actorID
        self.version = version
        self.lamport = lamport
        lastLocalDot = nil
        lastLocalContext = nil
    }

    mutating func nextStamp(
        operationID: String = UUID().uuidString.lowercased(),
        createdAt: Date = Date()
    ) -> CollaborationStamp {
        let context = version
        let dot = CollaborationDot(actorID: actorID, counter: version[actorID] + 1)
        lamport += 1
        version.observe(dot)
        lastLocalDot = dot
        lastLocalContext = context
        return CollaborationStamp(
            dot: dot,
            context: context,
            lamport: lamport,
            operationID: operationID,
            createdAt: createdAt
        )
    }

    /// Creates an event from the version the editor actually observed. Remote events downloaded
    /// behind an open edit sheet/dirty canvas are intentionally excluded, so the merge engine sees
    /// a real concurrent edit instead of a false causal overwrite. Local actor dots remain a
    /// contiguous causal chain, which is required by version-vector counter compression.
    mutating func nextStamp(
        observedContext: CollaborationVersionVector,
        operationID: String = UUID().uuidString.lowercased(),
        createdAt: Date = Date()
    ) -> CollaborationStamp {
        var context = observedContext
        let dot: CollaborationDot
        if let lastLocalDot,
           version[lastLocalDot.actorID] == lastLocalDot.counter,
           context.contains(lastLocalDot) {
            // The editor saw our previous event, so continuing that actor chain is valid. Carry
            // its context forward explicitly; version-vector causality must be transitively closed.
            if let lastLocalContext { context.formUnion(lastLocalContext) }
            dot = CollaborationDot(
                actorID: lastLocalDot.actorID,
                counter: lastLocalDot.counter + 1
            )
        } else if lastLocalDot == nil, context[actorID] >= version[actorID] {
            // Migration from clocks persisted before lastLocalDot existed. A full observed frontier
            // can safely continue the primary actor.
            dot = CollaborationDot(actorID: actorID, counter: version[actorID] + 1)
        } else {
            // This editor predates a local/remote event already known by the process. Reusing the
            // primary actor counter would imply a false happened-before edge. A stable branch for
            // this save batch preserves the editor's real observed frontier; later full-context
            // events naturally merge the branch back into the primary replica history.
            dot = CollaborationDot(
                actorID: "\(actorID)|edit|\(operationID)",
                counter: 1
            )
        }
        lamport += 1
        version.observe(dot)
        lastLocalDot = dot
        lastLocalContext = context
        return CollaborationStamp(
            dot: dot,
            context: context,
            lamport: lamport,
            operationID: operationID,
            createdAt: createdAt
        )
    }

    mutating func observe(_ stamp: CollaborationStamp) {
        version.formUnion(stamp.context)
        version.observe(stamp.dot)
        lamport = max(lamport, stamp.lamport)
    }

    /// Incorporates a precomputed operation-log summary. Drawing diffs build this summary away
    /// from MainActor so installing a large page history does not delay Pencil input.
    mutating func observe(
        frontier: CollaborationVersionVector,
        maximumLamport: UInt64
    ) {
        version.formUnion(frontier)
        lamport = max(lamport, maximumLamport)
    }
}

struct CollaborationInkStroke: Codable, Hashable, Sendable {
    /// Stable OR-set identity. The PencilKit serialization is immutable for this identity.
    let id: String
    let drawingData: Data
    let zIndex: Int

    init(id: String, drawingData: Data, zIndex: Int = 0) {
        self.id = id
        self.drawingData = drawingData
        self.zIndex = zIndex
    }
}

/// Object edits carry the complete post-edit value for recovery, plus the precise fields changed
/// by that gesture or editor. Concurrent edits to disjoint fields therefore commute, while two
/// writers of the same field use the causal register and preserve the losing operation.
enum CollaborationElementField: String, Codable, CaseIterable, Hashable, Sendable {
    case logicalBounds
    case rotationRadians
    case zIndex
    case isLocked
    case groupID
    case payload
}

enum CollaborationOperationPayload: Codable, Hashable, Sendable {
    case pagePosition(CollaborativePosition)
    case pageDelete
    case pageRestore
    case metadataSet(field: String, value: Data?)
    case strokeUpsert(CollaborationInkStroke)
    case strokeDelete(strokeID: String)
    case elementUpsert(CanvasPageElement)
    case elementPatch(element: CanvasPageElement, fields: Set<CollaborationElementField>)
    case elementDelete(elementID: UUID)
}

/// An immutable event. CloudKit uses `operationID` as its record ID, so concurrent writers never
/// update the same record and therefore cannot overwrite one another's operation.
struct CollaborationOperation: Identifiable, Codable, Hashable, Sendable {
    var id: String { stamp.operationID }

    let workspaceID: String
    let documentID: String
    let pageID: String
    let stamp: CollaborationStamp
    let payload: CollaborationOperationPayload

    /// Orders even malformed duplicate operation IDs deterministically. A healthy replica never
    /// emits two payloads for one ID, but choosing by canonical bytes prevents arrival order from
    /// becoming observable if storage corruption or a buggy old client does so.
    func deterministicallyPrecedes(_ other: CollaborationOperation) -> Bool {
        if stamp != other.stamp {
            if stamp.deterministicallyPrecedes(other.stamp) { return true }
            if other.stamp.deterministicallyPrecedes(stamp) { return false }
        }
        guard self != other else { return false }
        return canonicalBytes.lexicographicallyPrecedes(other.canonicalBytes)
    }

    static func preferred(
        _ lhs: CollaborationOperation,
        _ rhs: CollaborationOperation
    ) -> CollaborationOperation {
        lhs.deterministicallyPrecedes(rhs) ? rhs : lhs
    }

    private var canonicalBytes: Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(self)) ?? Data()
    }
}

struct CollaborationPageOperationArchive: Codable, Hashable, Sendable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int
    var operations: [CollaborationOperation]

    init(
        schemaVersion: Int = CollaborationPageOperationArchive.currentSchemaVersion,
        operations: [CollaborationOperation]
    ) {
        self.schemaVersion = schemaVersion
        self.operations = operations
    }
}

struct CollaborationConflictCopy: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let targetID: String
    let winnerOperationID: String
    let preservedOperationID: String
    let reason: String
    let payload: CollaborationOperationPayload
}

struct MaterializedCollaborationPage: Codable, Hashable, Sendable {
    var position: CollaborativePosition?
    var isDeleted: Bool
    var metadata: [String: Data]
    var strokes: [String: CollaborationInkStroke]
    var elements: [UUID: CanvasPageElement]
    var conflicts: [CollaborationConflictCopy]
    var frontier: CollaborationVersionVector
}

private struct VersionedCollaborationValue<Value: Equatable & Sendable>: Sendable {
    var value: Value
    var stamp: CollaborationStamp
    var payload: CollaborationOperationPayload
}

private struct VersionedCollaborationElement: Sendable {
    var logicalBounds: VersionedCollaborationValue<CGRect>
    var rotationRadians: VersionedCollaborationValue<Double>
    var zIndex: VersionedCollaborationValue<Int>
    var isLocked: VersionedCollaborationValue<Bool>
    var groupID: VersionedCollaborationValue<UUID?>
    var payload: VersionedCollaborationValue<PageElementPayload>

    init(
        element: CanvasPageElement,
        stamp: CollaborationStamp,
        operationPayload: CollaborationOperationPayload
    ) {
        logicalBounds = VersionedCollaborationValue(
            value: element.logicalBounds,
            stamp: stamp,
            payload: operationPayload
        )
        rotationRadians = VersionedCollaborationValue(
            value: element.rotationRadians,
            stamp: stamp,
            payload: operationPayload
        )
        zIndex = VersionedCollaborationValue(
            value: element.zIndex,
            stamp: stamp,
            payload: operationPayload
        )
        isLocked = VersionedCollaborationValue(
            value: element.isLocked,
            stamp: stamp,
            payload: operationPayload
        )
        groupID = VersionedCollaborationValue(
            value: element.groupID,
            stamp: stamp,
            payload: operationPayload
        )
        payload = VersionedCollaborationValue(
            value: element.payload,
            stamp: stamp,
            payload: operationPayload
        )
    }

    func value(id: UUID) -> CanvasPageElement {
        CanvasPageElement(
            id: id,
            logicalBounds: logicalBounds.value,
            rotationRadians: rotationRadians.value,
            zIndex: zIndex.value,
            isLocked: isLocked.value,
            groupID: groupID.value,
            payload: payload.value
        )
    }

    var stamps: [CollaborationStamp] {
        [
            logicalBounds.stamp,
            rotationRadians.stamp,
            zIndex.stamp,
            isLocked.stamp,
            groupID.stamp,
            payload.stamp
        ]
    }
}

enum CollaborationMergeEngine {
    static func materialize(_ source: [CollaborationOperation]) -> MaterializedCollaborationPage {
        var operationsByID: [String: CollaborationOperation] = [:]
        for operation in source {
            if let current = operationsByID[operation.id] {
                operationsByID[operation.id] = .preferred(current, operation)
            } else {
                operationsByID[operation.id] = operation
            }
        }
        let operations = operationsByID.values.sorted {
            $0.deterministicallyPrecedes($1)
        }

        var frontier = CollaborationVersionVector()
        var position: VersionedCollaborationValue<CollaborativePosition>?
        var pageDeleteStamps: [CollaborationStamp] = []
        var pageRestoreStamps: [CollaborationStamp] = []
        var metadata: [String: VersionedCollaborationValue<Data?>] = [:]
        var strokes: [String: VersionedCollaborationValue<CollaborationInkStroke>] = [:]
        var strokeTombstones: [String: [CollaborationStamp]] = [:]
        var elements: [UUID: VersionedCollaborationElement] = [:]
        var elementTombstones: [UUID: [CollaborationStamp]] = [:]
        var conflicts: [CollaborationConflictCopy] = []

        for operation in operations {
            frontier.formUnion(operation.stamp.context)
            frontier.observe(operation.stamp.dot)
            switch operation.payload {
            case .pagePosition(let value):
                position = mergeRegister(
                    current: position,
                    incoming: VersionedCollaborationValue(
                        value: value,
                        stamp: operation.stamp,
                        payload: operation.payload
                    ),
                    targetID: "page-position",
                    conflicts: &conflicts
                )
            case .pageDelete:
                pageDeleteStamps = causalAntichain(
                    pageDeleteStamps + [operation.stamp]
                )
            case .pageRestore:
                pageRestoreStamps = causalAntichain(
                    pageRestoreStamps + [operation.stamp]
                )
            case .metadataSet(let field, let value):
                metadata[field] = mergeRegister(
                    current: metadata[field],
                    incoming: VersionedCollaborationValue(
                        value: value,
                        stamp: operation.stamp,
                        payload: operation.payload
                    ),
                    targetID: "metadata:\(field)",
                    conflicts: &conflicts
                )
            case .strokeUpsert(let stroke):
                if let tombstones = strokeTombstones[stroke.id], !tombstones.isEmpty {
                    let blockers = blockingTombstones(
                        for: operation.stamp,
                        in: tombstones
                    )
                    if blockers.isEmpty {
                        strokeTombstones[stroke.id] = nil
                    } else {
                        let concurrentBlockers = blockers.filter {
                            operation.stamp.causalRelation(to: $0) == .concurrent
                        }
                        if !concurrentBlockers.isEmpty {
                            preserveConflict(
                                targetID: stroke.id,
                                winner: preferredStamp(in: concurrentBlockers),
                                preserved: operation,
                                reason: "笔迹删除与写入冲突，删除胜出",
                                conflicts: &conflicts
                            )
                        }
                        continue
                    }
                }
                strokes[stroke.id] = mergeRegister(
                    current: strokes[stroke.id],
                    incoming: VersionedCollaborationValue(
                        value: stroke,
                        stamp: operation.stamp,
                        payload: operation.payload
                    ),
                    targetID: stroke.id,
                    conflicts: &conflicts
                )
            case .strokeDelete(let strokeID):
                let tombstone = mergeTombstone(
                    current: strokeTombstones[strokeID] ?? [],
                    incoming: operation.stamp
                )
                strokeTombstones[strokeID] = tombstone
                if let current = strokes[strokeID] {
                    let blockers = blockingTombstones(
                        for: current.stamp,
                        in: tombstone
                    )
                    if blockers.isEmpty {
                        strokeTombstones[strokeID] = nil
                    } else {
                        if current.stamp.causalRelation(to: operation.stamp) == .concurrent {
                            preserveConflict(
                                targetID: strokeID,
                                winner: operation.stamp,
                                preserved: CollaborationOperation(
                                    workspaceID: operation.workspaceID,
                                    documentID: operation.documentID,
                                    pageID: operation.pageID,
                                    stamp: current.stamp,
                                    payload: .strokeUpsert(current.value)
                                ),
                                reason: "笔迹被一端删除、另一端同时修改，删除胜出",
                                conflicts: &conflicts
                            )
                        }
                        strokes[strokeID] = nil
                    }
                }
            case .elementUpsert(let element):
                mergeElementOperation(
                    operation,
                    element: element,
                    fields: Set(CollaborationElementField.allCases),
                    elements: &elements,
                    tombstones: &elementTombstones,
                    conflicts: &conflicts
                )
            case .elementPatch(let element, let fields):
                guard !fields.isEmpty else { continue }
                mergeElementOperation(
                    operation,
                    element: element,
                    fields: fields,
                    elements: &elements,
                    tombstones: &elementTombstones,
                    conflicts: &conflicts
                )
            case .elementDelete(let elementID):
                let tombstone = mergeTombstone(
                    current: elementTombstones[elementID] ?? [],
                    incoming: operation.stamp
                )
                elementTombstones[elementID] = tombstone
                if let current = elements[elementID] {
                    let editSurvives = current.stamps.contains { stamp in
                        blockingTombstones(for: stamp, in: tombstone).isEmpty
                    }
                    if editSurvives {
                        elementTombstones[elementID] = nil
                    } else {
                        let concurrentStamps = current.stamps.filter {
                            $0.causalRelation(to: operation.stamp) == .concurrent
                        }
                        if let preservedStamp = concurrentStamps.max(by: {
                            $0.deterministicallyPrecedes($1)
                        }) {
                            preserveConflict(
                                targetID: elementID.uuidString,
                                winner: operation.stamp,
                                preserved: CollaborationOperation(
                                    workspaceID: operation.workspaceID,
                                    documentID: operation.documentID,
                                    pageID: operation.pageID,
                                    stamp: preservedStamp,
                                    payload: .elementUpsert(current.value(id: elementID))
                                ),
                                reason: "对象被一端删除、另一端同时编辑，删除胜出并保留副本",
                                conflicts: &conflicts
                            )
                        }
                        elements[elementID] = nil
                    }
                }
            }
        }

        return MaterializedCollaborationPage(
            position: position?.value,
            isDeleted: pageDeleteStamps.contains { deletion in
                !pageRestoreStamps.contains { restore in
                    restore.causalRelation(to: deletion) == .after
                }
            },
            metadata: metadata.compactMapValues { $0.value },
            strokes: strokes.mapValues(\.value),
            elements: Dictionary(uniqueKeysWithValues: elements.map { id, element in
                (id, element.value(id: id))
            }),
            conflicts: conflicts.sorted { $0.id < $1.id },
            frontier: frontier
        )
    }

    private static func mergeElementOperation(
        _ operation: CollaborationOperation,
        element: CanvasPageElement,
        fields: Set<CollaborationElementField>,
        elements: inout [UUID: VersionedCollaborationElement],
        tombstones: inout [UUID: [CollaborationStamp]],
        conflicts: inout [CollaborationConflictCopy]
    ) {
        if let currentTombstones = tombstones[element.id], !currentTombstones.isEmpty {
            let blockers = blockingTombstones(
                for: operation.stamp,
                in: currentTombstones
            )
            if blockers.isEmpty {
                tombstones[element.id] = nil
            } else {
                let concurrentBlockers = blockers.filter {
                    operation.stamp.causalRelation(to: $0) == .concurrent
                }
                if !concurrentBlockers.isEmpty {
                    preserveConflict(
                        targetID: element.id.uuidString,
                        winner: preferredStamp(in: concurrentBlockers),
                        preserved: operation,
                        reason: "对象删除与编辑冲突，删除胜出并保留编辑副本",
                        conflicts: &conflicts
                    )
                }
                return
            }
        }

        guard var current = elements[element.id] else {
            elements[element.id] = VersionedCollaborationElement(
                element: element,
                stamp: operation.stamp,
                operationPayload: operation.payload
            )
            return
        }

        let targetID = element.id.uuidString
        func incoming<Value: Equatable & Sendable>(
            _ value: Value
        ) -> VersionedCollaborationValue<Value> {
            VersionedCollaborationValue(
                value: value,
                stamp: operation.stamp,
                payload: operation.payload
            )
        }
        if fields.contains(.logicalBounds) {
            current.logicalBounds = mergeRegister(
                current: current.logicalBounds,
                incoming: incoming(element.logicalBounds),
                targetID: targetID,
                conflicts: &conflicts
            )
        }
        if fields.contains(.rotationRadians) {
            current.rotationRadians = mergeRegister(
                current: current.rotationRadians,
                incoming: incoming(element.rotationRadians),
                targetID: targetID,
                conflicts: &conflicts
            )
        }
        if fields.contains(.zIndex) {
            current.zIndex = mergeRegister(
                current: current.zIndex,
                incoming: incoming(element.zIndex),
                targetID: targetID,
                conflicts: &conflicts
            )
        }
        if fields.contains(.isLocked) {
            current.isLocked = mergeRegister(
                current: current.isLocked,
                incoming: incoming(element.isLocked),
                targetID: targetID,
                conflicts: &conflicts
            )
        }
        if fields.contains(.groupID) {
            current.groupID = mergeRegister(
                current: current.groupID,
                incoming: incoming(element.groupID),
                targetID: targetID,
                conflicts: &conflicts
            )
        }
        if fields.contains(.payload) {
            current.payload = mergeRegister(
                current: current.payload,
                incoming: incoming(element.payload),
                targetID: targetID,
                conflicts: &conflicts
            )
        }
        elements[element.id] = current
    }

    static func canCompact(
        _ operation: CollaborationOperation,
        acknowledgements: [CollaborationAcknowledgement],
        activeParticipantIDs: Set<String>
    ) -> Bool {
        let acknowledgementByParticipant = Dictionary(
            uniqueKeysWithValues: acknowledgements.map { ($0.participantID, $0) }
        )
        return activeParticipantIDs.allSatisfy { participantID in
            acknowledgementByParticipant[participantID]?.frontier.contains(operation.stamp.dot) == true
        }
    }

    private static func mergeRegister<Value: Equatable & Sendable>(
        current: VersionedCollaborationValue<Value>?,
        incoming: VersionedCollaborationValue<Value>,
        targetID: String,
        conflicts: inout [CollaborationConflictCopy]
    ) -> VersionedCollaborationValue<Value> {
        guard let current else { return incoming }
        switch incoming.stamp.causalRelation(to: current.stamp) {
        case .after:
            return incoming
        case .before, .same:
            return current
        case .concurrent:
            let incomingWins = current.stamp.deterministicallyPrecedes(incoming.stamp)
            let winner = incomingWins ? incoming : current
            let loser = incomingWins ? current : incoming
            if current.value != incoming.value {
                let conflictID = "\(targetID)|\(loser.stamp.operationID)"
                if !conflicts.contains(where: { $0.id == conflictID }) {
                    conflicts.append(
                        CollaborationConflictCopy(
                            id: conflictID,
                            targetID: targetID,
                            winnerOperationID: winner.stamp.operationID,
                            preservedOperationID: loser.stamp.operationID,
                            reason: "同一对象发生并发编辑，已确定性合并并保留另一版本",
                            payload: loser.payload
                        )
                    )
                }
            }
            return winner
        }
    }

    private static func mergeTombstone(
        current: [CollaborationStamp],
        incoming: CollaborationStamp
    ) -> [CollaborationStamp] {
        causalAntichain(current + [incoming])
    }

    /// Keeps every causally maximal delete. Collapsing concurrent deletes to one stamp is unsafe:
    /// an edit that observed only the chosen stamp could otherwise resurrect an object while still
    /// concurrent with another delete.
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

    private static func blockingTombstones(
        for stamp: CollaborationStamp,
        in tombstones: [CollaborationStamp]
    ) -> [CollaborationStamp] {
        tombstones.filter { stamp.causalRelation(to: $0) != .after }
    }

    private static func preferredStamp(
        in stamps: [CollaborationStamp]
    ) -> CollaborationStamp {
        precondition(!stamps.isEmpty)
        return stamps.max { lhs, rhs in
            lhs.deterministicallyPrecedes(rhs)
        }!
    }

    private static func preserveConflict(
        targetID: String,
        winner: CollaborationStamp,
        preserved: CollaborationOperation,
        reason: String,
        conflicts: inout [CollaborationConflictCopy]
    ) {
        let conflictID = "\(targetID)|\(preserved.id)"
        guard !conflicts.contains(where: { $0.id == conflictID }) else { return }
        conflicts.append(
            CollaborationConflictCopy(
                id: conflictID,
                targetID: targetID,
                winnerOperationID: winner.operationID,
                preservedOperationID: preserved.id,
                reason: reason,
                payload: preserved.payload
            )
        )
    }
}

struct CollaborationAcknowledgement: Identifiable, Codable, Hashable, Sendable {
    var id: String { "\(documentID)|\(participantID)" }

    let documentID: String
    let participantID: String
    var frontier: CollaborationVersionVector
    var lastSeenAt: Date

    init(
        documentID: String = "",
        participantID: String,
        frontier: CollaborationVersionVector,
        lastSeenAt: Date
    ) {
        self.documentID = documentID
        self.participantID = participantID
        self.frontier = frontier
        self.lastSeenAt = lastSeenAt
    }

    func merged(with other: CollaborationAcknowledgement) -> CollaborationAcknowledgement {
        precondition(documentID == other.documentID && participantID == other.participantID)
        return CollaborationAcknowledgement(
            documentID: documentID,
            participantID: participantID,
            frontier: frontier.union(other.frontier),
            lastSeenAt: max(lastSeenAt, other.lastSeenAt)
        )
    }
}
