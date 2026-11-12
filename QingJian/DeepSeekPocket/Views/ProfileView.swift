import SwiftUI
import PhotosUI
import ImageIO

private struct LocalProfile: Codable {
    var name = "唐宋"
    var handle = "tangsong"
    var avatar: Data?
}

@MainActor
final class ProfileStore: ObservableObject {
    @Published private var profile = LocalProfile()
    @Published var error: String?
    private var file: URL?
    private let preview: Bool
    var name: String { profile.name }
    var handle: String { profile.handle }
    var avatar: UIImage? { profile.avatar.flatMap(UIImage.init(data:)) }
    var avatarData: Data? { profile.avatar }

    init(preview: Bool = ProcessInfo.processInfo.arguments.contains("--ui-preview")) {
        self.preview = preview
        guard !preview else { return }
        reloadIfNeeded()
    }

    func reloadIfNeeded() {
        guard !preview, file == nil else { return }
        do {
            let directory = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
                .appendingPathComponent("QingJian", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let target = directory.appendingPathComponent("profile.json")
            if FileManager.default.fileExists(atPath: target.path) {
                try? FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: target.path)
                profile = try JSONDecoder().decode(LocalProfile.self, from: Data(contentsOf: target))
            }
            file = target
            error = nil
        } catch { self.error = "暂时无法读取个人资料，原文件已保留。" }
    }

    func save(name: String, handle: String, avatar: Data?) -> Bool {
        let next = LocalProfile(name: String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(30)),
                                handle: String(handle.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40)), avatar: avatar)
        guard !next.name.isEmpty else { error = "请填写一个名字。"; return false }
        do {
            if !preview {
                guard let file else { error = "个人资料存储暂时不可用。"; return false }
                try JSONEncoder().encode(next).write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            }
            profile = next
            return true
        } catch { self.error = "个人资料未能保存，请检查手机可用空间后重试。"; return false }
    }

    static func thumbnail(_ data: Data) throws -> Data {
        guard data.count <= 30 * 1024 * 1024,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 512
              ] as CFDictionary),
              let jpeg = UIImage(cgImage: cg).jpegData(compressionQuality: 0.85) else {
            throw ChatError.server("无法读取这张图片，请选择小于 30 MB 的普通照片。")
        }
        return jpeg
    }
}

struct ProfileAvatar: View {
    let image: UIImage?
    var size: CGFloat = 64
    // Shown when no photo is set, e.g. the first character of the name.
    var initial: String?
    var body: some View {
        Group {
            if let image { Image(uiImage: image).resizable().scaledToFill() }
            else if let initial {
                ZStack {
                    Ink.raised
                    Text(initial).font(TypeScale.heavy(size * 0.4)).foregroundStyle(Ink.ink)
                }
            } else {
                ZStack {
                    LinearGradient(colors: [Ink.raised, Ink.sheet], startPoint: .topLeading, endPoint: .bottomTrailing)
                    Image(systemName: "person.fill").font(.system(size: size * 0.37, weight: .light)).foregroundStyle(Ink.ink2)
                }
            }
        }.frame(width: size, height: size).clipShape(Circle())
            .overlay(Circle().stroke(Ink.line, lineWidth: 0.5))
    }
}

@MainActor
struct ProfileEditor: View {
    @EnvironmentObject private var profile: ProfileStore
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var handle = ""
    @State private var avatar: Data?
    @State private var selection: PhotosPickerItem?
    @State private var loading = false
    @State private var loadError: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        Spacer()
                        PhotosPicker(selection: $selection, matching: .images) { [avatar, loading] in
                            VStack(spacing: 12) {
                                ProfileAvatar(image: avatar.flatMap(UIImage.init(data:)), size: 96)
                                Text(loading ? "正在读取…" : "更换头像").font(TypeScale.label)
                            }.padding(.vertical, 14)
                        }.buttonStyle(.plain).disabled(loading)
                        Spacer()
                    }
                }.listRowBackground(Color.clear)
                Section("个人资料") {
                    TextField("名字", text: $name)
                    TextField("ID", text: $handle).textInputAutocapitalization(.never).autocorrectionDisabled()
                }
                Section {
                    Text("头像、名字和 ID 只保存在这台手机，不会发送给模型。")
                        .font(TypeScale.caption).foregroundStyle(Ink.ink3)
                }.listRowBackground(Color.clear)
            }
            .scrollContentBackground(.hidden).background(AppBackground())
            .listRowBackground(Color.clear).listRowSeparatorTint(Ink.line)
            .foregroundStyle(Ink.ink).tint(Ink.ink)
            .navigationTitle("个人资料").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("保存") { if profile.save(name: name, handle: handle, avatar: avatar) { dismiss() } }
                        .disabled(loading || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .onAppear { name = profile.name; handle = profile.handle; avatar = profile.avatarData }
            .task(id: selection) {
                guard let selection else { return }
                loading = true
                defer { loading = false }
                do {
                    guard let data = try await selection.loadTransferable(type: Data.self) else { throw ChatError.server("没有读取到照片。") }
                    try Task.checkCancellation()
                    avatar = try ProfileStore.thumbnail(data)
                } catch { if !Task.isCancelled { loadError = error.localizedDescription } }
            }
            .alert("暂时没有完成", isPresented: Binding(get: { loadError != nil || profile.error != nil }, set: { if !$0 { loadError = nil; profile.error = nil } })) {
                Button("知道了") { loadError = nil; profile.error = nil }
            } message: { Text(loadError ?? profile.error ?? "") }
        }
    }
}
