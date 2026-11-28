import SwiftUI

// 1.47 「流式出字」: an answer that is being written inks in character by character
// instead of jumping a chunk at a time.
//
// Text still arrives in chunks (about fifteen a second) and is laid out once per chunk,
// as before. Between chunks nothing is laid out again: a TextRenderer only draws each
// character at its own opacity, so the extra cost is a little drawing for the paragraph
// being written, and none at all once its ink has settled.
//
// How fast: the shown text follows what has arrived at no less than `Motion.Stream.baseRate`
// characters a second, faster when it falls behind, so it never trails by much more than
// `Motion.Stream.maxLag`. Each character fades in over `Motion.Stream.inkIn` from the moment
// the writing reaches it, rising a hair as it does.

/// When each character of one block of an answer was (or will be) reached by the writing.
/// A value type, so the renderer can be handed a copy each frame.
struct InkTimeline: Sendable {
    /// The writing moved from `from` to `to` starting at `start`, at `rate` characters a second.
    struct Segment: Sendable {
        var from: Double
        var to: Double
        var start: TimeInterval
        var rate: Double
        var reachesEnd: TimeInterval { start + (to - from) / rate }
    }

    private(set) var segments: [Segment] = []
    /// How many characters there are to show.
    private(set) var target: Double = 0
    private(set) var touched: TimeInterval = 0

    /// Starts with `shown` characters already in full ink (a block seen for the first time
    /// mid-way, so it is not written out again from the start).
    init(alreadyShown shown: Int = 0, now: TimeInterval = 0) {
        target = Double(max(0, shown))
        touched = now
    }

    /// The block now has `length` characters; the writing heads for the new end.
    mutating func advance(to length: Int, now: TimeInterval) {
        let goal = Double(max(0, length))
        touched = now
        guard goal != target else { return }
        if goal < target {
            // Re-read text came out shorter: show what is there, at once.
            segments.removeAll()
            target = goal
            return
        }
        let current = frontier(at: now)
        if let last = segments.indices.last, current < segments[last].to {
            segments[last].to = current
        }
        let backlog = goal - current
        let rate = max(Motion.Stream.baseRate, backlog / Motion.Stream.maxLag)
        segments.append(Segment(from: current, to: goal, start: now, rate: rate))
        target = goal
        prune(now)
    }

    /// How far the writing has got at `t`.
    func frontier(at t: TimeInterval) -> Double {
        for segment in segments.reversed() where t >= segment.start {
            return min(segment.to, segment.from + (t - segment.start) * segment.rate)
        }
        return segments.first?.from ?? target
    }

    /// Everything below this index is in full ink at `t`.
    func settledBelow(at t: TimeInterval) -> Double {
        for segment in segments where t < segment.reachesEnd + Motion.Stream.inkIn {
            // The first segment still inking: everything before the part it has not finished.
            let inked = segment.from + max(0, (t - Motion.Stream.inkIn - segment.start) * segment.rate)
            return min(segment.to, inked)
        }
        return target
    }

    /// Opacity of character `index` at `t`, from 0 to 1.
    func ink(_ index: Double, at t: TimeInterval) -> Double {
        let i = min(index, max(0, target - 1))
        if let first = segments.first, i < first.from { return 1 }
        for segment in segments where i >= segment.from && i < segment.to {
            let reached = segment.start + (i - segment.from) / segment.rate
            return min(1, max(0, (t - reached) / Motion.Stream.inkIn))
        }
        return segments.isEmpty ? 1 : (i < target ? 1 : 0)
    }

    /// True once every character is in full ink.
    func isSettled(at t: TimeInterval) -> Bool {
        guard let last = segments.last else { return true }
        return t >= last.reachesEnd + Motion.Stream.inkIn
    }

    /// When the last character will be in full ink.
    var settlesAt: TimeInterval { (segments.last?.reachesEnd ?? touched) + Motion.Stream.inkIn }

    private mutating func prune(_ now: TimeInterval) {
        while let first = segments.first, segments.count > 1, now >= first.reachesEnd + Motion.Stream.inkIn {
            segments.removeFirst()
        }
    }
}

