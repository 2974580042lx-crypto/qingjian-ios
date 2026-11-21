import SwiftUI

@main
@MainActor
struct QingJianApp: App {
    @UIApplicationDelegateAdaptor(ReaderAppDelegate.self) private var readerDelegate
    @StateObject private var store = AppStore()
    @StateObject private var profile = ProfileStore()
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(FontLibrary.choiceKey) private var fontChoice = ""
    @AppStorage(FontLibrary.revisionKey) private var fontRevision = 0
    @AppStorage(InterfaceStyle.key) private var interfaceStyle = ""

    init() {
        FontLibrary.registerSaved()
        FontLibrary.applyReadingDefaultsOnce()
        InkAppearance.apply()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .onAppear {
                    InkAppearance.apply()
                    store.drainShortcutsShareInbox()
                }
                .onChange(of: fontRevision) { _, _ in FontAppearance.shared.invalidate(); InkAppearance.apply() }
                .onChange(of: fontChoice) { _, _ in FontAppearance.shared.invalidate(); InkAppearance.apply() }
                .onChange(of: interfaceStyle) { _, _ in
                    StyleAppearance.shared.reload(); FontAppearance.shared.invalidate(); InkAppearance.apply()
                }
                .environmentObject(store)
                .environmentObject(profile)
                .tint(Ink.ink)
                .onReceive(NotificationCenter.default.publisher(for: UIApplication.protectedDataDidBecomeAvailableNotification)) { _ in
                    store.reloadAfterUnlockIfNeeded()
                    profile.reloadIfNeeded()
                }
                .onReceive(NotificationCenter.default.publisher(for: Notification.Name("sermo.profile.didRestore"))) { _ in
                    profile.reloadFromDisk()
                }
                .onChange(of: scenePhase) { _, phase in
                    store.speech.setForeground(phase == .active)
                    store.studyCloud.setForeground(phase == .active)
                    if phase == .background {
                        store.persistNow()
                        // relockProjects() also triggers updateMemory(leaving: activeThreadID) once cleanly.
                        store.relockProjects()
                    }
                    if phase == .active {
                        store.reloadAfterUnlockIfNeeded()
                        profile.reloadIfNeeded()
                        store.autoBackupIfNeeded()
                        store.refreshColabEndpoint()
                        store.drainShortcutsShareInbox()
                    }
                }
        }
    }
}
