import SwiftUI
import UIKit

private struct PhotoGallerySelection: Identifiable {
    let id = UUID()
    let index: Int
}

/// Renders 1 photo as a clean card or 2–4 photos as an Apple/Telegram-style
/// fanned stack that opens a full-screen swipeable gallery on tap.
@MainActor
struct PhotoStackView: View {
    let names: [String]
    var swiss: Bool = false
    @State private var gallerySelection: PhotoGallerySelection?

    private struct LayerGeometry {
        let angle: Double
        let offsetX: CGFloat
        let offsetY: CGFloat
        let scale: CGFloat
    }

    private func geometry(for layer: Int, total: Int) -> LayerGeometry {
        if total == 2 {
            return layer == 0
                ? LayerGeometry(angle: 0, offsetX: 0, offsetY: 0, scale: 1.0)
                : LayerGeometry(angle: -6.5, offsetX: -11, offsetY: -4, scale: 0.96)
        }
        switch layer {
        case 0: return LayerGeometry(angle: 0, offsetX: 0, offsetY: 0, scale: 1.0)
        case 1: return LayerGeometry(angle: -6.5, offsetX: -11, offsetY: -4, scale: 0.97)
        case 2: return LayerGeometry(angle: 6.0, offsetX: 11, offsetY: -7, scale: 0.94)
        default: return LayerGeometry(angle: -10.5, offsetX: -15, offsetY: -9, scale: 0.91)
        }
    }

    var body: some View {
        let displayed = Array(names.prefix(4))
        Button {
            Haptic.tap()
            gallerySelection = PhotoGallerySelection(index: 0)
        } label: {
            Group {
                if displayed.count <= 1, let first = displayed.first {
                    singleCard(name: first)
                } else {
                    stackedDeck(displayed)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.pressFeedback)
        .accessibilityLabel(names.count > 1 ? "查看 \(names.count) 张图片" : "查看大图")
        .fullScreenCover(item: $gallerySelection) { selection in
            PhotoGallerySheet(names: names, initialIndex: selection.index)
        }
    }

    private func singleCard(name: String) -> some View {
        let radius: CGFloat = swiss ? 0 : 18
        return thumbnailImage(named: name)
            .frame(width: 192, height: 192)
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .stroke(Ink.line, lineWidth: 0.8)
            )
            .shadow(color: swiss ? .clear : Color.black.opacity(0.08), radius: 6, y: 2)
    }

    private func stackedDeck(_ displayed: [String]) -> some View {
        let radius: CGFloat = swiss ? 0 : 18
        return ZStack {
            ForEach(Array(displayed.enumerated()).reversed(), id: \.offset) { index, name in
                let geom = geometry(for: index, total: displayed.count)
                thumbnailImage(named: name)
                    .frame(width: 164, height: 164)
                    .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: radius, style: .continuous)
                            .stroke(swiss ? Ink.line : Ink.paper, lineWidth: swiss ? 1 : 2.2)
                    )
                    .shadow(color: swiss ? .clear : Color.black.opacity(index == 0 ? 0.16 : 0.10), radius: 7, y: 3)
                    .overlay(alignment: .bottomTrailing) {
                        if index == 0 {
                            HStack(spacing: 4) {
                                Image(systemName: "photo.stack.fill")
                                    .font(.system(size: 10, weight: .semibold))
                                Text("\(names.count) 张")
                                    .font(.system(size: 11.5, weight: .semibold))
                                    .monospacedDigit()
                            }
                            .foregroundStyle(Color.white)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.black.opacity(0.58), in: Capsule())
                            .padding(8)
                        }
                    }
                    .scaleEffect(geom.scale)
                    .rotationEffect(.degrees(geom.angle))
                    .offset(x: geom.offsetX, y: geom.offsetY)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 4)
    }

    @ViewBuilder
    private func thumbnailImage(named name: String) -> some View {
        if let image = ImageStore.thumbnail(named: name) {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .accessibilityLabel("附带的图片")
        } else {
            Ink.raised
                .overlay(Image(systemName: "photo").foregroundStyle(Ink.ink3))
                .accessibilityLabel("图片文件已不在这台手机上")
        }
    }
}

