import AppKit

/// The two-finger swipe's side of the Quick View preview surface: where the file is drawn while the
/// gesture is under way, and how the next one arrives (PLAN.md §M11). Split from
/// `QuickViewPreviewView`, which owns the backends and the header, to stay under SwiftLint's
/// `type_body_length`.
///
/// The gesture driving all of this is `NSEvent.trackSwipeEvent` in
/// `BrowserWindowController+QuickViewFullSize` — the system tracks the fingers and animates the
/// travel; this only draws where it is told.
extension QuickViewPreviewView {
    static let swipeAnimation = "quickViewSwipe"
    static let flipInDuration: CFTimeInterval = 0.16

    /// Draw the file `offset` points from centre while a two-finger swipe is under way
    /// (PLAN.md §M11). Driven straight from `NSEvent.trackSwipeEvent`'s progress, so this is called
    /// at the system's tracking rate both while the fingers are down and through the animation it
    /// runs after they lift.
    ///
    /// A layer transform rather than a constraint: a constraint change relays out the backend each
    /// frame, and this is called at gesture rate.
    func setSwipeOffset(_ offset: CGFloat) {
        guard let layer = content.layer else { return }
        layer.removeAnimation(forKey: Self.swipeAnimation)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.transform = CATransform3DMakeTranslation(offset, 0, 0)
        CATransaction.commit()
    }

    /// Turn the page: put the next file in behind the surface and bring it on from the edge.
    ///
    /// Both ways of changing file end here. After a swipe, `trackSwipeEvent` has already carried the
    /// old one off, so this is only the arrival; from ← / → nothing has moved yet, so the swap is
    /// instantaneous and the new file slides in over it. That difference is the whole feel of the
    /// keyboard flip — fast, because there is no drag phase in front of it, and smooth, because the
    /// arrival is the same eased slide either way.
    ///
    /// `steps` is the cursor move, and its sign is the side the new file arrives from — fingers left
    /// flip forward, so the old file left to the left and the next one comes in from the right.
    /// There is no exit animation here: after a gesture `trackSwipeEvent` already animated the
    /// progress to ±1, which *is* the exit, and duplicating it was what made the flip feel like two
    /// separate movements.
    func flip(steps: Int, advance: @escaping () -> Void) {
        advance()
        let entry = CGFloat(steps) * bounds.width
        setSwipeOffset(entry)
        // `from:` is stated rather than read off the layer, and that is the whole fix for a flip
        // that brought the next file in from the side it had just left: the presentation layer
        // still shows the *exit* position for a frame after the transform above is set, so reading
        // it here animated from the wrong edge every time.
        animateContent(from: entry, to: 0, duration: Self.flipInDuration, timing: .easeOut)
    }

    /// The user pulled back: run the file home from wherever the fingers left it, at the same speed
    /// a flip travels, so changing your mind costs the same as going through with it.
    func returnSwipe(from offset: CGFloat) {
        let width = bounds.width
        guard width > 0, abs(offset) > 1 else {
            resetSwipe()
            return
        }
        animateContent(
            from: offset,
            to: 0,
            duration: Self.flipInDuration * TimeInterval(abs(offset) / width),
            timing: .easeOut
        )
    }

    /// Put the file back at centre with no animation. The belt to `trackSwipeEvent`'s braces: its
    /// handler always terminates, but a surface torn down mid-gesture must not come back shifted.
    func resetSwipe() {
        content.layer?.removeAnimation(forKey: Self.swipeAnimation)
        content.layer?.transform = CATransform3DIdentity
    }

    /// Slide the content layer to `offset` over `duration`. `CABasicAnimation` rather than
    /// `animator()`: a layer transform is not an animatable `NSView` property, so the animator
    /// proxy would set it outright and the movement would jump.
    private func animateContent(
        from start: CGFloat,
        to offset: CGFloat,
        duration: CFTimeInterval,
        timing: CAMediaTimingFunctionName
    ) {
        guard let layer = content.layer else { return }
        let animation = CABasicAnimation(keyPath: "transform")
        animation.fromValue = NSValue(caTransform3D: CATransform3DMakeTranslation(start, 0, 0))
        animation.toValue = NSValue(caTransform3D: CATransform3DMakeTranslation(offset, 0, 0))
        animation.duration = duration
        animation.timingFunction = CAMediaTimingFunction(name: timing)
        CATransaction.begin()
        layer.transform = CATransform3DMakeTranslation(offset, 0, 0)
        layer.add(animation, forKey: Self.swipeAnimation)
        CATransaction.commit()
    }
}
