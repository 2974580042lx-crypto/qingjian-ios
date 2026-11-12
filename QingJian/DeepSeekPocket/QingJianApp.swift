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
                .onChange(of: scenePhase) { _, phase in
                    store.speech.setForeground(phase == .active)
                    store.studyCloud.setForeground(phase == .active)
                    if phase == .background {
                        store.persistNow()
                        // Leaving the app counts as leaving the conversation for project memory.
                        store.updateMemory(leaving: store.activeThreadID)
                        store.relockProjects()
                    }
                    if phase == .active {
                        store.reloadAfterUnlockIfNeeded()
                        profile.reloadIfNeeded()
                        store.autoBackupIfNeeded()
                        store.refreshColabEndpoint()
                    }
                }
        }
    }
}
