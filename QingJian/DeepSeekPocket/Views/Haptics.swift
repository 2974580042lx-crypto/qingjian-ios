import CoreHaptics
import UIKit

// 1.47.1 「马达」: what you feel in the hand.
//
// - While an answer is written: a soft patter in step with the characters inking in, so the
//   hand and the eye agree, a little firmer where a sentence or a paragraph ends. Only while
//   you are watching: Sermo in front, that chat open, the page following the end of the
//   answer (not scrolled up, no finger on it, the sidebar shut).
// - Your message leaving: one firm 「嗒」. The answer finished: 「嗒嗒」, when its last
//   character lands.
// - Small things: a press, a switch, copied or undone.
//
// Every strength and rhythm is in `Feel`, so 「重了」「轻了」 is one change here.

enum Feel {
    // MARK: 出字震动 (Core Haptics taps)

    /// One tap for about this many characters written…
    static let charactersPerTap: Double = 5
    /// …and never closer together than this: about twelve a second at most.
    static let minimumGap: TimeInterval = 0.085
    /// Tap strength for 轻, 中 and 重, from 0 to 1.
    static let tapIntensity: [Float] = [0.32, 0.48, 0.66]
    /// Low is a soft, dull touch, high a crisp click. The patter stays on the soft side.
    static let tapSharpness: Float = 0.36
    /// Where a sentence or a paragraph ends, the tap is this much firmer, and crisper.
    static let stopBoost: Float = 0.2
    static let stopSharpness: Float = 0.58

    // MARK: Moments (the system's feedback generators)

    /// Sending: a rigid knock at full strength.
    static let send: CGFloat = 1
    /// Finished: a medium knock, then a lighter rigid one this long after it.
    static let finishFirst: CGFloat = 0.9
    static let finishSecond: CGFloat = 0.6
    static let finishGap: TimeInterval = 0.11
    /// A plain press.
    static let tap: CGFloat = 0.8
    /// The drawer or a sheet settling.
    static let settle: CGFloat = 0.75
}

/// The moments, unless 触感反馈 is switched off in 设置 → 个性化.
enum Haptic {
    static let enabledKey = "qingjian.haptics"
    static let writingKey = "sermo.haptics.writing"

    @MainActor static var enabled: Bool {
        UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true
    }
    /// 出字震动: 0 关, 1 轻, 2 中 (the default), 3 重. Always 0 with 触感反馈 off.
    @MainActor static var writingLevel: Int {
        guard enabled else { return 0 }
        let raw = UserDefaults.standard.object(forKey: writingKey) as? Int ?? 2
        return min(3, max(0, raw))
    }

    @MainActor private static let light = UIImpactFeedbackGenerator(style: .light)
    @MainActor private static let medium = UIImpactFeedbackGenerator(style: .medium)
    @MainActor private static let soft = UIImpactFeedbackGenerator(style: .soft)
    @MainActor private static let rigid = UIImpactFeedbackGenerator(style: .rigid)
    @MainActor private static let selectionFeedback = UISelectionFeedbackGenerator()
    @MainActor private static let notice = UINotificationFeedbackGenerator()

    /// A plain button press.
    @MainActor static func tap() {
        guard enabled else { return }
        light.impactOccurred(intensity: Feel.tap)
    }
    /// Your message leaves: one firm 「嗒」.
    @MainActor static func send() {
        guard enabled else { return }
        rigid.impactOccurred(intensity: Feel.send)
    }
    /// An answer has finished: 「嗒嗒」.
    @MainActor static func finish() {
        guard enabled else { return }
        medium.impactOccurred(intensity: Feel.finishFirst)
        rigid.prepare()
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(Feel.finishGap * 1_000_000_000))
            Haptic.rigid.impactOccurred(intensity: Feel.finishSecond)
        }
    }
    /// Moving between choices: a model, an option, the next suggestion.
    @MainActor static func select() {
        guard enabled else { return }
        selectionFeedback.selectionChanged()
    }
    /// Something worked that you will want to know about: copied, saved, undone.
    @MainActor static func success() {
        guard enabled else { return }
        notice.notificationOccurred(.success)
    }
    /// The drawer or a sheet settles open or shut.
    @MainActor static func settle() {
        guard enabled else { return }
        soft.impactOccurred(intensity: Feel.settle)
    }
    /// One tap of 出字震动 on a phone without Core Haptics.
    @MainActor static func writingTap(intensity: Float) {
        soft.impactOccurred(intensity: CGFloat(intensity))
    }
}

