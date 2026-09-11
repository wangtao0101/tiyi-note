import PencilKit

/// A passive observer: it never recognizes, delays, cancels, or prevents PencilKit's gesture.
/// The only scheduled work belongs to a live contact; lifting cancels it immediately.
final class HeldInkGestureRecognizer: UIGestureRecognizer {
    var canTrack: (() -> Bool)?
    var onContactBegan: (() -> Void)?
    var onHold: (([CGPoint]) -> Bool)?
    var onResume: (() -> Void)?
    var onContactEnded: (([CGPoint], Bool) -> Void)?

    private(set) var isTrackingContact = false
    private weak var trackedTouch: UITouch?
    private var points: [CGPoint] = []
    private var stationaryAnchor = CGPoint.zero
    private var lastMotionAt: TimeInterval = 0
    private var holdWorkItem: DispatchWorkItem?
    private var isPreviewing = false
    private let holdDuration: TimeInterval = 0.62

    init() {
        super.init(target: nil, action: nil)
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
        requiresExclusiveTouchType = false
    }

    override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool { false }
    override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool { false }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        guard !isTrackingContact, touches.count == 1, canTrack?() == true,
              let touch = touches.first else {
            cancelTracking()
            state = .failed
            return
        }
        trackedTouch = touch
        isTrackingContact = true
        points.removeAll(keepingCapacity: true)
        stationaryAnchor = touch.location(in: nil)
        lastMotionAt = CACurrentMediaTime()
        append(touch)
        onContactBegan?()
        scheduleHold(after: holdDuration)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let touch = trackedTouch, touches.contains(touch) else { return }
        let screenPoint = touch.location(in: nil)
        let motion = hypot(screenPoint.x - stationaryAnchor.x, screenPoint.y - stationaryAnchor.y)
        if motion > (isPreviewing ? 6 : 2.5) {
            stationaryAnchor = screenPoint
            lastMotionAt = CACurrentMediaTime()
            if isPreviewing {
                isPreviewing = false
                onResume?()
            }
            if holdWorkItem == nil { scheduleHold(after: holdDuration) }
        }
        for sample in event.coalescedTouches(for: touch) ?? [touch] { append(sample) }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let touch = trackedTouch, touches.contains(touch) else { return }
        append(touch)
        endContact(cancelled: false)
        state = .failed
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        cancelTracking()
        state = .failed
    }

    override func reset() {
        cancelTracking()
        super.reset()
    }

    func cancelTracking() {
        guard isTrackingContact else {
            holdWorkItem?.cancel()
            holdWorkItem = nil
            return
        }
        endContact(cancelled: true)
    }

    private func endContact(cancelled: Bool) {
        holdWorkItem?.cancel()
        holdWorkItem = nil
        isTrackingContact = false
        trackedTouch = nil
        let completedPoints = points
        points.removeAll(keepingCapacity: true)
        isPreviewing = false
        onContactEnded?(completedPoints, cancelled)
    }

    private func append(_ touch: UITouch) {
        guard let canvas = view as? PKCanvasView else { return }
        let zoom = max(canvas.zoomScale, 0.001)
        let location = touch.location(in: canvas)
        let point = CGPoint(x: location.x / zoom, y: location.y / zoom)
        if let last = points.last, hypot(point.x - last.x, point.y - last.y) * zoom < 1 { return }
        points.append(point)
        if points.count > 768 {
            points = points.enumerated().filter { $0.offset.isMultiple(of: 2) }.map(\.element)
        }
    }

    private func scheduleHold(after delay: TimeInterval) {
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, self.isTrackingContact, self.canTrack?() == true else { return }
            self.holdWorkItem = nil
            let remaining = self.holdDuration - (CACurrentMediaTime() - self.lastMotionAt)
            if remaining > 0.005 {
                self.scheduleHold(after: remaining)
            } else if !self.isPreviewing {
                self.isPreviewing = self.onHold?(self.points) == true
            }
        }
        holdWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }
}

/// Observes the same contact as PencilKit's eraser without competing with drawing or navigation.
/// Independent vector objects participate in that contact's undo transaction alongside native ink.
final class ShapeEraserGestureRecognizer: UIGestureRecognizer {
    var canTrack: (() -> Bool)?
    var onContactBegan: (() -> Void)?
    var onSegment: ((CGPoint, CGPoint) -> Void)?
    var onContactEnded: (() -> Void)?
    private weak var trackedTouch: UITouch?
    private var lastPoint: CGPoint?
    var isTrackingContact: Bool { trackedTouch != nil }

    init() {
        super.init(target: nil, action: nil)
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
        requiresExclusiveTouchType = false
    }

    override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool { false }
    override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool { false }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        guard trackedTouch == nil, touches.count == 1, canTrack?() == true,
              let touch = touches.first else {
            endContact()
            state = .failed
            return
        }
        trackedTouch = touch
        onContactBegan?()
        append(touch)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let touch = trackedTouch, touches.contains(touch) else { return }
        for sample in event.coalescedTouches(for: touch) ?? [touch] { append(sample) }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let touch = trackedTouch, touches.contains(touch) else { return }
        append(touch)
        endContact()
        state = .failed
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        endContact()
        state = .failed
    }

    override func reset() {
        endContact()
        super.reset()
    }

    private func append(_ touch: UITouch) {
        guard let canvas = view as? PKCanvasView else { return }
        let location = touch.location(in: canvas)
        let scale = max(canvas.zoomScale, 0.0001)
        let point = CGPoint(x: location.x / scale, y: location.y / scale)
        onSegment?(lastPoint ?? point, point)
        lastPoint = point
    }

    private func endContact() {
        guard trackedTouch != nil else { return }
        trackedTouch = nil
        lastPoint = nil
        onContactEnded?()
    }
}

/// Finger taps select; movement, a second finger, Pencil and long holds immediately leave control
/// with the existing drawing/navigation recognizers. No native text-selection interaction is used.
final class FingerContentTapGestureRecognizer: UIGestureRecognizer {
    weak var drawingRecognizer: UIGestureRecognizer?
    var canSelect: ((CGPoint) -> Bool)?
    var onSelect: (() -> Void)?
    private weak var trackedTouch: UITouch?
    private var initialPoint = CGPoint.zero
    private var timeout: DispatchWorkItem?

    init() {
        super.init(target: nil, action: nil)
        allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
    }

    override func shouldBeRequiredToFail(by otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        // A Pencil contact never depends on this finger-only recognizer, even when practice
        // enables finger drawing. Only a live, eligible finger tap delays native ink recognition.
        otherGestureRecognizer === drawingRecognizer && trackedTouch != nil
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        guard trackedTouch == nil, touches.count == 1, let touch = touches.first,
              touch.type == .direct, canSelect?(touch.location(in: view)) == true else {
            state = .failed
            return
        }
        trackedTouch = touch
        initialPoint = touch.location(in: nil)
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.state == .possible else { return }
            self.state = .failed
        }
        timeout = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let touch = trackedTouch, touches.contains(touch) else { return }
        let point = touch.location(in: nil)
        if hypot(point.x - initialPoint.x, point.y - initialPoint.y) > 8 { state = .failed }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let touch = trackedTouch, touches.contains(touch), state == .possible else { return }
        state = .recognized
        onSelect?()
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) { state = .failed }

    override func reset() {
        timeout?.cancel()
        timeout = nil
        trackedTouch = nil
        super.reset()
    }
}
