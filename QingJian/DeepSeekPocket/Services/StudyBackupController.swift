import Foundation
import Combine
import UIKit

struct StudyRestorePreview: Identifiable {
    let id = UUID()
    let file: StudyDriveFile
    let payload: StudyBackupPayload
    let account: String?
    let isRemote: Bool
    let generation: Int
}

@MainActor final class StudyBackupController: ObservableObject {
    @Published private(set) var state = StudyCloudState()
    @Published private(set) var busy = false
    @Published private(set) var files: [StudyDriveFile] = []
    @Published var issue: String?
    @Published var preview: StudyRestorePreview?
    @Published private(set) var localRecoveryFiles: [URL] = []
    @Published private(set) var imageCapacity: StudyImageCapacity?
    private weak var app: AppStore?
    private var account: String?
    private var observer: AnyCancellable?
    private var scheduled: Task<Void, Never>?
    private var running: Task<Void, Never>?
    private var foreground = true
    private var capacityWarningShown = false
    private let deviceID: String
    init() {
        let key = "sermo.study-backup.install-id"
        let install = UserDefaults.standard.string(forKey: key) ?? UUID().uuidString
        UserDefaults.standard.set(install, forKey: key)
        deviceID = install + "-" + (UIDevice.current.identifierForVendor?.uuidString ?? "unknown-device")
        state.enabled = UserDefaults.standard.object(forKey: "sermo.study-backup.enabled") as? Bool ?? true
    }
    var status: String {
        if busy { return "正在处理学习备份…" }
        if state.conflict { return "检测到其他设备的新版本，等待你选择" }
        if account == nil { return "等待Google登录" }
        if !state.enabled { return "自动备份已关闭，本机记录照常保存" }
        if state.upload != nil { return "本机待传文件已保留，下次继续上传" }
        if (state.lastOmittedImageCount ?? 0) > 0 {
            return state.dirty ? "本机有新记录待备份；上一份保底包仍缺\(state.lastOmittedImageCount!)张图" : "记录已备份；\(state.lastOmittedImageCount!)张图片尚未包含，不能视为完整图片备份"
        }
        return state.dirty ? "本机已保存，等待云盘备份" : "云盘已回读校验"
    }
    private func root() throws -> URL {
        let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        return base.appendingPathComponent("QingJian/StudyCloud", isDirectory: true)
    }
    private func accountDirectory() throws -> URL {
        guard let account else { throw GoogleAuthError.signInRequired }
        let path = try root().appendingPathComponent(StudyCoding.hash(Data(account.utf8)), isDirectory: true)
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true); return path
    }
    private func write(_ data: Data, to url: URL) throws { try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]) }
    private func persist() throws { try write(StudyCoding.encode(state), to: accountDirectory().appendingPathComponent("state.json")) }
    private func refreshAccount(cancelRunning: Bool = true) throws {
        let next = app?.drive.backupAccountID
        guard next != account else { return }
        scheduled?.cancel(); if cancelRunning { running?.cancel() }; preview = nil; files = []; issue = nil
        account = next; state = StudyCloudState()
        state.enabled = UserDefaults.standard.object(forKey: "sermo.study-backup.enabled") as? Bool ?? true
        guard next != nil else { return }
        let path = try accountDirectory().appendingPathComponent("state.json")
        if FileManager.default.fileExists(atPath: path.path) { state = try StudyCoding.decode(StudyCloudState.self, from: Data(contentsOf: path)) }
        state.enabled = UserDefaults.standard.object(forKey: "sermo.study-backup.enabled") as? Bool ?? true
        try persist()
    }
    func configure(_ app: AppStore) {
        self.app = app
        guard !app.isPreview else { return }
        observer = app.drive.objectWillChange.sink { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                do { try self.refreshAccount(); self.schedule() } catch { self.issue = error.localizedDescription }
            }
        }
        do { try refreshAccount(); schedule() } catch { issue = error.localizedDescription }
    }
    func changed() {
        guard let app, !app.isPreview, !app.restoringStudyBackup else { return }
        do { try refreshAccount(); state.changed(); if account != nil { try persist(); schedule() } }
        catch { issue = error.localizedDescription }
    }
    func setEnabled(_ enabled: Bool) {
        state.enabled = enabled
        UserDefaults.standard.set(enabled, forKey: "sermo.study-backup.enabled")
        do { if account != nil { try persist() } } catch { issue = error.localizedDescription }
        if enabled { schedule() } else { scheduled?.cancel(); running?.cancel() }
    }
    func setForeground(_ value: Bool) {
        foreground = value
        if value { do { try refreshAccount(); if state.enabled { syncNow() } } catch { issue = error.localizedDescription } }
        else { scheduled?.cancel(); running?.cancel() }
    }
    private func schedule() {
        guard foreground, state.enabled, !state.conflict, account != nil, !busy, preview == nil else { return }
        scheduled?.cancel()
        let minimum = max(30, 300 - Date().timeIntervalSince(state.lastVerifiedAt ?? .distantPast))
        scheduled = Task { [weak self] in
            try? await Task.sleep(for: .seconds(minimum))
            guard !Task.isCancelled else { return }
            self?.syncNow()
        }
    }
    func syncNow(keepLocal: Bool = false) {
        guard !busy, preview == nil else { return }
        scheduled?.cancel()
        running = Task { [weak self] in await self?.sync(keepLocal: keepLocal) }
    }
    private func sync(keepLocal: Bool) async {
        guard !busy, let app, !app.isPreview, app.canPersist, foreground else { return }
        guard !app.isGenerating && !app.isTranslating && !app.restoringStudyBackup else { schedule(); return }
        do { try refreshAccount(cancelRunning: false) } catch { issue = error.localizedDescription; return }
        guard let currentAccount = account else { return }
        busy = true
        defer { busy = false; if state.dirty && !state.conflict { schedule() } }
        do {
            let client = try app.drive.studyBackupClient()
            let before = try await client.listBackups(); try Task.checkCancellation()
            guard account == currentAccount else { throw CancellationError() }
            files = before
            if state.conflicts(with: before, deviceID: deviceID) && !keepLocal {
                state.conflict = true; try persist(); return
            }
            let pendingURL = try accountDirectory().appendingPathComponent("pending.json")
            if keepLocal {
                if FileManager.default.fileExists(atPath: pendingURL.path) {
                    try FileManager.default.copyItem(at: pendingURL, to: accountDirectory().appendingPathComponent("retained-pending-\(UUID().uuidString).json"))
                }
                state.acknowledgedIDs = Set(before.map(\.id)); state.conflict = false; state.upload = nil
                state.pendingFingerprint = nil; state.pendingGeneration = nil; state.dirty = true; try persist()
            }
            var data: Data
            var payload: StudyBackupPayload
            if state.upload != nil && FileManager.default.fileExists(atPath: pendingURL.path) {
                data = try Data(contentsOf: pendingURL); payload = try StudyBackupCodec.decode(data)
                guard payload.backupID.uuidString == state.upload?.backupID, payload.contentFingerprint == state.pendingFingerprint else { throw StudyBackupError.invalid("待传文件与状态不一致，请保留文件并重新准备备份。") }
            } else {
                let capture = try app.studyBackupCapture()
                let generation = state.generation, device = deviceID, images = try ImageStore.directory()
                imageCapacity = try StudyBackupCodec.imageCapacity(snapshot: capture.0, learning: capture.1) { name in try images.appendingPathComponent(name).resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0 }
                showCapacityWarningIfNeeded()
                (data, payload) = try await Task.detached(priority: .utility) {
                    let p = try StudyBackupCodec.captureResilient(snapshot: capture.0, learning: capture.1, deviceID: device,
                        imageSize: { name in try images.appendingPathComponent(name).resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0 },
                        imageLoader: { name in try Data(contentsOf: images.appendingPathComponent(name)) })
                    return try StudyBackupCodec.encodeResilient(p)
                }.value
                try Task.checkCancellation(); guard account == currentAccount else { throw CancellationError() }
                if payload.contentFingerprint == state.lastFingerprint && !keepLocal {
                    state.dirty = state.generation != generation; state.error = nil; issue = nil; try persist(); return
                }
                try write(data, to: pendingURL)
                state.upload = .init(backupID: payload.backupID.uuidString, sessionURL: nil, offset: 0)
                state.pendingFingerprint = payload.contentFingerprint; state.pendingGeneration = generation; try persist()
            }
            guard let upload = state.upload, let generation = state.pendingGeneration else { throw StudyBackupError.unavailable }
            let file = try await client.upload(data, payload: payload, session: upload) { [weak self] progress in
                guard let self else { throw CancellationError() }
                try await self.saveProgress(progress, account: currentAccount)
            }
            let readback = try await client.download(file)
            guard StudyCoding.hash(readback) == StudyCoding.hash(data) else { throw StudyBackupError.invalid("上传后的实际云盘文件与本机文件不一致，未标记成功。") }
            let after = try await client.listBackups()
            try Task.checkCancellation(); guard account == currentAccount else { throw CancellationError() }
            files = after
            let beforeIDs = Set(before.map(\.id))
            if after.contains(where: { !beforeIDs.contains($0.id) && $0.deviceID != deviceID }) {
                state.conflict = true; issue = "本机版本已上传保留，但另一个设备同时写入了新版本，请选择如何继续。"; try persist(); return
            }
            let previousOmitted = state.lastOmittedImageCount ?? 0
            state.verified(file: file, fingerprint: payload.contentFingerprint, generation: generation, files: after, omittedImages: payload.omittedImages?.count ?? 0)
            if !payload.isComplete && previousOmitted != payload.omittedImages?.count {
                app.notifyStudyBackup("记录保底包已备份，\(payload.omittedImages?.count ?? 0)张图片未包含；本机图片和旧完整云端版本仍保留。")
            }
            issue = nil; try persist()
            if FileManager.default.fileExists(atPath: pendingURL.path) { try FileManager.default.removeItem(at: pendingURL) }
        } catch is CancellationError {
            issue = "备份已暂停，待传内容保留，回到App后继续。"
        } catch {
            state.error = error.localizedDescription; issue = error.localizedDescription
            try? persist()
        }
    }
    private func saveProgress(_ progress: StudyUploadSession, account expected: String) throws {
        guard account == expected, state.upload?.backupID == progress.backupID else { throw CancellationError() }
        state.upload = progress; try persist()
    }
    func refreshFiles() {
        guard !busy, let app else { return }
        running = Task {
            guard !busy else { return }
            busy = true; defer { busy = false }
            do { try refreshAccount(cancelRunning: false); files = try await app.drive.studyBackupClient().listBackups(); issue = nil }
            catch { issue = error.localizedDescription }
        }
    }
    func prepareRestore(_ file: StudyDriveFile) {
        guard !busy, let app, app.canRestoreStudyBackup else { issue = "请先等待当前回答或记忆处理结束。"; return }
        running = Task {
            guard !busy else { return }
            busy = true; defer { busy = false }
            do {
                try refreshAccount(cancelRunning: false); guard let selectedAccount = account else { throw GoogleAuthError.signInRequired }
                let data = try await app.drive.studyBackupClient().download(file)
                let payload = try StudyBackupCodec.decode(data)
                guard account == selectedAccount else { throw CancellationError() }
                let current = try app.studyBackupCapture()
                _ = try StudyBackupCodec.merge(payload, into: current.0, currentLearning: current.1)
                preview = .init(file: file, payload: payload, account: selectedAccount, isRemote: true, generation: state.generation)
                issue = nil
            } catch { issue = error.localizedDescription }
        }
    }
    func confirmRestore() {
        guard !busy, let app, let preview else { return }
        guard (!preview.isRemote || preview.account == account), preview.generation == state.generation, app.canRestoreStudyBackup else { issue = "本机记录或账号已变化，请重新查看恢复预览。"; return }
        busy = true; defer { busy = false; schedule() }
        do {
            try app.restoreStudyBackup(preview.payload)
            if preview.isRemote { state.acknowledgedIDs = Set(files.map(\.id)).union([preview.file.id]) }
            state.conflict = false; state.upload = nil; state.pendingFingerprint = nil; state.pendingGeneration = nil
            state.changed(); if account != nil { try persist() }; self.preview = nil; issue = nil; refreshRecoveryFiles()
        } catch { issue = error.localizedDescription }
    }
    func prepareLocalRestore(_ url: URL) {
        guard !busy, let app, app.canRestoreStudyBackup else { issue = "请先等待当前回答或记忆处理结束。"; return }
        running = Task {
            guard !busy else { return }
            busy = true; defer { busy = false }
            let copied = await Task.detached(priority: .utility) { IncomingFile.privateCopy(of: url) }.value
            let target = copied ?? url
            defer { if let copied { try? FileManager.default.removeItem(at: copied.deletingLastPathComponent()) } }
            let access = target.startAccessingSecurityScopedResource()
            defer { if access { target.stopAccessingSecurityScopedResource() } }
            do {
                let payload = try await Task.detached(priority: .utility) {
                    guard (try target.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= StudyBackupCodec.maximumBytes else { throw StudyBackupError.invalid("备份文件超过160MB。") }
                    return try StudyBackupCodec.decode(Data(contentsOf: target))
                }.value
                let current = try app.studyBackupCapture()
                _ = try StudyBackupCodec.merge(payload, into: current.0, currentLearning: current.1)
                preview = .init(file: .init(id: "local", name: url.lastPathComponent), payload: payload, account: account, isRemote: false, generation: state.generation)
                issue = nil
            } catch { issue = error.localizedDescription }
        }
    }
    func refreshRecoveryFiles() {
        guard let directory = try? AppStore.studyRecoveryDirectory() else { return }
        localRecoveryFiles = ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.creationDateKey])) ?? [])
            .filter { $0.lastPathComponent.hasPrefix("before-restore-backup-") && $0.pathExtension == "json" }
            .sorted { ((try? $0.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast) > ((try? $1.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast) }
    }
    func refreshImageCapacity() {
        guard let app, !app.isPreview else { return }
        do {
            let data = try app.studyBackupCapture(), directory = try ImageStore.directory()
            imageCapacity = try StudyBackupCodec.imageCapacity(snapshot: data.0, learning: data.1) { name in try directory.appendingPathComponent(name).resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0 }
            showCapacityWarningIfNeeded()
        } catch { issue = error.localizedDescription }
    }
    private func showCapacityWarningIfNeeded() {
        let near = imageCapacity?.warning == true
        if near && !capacityWarningShown {
            app?.notifyStudyBackup("学习图片容量已接近预算或有图片不可读，请在设置“学习备份”查看。超额时会先保存记录保底包，不会冒充完整图片备份。")
        }
        capacityWarningShown = near
    }
}
