import SwiftUI
import UIKit

@MainActor
final class ReaderAppDelegate: NSObject, UIApplicationDelegate {
    static var readerMask: UIInterfaceOrientationMask?
    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        Self.readerMask ?? (UIDevice.current.userInterfaceIdiom == .pad ? .all : .portrait)
    }
    static func setReaderOrientation(_ choice: String?) {
        if let choice {
            readerMask = choice == "portrait" ? .portrait : (choice == "landscape" ? .landscape : .allButUpsideDown)
        } else { readerMask = nil }
        let mask = readerMask ?? (UIDevice.current.userInterfaceIdiom == .pad ? .all : .portrait)
        for scene in UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }) where scene.activationState == .foregroundActive {
            for window in scene.windows {
                var top = window.rootViewController
                top?.setNeedsUpdateOfSupportedInterfaceOrientations()
                while let presented = top?.presentedViewController { top = presented }
                top?.setNeedsUpdateOfSupportedInterfaceOrientations()
            }
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask)) { _ in }
        }
    }
}

struct ReaderPageStyle: Equatable {
    var fontName: String
    var size: Double
    var lineGap: Double
    var paragraphGap: Double
    var margin: Double
    var paged: Bool
    var spreads: Bool
    var background: UInt32
    var foreground: UInt32
    var firstLineIndent: Bool
    var accent: UInt32 = 0x9A563F
    var backgroundColor: UIColor { Self.color(background) }
    var textColor: UIColor { Self.color(foreground) }
    static func color(_ hex: UInt32) -> UIColor {
        UIColor(red: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255, blue: CGFloat(hex & 255) / 255, alpha: 1)
    }
}

struct ReaderJump: Equatable {
    var id = UUID()
    var offset: Int
}

struct NovelDocument: Equatable {
    var chapter: Int
    var paragraphs: [String]
    var starts: [Int]
    var text: String
    var length: Int { (text as NSString).length }
    init(chapter: Int, text: String) {
        self.chapter = chapter
        paragraphs = BookScenes.paragraphs(text)
        var cursor = 0
        starts = paragraphs.map { value in defer { cursor += (value as NSString).length + 1 }; return cursor }
        self.text = paragraphs.joined(separator: "\n")
    }
    func paragraph(at offset: Int) -> Int {
        guard !starts.isEmpty else { return 0 }
        return max(0, starts.lastIndex(where: { $0 <= offset }) ?? 0)
    }
}

@MainActor
struct ReaderCanvas: UIViewControllerRepresentable {
    var document: NovelDocument
    var style: ReaderPageStyle
    var jump: ReaderJump
    var chapterTitle: String
    var tapped: () -> Void
    var moved: (Int, Int, Int) -> Void
    var chapterStep: (Int) -> Void
    var paragraphAction: (Int) -> Void
    var pageCommand: ReaderPageCommand? = nil
    func makeUIViewController(context: Context) -> NovelCanvasController { NovelCanvasController() }
    func updateUIViewController(_ controller: NovelCanvasController, context: Context) {
        controller.tapped = tapped; controller.moved = moved; controller.chapterStep = chapterStep
        controller.paragraphAction = paragraphAction
        controller.configure(document: document, style: style, jump: jump, title: chapterTitle)
        controller.consume(pageCommand)
    }
}

@MainActor
final class NovelCanvasController: UIViewController, UITextViewDelegate {
    var tapped: (() -> Void)?
    var moved: ((Int, Int, Int) -> Void)?
    var chapterStep: ((Int) -> Void)?
    var paragraphAction: ((Int) -> Void)?
    private var chapterTitle = ""
    private var chapterHeading: UIView?
    private let vertical = UITextView()
    private let horizontal = UIScrollView()
    private var document = NovelDocument(chapter: 0, text: "")
    private var style: ReaderPageStyle?
    private var jumpID: UUID?
    private var anchor = 0
    private var pages: [NSRange] = []
    private var displayed: [Int: UIView] = [:]
    private var pageStarts: [ObjectIdentifier: Int] = [:]
    private var attributed = NSAttributedString(string: "")
    private var layoutSize = CGSize.zero
    private var columns = 1
    private var changingLayout = false
    private var lastNotice = Date.distantPast
    private var settling = false
    private var consumedCommand: UUID?

    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { ReaderAppDelegate.readerMask ?? .allButUpsideDown }
    override var prefersStatusBarHidden: Bool { true }
    override var prefersHomeIndicatorAutoHidden: Bool { true }

