import Foundation
import Combine
import UIKit

@MainActor
final class DriveFullBackupController: ObservableObject {
    private static let enabledKey = "sermo.drive-full-backup.enabled"
    private static let installIDKey = "sermo.drive-full-backup.install-id"

    @Published private(set) var state = DriveFullBackupState()
    @Published private(set) var busy = false
    @Published private(set) var files: [StudyDriveFile] = []
    @Published var issue: String?

    private weak var app: AppStore?
    private var account: String?
    private var driveObserver: AnyCancellable?
    private var activeTask: Task<Void, Never>?
    private let deviceID: String

    init() {
        let install = UserDefaults.standard.string(forKey: Self.installIDKey) ?? UUID().uuidString
        UserDefaults.standard.set(install, forKey: Self.installIDKey)
        deviceID = install + "-" + (UIDevice.current.identifierForVendor?.uuidString ?? "ios-device")
        state.enabled = UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true
    }

    var statusSummary: String {
        if busy { return "正在处理 Google 云盘备份…" }
        if account == nil { return "尚未连接 Google 云盘" }
        if !state.enabled { return "自动云备份已关闭" }
        if let err = state.lastError, !err.isEmpty { return "上次备份未完成（联网后自动重试）" }
        if state.pendingUpload != nil { return "待传备份已保留，回到前台后继续上传" }
        if let success = state.lastSuccessAt {
            if Calendar.current.isDateInToday(success) {
                return "今日已备份（\(success.formatted(date: .omitted, time: .shortened))）"
            }
            return "最近备份：\(success.formatted(date: .abbreviated, time: .shortened))"
        }
        return "等待首次自动备份"
    }

    private func rootDirectory() throws -> URL {
        let dir = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("QingJian/DriveFullBackup", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: dir.path)
        return dir
    }

    private func accountDirectory() throws -> URL {
        guard let account, !account.isEmpty else { throw GoogleAuthError.signInRequired }
        let dir = try rootDirectory().appendingPathComponent(StudyCoding.hash(Data(account.utf8)), isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: dir.path)
        return dir
    }

    private func persistState() throws {
        let target = try accountDirectory().appendingPathComponent("state.json")
        let encoded = try StudyCoding.encode(state)
        try encoded.write(to: target, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    private func syncAccountIfNeeded(cancelActive: Bool = true) throws {
        let next = app?.drive.backupAccountID
        guard next != account else { return }
        if cancelActive { activeTask?.cancel() }
        files = []
        issue = nil
        account = next
        var fresh = DriveFullBackupState()
        fresh.enabled = UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true
        state = fresh
        guard next != nil else { return }
        let stateURL = try accountDirectory().appendingPathComponent("state.json")
        if FileManager.default.fileExists(atPath: stateURL.path),
           let loaded = try? StudyCoding.decode(DriveFullBackupState.self, from: Data(contentsOf: stateURL)) {
            state = loaded
            state.enabled = UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true
        }
        try persistState()
    }

    func configure(_ app: AppStore) {
        self.app = app
        guard !app.isPreview else { return }
        driveObserver = app.drive.objectWillChange.sink { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                do {
                    try self.syncAccountIfNeeded()
                    self.checkDailyBackupIfNeeded(force: false)
                } catch {
                    self.issue = error.localizedDescription
                }
            }
        }
        do { try syncAccountIfNeeded() } catch { issue = error.localizedDescription }
    }

    func setEnabled(_ enabled: Bool) {
        state.enabled = enabled
        UserDefaults.standard.set(enabled, forKey: Self.enabledKey)
        if account != nil { try? persistState() }
        if enabled {
            checkDailyBackupIfNeeded(force: false)
        } else {
            activeTask?.cancel()
        }
    }

    func checkDailyBackupIfNeeded(force: Bool = false) {
        guard !busy, let app, !app.isPreview, app.canPersist else { return }
        do { try syncAccountIfNeeded(cancelActive: false) } catch { issue = error.localizedDescription; return }
        guard let currentAccount = account, app.drive.connected else {
            if force { issue = "请先在「授权与连接」中登录 Google 云盘。" }
            return
        }
        if !force {
            let hasPending = (state.pendingUpload != nil)
            let shouldRun = hasPending || state.shouldRunAutomaticBackup(now: Date(), hasRealData: app.hasRealBackupData)
            guard shouldRun else { return }
            guard !app.isGenerating && !app.unifiedBackupBusy && !app.restoringStudyBackup else { return }
        } else {
            guard !app.unifiedBackupBusy && !app.restoringStudyBackup else {
                issue = "当前正在执行另一项备份或恢复操作，请稍候再试。"
                return
            }
        }

        busy = true
        issue = nil
        let lease = DriveUploadBackgroundLease()
        let worker = Task { @MainActor [weak self] in
            defer { lease.end() }
            guard let self else { return }
            defer { self.busy = false }
            await self.performUpload(account: currentAccount, force: force)
        }
        lease.bind(worker)
        activeTask = worker
    }

    private func performUpload(account expectedAccount: String, force: Bool) async {
        guard let app else { return }
        do {
            let client = try app.drive.fullBackupClient()
            let pendingFileURL = try accountDirectory().appendingPathComponent("pending.sermobackup")
            let data: Data
            let payload: UnifiedBackupPayload
            let fingerprint: String

            if !force,
               state.pendingUpload != nil,
               FileManager.default.fileExists(atPath: pendingFileURL.path),
               let existingBytes = try? Data(contentsOf: pendingFileURL),
               let decoded = try? UnifiedBackupCodec.decode(existingBytes),
               decoded.backupID.uuidString == state.pendingUpload?.backupID {
                data = existingBytes
                payload = decoded
                fingerprint = try state.pendingFingerprint ?? UnifiedBackupCodec.contentFingerprint(of: decoded)
            } else {
                let captured = try await app.captureUnifiedBackupData(imageBudgetBytes: UnifiedBackupCodec.maximumImageBudgetBytes)
                try Task.checkCancellation()
                guard account == expectedAccount else { throw CancellationError() }
                if !force, let lastFP = state.lastFingerprint, lastFP == captured.fingerprint {
                    // Data unchanged since last verified cloud backup: mark today checked without uploading duplicate identical bytes
                    state.lastSuccessAt = Date()
                    state.lastAttemptAt = Date()
                    state.lastError = nil
                    try persistState()
                    return
                }
                data = captured.data
                payload = captured.payload
                fingerprint = captured.fingerprint
                try data.write(to: pendingFileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
                state.pendingUpload = StudyUploadSession(backupID: payload.backupID.uuidString, sessionURL: nil, offset: 0)
                state.pendingFingerprint = fingerprint
                try persistState()
            }

            guard let session = state.pendingUpload else { return }
            let uploaded = try await client.upload(
                data,
                payload: payload,
                deviceID: deviceID,
                session: session
            ) { [weak self] updatedSession in
                guard let self else { throw CancellationError() }
                await MainActor.run {
                    guard self.account == expectedAccount else { return }
                    self.state.pendingUpload = updatedSession
                    try? self.persistState()
                }
            }
            let allFiles = try await client.listBackups()
            try Task.checkCancellation()
            guard account == expectedAccount else { throw CancellationError() }
            files = allFiles
            state.markSucceeded(fileID: uploaded.id, fileName: uploaded.name, fingerprint: fingerprint, now: Date())
            issue = nil
            try persistState()
            if FileManager.default.fileExists(atPath: pendingFileURL.path) {
                try? FileManager.default.removeItem(at: pendingFileURL)
            }
            if force {
                app.noticeMessage = "已上传新版本备份至 Google 云盘 /Sermo Backups/（历史备份均完整保留）。"
            }
        } catch is CancellationError {
            issue = "云盘备份已暂停，回到前台联网后会自动继续上传。"
        } catch {
            state.markFailed(error.localizedDescription, now: Date())
            issue = error.localizedDescription
            try? persistState()
        }
    }

    func refreshHistory() {
        guard !busy, let app else { return }
        busy = true
        let worker = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.busy = false }
            do {
                try self.syncAccountIfNeeded(cancelActive: false)
                guard self.account != nil, app.drive.connected else {
                    self.issue = "请先登录 Google 云盘后再查看历史备份。"
                    return
                }
                self.files = try await app.drive.fullBackupClient().listBackups()
                self.issue = nil
            } catch {
                self.issue = error.localizedDescription
            }
        }
        activeTask = worker
    }

