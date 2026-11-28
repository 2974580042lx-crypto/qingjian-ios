import SwiftUI
import UIKit

private struct PhotoGallerySelection: Identifiable {
    let id = UUID()
    let index: Int
}

/// Marker view used by `SidebarDrawerContainer` and `TranscriptLeftSwipePan` to
/// exclude photo-stack horizontal swipes from drawer/timestamp gestures.
final class PhotoStackGestureHostView: UIView {}

/// Renders 1 photo as a clean card or 2–4 photos as an interactive Apple iMessage-style
/// fanned stack: drag the top card left/right to flip it to the back in-place, or
/// tap to open the full-screen zoomable gallery.
@MainActor
struct PhotoStackView: View {
    let names: [String]

    @State private var topIndex = 0
    @State private var dragOffsetX: CGFloat = 0
    @State private var isCycling = false
    @State private var gallerySelection: PhotoGallerySelection?

    private struct LayerGeometry {
        let angle: Double
        let offsetX: CGFloat
        let offsetY: CGFloat
        let scale: CGFloat
    }

    private func restGeometry(for layer: Int, total: Int) -> LayerGeometry {
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
        Group {
            if names.count <= 1, let first = names.first {
                Button {
                    Haptic.tap()
                    gallerySelection = PhotoGallerySelection(index: 0)
                } label: {
                    singleCard(name: first)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.pressFeedback)
                .accessibilityLabel("查看大图")
            } else {
                stackedDeck
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("照片堆叠，共 \(names.count) 张，当前第 \((topIndex % max(1, names.count)) + 1) 张。左右滑动切换，轻点查看大图。")
            }
        }
        .fullScreenCover(item: $gallerySelection) { selection in
            PhotoGallerySheet(names: names, initialIndex: selection.index)
        }
    }