/// 出字震动: taps in step with the ink of the answer being written.
///
/// Fed the answer's length each time a chunk arrives, it follows the same pace as the ink
/// (`InkTimeline` and `Motion.Stream`), so a tap comes as characters appear, not when the
/// network delivers them. It also says when the last character has landed, which is when
/// the 「嗒嗒」 of a finished answer plays.
@MainActor
final class StreamHaptics {
    static let shared = StreamHaptics()

    /// Asked before every tap: is someone watching the answer come in? (Set by the chat page.)
    var isWatching: () -> Bool = { false }

    private var messageID: UUID?
    private var timeline = InkTimeline()
    /// Where sentences and paragraphs end in the answer, not yet reached by the writing.
    private var stops: [Int] = []
    private var lastStopQueued = -1
    /// How far the writing had got at the last tap (or while nobody was watching).
    private var felt: Double = 0
    private var lastTapAt: TimeInterval = 0
    private var lastFeedAt: TimeInterval = 0
    private var onLanded: (() -> Void)?
    private var loop: Task<Void, Never>?
    private var idleStop: Task<Void, Never>?

    private let supported = CHHapticEngine.capabilitiesForHardware().supportsHaptics
    private var engine: CHHapticEngine?
    private var running = false
    private var players: [String: CHHapticPatternPlayer] = [:]

    private static var now: TimeInterval { Date().timeIntervalSinceReferenceDate }

    /// The answer being written has grown (from the chat's live row).
    func feed(from live: LiveStream) {
        guard Haptic.enabled, let id = live.messageID, live.contentCount > 0 else { return }
        let now = Self.now
        if id != messageID {
            messageID = id
            // Met part-way through (back in a chat still being written): carry on from here,
            // rather than tapping through everything already there. A first chunk is never
            // this long, even from a fast model.
            let shown = live.contentCount > 200 ? live.contentCount : 0
            timeline = InkTimeline(alreadyShown: shown, now: now)
            felt = Double(shown)
            stops.removeAll()
            lastStopQueued = shown - 1
            onLanded = nil
        }
        guard Double(live.contentCount) >= timeline.target else { return }
        timeline.advance(to: live.contentCount, now: now)
        for stop in live.stops where stop > lastStopQueued {
            stops.append(stop)
            lastStopQueued = stop
        }
        lastFeedAt = now
        if Haptic.writingLevel > 0 { warmUp() }
        startLooking()
    }

    /// The answer `id` is complete with `length` characters: run `landed` once the writing
    /// has reached its end (at once if it is not being followed here).
    func finish(messageID id: UUID, length: Int, landed: @escaping () -> Void) {
        guard id == messageID, loop != nil || Double(length) > timeline.target else {
            landed()
            return
        }
        // The last few characters can arrive in the very update that ends the answer.
        if Double(length) > timeline.target {
            timeline.advance(to: length, now: Self.now)
            lastFeedAt = Self.now
        }
        onLanded = landed
        startLooking()
    }

    /// You left the chat: stop, and start afresh if you come back while it is still written.
    func silence() {
        messageID = nil
        stops.removeAll()
        onLanded = nil
    }

    /// A taste of 出字震动 at `level`, for the moment you pick it in Settings: five light taps
    /// and the firmer one of a sentence's end.
    func sample(level: Int) {
        guard level > 0, Haptic.enabled else { return }
        let base = Feel.tapIntensity[min(3, level) - 1]
        guard warmUp(), let engine else {
            Haptic.writingTap(intensity: base)
            return
        }
        let events = (0..<6).map { index -> CHHapticEvent in
            let stop = index == 5
            return Self.tapEvent(intensity: stop ? min(1, base + Feel.stopBoost) : base,
                                 sharpness: stop ? Feel.stopSharpness : Feel.tapSharpness,
                                 at: Double(index) * Feel.minimumGap * 1.3)
        }
        if let pattern = try? CHHapticPattern(events: events, parameters: []),
           let player = try? engine.makePlayer(with: pattern) {
            try? player.start(atTime: CHHapticTimeImmediate)
        }
        if loop == nil { scheduleIdleStop() }
    }

    // MARK: Following the writing