    func prepareCloudRestore(_ file: StudyDriveFile) {
        guard !busy, let app, app.canRestoreStudyBackup else {
            issue = "请先等待当前回答、翻译或其它备份任务结束后再恢复。"
            return
        }
        busy = true
        issue = nil
        let worker = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.busy = false }
            do {
                try self.syncAccountIfNeeded(cancelActive: false)
                let client = try app.drive.fullBackupClient()
                let (data, payload) = try await client.download(file)
                try Task.checkCancellation()
                app.unifiedRestorePreview = UnifiedRestorePreview(
                    fileName: file.name,
                    fileSize: Int64(data.count),
                    package: .unified(payload)
                )
            } catch {
                self.issue = "云盘备份校验或读取未通过：\(error.localizedDescription)"
            }
        }
        activeTask = worker
    }

    func moveCloudBackupToTrash(_ file: StudyDriveFile) {
        guard !busy, let app else { return }
        busy = true
        let worker = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.busy = false }
            do {
                let client = try app.drive.fullBackupClient()
                try await client.moveBackupToTrash(fileID: file.id)
                self.files.removeAll { $0.id == file.id }
                app.noticeMessage = "已将《\(file.name)》移入 Google 云盘回收站（30 天内可在云盘恢复）。"
            } catch {
                self.issue = "未能移入回收站：\(error.localizedDescription)"
            }
        }
        activeTask = worker
    }
}

private final class DriveUploadBackgroundLease: @unchecked Sendable {
    private var id: UIBackgroundTaskIdentifier = .invalid
    private var worker: Task<Void, Never>?

    @MainActor init() {
        id = UIApplication.shared.beginBackgroundTask(withName: "drive-daily-backup") { [weak self] in
            if Thread.isMainThread {
                MainActor.assumeIsolated { self?.expire() }
            } else {
                DispatchQueue.main.sync {
                    MainActor.assumeIsolated { self?.expire() }
                }
            }
        }
    }

    @MainActor func bind(_ task: Task<Void, Never>) {
        worker = task
        if id == .invalid { task.cancel() }
    }

    @MainActor private func expire() {
        let current = id
        id = .invalid
        let task = worker
        worker = nil
        task?.cancel()
        if current != .invalid { UIApplication.shared.endBackgroundTask(current) }
    }

    @MainActor func end() {
        let current = id
        id = .invalid
        worker = nil
        if current != .invalid { UIApplication.shared.endBackgroundTask(current) }
    }
}
