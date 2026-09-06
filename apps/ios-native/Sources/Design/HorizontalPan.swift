import SwiftUI
import UIKit

/// A horizontal drag that leaves vertical scrolling alone.
///
/// SwiftUI's `DragGesture` cannot do this. Attached to a row inside a `ScrollView` — with
/// `.gesture`, `.simultaneousGesture` or `.highPriorityGesture`, it makes no difference —
/// it claims the touch on the first twelve points of movement in any direction, and the
/// list stops scrolling wherever a finger lands on a row. Every swipeable list in the app
/// had that problem. UIKit's pan recogniser can be told to begin only when the movement is
/// sideways; a vertical pull then fails it, the scroll view's own pan takes the touch, and
/// a sideways one cancels the touches beneath it, so the row's button never sees the
/// release as a tap.
///
/// The recogniser is attached to the nearest enclosing scroll view rather than to this
/// view, because this view refuses hit-testing: the SwiftUI content above it — the button,
/// its long press, its context menu — keeps receiving touches exactly as it would without
/// it. A recogniser only hears about a touch from the touched view or its ancestors, and
/// the touched view here is SwiftUI's hosting view, which sits *above* this one; the scroll
/// view is above both. The delegate narrows it to touches inside this row's own frame.
struct HorizontalPan: UIViewRepresentable {
    /// Horizontal translation so far, in points.
    var onChange: (CGFloat) -> Void
    /// Final translation, and whether the gesture was cancelled rather than released.
    var onEnd: (CGFloat, Bool) -> Void

    func makeUIView(context: Context) -> PanAnchorView {
        let view = PanAnchorView()
        view.onChange = onChange
        view.onEnd = onEnd
        return view
    }

    func updateUIView(_ view: PanAnchorView, context: Context) {
        view.onChange = onChange
        view.onEnd = onEnd
    }

    static func dismantleUIView(_ view: PanAnchorView, coordinator: ()) {
        view.detach()
    }
}

final class PanAnchorView: UIView, UIGestureRecognizerDelegate {
    var onChange: ((CGFloat) -> Void)?
    var onEnd: ((CGFloat, Bool) -> Void)?

    private var pan: UIPanGestureRecognizer?
    private weak var host: UIView?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isUserInteractionEnabled = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Never the touch's view. The SwiftUI content drawn over this view is what a finger
    /// is touching; the recogniser hears about it from the ancestor it is attached to.
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? { nil }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        detach()
        if window != nil { attach() }
    }

    /// The nearest scroll view above this row, or the top of the hierarchy when there is
    /// none. Either is an ancestor of whatever view the finger actually lands on.
    private func anchorHost() -> UIView? {
        var view = superview
        while let current = view {
            if current is UIScrollView { return current }
            guard let above = current.superview else { return current }
            view = above
        }
        return nil
    }

    private func attach() {
        guard pan == nil, let target = anchorHost() else { return }
        let recogniser = UIPanGestureRecognizer(target: self, action: #selector(handle(_:)))
        recogniser.delegate = self
        recogniser.maximumNumberOfTouches = 1
        // Once this begins, the touches under it are cancelled: the button's press ends
        // without a tap, and a long press that had started is abandoned.
        recogniser.cancelsTouchesInView = true
        target.addGestureRecognizer(recogniser)
        pan = recogniser
        host = target
    }

    func detach() {
        if let pan, let host { host.removeGestureRecognizer(pan) }
        pan = nil
        host = nil
    }

    // MARK: UIGestureRecognizerDelegate

    /// Only touches that land on this row.
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        bounds.contains(touch.location(in: self))
    }

    /// Only sideways movement. A vertical pull fails here, and the scroll view above takes it.
    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard let pan = gestureRecognizer as? UIPanGestureRecognizer else { return true }
        let velocity = pan.velocity(in: self)
        return abs(velocity.x) > abs(velocity.y) * 1.25
    }

    /// The scroll view's pan may also be tracking this touch; letting both run is what keeps
    /// a diagonal pull from feeling stuck. `gestureRecognizerShouldBegin` has already made
    /// sure ours only runs when the pull is mostly sideways.
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        other.view is UIScrollView
    }

    @objc private func handle(_ recogniser: UIPanGestureRecognizer) {
        let x = recogniser.translation(in: self).x
        switch recogniser.state {
        case .began, .changed:
            onChange?(x)
        case .ended:
            onEnd?(x, false)
        case .cancelled, .failed:
            onEnd?(x, true)
        default:
            break
        }
    }
}
