// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "DeepSeekCore",
    platforms: [.macOS(.v13)],
    products: [.library(name: "DeepSeekCore", targets: ["DeepSeekCore"])],
    dependencies: [
        .package(url: "https://github.com/open-spaced-repetition/swift-fsrs.git", revision: "4fbaf20184d62f82a9f44f343337c61a2c5483e9"),
        // Verifies the OpenAI sign-in token; same pinned revision as 研习.
        .package(url: "https://github.com/vapor/jwt-kit.git", revision: "13e7513b3ba0afa13967daf77af2fb4ad087306c")
    ],
    targets: [
        .target(name: "DeepSeekCore", dependencies: [.product(name: "JWTKit", package: "jwt-kit"), .product(name: "FSRS", package: "swift-fsrs")], path: "DeepSeekPocket",
                exclude: ["AppStore.swift", "QingJianApp.swift", "Info.plist", "Views", "Assets.xcassets", "Resources", "Services/ColabStore.swift", "Services/AppPersistence.swift", "Services/KeychainStore.swift", "Services/ImageStore.swift", "Services/SubscriptionStore.swift", "Services/GoogleDrive.swift", "Services/GitHubClient.swift", "Services/FontLibrary.swift", "Services/StudyBackupController.swift"],
                sources: ["Core", "Services/ColabClient.swift", "Services/DeepSeekClient.swift", "Services/SubscriptionHTTP.swift", "Services/SubscriptionLoopback.swift", "Services/BackupFolder.swift"],
                linkerSettings: [.linkedLibrary("sqlite3")]),
        .testTarget(name: "DeepSeekCoreTests", dependencies: ["DeepSeekCore"], path: "Tests")
    ]
)
