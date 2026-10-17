import Foundation

/// Finger contacts that overlap handwriting stay rejected until they lift. A
/// brief Pencil lift between letters must not turn the resting hand into a pan.
struct CanvasPalmRejectionState<Contact: Hashable> {
    private(set) var pencils: Set<Contact> = []
    private(set) var fingers: Set<Contact> = []
    private(set) var rejectedFingers: Set<Contact> = []
    private var lastPencilLift: TimeInterval?
    let liftGrace: TimeInterval = 0.35

    func blocksFingerActions(at time: TimeInterval) -> Bool {
        !pencils.isEmpty || !rejectedFingers.isEmpty
            || lastPencilLift.map { time - $0 < liftGrace } == true
    }

    mutating func begin(pencils newPencils: Set<Contact>, fingers newFingers: Set<Contact>, at time: TimeInterval) {
        pencils.formUnion(newPencils)
        fingers.formUnion(newFingers)
        if blocksFingerActions(at: time) { rejectedFingers.formUnion(fingers) }
    }

    mutating func end(_ contacts: Set<Contact>, at time: TimeInterval) {
        let hadPencil = !pencils.isEmpty
        pencils.subtract(contacts)
        if hadPencil && pencils.isEmpty { lastPencilLift = time }
        fingers.subtract(contacts)
        rejectedFingers.subtract(contacts)
    }

    mutating func cancelAll(at time: TimeInterval) {
        end(pencils.union(fingers), at: time)
    }
}

#if canImport(UIKit)
import UIKit

/// Passive observation of both touch types on their common ancestor. It never
/// competes with PencilKit; only finger navigation recognizers are suspended.
final class CanvasPalmRejectionGestureRecognizer: UIGestureRecognizer {
    /// Continuous PDF pages share navigation recognizers. A page that mounts after Pencil-down
    /// has not seen that contact, and removing one page must not release another page's lock.
    private final class NavigationLock {
        var owners: Set<ObjectIdentifier> = []
        let wasEnabled: Bool
        init(wasEnabled: Bool) { self.wasEnabled = wasEnabled }
    }
    private static let navigationLocks = NSMapTable<UIGestureRecognizer, NavigationLock>(
        keyOptions: .weakMemory, valueOptions: .strongMemory
    )

    static func isNavigationSuspended(_ gesture: UIGestureRecognizer) -> Bool {
        navigationLocks.object(forKey: gesture)?.owners.isEmpty == false
    }

    var onNavigationRestored: (() -> Void)?
    private var contacts = CanvasPalmRejectionState<ObjectIdentifier>()
    private let suspendedNavigation = NSHashTable<UIGestureRecognizer>.weakObjects()
    private var releaseWork: DispatchWorkItem?
    private var isDetaching = false

    var blocksFingerActions: Bool { contacts.blocksFingerActions(at: CACurrentMediaTime()) }

    init() {
        super.init(target: nil, action: nil)
        allowedTouchTypes = [NSNumber(value: UITouch.TouchType.pencil.rawValue),
                             NSNumber(value: UITouch.TouchType.direct.rawValue)]
        requiresExclusiveTouchType = false
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
    }

    override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool { false }
    override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool { false }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        contacts.begin(pencils: Set(touches.filter { $0.type == .pencil }.map(ObjectIdentifier.init)),
                       fingers: Set(touches.filter { $0.type == .direct }.map(ObjectIdentifier.init)),
                       at: CACurrentMediaTime())
        refreshNavigationLock()
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        refreshNavigationLock()
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) { finish(touches) }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) { finish(touches) }

    private func finish(_ touches: Set<UITouch>) {
        contacts.end(Set(touches.map(ObjectIdentifier.init)), at: CACurrentMediaTime())
        refreshNavigationLock()
        if contacts.pencils.isEmpty && contacts.fingers.isEmpty { state = .failed }
    }

    override func reset() {
        contacts.cancelAll(at: CACurrentMediaTime())
        if !isDetaching { refreshNavigationLock() }
        super.reset()
    }

    func attach(to host: UIView) {
        guard view !== host else { refreshNavigationLock(); return }
        detach()
        host.addGestureRecognizer(self)
    }

    func detach() {
        // Removing a recognizer may invoke reset synchronously. Clear any work
        // scheduled by that reset before restoring the host's navigation.
        isDetaching = true
        defer { isDetaching = false }
        view?.removeGestureRecognizer(self)
        releaseWork?.cancel()
        releaseWork = nil
        contacts = CanvasPalmRejectionState()
        restoreNavigation(reapplyPolicy: false)
    }

    func refreshNavigationLock() {
        releaseWork?.cancel()
        releaseWork = nil
        guard blocksFingerActions else { restoreNavigation(); return }
        var ancestor = view
        while let host = ancestor {
            // The observer's host contains the camera gestures. Native scrolling
            // lives on ancestor scroll views; never disable PencilKit's ink pan.
            if host === view || host is UIScrollView {
                for gesture in host.gestureRecognizers ?? []
                where gesture is UIPanGestureRecognizer || gesture is UIPinchGestureRecognizer {
                    let direct = NSNumber(value: UITouch.TouchType.direct.rawValue)
                    let pencil = NSNumber(value: UITouch.TouchType.pencil.rawValue)
                    if gesture.allowedTouchTypes.contains(direct)
                        && !gesture.allowedTouchTypes.contains(pencil) {
                        let lock = Self.navigationLocks.object(forKey: gesture)
                            ?? NavigationLock(wasEnabled: gesture.isEnabled)
                        lock.owners.insert(ObjectIdentifier(self))
                        Self.navigationLocks.setObject(lock, forKey: gesture)
                        suspendedNavigation.add(gesture)
                        if gesture.isEnabled { gesture.isEnabled = false }
                    }
                }
            }
            ancestor = host.superview
        }
        if contacts.pencils.isEmpty && contacts.rejectedFingers.isEmpty {
            let work = DispatchWorkItem { [weak self] in self?.refreshNavigationLock() }
            releaseWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + contacts.liftGrace, execute: work)
        }
    }

    private func restoreNavigation(reapplyPolicy: Bool = true) {
        let gestures = suspendedNavigation.allObjects
        suspendedNavigation.removeAllObjects()
        for gesture in gestures {
            guard let lock = Self.navigationLocks.object(forKey: gesture) else { continue }
            lock.owners.remove(ObjectIdentifier(self))
            guard lock.owners.isEmpty else { continue }
            Self.navigationLocks.removeObject(forKey: gesture)
            gesture.isEnabled = lock.wasEnabled
        }
        if reapplyPolicy && !gestures.isEmpty { onNavigationRestored?() }
    }
}
#endif