/// The writing's timelines, by block of the answer. Kept outside the views so an answer
/// keeps inking smoothly when its row is rebuilt (the moment it finishes, or when you come
/// back to the chat while it is still being written).
@MainActor
final class InkRegistry {
    static let shared = InkRegistry()
    private var timelines: [String: InkTimeline] = [:]
    private let capacity = 240

    func timeline(_ key: String) -> InkTimeline? { timelines[key] }

    /// Moves `key` on to `length` characters. A block met for the first time starts from
    /// nothing when `fresh`, otherwise in full ink as it is.
    @discardableResult
    func advance(_ key: String, to length: Int, fresh: Bool, now: TimeInterval) -> InkTimeline {
        var timeline = timelines[key] ?? InkTimeline(alreadyShown: fresh ? 0 : length, now: now)
        timeline.advance(to: length, now: now)
        timelines[key] = timeline
        if timelines.count > capacity { trim(now) }
        return timeline
    }

    private func trim(_ now: TimeInterval) {
        let settled = timelines.filter { $0.value.isSettled(at: now) }.sorted { $0.value.touched < $1.value.touched }
        for (key, _) in settled.prefix(timelines.count - capacity / 2) { timelines.removeValue(forKey: key) }
    }
}

/// Draws each character at its ink, rising slightly while it is still fresh.
struct InkRenderer: TextRenderer {
    var timeline: InkTimeline
    var time: TimeInterval

    func draw(layout: Text.Layout, in context: inout GraphicsContext) {
        let settled = timeline.settledBelow(at: time)
        let rise = Motion.Stream.rise
        var index: Double = 0
        for line in layout {
            var count = 0
            for run in line { count += run.count }
            if index + Double(count) <= settled {
                context.draw(line)
                index += Double(count)
                continue
            }
            for run in line {
                for slice in run {
                    let alpha = timeline.ink(index, at: time)
                    if alpha >= 0.995 {
                        context.draw(slice)
                    } else if alpha > 0.005 {
                        var copy = context
                        copy.opacity = alpha
                        copy.translateBy(x: 0, y: CGFloat(1 - alpha) * rise)
                        copy.draw(slice)
                    }
                    index += 1
                }
            }
        }
    }
}

/// A run of answer text that inks in while it is being written. `key` names the block
/// (nil: never inks); `grows` is true for the block the writing is in right now.
struct InkText: View {
    let text: Text
    let length: Int
    let key: String?
    let grows: Bool
    @State private var wake = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let _ = wake
        let now = Date().timeIntervalSinceReferenceDate
        let timeline: InkTimeline? = {
            guard let key, !reduceMotion else { return nil }
            if grows { return InkRegistry.shared.advance(key, to: length, fresh: true, now: now) }
            guard let existing = InkRegistry.shared.timeline(key) else { return nil }
            // The last few characters can land in the same update that ends the answer:
            // they still ink in rather than pop.
            if Double(length) > existing.target {
                return InkRegistry.shared.advance(key, to: length, fresh: true, now: now)
            }
            return existing
        }()
        Group {
            if let timeline, !timeline.isSettled(at: now) {
                // A new chunk re-runs this body with the advanced timeline; between chunks
                // only the clock moves.
                TimelineView(.animation) { frame in
                    text.textRenderer(InkRenderer(timeline: timeline, time: frame.date.timeIntervalSinceReferenceDate))
                }
            } else {
                text
            }
        }
        // Once the ink has settled, redraw once more so the timeline above stops ticking.
        .task(id: TaskKey(length: length, settles: timeline?.settlesAt ?? 0)) {
            guard let timeline else { return }
            let wait = timeline.settlesAt - Date().timeIntervalSinceReferenceDate
            guard wait > 0 else { return }
            try? await Task.sleep(nanoseconds: UInt64((wait + 0.05) * 1_000_000_000))
            if !Task.isCancelled { wake &+= 1 }
        }
    }

    private struct TaskKey: Equatable {
        let length: Int
        let settles: TimeInterval
    }
}
