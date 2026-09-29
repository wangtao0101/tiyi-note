import Foundation

@main
struct CanvasPalmRejectionChecks {
    static func main() {
        var count = 0
        func expect(_ value: Bool, _ message: String) {
            precondition(value, message)
            count += 1
        }
        // Little finger lands first; the pen follows. Lifting the pen cannot
        // reactivate the finger that is still resting on the page.
        var state = CanvasPalmRejectionState<Int>()
        state.begin(pencils: [], fingers: [1], at: 0)
        expect(!state.blocksFingerActions(at: 0), "Idle fingers remain available for navigation")
        state.begin(pencils: [10], fingers: [], at: 0.1)
        expect(state.rejectedFingers == [1], "Reject the finger already on the page")
        state.end([10], at: 0.2)
        expect(state.blocksFingerActions(at: 30), "A resting finger stays blocked, not just for a timer")
        state.end([1], at: 30)
        expect(!state.blocksFingerActions(at: 30), "Release after the hand leaves")

        // Palm arrives during the stroke, another contact arrives between letters.
        state = CanvasPalmRejectionState()
        state.begin(pencils: [10], fingers: [], at: 0)
        state.begin(pencils: [], fingers: [1], at: 0.1)
        state.end([10], at: 0.2)
        state.begin(pencils: [], fingers: [2], at: 0.3)
        state.begin(pencils: [11], fingers: [], at: 0.35)
        state.end([1, 11], at: 0.45)
        expect(state.blocksFingerActions(at: 10), "Remaining palm contact survives repeated pen lifts")
        state.end([2], at: 10)
        expect(!state.blocksFingerActions(at: 10), "Fresh intentional navigation is allowed")

        // Contacts during the short lift grace are latched until their own lift.
        state = CanvasPalmRejectionState()
        state.begin(pencils: [10], fingers: [], at: 0)
        state.end([10], at: 0.1)
        expect(state.blocksFingerActions(at: 0.2), "Protect a brief gap between strokes")
        state.begin(pencils: [], fingers: [1], at: 0.25)
        expect(state.blocksFingerActions(at: 20), "Grace-period contacts cannot become a later pan")
        state.end([1], at: 20)
        state.begin(pencils: [], fingers: [2, 3], at: 21)
        expect(!state.blocksFingerActions(at: 21), "A new two-finger gesture works after handwriting")

        // Cancellation, all-at-once contacts, and long sequences cannot leave a lock behind.
        state.begin(pencils: [12], fingers: [4], at: 22)
        expect(state.rejectedFingers == [2, 3, 4], "All simultaneous hand contacts are blocked")
        state.cancelAll(at: 23)
        expect(!state.blocksFingerActions(at: 24), "Cancellation releases after the grace interval")
        for i in 0..<150 {
            let time = Double(i) + 30
            state.begin(pencils: [1000 + i], fingers: [2000 + i], at: time)
            expect(state.blocksFingerActions(at: time), "Repeated pencil + palm contact")
            state.end([1000 + i], at: time + 0.1)
            expect(state.blocksFingerActions(at: time + 0.6), "Palm survives pen lift")
            state.end([2000 + i], at: time + 0.7)
            expect(!state.blocksFingerActions(at: time + 0.8), "No leaked lock between writing sessions")
        }
        print("Passed \(count) palm rejection state checks")
    }
}
