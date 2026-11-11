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
                .onChange(of: scenePhase) { _, phase in
                    store.speech.setForeground(phase == .active)
                    store.studyCloud.setForeground(phase == .active)
                    if phase != .active { store.persistNow() }
                    // Not on .inactive: the Face ID prompt itself makes the app inactive.
                    if phase == .background {
                        // Leaving the app counts as leaving the conversation for project memory.
                        store.updateMemory(leaving: store.activeThreadID)
                        store.relockProjects()
                    }
                    if phase == .active { store.autoBackupIfNeeded(); store.refreshColabEndpoint() }
                }
        }
    }
}
