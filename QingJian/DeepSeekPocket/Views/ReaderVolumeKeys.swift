import SwiftUI
import AVFAudio
import UIKit

struct ReaderPageCommand: Equatable { var id = UUID(); var step: Int }

@MainActor
final class ReaderVolumeKeys: ObservableObject {
    @Published var command: ReaderPageCommand?
    @Published var issue: String?
    var suspended = false
    private var observation: NSKeyValueObservation?
    private var reverse = false
    private var lastPress = Date.distantPast
    private var previous: (AVAudioSession.Category, AVAudioSession.Mode, AVAudioSession.CategoryOptions)?

    func configure(enabled: Bool, reverse: Bool) {
        self.reverse = reverse
        if !enabled { stop(); return }
        guard observation == nil else { return }
        let session = AVAudioSession.sharedInstance()
        previous = (session.category, session.mode, session.categoryOptions)
        do {
            try session.setCategory(.ambient, mode: .default)
            try session.setActive(true)
            issue = nil
            observation = session.observe(\.outputVolume, options: [.old, .new]) { [weak self] _, change in
                guard let before = change.oldValue, let after = change.newValue else { return }
                Task { @MainActor [weak self] in self?.changed(from: before, to: after) }
            }
        } catch {
            issue = "当前无法启用音量键兼容翻页：\(error.localizedDescription)"
            stop()
        }
    }

    private func changed(from old: Float, to new: Float) {
        guard observation != nil, !suspended, UIApplication.shared.applicationState == .active,
              abs(new - old) > 0.001, Date().timeIntervalSince(lastPress) > 0.22 else { return }
        lastPress = Date()
        let step = new > old ? -1 : 1
        command = ReaderPageCommand(step: reverse ? -step : step)
    }

    func stop() {
        observation = nil
        guard let previous else { return }
        self.previous = nil
        let session = AVAudioSession.sharedInstance()
        try? session.setActive(false, options: .notifyOthersOnDeactivation)
        try? session.setCategory(previous.0, mode: previous.1, options: previous.2)
    }
}