    private func singleCard(name: String) -> some View {
        let radius: CGFloat = 18
        return thumbnailImage(named: name)
            .frame(width: 192, height: 192)
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .stroke(Ink.line, lineWidth: 0.8)
            )
            .shadow(color: Color.black.opacity(0.08), radius: 6, y: 2)
    }

    private var stackedDeck: some View {
        let total = names.count
        let safeTop = ((topIndex % total) + total) % total
        let visibleCount = min(total, 4)
        let radius: CGFloat = 18
        let dragProgress = min(1.0, abs(dragOffsetX) / 110.0)

        return ZStack {
            ForEach((0..<visibleCount).reversed(), id: \.self) { layer in
                let photoIdx = (safeTop + layer) % total
                let name = names[photoIdx]
                let base = restGeometry(for: layer, total: visibleCount)

                let isFront = (layer == 0)
                let isSecond = (layer == 1)

                let xOffset: CGFloat = isFront
                    ? dragOffsetX
                    : (isSecond ? base.offsetX * (1 - dragProgress) : base.offsetX)
                let yOffset: CGFloat = isFront
                    ? abs(dragOffsetX) * -0.04
                    : (isSecond ? base.offsetY * (1 - dragProgress) : base.offsetY)
                let angle: Double = isFront
                    ? Double(dragOffsetX / 14.0)
                    : (isSecond ? base.angle * (1 - Double(dragProgress)) : base.angle)
                let scale: CGFloat = isFront
                    ? max(0.92, 1.0 - abs(dragOffsetX) / 1400.0)
                    : (isSecond ? base.scale + (1.0 - base.scale) * dragProgress : base.scale)
                let opacity: Double = (isFront && isCycling) ? max(0.15, 1.0 - Double(abs(dragOffsetX)) / 180.0) : 1.0

                thumbnailImage(named: name)
                    .frame(width: 164, height: 164)
                    .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: radius, style: .continuous)
                            .stroke(Ink.paper, lineWidth: 2.2)
                    )
                    .shadow(color: Color.black.opacity(isFront ? 0.16 : 0.10), radius: 7, y: 3)
                    .overlay(alignment: .bottomTrailing) {
                        if isFront {
                            HStack(spacing: 4) {
                                Image(systemName: "photo.stack.fill")
                                    .font(.system(size: 10, weight: .semibold))
                                Text("\(safeTop + 1)/\(total)")
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
                    .scaleEffect(scale)
                    .rotationEffect(.degrees(angle))
                    .offset(x: xOffset, y: yOffset)
                    .opacity(opacity)
                    .zIndex(Double(visibleCount - layer))
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 10)
        .padding(.bottom, 4)
        .overlay {
            PhotoStackPanOverlay(
                onChanged: { dx in
                    guard !isCycling else { return }
                    dragOffsetX = max(-185, min(185, dx))
                },
                onEnded: { dx, vx in
                    guard !isCycling else { return }
                    let shouldFlip = abs(dx) > 48 || abs(vx) > 340
                    guard shouldFlip else {
                        withAnimation(.spring(response: 0.30, dampingFraction: 0.80)) {
                            dragOffsetX = 0
                        }
                        return
                    }
                    Haptic.tap()
                    isCycling = true
                    let direction: CGFloat = (abs(vx) > 250 ? vx : dx) >= 0 ? 1 : -1
                    withAnimation(.easeOut(duration: 0.13)) {
                        dragOffsetX = direction * 155
                    }
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 135_000_000)
                        topIndex = (safeTop + 1) % total
                        isCycling = false
                        dragOffsetX = -direction * 14
                        withAnimation(.spring(response: 0.32, dampingFraction: 0.78)) {
                            dragOffsetX = 0
                        }
                    }
                },
                onCancelled: {
                    isCycling = false
                    withAnimation(.spring(response: 0.30, dampingFraction: 0.82)) {
                        dragOffsetX = 0
                    }
                },
                onTap: {
                    Haptic.tap()
                    gallerySelection = PhotoGallerySelection(index: safeTop)
                }
            )
        }
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
private struct PhotoStackPanOverlay: UIViewRepresentable {
    let onChanged: (CGFloat) -> Void
    let onEnded: (CGFloat, CGFloat) -> Void
    let onCancelled: () -> Void
    let onTap: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> PhotoStackGestureHostView {
        let view = PhotoStackGestureHostView()
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = true

        let pan = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handlePan(_:)))
        pan.delegate = context.coordinator
        pan.maximumNumberOfTouches = 1

        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTap))
        tap.require(toFail: pan)

        view.addGestureRecognizer(pan)
        view.addGestureRecognizer(tap)
        return view
    }

    func updateUIView(_ view: PhotoStackGestureHostView, context: Context) {
        context.coordinator.owner = self
    }

    @MainActor
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var owner: PhotoStackPanOverlay

        init(_ owner: PhotoStackPanOverlay) {
            self.owner = owner
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let pan = gestureRecognizer as? UIPanGestureRecognizer, let view = pan.view else {
                return true
            }
            let velocity = pan.velocity(in: view)
            return abs(velocity.x) > abs(velocity.y) * 1.35
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            true
        }

        @objc func handlePan(_ recognizer: UIPanGestureRecognizer) {
            guard let view = recognizer.view else { return }
            let dx = recognizer.translation(in: view).x
            switch recognizer.state {
            case .began:
                cancelParentScrollPans(from: view)
                owner.onChanged(dx)
            case .changed:
                owner.onChanged(dx)
            case .ended:
                owner.onEnded(dx, recognizer.velocity(in: view).x)
            case .cancelled, .failed:
                owner.onCancelled()
            default:
                break
            }
        }

        @objc func handleTap() {
            owner.onTap()
        }

        private func cancelParentScrollPans(from view: UIView) {
            var current = view.superview
            while let ancestor = current {
                if let scroll = ancestor as? UIScrollView, !(ancestor is UITextView) {
                    let pan = scroll.panGestureRecognizer
                    if pan.state == .began || pan.state == .changed {
                        pan.isEnabled = false
                        pan.isEnabled = true
                    }
                }
                current = ancestor.superview
            }
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

    var body: some View {
        let displayImage = fullImage ?? ImageStore.thumbnail(named: name)
        Group {
            if let displayImage {
                NativeZoomableScrollImage(image: displayImage)
                    .ignoresSafeArea()
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "photo")
                        .font(.system(size: 36))
                        .foregroundStyle(Color.white.opacity(0.5))
                    Text("图片文件已不在这台手机上")
                        .font(TypeScale.caption)
                        .foregroundStyle(Color.white.opacity(0.7))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
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

/// UIScrollView-backed zoomable & pannable photo view (1x–4x pinch zoom, pan when zoomed, double-tap at point).
@MainActor
private struct NativeZoomableScrollImage: UIViewRepresentable {
    let image: UIImage

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> ZoomContainerScrollView {
        let scroll = ZoomContainerScrollView()
        scroll.delegate = context.coordinator
        scroll.minimumZoomScale = 1.0
        scroll.maximumZoomScale = 4.0
        scroll.showsHorizontalScrollIndicator = false
        scroll.showsVerticalScrollIndicator = false
        scroll.bouncesZoom = true
        scroll.backgroundColor = .clear
        scroll.contentInsetAdjustmentBehavior = .never

        let imageView = UIImageView(image: image)
        imageView.contentMode = .scaleAspectFit
        imageView.backgroundColor = .clear
        scroll.addSubview(imageView)
        scroll.imageView = imageView
        context.coordinator.imageView = imageView

        let doubleTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        scroll.addGestureRecognizer(doubleTap)
        return scroll
    }

    func updateUIView(_ scroll: ZoomContainerScrollView, context: Context) {
        if scroll.imageView?.image !== image {
            scroll.imageView?.image = image
            scroll.setZoomScale(1.0, animated: false)
            scroll.setNeedsLayout()
        }
    }

    final class ZoomContainerScrollView: UIScrollView {
        weak var imageView: UIImageView?
        private var lastLaidOutBoundsSize: CGSize = .zero

        override func layoutSubviews() {
            super.layoutSubviews()
            guard let imageView, bounds.width > 0, bounds.height > 0 else { return }
            if lastLaidOutBoundsSize != bounds.size && zoomScale <= 1.01 {
                lastLaidOutBoundsSize = bounds.size
                zoomScale = 1.0
                imageView.frame = bounds
                contentSize = bounds.size
                contentInset = .zero
            } else {
                centerImageIfNeeded()
            }
        }

        func centerImageIfNeeded() {
            guard let imageView else { return }
            let offsetX = max((bounds.width - contentSize.width) * 0.5, 0)
            let offsetY = max((bounds.height - contentSize.height) * 0.5, 0)
            imageView.center = CGPoint(
                x: contentSize.width * 0.5 + offsetX,
                y: contentSize.height * 0.5 + offsetY
            )
        }
    }

    @MainActor
    final class Coordinator: NSObject, UIScrollViewDelegate {
        weak var imageView: UIImageView?

        func viewForZooming(in scrollView: UIScrollView) -> UIView? {
            imageView
        }

        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            (scrollView as? ZoomContainerScrollView)?.centerImageIfNeeded()
        }

        @objc func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
            guard let scroll = gesture.view as? ZoomContainerScrollView,
                  let imageView = scroll.imageView else { return }
            if scroll.zoomScale > 1.15 {
                scroll.setZoomScale(1.0, animated: true)
            } else {
                let point = gesture.location(in: imageView)
                let targetScale: CGFloat = 2.5
                let w = scroll.bounds.width / targetScale
                let h = scroll.bounds.height / targetScale
                let rect = CGRect(x: point.x - w * 0.5, y: point.y - h * 0.5, width: w, height: h)
                scroll.zoom(to: rect, animated: true)
            }
        }
    }
}