@MainActor
struct PhotoGallerySheet: View {
    let names: [String]
    let initialIndex: Int
    @Environment(\.dismiss) private var dismiss
    @State private var currentIndex: Int
    @State private var shareItem: ShareImageWrapper?

    private struct ShareImageWrapper: Identifiable {
        let id = UUID()
        let image: UIImage
    }

    init(names: [String], initialIndex: Int) {
        self.names = names
        self.initialIndex = initialIndex
        _currentIndex = State(initialValue: max(0, min(initialIndex, max(0, names.count - 1))))
    }

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.ignoresSafeArea()

            TabView(selection: $currentIndex) {
                ForEach(Array(names.enumerated()), id: \.offset) { index, name in
                    ZoomablePhotoPage(name: name)
                        .tag(index)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: names.count > 1 ? .automatic : .never))
            .ignoresSafeArea()

            HStack {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Color.white)
                        .frame(width: 40, height: 40)
                        .background(Color.white.opacity(0.16), in: Circle())
                }
                .accessibilityLabel("关闭图片查看")

                Spacer()

                if names.count > 1 {
                    Text("\(currentIndex + 1) / \(names.count)")
                        .font(.system(size: 14, weight: .medium, design: .monospaced))
                        .foregroundStyle(Color.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Color.white.opacity(0.14), in: Capsule())
                }

                Spacer()

                Button {
                    shareCurrentPhoto()
                } label: {
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Color.white)
                        .frame(width: 40, height: 40)
                        .background(Color.white.opacity(0.16), in: Circle())
                }
                .accessibilityLabel("保存或分享图片")
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
        }
        .preferredColorScheme(.dark)
        .sheet(item: $shareItem) { wrapper in
            ShareSheet(items: [wrapper.image])
        }
    }

    private func shareCurrentPhoto() {
        guard names.indices.contains(currentIndex) else { return }
        let name = names[currentIndex]
        if let data = ImageStore.jpegData(named: name), let full = UIImage(data: data) {
            shareItem = ShareImageWrapper(image: full)
        } else if let thumb = ImageStore.thumbnail(named: name) {
            shareItem = ShareImageWrapper(image: thumb)
        }
    }
}

@MainActor
private struct ZoomablePhotoPage: View {
    let name: String
    @State private var fullImage: UIImage?
    @State private var scale: CGFloat = 1
    @State private var baseScale: CGFloat = 1

    var body: some View {
        let displayImage = fullImage ?? ImageStore.thumbnail(named: name)
        GeometryReader { geo in
            Group {
                if let displayImage {
                    Image(uiImage: displayImage)
                        .resizable()
                        .scaledToFit()
                        .scaleEffect(scale)
                        .frame(width: geo.size.width, height: geo.size.height)
                        .gesture(
                            MagnifyGesture()
                                .onChanged { value in
                                    scale = min(4.0, max(1.0, baseScale * value.magnification))
                                }
                                .onEnded { _ in
                                    baseScale = scale
                                }
                        )
                        .onTapGesture(count: 2) {
                            withAnimation(.snappy(duration: 0.24)) {
                                if scale > 1.2 {
                                    scale = 1.0
                                    baseScale = 1.0
                                } else {
                                    scale = 2.4
                                    baseScale = 2.4
                                }
                            }
                        }
                } else {
                    VStack(spacing: 10) {
                        Image(systemName: "photo")
                            .font(.system(size: 36))
                            .foregroundStyle(Color.white.opacity(0.5))
                        Text("图片文件已不在这台手机上")
                            .font(TypeScale.caption)
                            .foregroundStyle(Color.white.opacity(0.7))
                    }
                    .frame(width: geo.size.width, height: geo.size.height)
                }
            }
        }
        .task(id: name) {
            let loaded = await Task.detached(priority: .userInitiated) {
                guard let data = ImageStore.jpegData(named: name) else { return UIImage?.none }
                return UIImage(data: data)
            }.value
            if let loaded {
                fullImage = loaded
            }
        }
    }
}
