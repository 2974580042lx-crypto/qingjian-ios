import SwiftUI
import UIKit

/// 1.47: every duration, spring and stagger the app moves with, in one file, so a
/// feel that is too quick or too slow is changed here once and everywhere follows.
///
/// Only opacity, offset, scale and rotation are animated (cheap on the GPU); nothing
/// blurs while it moves. With 减弱动态效果 on in iOS Settings, things fade instead of
/// travelling, and nothing loops.
enum Motion {
    @MainActor static var reduced: Bool { UIAccessibility.isReduceMotionEnabled }

    // MARK: Springs

    /// A button going down under the finger: fast and firm.
    static let pressDown = Animation.spring(response: 0.16, dampingFraction: 0.9)
    /// The same button coming back: a little give, so it feels like rubber, not tin.
    static let pressUp = Animation.spring(response: 0.36, dampingFraction: 0.58)
    /// Most things that appear, move or resize: quick and settled, no wobble.
    static let snappy = Animation.spring(response: 0.34, dampingFraction: 0.86)
    /// Things that should land with life: your message, a finished answer's controls.
    static let lively = Animation.spring(response: 0.46, dampingFraction: 0.74)
    /// Large, calm moves: the welcome page, a chat coming in.
    static let gentle = Animation.spring(response: 0.62, dampingFraction: 0.9)
    /// Lists reordering: pinning, deleting, moving into a project.
    static let list = Animation.spring(response: 0.42, dampingFraction: 0.86)
    /// Fades with no movement.
    static let fade = Animation.easeInOut(duration: 0.22)
    static let quickFade = Animation.easeOut(duration: 0.14)

    // MARK: Sequences

    /// The gap between items that arrive one after another.
    static let stagger: Double = 0.032
    /// `base`, held back by `index` steps of `stagger` (at most `cap` steps).
    static func staggered(_ index: Int, base: Animation = Motion.snappy, cap: Int = 12) -> Animation {
        base.delay(Double(max(0, min(index, cap))) * stagger)
    }

    // MARK: The sidebar drawer (UIKit)

    enum Drawer {
        /// How much the chat page shrinks when the drawer is fully open.
        static let pageShrink: CGFloat = 0.055
        /// How small the drawer starts before it slides into place.
        static let sidebarShrink: CGFloat = 0.035
        /// How dark the page gets at most, in light and dark appearance.
        static let dimLight: CGFloat = 0.07
        static let dimDark: CGFloat = 0.30
        static let duration: TimeInterval = 0.46
        static let damping: CGFloat = 0.86
        static let velocity: CGFloat = 0.3
    }

    // MARK: An answer being written

    enum Stream {
        /// Characters per second shown while the text keeps up with the network.
        static let baseRate: Double = 70
        /// The shown text never trails what has arrived by more than about this long.
        static let maxLag: Double = 0.55
        /// How long a character takes to go from invisible to full ink.
        static let inkIn: Double = 0.32
        /// How far a fresh character rises as it inks in, in points.
        static let rise: CGFloat = 2.5
    }
}

extension Animation {
    /// This animation, or none at all with 减弱动态效果 on.
    @MainActor var motionSafe: Animation? { Motion.reduced ? nil : self }
}

/// `withAnimation`, but immediate with 减弱动态效果 on.
@MainActor
@discardableResult
func withMotion<Result>(_ animation: Animation = Motion.snappy, _ body: () throws -> Result) rethrows -> Result {
    if Motion.reduced { return try body() }
    return try withAnimation(animation, body)
}

// MARK: - Transitions

/// Rises a few points as it fades in.
private struct RiseModifier: ViewModifier {
    let progress: Double
    var distance: CGFloat = 10
    var scale: CGFloat = 0.98
    var anchor: UnitPoint = .center
    func body(content: Content) -> some View {
        let p = CGFloat(progress)
        content
            .opacity(progress)
            .scaleEffect(scale + (1 - scale) * p, anchor: anchor)
            .offset(y: (1 - p) * distance)
    }
}