    override func viewDidLoad() {
        super.viewDidLoad()
        vertical.isEditable = false; vertical.isSelectable = false; vertical.backgroundColor = .clear
        vertical.alwaysBounceVertical = true; vertical.showsVerticalScrollIndicator = false; vertical.delegate = self
        vertical.textContainer.lineFragmentPadding = 0
        vertical.contentInsetAdjustmentBehavior = .never
        horizontal.isPagingEnabled = true; horizontal.delegate = self
        horizontal.alwaysBounceHorizontal = true
        horizontal.showsHorizontalScrollIndicator = false
        horizontal.contentInsetAdjustmentBehavior = .never
        view.addSubview(vertical); view.addSubview(horizontal)
        installGestures(vertical)
        let tap = UITapGestureRecognizer(target: self, action: #selector(pageTapped(_:)))
        horizontal.addGestureRecognizer(tap)
        horizontal.accessibilityLabel = "左右翻页阅读"
    }

    func configure(document: NovelDocument, style: ReaderPageStyle, jump: ReaderJump, title: String) {
        loadViewIfNeeded()
        let newDocument = self.document != document
        let rebuild = newDocument || self.style != style || chapterTitle != title
        chapterTitle = title
        if newDocument { anchor = jump.offset }
        self.document = document
        self.style = style
        if jumpID != jump.id { anchor = jump.offset; jumpID = jump.id; settling = true }
        if rebuild { layoutSize = .zero; view.setNeedsLayout() }
        else if settling { moveToAnchor(); settling = false; DispatchQueue.main.async { [weak self] in self?.reportPosition(force: true) } }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard let style, view.bounds.width > 20, view.bounds.height > 20 else { return }
        guard layoutSize != view.bounds.size else { return }
        changingLayout = true
        layoutSize = view.bounds.size
        view.backgroundColor = style.backgroundColor
        vertical.frame = view.bounds; horizontal.frame = view.bounds
        vertical.isHidden = style.paged; horizontal.isHidden = !style.paged
        let wide = view.bounds.width > view.bounds.height
        let tablet = UIDevice.current.userInterfaceIdiom == .pad
        columns = style.paged && style.spreads && tablet && wide && view.bounds.width >= 760 ? 2 : 1
        let font = UIFont(name: style.fontName, size: style.size) ?? UIFont.systemFont(ofSize: style.size)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = style.lineGap
        paragraph.paragraphSpacing = style.paragraphGap
        paragraph.firstLineHeadIndent = style.firstLineIndent ? style.size * 2 : 0
        paragraph.lineBreakMode = .byWordWrapping
        attributed = NSAttributedString(string: document.text, attributes: [.font: font, .foregroundColor: style.textColor, .paragraphStyle: paragraph])
        if style.paged {
            makePages()
        } else {
            let margin = horizontalMargin(columns: 1)
            chapterHeading?.removeFromSuperview()
            let header = headingHeight(width: view.bounds.width - margin * 2)
            if header > 0 {
                let heading = makeHeading(x: margin, y: 16, width: view.bounds.width - margin * 2, height: header)
                vertical.addSubview(heading); chapterHeading = heading
            }
            vertical.textContainerInset = UIEdgeInsets(top: 16 + header, left: margin, bottom: 36, right: margin)
            vertical.attributedText = attributed
            vertical.layoutManager.ensureLayout(for: vertical.textContainer)
        }
        moveToAnchor()
        settling = false
        changingLayout = false
        DispatchQueue.main.async { [weak self] in self?.reportPosition(force: true) }
    }

    private func headingHeight(width: CGFloat) -> CGFloat {
        guard let style, !chapterTitle.isEmpty, view.bounds.height >= 260 else { return 0 }
        let font = UIFont(name: style.fontName, size: min(28, max(23, style.size + 3))) ?? .systemFont(ofSize: 24)
        let rect = (chapterTitle as NSString).boundingRect(with: CGSize(width: max(40, width), height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: font], context: nil)
        return min(font.lineHeight * 3, ceil(rect.height)) + 48
    }
    private func makeHeading(x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat) -> UIView {
        let holder = UIView(frame: CGRect(x: x, y: y, width: width, height: height))
        guard let style else { return holder }
        let label = UILabel(frame: CGRect(x: 0, y: 8, width: width, height: max(28, height - 48)))
        label.font = UIFont(name: style.fontName, size: min(28, max(23, style.size + 3))) ?? .systemFont(ofSize: 24)
        label.textColor = style.textColor; label.text = chapterTitle; label.numberOfLines = 3
        label.accessibilityTraits = .header
        holder.addSubview(label)
        let rule = UIView(frame: CGRect(x: 0, y: height - 25, width: 28, height: 1))
        rule.backgroundColor = ReaderPageStyle.color(style.accent).withAlphaComponent(0.6)
        holder.addSubview(rule)
        return holder
    }

    private func horizontalMargin(columns: Int) -> CGFloat {
        guard let style else { return 24 }
        let width = view.bounds.width / CGFloat(columns)
        return max(CGFloat(style.margin), (width - 680) / 2)
    }

    private func makePages() {
        displayed.values.forEach { $0.removeFromSuperview() }; displayed = [:]; pageStarts = [:]
        pages = []
        guard attributed.length > 0 else {
            pages = [NSRange(location: 0, length: 0)]
            horizontal.contentSize = view.bounds.size
            return
        }
        let storage = NSTextStorage(attributedString: attributed)
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let width = view.bounds.width / CGFloat(columns) - horizontalMargin(columns: columns) * 2
        let height = max(30, view.bounds.height - 32)
        var previous = -1
        while pages.count < 5000 {
            let opening = pages.isEmpty ? headingHeight(width: width) : 0
            let container = NSTextContainer(size: CGSize(width: max(40, width), height: max(30, height - opening)))
            container.lineFragmentPadding = 0
            layout.addTextContainer(container)
            layout.ensureLayout(for: container)
            let glyphs = layout.glyphRange(for: container)
            let range = layout.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
            guard range.length > 0, range.location > previous else { break }
            pages.append(range); previous = range.location
            if NSMaxRange(range) >= attributed.length { break }
        }
        if pages.isEmpty { pages = [NSRange(location: 0, length: attributed.length)] }
        let spreads = max(1, (pages.count + columns - 1) / columns)
        horizontal.contentSize = CGSize(width: view.bounds.width * CGFloat(spreads), height: view.bounds.height)
    }

    private func showNearby() {
        guard style?.paged == true, view.bounds.width > 0 else { return }
        let selected = min(max(0, (pages.count - 1) / columns), max(0, Int(round(horizontal.contentOffset.x / view.bounds.width))))
        let valid = Set(max(0, selected - 1)...min(max(0, (pages.count - 1) / columns), selected + 1))
        for key in Array(displayed.keys) where !valid.contains(key) {
            displayed[key]?.removeFromSuperview(); displayed[key] = nil
        }
        for spread in valid where displayed[spread] == nil {
            let holder = UIView(frame: CGRect(x: CGFloat(spread) * view.bounds.width, y: 0, width: view.bounds.width, height: view.bounds.height))
            holder.backgroundColor = style?.backgroundColor
            for column in 0..<columns {
                let index = spread * columns + column
                guard pages.indices.contains(index) else { continue }
                let margin = horizontalMargin(columns: columns)
                let width = view.bounds.width / CGFloat(columns) - margin * 2
                let x = CGFloat(column) * view.bounds.width / CGFloat(columns) + margin
                let opening = index == 0 ? headingHeight(width: width) : 0
                if opening > 0 { holder.addSubview(makeHeading(x: x, y: 16, width: width, height: opening)) }
                let text = UITextView(frame: CGRect(x: x, y: 16 + opening,
                                                    width: width, height: max(30, view.bounds.height - 32 - opening)))
                text.isEditable = false; text.isSelectable = false; text.isScrollEnabled = false
                text.backgroundColor = .clear; text.textContainerInset = .zero; text.textContainer.lineFragmentPadding = 0
                text.attributedText = attributed.attributedSubstring(from: pages[index])
                // A paragraph continuing from the previous page must not acquire a new first-line indent.
                if pages[index].location > 0, (document.text as NSString).substring(with: NSRange(location: pages[index].location - 1, length: 1)) != "\n",
                   let original = text.attributedText.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle {
                    let value = NSMutableAttributedString(attributedString: text.attributedText)
                    let paragraph = original.mutableCopy() as! NSMutableParagraphStyle
                    paragraph.firstLineHeadIndent = 0
                    let first = (value.string as NSString).paragraphRange(for: NSRange(location: 0, length: 0))
                    value.addAttribute(.paragraphStyle, value: paragraph, range: first)
                    text.attributedText = value
                }
                pageStarts[ObjectIdentifier(text)] = pages[index].location
                let longPress = UILongPressGestureRecognizer(target: self, action: #selector(held(_:)))
                text.addGestureRecognizer(longPress)
                holder.addSubview(text)
            }
            if columns == 2 {
                let rule = UIView(frame: CGRect(x: view.bounds.width / 2, y: 24, width: 0.5, height: max(0, view.bounds.height - 48)))
                rule.backgroundColor = style?.textColor.withAlphaComponent(0.12); holder.addSubview(rule)
            }
            horizontal.addSubview(holder); displayed[spread] = holder
        }
    }

    private func moveToAnchor() {
        guard let style, layoutSize != .zero else { return }
        anchor = max(0, min(anchor, max(0, document.length - 1)))
        changingLayout = true
        if style.paged {
            let page = pages.firstIndex { NSLocationInRange(anchor, $0) } ?? 0
            horizontal.setContentOffset(CGPoint(x: CGFloat(page / columns) * view.bounds.width, y: 0), animated: false)
            showNearby()
        } else if document.length > 0 {
            vertical.layoutManager.ensureLayout(for: vertical.textContainer)
            let glyph = vertical.layoutManager.glyphRange(forCharacterRange: NSRange(location: anchor, length: 1), actualCharacterRange: nil)
            let rect = vertical.layoutManager.boundingRect(forGlyphRange: glyph, in: vertical.textContainer)
            let maxY = max(0, vertical.contentSize.height - vertical.bounds.height)
            let y = anchor == 0 ? 0 : rect.minY + vertical.textContainerInset.top - 16
            vertical.setContentOffset(CGPoint(x: 0, y: min(maxY, max(0, y))), animated: false)
        }
        changingLayout = false
    }

    private func installGestures(_ text: UITextView) {
        text.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(bodyTapped)))
        text.addGestureRecognizer(UILongPressGestureRecognizer(target: self, action: #selector(held(_:))))
        let next = UISwipeGestureRecognizer(target: self, action: #selector(nextChapter)); next.direction = .left
        let previous = UISwipeGestureRecognizer(target: self, action: #selector(previousChapter)); previous.direction = .right
        text.addGestureRecognizer(next); text.addGestureRecognizer(previous)
    }
    @objc private func bodyTapped() { tapped?() }
    @objc private func nextChapter() { chapterStep?(1) }
    @objc private func previousChapter() { chapterStep?(-1) }
    @objc private func pageTapped(_ gesture: UITapGestureRecognizer) {
        let x = gesture.location(in: view).x / max(1, view.bounds.width)
        if x < 0.25 { turn(-1) } else if x > 0.75 { turn(1) } else { tapped?() }
    }
    func consume(_ command: ReaderPageCommand?) {
        guard let command, consumedCommand != command.id, layoutSize != .zero else { return }
        consumedCommand = command.id
        if style?.paged == true { turn(command.step); return }
        let maxY = max(0, vertical.contentSize.height - vertical.bounds.height)
        let current = vertical.contentOffset.y
        if command.step > 0 && current >= maxY - 2 { chapterStep?(1); return }
        if command.step < 0 && current <= 2 { chapterStep?(-1); return }
        vertical.setContentOffset(CGPoint(x: 0, y: min(maxY, max(0, current + CGFloat(command.step) * vertical.bounds.height * 0.88))), animated: true)
    }

    private func turn(_ step: Int) {
        let page = Int(round(horizontal.contentOffset.x / max(1, view.bounds.width))) + step
        let count = max(1, (pages.count + columns - 1) / columns)
        if page < 0 || page >= count { chapterStep?(step); return }
        horizontal.setContentOffset(CGPoint(x: CGFloat(page) * view.bounds.width, y: 0), animated: true)
    }
    @objc private func held(_ gesture: UILongPressGestureRecognizer) {
        guard gesture.state == .began, let text = gesture.view as? UITextView, document.length > 0 else { return }
        let point = gesture.location(in: text)
        let local = CGPoint(x: point.x - text.textContainerInset.left, y: point.y - text.textContainerInset.top)
        guard local.y >= 0, text.layoutManager.numberOfGlyphs > 0 else { return }
        let glyph = text.layoutManager.glyphIndex(for: local, in: text.textContainer)
        let char = text.layoutManager.characterIndexForGlyph(at: min(glyph, max(0, text.layoutManager.numberOfGlyphs - 1)))
        let absolute = min(document.length - 1, char + (pageStarts[ObjectIdentifier(text)] ?? 0))
        let paragraph = document.paragraph(at: absolute)
        guard document.paragraphs.indices.contains(paragraph) else { return }
        paragraphAction?(paragraph)
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        if scrollView === horizontal { showNearby() }
        reportPosition(force: false)
    }
    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) { reportPosition(force: true) }
    func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) { reportPosition(force: true) }
    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if scrollView === vertical {
            if scrollView.contentOffset.y > max(0, scrollView.contentSize.height - scrollView.bounds.height) + 85 { chapterStep?(1); return }
            if scrollView.contentOffset.y < -85 { chapterStep?(-1); return }
        } else {
            if scrollView.contentOffset.x > max(0, scrollView.contentSize.width - scrollView.bounds.width) + 65 { chapterStep?(1); return }
            if scrollView.contentOffset.x < -65 { chapterStep?(-1); return }
        }
        if !decelerate { reportPosition(force: true) }
    }
    private func reportPosition(force: Bool) {
        guard !changingLayout, let style, force || Date().timeIntervalSince(lastNotice) > 0.25 else { return }
        lastNotice = Date()
        if style.paged {
            let spread = max(0, min(max(0, (pages.count - 1) / columns), Int(round(horizontal.contentOffset.x / max(1, view.bounds.width)))))
            anchor = pages.indices.contains(spread * columns) ? pages[spread * columns].location : 0
            moved?(anchor, spread + 1, max(1, (pages.count + columns - 1) / columns))
        } else {
            guard vertical.layoutManager.numberOfGlyphs > 0 else { moved?(0, 1, 1); return }
            let point = CGPoint(x: 1, y: max(0, vertical.contentOffset.y - vertical.textContainerInset.top + 16))
            let glyph = vertical.layoutManager.glyphIndex(for: point, in: vertical.textContainer)
            anchor = vertical.layoutManager.characterIndexForGlyph(at: min(glyph, vertical.layoutManager.numberOfGlyphs - 1))
            moved?(anchor, 0, 0)
        }
    }
}

