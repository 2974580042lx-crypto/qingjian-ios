import AVFoundation
import Foundation
import Speech

/// Live Mandarin speech-to-text controller built on Apple `SFSpeechRecognizer` + `AVAudioEngine`.
/// Honestly verifies both microphone and speech-recognition authorizations and always releases
/// `AVAudioSession` with `.notifyOthersOnDeactivation` on stop.
@MainActor
final class VoiceDictationController: ObservableObject {
    @Published var transcript: String = ""
    @Published private(set) var isListening: Bool = false
    @Published private(set) var audioLevel: Double = 0
    @Published private(set) var authState: VoiceAuthorizationState = .notDetermined
    @Published var statusMessage: String = "点击下方话筒开始说话"
    @Published var errorMessage: String?

    private var recognizer: SFSpeechRecognizer?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var audioEngine: AVAudioEngine?
    private var tapInstalled = false
    private var audioSessionActive = false
    private var sessionToken = UUID()

    func startListening(beforeStart: () -> Void = {}) async {
        stopListening()
        let currentToken = sessionToken
        beforeStart()
        errorMessage = nil

        let state = await ensurePermissions()
        guard sessionToken == currentToken, !Task.isCancelled else { return }
        authState = state
        guard state.isReady else {
            errorMessage = state.userMessage
            statusMessage = "需要先开启权限"
            return
        }

        let speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN"))
            ?? SFSpeechRecognizer(locale: Locale.current)
        guard let speechRecognizer else {
            let msg = "当前系统语言暂不支持语音识别，请在系统「设置 → 通用 → 键盘」启用听写后再试。"
            authState = .unavailable(msg)
            errorMessage = msg
            statusMessage = "语音识别不可用"
            return
        }
        guard speechRecognizer.isAvailable else {
            let msg = "系统语音识别服务当前暂时不可用（请检查网络连接，或在系统里下载离线中文听写语音包）。"
            authState = .unavailable(msg)
            errorMessage = msg
            statusMessage = "服务暂不可用"
            return
        }

        recognizer = speechRecognizer

        do {
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(.playAndRecord, mode: .measurement, options: [.duckOthers, .defaultToSpeaker])
            try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
            audioSessionActive = true

            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = true
            request.addsPunctuation = true
            if #available(iOS 16.0, *) {
                request.taskHint = .dictation
            }
            recognitionRequest = request

            let engine = AVAudioEngine()
            audioEngine = engine
            let inputNode = engine.inputNode
            let recordingFormat = inputNode.outputFormat(forBus: 0)
            guard recordingFormat.sampleRate > 0 && recordingFormat.channelCount > 0 else {
                throw NSError(domain: "SermoVoice", code: -1, userInfo: [NSLocalizedDescriptionKey: "未能初始化麦克风输入通道，请重试。"])
            }

            inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { [weak request, weak self] buffer, _ in
                request?.append(buffer)
                let rms = Self.computeNormalizedLevel(from: buffer)
                Task { @MainActor [weak self] in
                    guard let self, self.sessionToken == currentToken, self.isListening else { return }
                    self.audioLevel = (self.audioLevel * 0.65) + (rms * 0.35)
                }
            }

            tapInstalled = true
            engine.prepare()
            try engine.start()

            isListening = true
            statusMessage = speechRecognizer.supportsOnDeviceRecognition
                ? "正在聆听（普通话实时转写）…"
                : "正在聆听（联网普通话转写）…"

            recognitionTask = speechRecognizer.recognitionTask(with: request) { [weak self] result, error in
                Task { @MainActor [weak self] in
                    guard let self, self.sessionToken == currentToken else { return }
                    if let result {
                        self.transcript = result.bestTranscription.formattedString
                        if result.isFinal {
                            self.stopListening()
                            self.statusMessage = "已识别完成，可编辑后发送"
                        }
                    }
                    if let error {
                        // Ignore expected cancellation errors when user stops recording manually
                        if self.isListening {
                            let ns = error as NSError
                            let isNoSpeech = (ns.domain == "kAFAssistantErrorDomain" && ns.code == 1110)
                            self.stopListening()
                            if isNoSpeech {
                                self.statusMessage = "没有听到清晰人声，点话筒可以再说一遍"
                            } else {
                                self.errorMessage = "语音识别中断：\(error.localizedDescription)"
                                self.statusMessage = "识别已暂停"
                            }
                        }
                    }
                }
            }
        } catch {
            stopListening()
            errorMessage = "无法启动麦克风录音：\(error.localizedDescription)"
            statusMessage = "启动失败"
        }
    }

    func stopListening() {
        sessionToken = UUID()
        isListening = false
        audioLevel = 0

        if let engine = audioEngine {
            if tapInstalled { engine.inputNode.removeTap(onBus: 0); tapInstalled = false }
            if engine.isRunning {
                engine.stop()
            }
            audioEngine = nil
        }
        recognitionRequest?.endAudio()
        recognitionRequest = nil
        recognitionTask?.cancel()
        recognitionTask = nil
        recognizer = nil

        if audioSessionActive {
            audioSessionActive = false
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }

    func clear() {
        transcript = ""
        errorMessage = nil
        statusMessage = isListening ? "正在聆听…" : "点击下方话筒开始说话"
    }

    private func ensurePermissions() async -> VoiceAuthorizationState {
        // 1. Microphone permission
        let micPermission = AVAudioApplication.shared.recordPermission
        switch micPermission {
        case .denied:
            return .microphoneDenied
        case .undetermined:
            let granted = await AVAudioApplication.requestRecordPermission()
            if !granted { return .microphoneDenied }
        case .granted:
            break
        @unknown default:
            return .microphoneDenied
        }

        // 2. Speech recognition permission
        let speechStatus = SFSpeechRecognizer.authorizationStatus()
        switch speechStatus {
        case .authorized:
            return .authorized
        case .denied:
            return .speechDenied
        case .restricted:
            return .restricted
        case .notDetermined:
            let resolved = await withCheckedContinuation { (continuation: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>) in
                SFSpeechRecognizer.requestAuthorization { status in
                    continuation.resume(returning: status)
                }
            }
            switch resolved {
            case .authorized: return .authorized
            case .denied: return .speechDenied
            case .restricted: return .restricted
            default: return .speechDenied
            }
        @unknown default:
            return .speechDenied
        }
    }

    private nonisolated static func computeNormalizedLevel(from buffer: AVAudioPCMBuffer) -> Double {
        guard let channelData = buffer.floatChannelData?[0] else { return 0 }
        let frameLength = Int(buffer.frameLength)
        guard frameLength > 0 else { return 0 }
        var sum: Float = 0
        for i in 0..<frameLength {
            let sample = channelData[i]
            sum += sample * sample
        }
        let rms = sqrt(sum / Float(frameLength))
        // Convert roughly to 0...1 visual level
        let scaled = min(1.0, max(0.0, Double(rms) * 8.5))
        return scaled
    }
}