extension AnyTransition {
    /// Fades in rising from just below; leaves with a plain fade.
    @MainActor static var rise: AnyTransition {
        guard !Motion.reduced else { return .opacity }
        return .asymmetric(
            insertion: .modifier(active: RiseModifier(progress: 0), identity: RiseModifier(progress: 1)),
            removal: .opacity)
    }
    /// Your message leaving the composer: up from the bottom edge, from slightly small,
    /// held at its trailing corner so it reads as coming out of the input bar.
    @MainActor static var sent: AnyTransition {
        guard !Motion.reduced else { return .opacity }
        return .asymmetric(
            insertion: .modifier(active: RiseModifier(progress: 0, distance: 46, scale: 0.86, anchor: .bottomTrailing),
                                 identity: RiseModifier(progress: 1, distance: 46, scale: 0.86, anchor: .bottomTrailing)),
            removal: .opacity)
    }
    /// Grows from a little smaller, for small floating controls.
    @MainActor static var pop: AnyTransition {
        guard !Motion.reduced else { return .opacity }
        return .scale(scale: 0.8).combined(with: .opacity)
    }
    /// Grey suggestion text in the composer: the new one drifts up in as the old fades.
    @MainActor static var ghostSwap: AnyTransition {
        guard !Motion.reduced else { return .opacity }
        return .asymmetric(
            insertion: .modifier(active: RiseModifier(progress: 0, distance: 8, scale: 1, anchor: .leading),
                                 identity: RiseModifier(progress: 1, distance: 8, scale: 1, anchor: .leading)),
            removal: .opacity)
    }
    /// Comes up from the bottom, for bars above the composer.
    @MainActor static var barRise: AnyTransition {
        guard !Motion.reduced else { return .opacity }
        return .asymmetric(
            insertion: .modifier(active: RiseModifier(progress: 0, distance: 14, scale: 0.97, anchor: .bottom),
                                 identity: RiseModifier(progress: 1, distance: 14, scale: 0.97, anchor: .bottom)),
            removal: .modifier(active: RiseModifier(progress: 0, distance: 8, scale: 0.98, anchor: .bottom),
                               identity: RiseModifier(progress: 1, distance: 8, scale: 0.98, anchor: .bottom)))
    }
}

// MARK: - Arrival

/// Rises into place `delay` seconds after it appears while `active`, or after `active`
/// turns on (a finished answer is marked a moment after its controls are first drawn).
/// For small groups that should land one after another.
struct ArriveModifier: ViewModifier {
    var delay: Double = 0
    var distance: CGFloat = 8
    var active = true
    // Once started, `shown` decides; before that, anything inactive is simply visible.
    @State private var started = false
    @State private var shown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        let visible = started ? shown : !active
        content
            .opacity(visible ? 1 : 0)
            .offset(y: visible || reduceMotion ? 0 : distance)
            .onAppear { if active { start() } }
            .onChange(of: active) { _, now in if now && !started { start() } }
    }

    private func start() {
        var still = Transaction()
        still.disablesAnimations = true
        withTransaction(still) { started = true; shown = false }
        // Read now, while the view is being updated; the closure below runs after.
        let animation = reduceMotion ? Motion.fade : Motion.lively.delay(delay)
        let reveal = $shown
        // Next turn of the run loop, so the hidden state is drawn before it animates away.
        DispatchQueue.main.async {
            withAnimation(animation) { reveal.wrappedValue = true }
        }
    }
}

extension View {
    /// Rises into place `delay` seconds after it appears; does nothing when `active` is false.
    func arrive(delay: Double = 0, distance: CGFloat = 8, active: Bool = true) -> some View {
        modifier(ArriveModifier(delay: delay, distance: distance, active: active))
    }
}

// MARK: - Working shimmer

/// A soft band of light passing across text while something is at work, the way
/// Claude writes 「正在搜索…」. Drawn as a mask over the text itself, so it costs one
/// gradient per frame and follows the text's own colour.
struct ShimmerModifier: ViewModifier {
    var active: Bool
    var period: Double = 1.7
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @ViewBuilder func body(content: Content) -> some View {
        if active && !reduceMotion {
            TimelineView(.animation) { timeline in
                let t = timeline.date.timeIntervalSinceReferenceDate
                let phase = CGFloat((t.truncatingRemainder(dividingBy: period)) / period)
                content.mask {
                    GeometryReader { proxy in
                        let width = proxy.size.width
                        let band = max(60, width * 0.45)
                        // Clear at both ends, so the band melts into the dimmer base below it.
                        LinearGradient(stops: [
                            .init(color: .clear, location: 0),
                            .init(color: .black, location: 0.5),
                            .init(color: .clear, location: 1)
                        ], startPoint: .leading, endPoint: .trailing)
                        .frame(width: band)
                        .offset(x: -band + (width + band * 2) * phase)
                        .frame(width: width, height: proxy.size.height, alignment: .leading)
                        .background(Color.black.opacity(0.42))
                    }
                }
            }
        } else {
            content
        }
    }
}

extension View {
    /// A band of light passes across this while `active`.
    func shimmering(_ active: Bool = true) -> some View { modifier(ShimmerModifier(active: active)) }
}