    private func startLooking() {
        guard loop == nil else { return }
        idleStop?.cancel()
        idleStop = nil
        loop = Task { @MainActor in
            // About fifty looks a second, only while an answer is being written.
            while !Task.isCancelled, self.look() {
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
        }
    }

    /// One look at the writing; false once there is nothing more to follow.
    private func look() -> Bool {
        let now = Self.now
        let reached = timeline.frontier(at: now)
        let level = Haptic.writingLevel
        var watching = level > 0 && UIApplication.shared.applicationState == .active && isWatching()
        let passedStop = stops.contains { Double($0) < reached }
        let due = now - lastTapAt >= Feel.minimumGap && (passedStop || reached - felt >= Feel.charactersPerTap)
        // Checked only when a tap is due: a sheet over the chat (Settings, the thinking…).
        if watching && due && Self.chatIsCovered { watching = false }
        var tapped = false
        if !watching {
            // Nothing is owed for what was written while nobody watched.
            felt = reached
        } else if due {
            tap(level: level, stop: passedStop)
            felt = reached
            lastTapAt = now
            tapped = true
        }
        // A sentence's end waits for the next tap if it came too soon after the last one.
        if passedStop && (tapped || !watching) {
            stops.removeAll { Double($0) < reached }
        }
        let landed = reached >= timeline.target
        if landed, let done = onLanded {
            onLanded = nil
            done()
        }
        // Keep looking while more may come; let go a little after the last chunk.
        if landed && (now - lastFeedAt > 0.8 || messageID == nil) {
            loop = nil
            scheduleIdleStop()
            return false
        }
        return true
    }

    private func tap(level: Int, stop: Bool) {
        let base = Feel.tapIntensity[min(3, level) - 1]
        let intensity = stop ? min(1, base + Feel.stopBoost) : base
        let sharpness = stop ? Feel.stopSharpness : Feel.tapSharpness
        guard warmUp(), let engine else {
            Haptic.writingTap(intensity: intensity)
            return
        }
        let key = "\(level)-\(stop)"
        do {
            let player: CHHapticPatternPlayer
            if let made = players[key] {
                player = made
            } else {
                let pattern = try CHHapticPattern(events: [Self.tapEvent(intensity: intensity, sharpness: sharpness, at: 0)],
                                                  parameters: [])
                player = try engine.makePlayer(with: pattern)
                players[key] = player
            }
            try player.start(atTime: CHHapticTimeImmediate)
        } catch {
            // The engine went away underneath (another app took the hardware, say): start
            // again on the next tap.
            engineStopped()
        }
    }

    /// Something is presented over the chat in the window you are looking at.
    private static var chatIsCovered: Bool {
        for scene in UIApplication.shared.connectedScenes where scene.activationState == .foregroundActive {
            guard let windowScene = scene as? UIWindowScene else { continue }
            for window in windowScene.windows where window.isKeyWindow {
                if window.rootViewController?.presentedViewController != nil { return true }
            }
        }
        return false
    }

    private static func tapEvent(intensity: Float, sharpness: Float, at time: TimeInterval) -> CHHapticEvent {
        CHHapticEvent(eventType: .hapticTransient, parameters: [
            CHHapticEventParameter(parameterID: .hapticIntensity, value: intensity),
            CHHapticEventParameter(parameterID: .hapticSharpness, value: sharpness)
        ], relativeTime: time)
    }

    // MARK: The engine

    /// Starts the haptic engine if it is not running; false where it cannot.
    @discardableResult
    private func warmUp() -> Bool {
        guard supported else { return false }
        idleStop?.cancel()
        idleStop = nil
        if engine == nil {
            guard let made = try? CHHapticEngine() else { return false }
            made.playsHapticsOnly = true
            made.isAutoShutdownEnabled = false
            // Called on the engine's own queue.
            made.stoppedHandler = { @Sendable _ in Task { @MainActor in StreamHaptics.shared.engineStopped() } }
            made.resetHandler = { @Sendable in Task { @MainActor in StreamHaptics.shared.engineStopped() } }
            engine = made
        }
        if !running, let engine {
            do { try engine.start() } catch { return false }
            running = true
        }
        return running
    }

    private func engineStopped() {
        running = false
        players.removeAll()
    }

    /// The engine keeps the hardware awake: stop it a few seconds after the last tap.
    private func scheduleIdleStop() {
        idleStop?.cancel()
        idleStop = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled else { return }
            let haptics = StreamHaptics.shared
            guard haptics.loop == nil, haptics.running else { return }
            haptics.engine?.stop(completionHandler: nil)
            haptics.engineStopped()
        }
    }
}
