import SwiftUI
import UIKit

struct ReaderTextPage {
    let glyphRange: NSRange
    let offset: CGFloat
    let visibleHeight: CGFloat
    var secondOffset: CGFloat?
}

@MainActor
enum ReaderPageRenderer {
    static func render(_ view: ReaderLayoutTextView, color: UIColor, image: UIImage? = nil,
                       imageFrame: CGRect = .zero) -> UIImageView? {
        guard view.bounds.width > 0, view.bounds.height > 0 else { return nil }
        view.updatePagination()
        let format = UIGraphicsImageRendererFormat()
        format.scale = max(view.traitCollection.displayScale, 1)
        format.opaque = true
        let bitmap = UIGraphicsImageRenderer(size: view.bounds.size, format: format).image { context in
            (color.cgColor.alpha > 0 ? color : .systemBackground).setFill()
            context.fill(CGRect(origin: .zero, size: view.bounds.size))
            if let image, image.size.width > 0, image.size.height > 0 {
                let frame = imageFrame.isEmpty ? CGRect(origin: .zero, size: view.bounds.size) : imageFrame
                let scale = max(frame.width / image.size.width, frame.height / image.size.height)
                let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
                image.draw(in: CGRect(x: frame.midX - size.width / 2, y: frame.midY - size.height / 2,
                                      width: size.width, height: size.height))
            }
            view.drawPageText(in: context.cgContext)
        }
        let page = UIImageView(image: bitmap)
        page.isOpaque = true
        page.isUserInteractionEnabled = false
        return page
    }
}

enum ReaderPageTurnState: Equatable {
    case idle
    case waiting(contentKey: Int, offset: CGFloat, direction: Int)
    case animating

    var isBusy: Bool { self != .idle }

    mutating func begin(contentKey: Int, offset: CGFloat) -> Int? {
        guard case let .waiting(source, sourceOffset, direction) = self,
              source != contentKey || abs(sourceOffset - offset) > 0.001 else { return nil }
        self = .animating
        return direction
    }
}

@MainActor
final class ReaderPageTransition {
    private(set) var state = ReaderPageTurnState.idle
    private var cover: UIView?
    private(set) var animator: UIViewPropertyAnimator?
    private var usesTwoPages = false

    func prepare(_ direction: Int, sourceKey: Int, in view: UIView, render: () -> UIImageView?) {
        if case let .waiting(source, offset, _) = state, source == sourceKey, abs(offset - view.bounds.minY) < 0.001 {
            state = .waiting(contentKey: sourceKey, offset: offset, direction: direction)
            return
        }
        cancel()
        guard let host = view.superview, let page = render() else { return }
        let cover = UIView(frame: view.convert(view.bounds, to: host))
        cover.isUserInteractionEnabled = false
        cover.clipsToBounds = true
        page.frame = cover.bounds
        cover.addSubview(page)
        host.addSubview(cover)
        self.cover = cover
        usesTwoPages = (view as? ReaderLayoutTextView)?.usesTwoPages == true
        state = .waiting(contentKey: sourceKey, offset: view.bounds.minY, direction: direction)
    }

    func finish(contentKey: Int, offset: CGFloat, style: Int, render: () -> UIImageView?) {
        guard let cover, let direction = state.begin(contentKey: contentKey, offset: offset) else { return }
        guard let oldPage = cover.subviews.first as? UIImageView, let newPage = render() else { cancel(); return }
        newPage.frame = cover.bounds
        cover.addSubview(newPage)
        let completion: (Bool) -> Void = { [weak self, weak cover] _ in
            guard let self, let cover, self.cover === cover else { return }
            self.cancel()
        }
        let animator: UIViewPropertyAnimator
        if usesTwoPages, style == 2 {
            oldPage.isHidden = true
            let midpoint = cover.bounds.width / 2
            func half(_ page: UIImageView, right: Bool) -> UIView {
                let half = UIView(frame: CGRect(x: right ? midpoint : 0, y: 0,
                                               width: midpoint, height: cover.bounds.height))
                half.layer.contents = page.image?.cgImage
                half.layer.contentsRect = CGRect(x: right ? 0.5 : 0, y: 0, width: 0.5, height: 1)
                half.layer.contentsScale = page.image?.scale ?? 1
                half.layer.isDoubleSided = false
                cover.addSubview(half)
                return half
            }
            _ = half(oldPage, right: direction < 0)
            let front = half(oldPage, right: direction > 0)
            let back = half(newPage, right: direction < 0)
            for face in [front, back] {
                face.layer.shadowColor = UIColor.black.cgColor
                face.layer.shadowOpacity = 0.18
                face.layer.shadowRadius = 8
                face.layer.shadowOffset = .zero
                face.layer.shadowPath = UIBezierPath(rect: face.bounds).cgPath
            }
            front.layer.anchorPoint = CGPoint(x: direction > 0 ? 0 : 1, y: 0.5)
            back.layer.anchorPoint = CGPoint(x: direction > 0 ? 1 : 0, y: 0.5)
            front.layer.position = CGPoint(x: midpoint, y: cover.bounds.midY)
            back.layer.position = front.layer.position
            var perspective = CATransform3DIdentity
            perspective.m34 = -1 / max(cover.bounds.width * 2, 1000)
            cover.layer.sublayerTransform = perspective
            // Exactly 180 degrees leaves the shortest rotation direction ambiguous.
            let angle: CGFloat = (direction > 0 ? -1 : 1) * (.pi - 0.001)
            back.transform3D = CATransform3DMakeRotation(-angle, 0, 1, 0)
            animator = UIViewPropertyAnimator(duration: 0.5, curve: .easeInOut) {
                front.transform3D = CATransform3DMakeRotation(angle, 0, 1, 0)
                back.transform3D = CATransform3DIdentity
            }
        } else {
            let distance = CGFloat(direction) * cover.bounds.width
            switch style {
            case 0, 1:
                if style == 0, direction > 0 { cover.insertSubview(newPage, belowSubview: oldPage) }
                else { newPage.transform = CGAffineTransform(translationX: distance, y: 0) }
                animator = UIViewPropertyAnimator(duration: 0.3, curve: .easeInOut) {
                    if style == 1 || direction > 0 { oldPage.transform = CGAffineTransform(translationX: -distance, y: 0) }
                    newPage.transform = .identity
                }
            case 2:
                newPage.isHidden = true
                UIView.transition(with: cover, duration: 0.38,
                                  options: direction > 0 ? .transitionCurlUp : .transitionCurlDown,
                                  animations: { oldPage.isHidden = true; newPage.isHidden = false }, completion: completion)
                return
            default:
                completion(true)
                return
            }
        }
        animator.addCompletion { _ in completion(true) }
        self.animator = animator
        animator.startAnimation()
    }

    func cancel() {
        let oldCover = cover
        cover = nil
        state = .idle
        usesTwoPages = false
        if animator?.state == .active { animator?.stopAnimation(true) }
        animator = nil
        oldCover?.layer.removeAllAnimations()
        oldCover?.removeFromSuperview()
    }
}

@MainActor
enum ReaderTextPagination {
    static func pages(in view: UITextView) -> [ReaderTextPage] {
        pages(manager: view.layoutManager, container: view.textContainer,
              height: max(view.bounds.height - view.textContainerInset.top - view.textContainerInset.bottom, 1),
              scale: max(view.traitCollection.displayScale, 1))
    }

    static func pages(manager: NSLayoutManager, container: NSTextContainer, height: CGFloat, scale: CGFloat = 1) -> [ReaderTextPage] {
        manager.ensureLayout(for: container)
        let text = (manager.textStorage?.string ?? "") as NSString
        var lines: [(range: NSRange, bounds: CGRect, blank: Bool)] = []
        manager.enumerateLineFragments(forGlyphRange: NSRange(location: 0, length: manager.numberOfGlyphs)) { rect, used, _, range, _ in
            var bounds = rect
            if !used.isEmpty { bounds = bounds.union(used) }
            let ink = manager.boundingRect(forGlyphRange: range, in: container)
            if !ink.isEmpty { bounds = bounds.union(ink) }
            let characters = manager.characterRange(forGlyphRange: range, actualGlyphRange: nil)
            let blank = text.substring(with: characters).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            lines.append((range, bounds, blank))
        }
        // Trailing empty paragraphs have no visible text and must not add a blank page.
        while lines.last?.blank == true { lines.removeLast() }
        guard !lines.isEmpty else {
            return [.init(glyphRange: NSRange(location: 0, length: manager.numberOfGlyphs), offset: 0, visibleHeight: 0)]
        }
        var pages: [ReaderTextPage] = []
        var start = 0
        var offset: CGFloat = 0
        var bottom: CGFloat = 0
        for (index, line) in lines.enumerated() {
            if index > start, line.bounds.maxY - offset > height {
                let first = lines[start].range.location
                pages.append(.init(glyphRange: NSRange(location: first, length: line.range.location - first),
                                   offset: offset, visibleHeight: min(ceil((bottom - offset) * scale) / scale, height)))
                start = index
                offset = floor(line.bounds.minY * scale) / scale
            }
            bottom = line.bounds.maxY
        }
        let first = lines[start].range.location
        pages.append(.init(glyphRange: NSRange(location: first, length: manager.numberOfGlyphs - first),
                           offset: offset, visibleHeight: min(ceil(max(bottom - offset, 0) * scale) / scale, height)))
        return pages
    }

    static func index(at offset: CGFloat, pages: [ReaderTextPage]) -> Int {
        var low = 0, high = pages.count
        while low < high {
            let middle = (low + high) / 2
            if pages[middle].offset <= offset + 0.001 { low = middle + 1 }
            else { high = middle }
        }
        return max(low - 1, 0)
    }

    static func index(containing glyph: Int, pages: [ReaderTextPage]) -> Int {
        pages.firstIndex(where: { NSLocationInRange(glyph, $0.glyphRange) }) ?? max(pages.count - 1, 0)
    }
}

class ReaderSelectableTextView: UITextView, UITextViewDelegate {
    override init(frame: CGRect, textContainer: NSTextContainer?) {
        if let textContainer { super.init(frame: frame, textContainer: textContainer) }
        else {
            let storage = NSTextStorage()
            let manager = NSLayoutManager()
            let container = NSTextContainer(size: CGSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
            storage.addLayoutManager(manager)
            manager.addTextContainer(container)
            super.init(frame: frame, textContainer: container)
        }
    }
    required init?(coder: NSCoder) { super.init(coder: coder) }
    var onAddPurification: ((String) -> Void)?

    @objc private func addPurificationRule() {
        guard selectedRange.length > 0, NSMaxRange(selectedRange) <= textStorage.length else { return }
        let selected = (textStorage.string as NSString).substring(with: selectedRange)
        selectedRange = NSRange(location: 0, length: 0)
        resignFirstResponder()
        onAddPurification?(selected)
    }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(addPurificationRule) { return selectedRange.length > 0 && onAddPurification != nil }
        return super.canPerformAction(action, withSender: sender)
    }

    override func becomeFirstResponder() -> Bool {
        if #unavailable(iOS 16.0) {
            UIMenuController.shared.menuItems = [UIMenuItem(title: "添加净化规则", action: #selector(addPurificationRule))]
        }
        return super.becomeFirstResponder()
    }

    @available(iOS 16.0, *)
    func selectionMenu(for range: NSRange) -> UIMenu {
        UIMenu(children: [
            UIAction(title: "复制", image: UIImage(systemName: "doc.on.doc")) { [weak self] _ in self?.copy(nil) },
            UIAction(title: "添加净化规则", image: UIImage(systemName: "line.3.horizontal.decrease.circle")) { [weak self] _ in self?.addPurificationRule() }
        ])
    }

    @available(iOS 16.0, *)
    func textView(_ textView: UITextView, editMenuForTextIn range: NSRange, suggestedActions: [UIMenuElement]) -> UIMenu? {
        selectionMenu(for: range)
    }
}

final class ReaderLayoutTextView: ReaderSelectableTextView {
    init() {
        let storage = NSTextStorage()
        let manager = NSLayoutManager()
        let container = NSTextContainer(size: CGSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        storage.addLayoutManager(manager)
        manager.addTextContainer(container)
        super.init(frame: .zero, textContainer: container)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    var hasTextSelection: Bool { selectedRange.length > 0 || (facingPage?.selectedRange.length ?? 0) > 0 }
    var paginates = false
    var usesTwoPages = false {
        didSet { if usesTwoPages != oldValue { invalidatePagination() } }
    }
    var spreadStartCharacter = 0 {
        didSet { if spreadStartCharacter != oldValue { invalidatePagination() } }
    }
    var continuationText: NSAttributedString? {
        didSet { invalidatePagination() }
    }
    var continuationBodyStart = 0
    var onLayout: ((UITextView) -> Void)?
    private(set) var pages: [ReaderTextPage] = []
    private var paginationDirty = true
    private var paginationSize = CGSize.zero
    private var paginationInsets = UIEdgeInsets.zero
    private var paginationWidth: CGFloat = 0
    private(set) var isUpdatingPagination = false
    private(set) var isUpdatingLayout = false
    private let pageMask = CAShapeLayer()
    private var reportedSize = CGSize.zero
    private var reportedContentSize = CGSize.zero
    private var facingPage: ReaderLayoutTextView?
    private var facingContinuation = false
    private var startsWithSinglePage = false

    var firstSpreadOffset: CGFloat {
        pages.isEmpty ? 0 : pages[startsWithSinglePage ? min(1, pages.count - 1) : 0].offset
    }

    var continuationPosition: Int? {
        guard facingContinuation, let right = facingPage, let page = right.pages.first else { return nil }
        let range = right.layoutManager.characterRange(forGlyphRange: page.glyphRange, actualGlyphRange: nil)
        return max(NSMaxRange(range) - continuationBodyStart, 0)
    }

    private var columnWidth: CGFloat { usesTwoPages ? max((bounds.width - 24) / 2, 1) : bounds.width }

    private func updateColumnWidth() {
        if textContainer.widthTracksTextView != !usesTwoPages {
            textContainer.widthTracksTextView = !usesTwoPages
        }
        if usesTwoPages {
            let width = max(columnWidth - textContainerInset.left - textContainerInset.right, 1)
            if textContainer.size.width != width { textContainer.size.width = width }
        }
    }

    override var contentSize: CGSize {
        get { super.contentSize }
        set {
            var size = newValue
            if paginates, !paginationDirty, paginationSize == bounds.size,
               paginationInsets == textContainerInset, paginationWidth == textContainer.size.width,
               let last = pages.last {
                // The last page is allowed to keep its unused bottom space.
                // Otherwise UITextView clamps it upward into the previous page.
                size.height = last.offset + bounds.height
            }
            super.contentSize = size
        }
    }

    func invalidatePagination() {
        paginationDirty = true
        setNeedsLayout()
    }

    @discardableResult
    func updatePagination() -> Bool {
        guard paginates else {
            layer.mask = nil
            facingPage?.removeFromSuperview()
            facingPage = nil
            facingContinuation = false
            pages = []
            paginationDirty = true
            return false
        }
        guard !isUpdatingPagination, bounds.width > 0, bounds.height > 0 else { return false }
        isUpdatingPagination = true
        defer { isUpdatingPagination = false }
        updateColumnWidth()
        let changed = paginationDirty || paginationSize != bounds.size || paginationInsets != textContainerInset
            || paginationWidth != textContainer.size.width
        if changed {
            pages = ReaderTextPagination.pages(in: self)
            startsWithSinglePage = false
            if usesTwoPages {
                let leaves = pages
                let character = min(max(spreadStartCharacter, 0), max(textStorage.length - 1, 0))
                let glyph = textStorage.length > 0 ? layoutManager.glyphIndexForCharacter(at: character) : 0
                startsWithSinglePage = ReaderTextPagination.index(containing: glyph, pages: leaves) % 2 == 1
                pages = []
                var index = 0
                while index < leaves.count {
                    var page = leaves[index]
                    let pairsNext = !(index == 0 && startsWithSinglePage) && index + 1 < leaves.count
                    if pairsNext {
                        let second = leaves[index + 1]
                        page = ReaderTextPage(glyphRange: NSUnionRange(page.glyphRange, second.glyphRange),
                                              offset: page.offset, visibleHeight: page.visibleHeight,
                                              secondOffset: second.offset)
                    }
                    pages.append(page)
                    index += pairsNext ? 2 : 1
                }
                let right = facingPage ?? ReaderLayoutTextView()
                right.paginates = true
                right.scrollsToTop = false
                right.isEditable = false
                right.isSelectable = isSelectable
                right.isUserInteractionEnabled = isSelectable
                right.onAddPurification = onAddPurification
                right.delegate = right
                right.accessibilityElementsHidden = true
                right.contentInsetAdjustmentBehavior = .never
                right.textContainerInset = textContainerInset
                right.textContainer.lineFragmentPadding = textContainer.lineFragmentPadding
                right.backgroundColor = .clear
                right.isOpaque = false
                right.attributedText = attributedText
                right.invalidatePagination()
                facingContinuation = false
                if facingPage == nil { addSubview(right); facingPage = right }
            } else {
                facingPage?.removeFromSuperview()
                facingPage = nil
                facingContinuation = false
            }
            paginationDirty = false
            paginationSize = bounds.size
            paginationInsets = textContainerInset
            paginationWidth = textContainer.size.width
        }
        let size = CGSize(width: contentSize.width, height: (pages.last?.offset ?? 0) + bounds.height)
        if contentSize != size { contentSize = size }
        updatePageMask()
        return changed
    }

    func updatePageMask() {
        guard paginates, !pages.isEmpty else { layer.mask = nil; return }
        let page = pages[ReaderTextPagination.index(at: contentOffset.y, pages: pages)]
        let height = min(max(page.offset + page.visibleHeight - contentOffset.y, 0), bounds.height)
        let path = UIBezierPath(rect: CGRect(x: 0, y: textContainerInset.top, width: columnWidth, height: height))
        if let right = facingPage {
            right.frame = CGRect(x: columnWidth + 24, y: bounds.minY, width: columnWidth, height: bounds.height)
            let showsContinuation = page.secondOffset == nil && NSMaxRange(page.glyphRange) == layoutManager.numberOfGlyphs
                && continuationText != nil
            if showsContinuation != facingContinuation {
                right.attributedText = showsContinuation ? continuationText : attributedText
                right.invalidatePagination()
                facingContinuation = showsContinuation
            }
            right.isHidden = page.secondOffset == nil && !showsContinuation
            if let offset = page.secondOffset ?? (showsContinuation ? 0 : nil) {
                right.layoutIfNeeded()
                right.updatePagination()
                right.setContentOffset(CGPoint(x: 0, y: offset), animated: false)
                right.updatePageMask()
                path.append(UIBezierPath(rect: CGRect(x: columnWidth + 24, y: textContainerInset.top,
                                                      width: columnWidth, height: bounds.height)))
            }
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        pageMask.frame = bounds
        pageMask.path = path.cgPath
        layer.mask = pageMask
        CATransaction.commit()
    }

    func drawPageText(in context: CGContext) {
        guard !pages.isEmpty else { return }
        let page = pages[ReaderTextPagination.index(at: contentOffset.y, pages: pages)]
        let height = min(max(page.offset + page.visibleHeight - contentOffset.y, 0), bounds.height)
        context.saveGState()
        context.clip(to: CGRect(x: 0, y: textContainerInset.top, width: columnWidth, height: height))
        let origin = CGPoint(x: textContainerInset.left, y: textContainerInset.top - contentOffset.y)
        layoutManager.drawBackground(forGlyphRange: page.glyphRange, at: origin)
        layoutManager.drawGlyphs(forGlyphRange: page.glyphRange, at: origin)
        context.restoreGState()
        if let right = facingPage, !right.isHidden {
            context.saveGState()
            context.translateBy(x: columnWidth + 24, y: 0)
            right.drawPageText(in: context)
            context.restoreGState()
        }
    }

    override func layoutSubviews() {
        guard !isUpdatingLayout else { return }
        isUpdatingLayout = true
        updateColumnWidth()
        super.layoutSubviews()
        isUpdatingLayout = false
        guard !isUpdatingPagination else { return }
        let changed = updatePagination()
        guard bounds.width > 0, bounds.height > 0,
              changed || bounds.size != reportedSize || contentSize != reportedContentSize else { return }
        reportedSize = bounds.size
        reportedContentSize = contentSize
        onLayout?(self)
    }
}

struct ReaderTextView: UIViewRepresentable {
    let text: String
    let title: String
    let previousTitle: String?
    let previousText: String
    let isPreviousReady: Bool
    let continuationTitle: String?
    let continuationText: String
    let isContinuationReady: Bool
    let isVolume: Bool
    let fontSize: Double
    let fontPath: String
    let letterSpacing: Double
    let lineSpacing: Double
    let paragraphSpacing: Double
    let paragraphIndent: String
    let paddingLeft: Double
    let paddingRight: Double
    let paddingTop: Double
    let paddingBottom: Double
    let headerInset: Double
    let footerInset: Double
    let fontWeight: Int
    let titleMode: Int
    let titleSize: Double
    let titleTopSpacing: Double
    let titleBottomSpacing: Double
    let underlineMode: Int
    let isSelectable: Bool
    let fullJustify: Bool
    let pageAnimation: Int
    let isEInkMode: Bool
    let clickActions: [Int]
    let backgroundColor: UIColor
    let foregroundColor: UIColor
    let requestedPosition: Int
    let jumpPosition: Int?
    let renderRevision: Int
    var chapterRevision = 0
    var chapterIndex = 0
    var usesTwoPages = false
    var spreadStartPosition = 0
    var previousSpreadChapter: Int?
    var pageBackgroundColor: UIColor?
    var pageBackgroundImage: UIImage?
    var pageBackgroundFrame = CGRect.zero
    @Binding var readerPosition: Int
    @Binding var pageRanges: [NSRange]
    @Binding var currentPage: Int
    @Binding var totalPages: Int
    let isAutoReading: Bool
    let isAutoReadPaused: Bool
    let isLoadingNextChapter: Bool
    let secondsPerScreen: Double
    let onReachedEnd: (Int) -> Void
    let onReachedStart: (Int, Int?) -> Void
    let onEnteredPrevious: (Int) -> Void
    let onEnteredContinuation: (Int) -> Bool
    let onDeferredRender: () -> Void
    let onCancelNextLoading: () -> Void
    let onPageChanged: () -> Void
    let onTapAction: (Int) -> Void
    var onAddPurification: ((String) -> Void)? = nil
    var tapX1 = 1.0 / 3
    var tapX2 = 2.0 / 3
    var tapY1 = 1.0 / 3
    var tapY2 = 2.0 / 3
    var scrollsToTop = false

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeUIView(context: Context) -> UITextView {
        // Pagination uses NSLayoutManager. Start in TextKit 1 rather than
        // switching a TextKit 2 view after its content size has been computed.
        let view = ReaderLayoutTextView()
        view.onLayout = { [weak coordinator = context.coordinator] view in
            guard let coordinator else { return }
            let previousSize = coordinator.lastViewportSize
            coordinator.lastViewportSize = view.bounds.size
            if previousSize != .zero, previousSize != view.bounds.size { coordinator.cancelTransitions() }
            if coordinator.hasPendingScroll {
                coordinator.applyPendingScroll(in: view)
                return
            }
            if previousSize != .zero, previousSize != view.bounds.size {
                coordinator.scroll(to: coordinator.parent.readerPosition, in: view)
            } else {
                coordinator.reportPage(in: view)
                coordinator.reportPageRanges(in: view)
            }
        }
        view.accessibilityIdentifier = "reader.text"
        let effectivePageAnimation = isEInkMode ? 4 : pageAnimation
        view.paginates = effectivePageAnimation != 3
        view.usesTwoPages = usesTwoPages && view.paginates
        view.backgroundColor = backgroundColor
        view.isOpaque = backgroundColor != .clear
        view.delegate = context.coordinator
        view.contentInsetAdjustmentBehavior = .never
        view.isEditable = false
        view.scrollsToTop = scrollsToTop
        view.isSelectable = isSelectable
        (view as? ReaderSelectableTextView)?.onAddPurification = onAddPurification
        view.alwaysBounceVertical = effectivePageAnimation == 3
        view.isScrollEnabled = true
        view.panGestureRecognizer.isEnabled = effectivePageAnimation == 3
        view.textContainer.lineFragmentPadding = 4
        view.showsVerticalScrollIndicator = false
        view.isPagingEnabled = false
        view.decelerationRate = effectivePageAnimation == 3 ? .normal : .fast
        context.coordinator.installDisplayLink(for: view)
        context.coordinator.installGestures(on: view)
        context.coordinator.updateInteractionMode(on: view, isScrollMode: effectivePageAnimation == 3)
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        context.coordinator.parent = self
        let viewportSizeChanged = view.bounds.size != .zero
            && context.coordinator.lastViewportSize != view.bounds.size
        if viewportSizeChanged {
            context.coordinator.cancelTransitions()
            context.coordinator.lastViewportSize = view.bounds.size
        }
        let effectivePageAnimation = isEInkMode ? 4 : pageAnimation
        if context.coordinator.renderedPageAnimation != effectivePageAnimation {
            context.coordinator.cancelTransitions()
            context.coordinator.renderedPageAnimation = effectivePageAnimation
        }
        if let layoutView = view as? ReaderLayoutTextView {
            layoutView.paginates = effectivePageAnimation != 3
            layoutView.usesTwoPages = usesTwoPages && layoutView.paginates
        }
        if viewportSizeChanged {
            view.layoutManager.invalidateLayout(
                forCharacterRange: NSRange(location: 0, length: view.textStorage.length),
                actualCharacterRange: nil
            )
        }
        view.scrollsToTop = scrollsToTop
        view.isSelectable = isSelectable
        (view as? ReaderSelectableTextView)?.onAddPurification = onAddPurification
        view.alwaysBounceVertical = effectivePageAnimation == 3
        view.isScrollEnabled = true
        view.panGestureRecognizer.isEnabled = effectivePageAnimation == 3
        view.showsVerticalScrollIndicator = false
        view.isPagingEnabled = false
        view.decelerationRate = effectivePageAnimation == 3 ? .normal : .fast
        context.coordinator.updateInteractionMode(on: view, isScrollMode: effectivePageAnimation == 3)
        view.backgroundColor = backgroundColor
        view.isOpaque = backgroundColor != .clear
        view.scrollsToTop = scrollsToTop
        view.isSelectable = isSelectable
        (view as? ReaderSelectableTextView)?.onAddPurification = onAddPurification
        view.textContainerInset = .init(
            top: CGFloat(paddingTop + headerInset),
            left: CGFloat(paddingLeft),
            bottom: CGFloat(paddingBottom + footerInset),
            right: CGFloat(paddingRight)
        )
        let contentKey = text.hashValue
        let primaryContentKey = "\(chapterRevision)|\(title)|\(text)".hashValue
        let showsContinuation = effectivePageAnimation == 3 && isContinuationReady && continuationTitle != nil
        let showsFacingContinuation = usesTwoPages && isContinuationReady && continuationTitle != nil && !continuationText.isEmpty
        let showsPrevious = showsContinuation && isPreviousReady && previousTitle != nil
        let adjacentContentKey = showsPrevious || showsContinuation || showsFacingContinuation
            ? "\(showsPrevious)|\(previousTitle ?? "")|\(previousText)|\(showsContinuation)|\(continuationTitle ?? "")|\(continuationText)".hashValue : 0
        let displaysTitle = titleMode != 2 || isVolume
        let titlePrefix = displaysTitle && !title.isEmpty ? title + "\n" : ""
        let styleKey = "\(chapterRevision)|\(contentKey)|\(usesTwoPages)|\(title)|\(isVolume)|\(fontSize)|\(fontPath)|\(letterSpacing)|\(lineSpacing)|\(paragraphSpacing)|\(paragraphIndent)|\(paddingLeft)|\(paddingRight)|\(paddingTop)|\(paddingBottom)|\(headerInset)|\(footerInset)|\(fontWeight)|\(titleMode)|\(titleSize)|\(titleTopSpacing)|\(titleBottomSpacing)|\(underlineMode)|\(isSelectable)|\(fullJustify)|\(effectivePageAnimation)|\(foregroundColor.hash)"
        if context.coordinator.styleKey != styleKey || context.coordinator.adjacentContentKey != adjacentContentKey {
            if context.coordinator.shouldDeferRender(in: view) {
                context.coordinator.needsDeferredRender = true
                return
            }
            let primaryContentChanged = context.coordinator.primaryContentKey != primaryContentKey
            if primaryContentChanged, effectivePageAnimation != 3,
               let oldIndex = context.coordinator.displayedChapterIndex, oldIndex != chapterIndex {
                context.coordinator.preparePageTurn(chapterIndex > oldIndex ? 1 : -1, in: view)
            } else if context.coordinator.styleKey != styleKey { context.coordinator.cancelTransitions() }
            context.coordinator.displayedChapterIndex = chapterIndex
            let visiblePosition = context.coordinator.contentCharacter(at: view.contentOffset, in: view)
            context.coordinator.resetAutoReadForPageChange()
            context.coordinator.resetPageRangeRetry()
            context.coordinator.contentKey = contentKey
            context.coordinator.primaryContentKey = primaryContentKey
            context.coordinator.adjacentContentKey = adjacentContentKey
            context.coordinator.styleKey = styleKey
            let typography = ReaderTypography(configuration: self)
            let bodyAttributes = typography.bodyAttributes
            let rendered = NSMutableAttributedString(string: "")
            context.coordinator.previousBodyStart = nil
            context.coordinator.previousBodyEnd = nil
            context.coordinator.continuationSectionStart = nil
            context.coordinator.continuationBodyStart = nil
            if showsPrevious {
                let previousHeading = displaysTitle ? (previousTitle ?? "") + "\n" : ""
                rendered.append(NSAttributedString(string: previousHeading, attributes: typography.headingAttributes))
                context.coordinator.previousBodyStart = rendered.length
                rendered.append(NSAttributedString(
                    string: previousText.isEmpty ? String(repeating: "\n", count: 80) : previousText,
                    attributes: bodyAttributes
                ))
                context.coordinator.previousBodyEnd = rendered.length
                rendered.append(NSAttributedString(string: "\n\n", attributes: bodyAttributes))
            }
            context.coordinator.currentSectionStart = rendered.length
            if !titlePrefix.isEmpty {
                rendered.append(NSAttributedString(string: titlePrefix, attributes: typography.headingAttributes))
            }
            context.coordinator.renderedPrefixLength = rendered.length
            rendered.append(NSAttributedString(string: text, attributes: bodyAttributes))
            context.coordinator.currentBodyEnd = rendered.length
            if showsContinuation {
                rendered.append(NSAttributedString(string: "\n\n", attributes: bodyAttributes))
                context.coordinator.continuationSectionStart = rendered.length
                let continuationHeading = displaysTitle ? (continuationTitle ?? "") + "\n" : ""
                rendered.append(NSAttributedString(string: continuationHeading, attributes: typography.headingAttributes))
                context.coordinator.continuationBodyStart = rendered.length
                rendered.append(NSAttributedString(
                    string: continuationText.isEmpty ? String(repeating: "\n", count: 80) : continuationText,
                    attributes: bodyAttributes
                ))
            }
            if let layoutView = view as? ReaderLayoutTextView {
                layoutView.spreadStartCharacter = context.coordinator.renderedPrefixLength
                    + min(max(spreadStartPosition, 0), text.utf16.count)
                if showsFacingContinuation {
                    let next = NSMutableAttributedString(string: titleMode != 2 ? (continuationTitle ?? "") + "\n" : "",
                                                         attributes: typography.headingAttributes)
                    layoutView.continuationBodyStart = next.length
                    next.append(NSAttributedString(string: continuationText, attributes: bodyAttributes))
                    layoutView.continuationText = next
                } else {
                    layoutView.continuationText = nil
                }
            }
            context.coordinator.isApplyingContent = true
            (view as? ReaderLayoutTextView)?.invalidatePagination()
            view.attributedText = rendered
            context.coordinator.isApplyingContent = false
            context.coordinator.scroll(
                to: primaryContentChanged ? requestedPosition : visiblePosition,
                in: view
            )
            let generation = context.coordinator.layoutGeneration
            DispatchQueue.main.async { [weak coordinator = context.coordinator] in
                guard coordinator?.layoutGeneration == generation else { return }
                coordinator?.reportPage(in: view)
                coordinator?.reportPageRanges(in: view)
            }
        } else if viewportSizeChanged, !context.coordinator.hasPendingScroll {
            context.coordinator.scroll(to: readerPosition, in: view)
            let generation = context.coordinator.layoutGeneration
            DispatchQueue.main.async { [weak coordinator = context.coordinator] in
                guard coordinator?.layoutGeneration == generation else { return }
                coordinator?.reportPage(in: view)
                coordinator?.reportPageRanges(in: view)
            }
        }
        if let jumpPosition, context.coordinator.lastJumpPosition != jumpPosition {
            context.coordinator.cancelTransitions()
            context.coordinator.lastJumpPosition = jumpPosition
            context.coordinator.scroll(to: jumpPosition, in: view)
        } else if jumpPosition == nil {
            context.coordinator.lastJumpPosition = nil
        }
        context.coordinator.updateLoadingFooter(in: view, visible: isLoadingNextChapter)
        context.coordinator.updateAutoRead(
            isRunning: isAutoReading,
            isPaused: isAutoReadPaused,
            secondsPerScreen: secondsPerScreen
        )
        // SwiftUI can reset the bindings after the chapter's TextKit layout has
        // already completed. Reconcile them even when the text/style is unchanged.
        if view.bounds.width > 0, view.bounds.height > 0 {
            context.coordinator.reportPage(in: view)
            if pageRanges.isEmpty { context.coordinator.reportPageRanges(in: view) }
        }
    }

    static func dismantleUIView(_ view: UITextView, coordinator: Coordinator) {
        coordinator.invalidate()
    }

    final class Coordinator: NSObject, UITextViewDelegate, UIGestureRecognizerDelegate {
        var parent: ReaderTextView
        var contentKey = 0
        var primaryContentKey = 0
        var adjacentContentKey = 0
        var displayedChapterIndex: Int?
        var renderedPageAnimation: Int?
        var styleKey = ""
        var renderedPrefixLength = 0
        var currentSectionStart = 0
        var currentBodyEnd = 0
        var previousBodyStart: Int?
        var previousBodyEnd: Int?
        var continuationSectionStart: Int?
        var continuationBodyStart: Int?
        var lastJumpPosition: Int?
        private(set) var layoutGeneration = 0
        private var pendingScrollPosition: Int?
        private var isApplyingScroll = false
        var hasPendingScroll: Bool { pendingScrollPosition != nil }
        var lastViewportSize = CGSize.zero
        private var isAutoReading = false
        private var isAutoReadPaused = false
        private var secondsPerScreen = 10.0
        private weak var textView: UITextView?
        private var displayLink: CADisplayLink?
        private var lastTimestamp: CFTimeInterval = 0
        private var isUserDragging = false
        private var lastDragOffsetY: CGFloat = 0
        private var dragDirection = 0
        private var didReachEnd = false
        private var didReachStart = false
        private var didEnterPrevious = false
        private var didEnterContinuation = false
        private var pendingPreviousPosition: Int?
        private var pendingContinuationPosition: Int?
        var needsDeferredRender = false
        var isApplyingContent = false
        let pageTransition = ReaderPageTransition()
        private var isRenderingAutoPage = false
        private var lastReportedPage: Int?
        private var autoPageProgress: CGFloat = 0
        private var eInkElapsed: CFTimeInterval = 0
        private var eInkPageInterval: CFTimeInterval = 10
        private var autoPageTarget: CGFloat?
        private weak var autoPageOverlay: UIImageView?
        private var pageRangeRetryCount = 0
        private weak var nextSwipe: UISwipeGestureRecognizer?
        private weak var previousSwipe: UISwipeGestureRecognizer?
        private weak var readerTap: UITapGestureRecognizer?
        private weak var loadingFooter: UIView?
        private var didRequestLoadingCancellation = false

        init(parent: ReaderTextView) { self.parent = parent }

        func installDisplayLink(for view: UITextView) {
            textView = view
            let link = CADisplayLink(target: self, selector: #selector(step(_:)))
            link.add(to: .main, forMode: .common)
            displayLink = link
        }

        func installGestures(on view: UITextView) {
            let tap = UITapGestureRecognizer(target: self, action: #selector(tapped(_:)))
            tap.delaysTouchesBegan = false
            tap.cancelsTouchesInView = false
            tap.delegate = self
            view.addGestureRecognizer(tap)
            readerTap = tap
            let next = UISwipeGestureRecognizer(target: self, action: #selector(swiped(_:)))
            next.delegate = self
            next.direction = .left
            view.addGestureRecognizer(next)
            let previous = UISwipeGestureRecognizer(target: self, action: #selector(swiped(_:)))
            previous.delegate = self
            previous.direction = .right
            view.addGestureRecognizer(previous)
            nextSwipe = next
            previousSwipe = previous
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            gestureRecognizer === readerTap || otherGestureRecognizer === readerTap
        }

        @available(iOS 16.0, *)
        func textView(_ textView: UITextView, editMenuForTextIn range: NSRange, suggestedActions: [UIMenuElement]) -> UIMenu? {
            (textView as? ReaderSelectableTextView)?.selectionMenu(for: range)
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            (textView as? ReaderLayoutTextView)?.hasTextSelection != true
        }

        func updateInteractionMode(on view: UITextView, isScrollMode: Bool) {
            // The scroll reader owns the vertical pan gesture. Horizontal
            // swipe recognizers must be disabled there or UIKit can cancel the
            // pan before the user reaches the end of a long chapter.
            nextSwipe?.isEnabled = !isScrollMode
            previousSwipe?.isEnabled = !isScrollMode
            view.panGestureRecognizer.isEnabled = isScrollMode
            view.alwaysBounceVertical = isScrollMode
            // Page boundaries follow complete text lines rather than a uniform screen stride.
            view.isPagingEnabled = false
            view.showsVerticalScrollIndicator = false
        }

        func updateLoadingFooter(in view: UITextView, visible: Bool) {
            if !visible {
                loadingFooter?.removeFromSuperview()
                loadingFooter = nil
                view.contentInset.bottom = 0
                didRequestLoadingCancellation = false
                return
            }
            let footer: UIView
            if let loadingFooter {
                footer = loadingFooter
            } else {
                let container = UIView()
                container.isUserInteractionEnabled = false
                let indicator = UIActivityIndicatorView(style: .medium)
                indicator.color = parent.foregroundColor.withAlphaComponent(0.65)
                indicator.startAnimating()
                let label = UILabel()
                label.text = "正在加载下一章…"
                label.textColor = parent.foregroundColor.withAlphaComponent(0.65)
                label.font = .systemFont(ofSize: 13)
                let stack = UIStackView(arrangedSubviews: [indicator, label])
                stack.axis = .horizontal
                stack.spacing = 8
                stack.alignment = .center
                stack.translatesAutoresizingMaskIntoConstraints = false
                container.addSubview(stack)
                NSLayoutConstraint.activate([
                    stack.centerXAnchor.constraint(equalTo: container.centerXAnchor),
                    stack.centerYAnchor.constraint(equalTo: container.centerYAnchor)
                ])
                view.addSubview(container)
                loadingFooter = container
                footer = container
            }
            view.contentInset.bottom = 64
            footer.frame = CGRect(x: 0, y: view.contentSize.height, width: view.bounds.width, height: 52)
        }

        func shouldDeferRender(in view: UITextView) -> Bool {
            parent.pageAnimation == 3 && (isUserDragging || view.isDragging || view.isDecelerating)
        }

        func invalidate() {
            pageTransition.cancel()
            layoutGeneration &+= 1
            pendingScrollPosition = nil
            resetAutoPage()
            displayLink?.invalidate()
            displayLink = nil
        }

        func updateAutoRead(isRunning: Bool, isPaused: Bool, secondsPerScreen: Double) {
            let wasRunning = isAutoReading
            let wasPaused = isAutoReadPaused
            self.isAutoReading = isRunning
            isAutoReadPaused = isPaused
            self.secondsPerScreen = max(1, secondsPerScreen)
            if wasRunning && !isRunning {
                resetAutoPage()
            } else if !wasRunning && isRunning {
                didReachEnd = false
                lastTimestamp = 0
                eInkPageInterval = self.secondsPerScreen
            } else if isPaused || wasPaused != isPaused {
                lastTimestamp = 0
            }
        }

        func resetAutoReadForPageChange() {
            didReachEnd = false
            didReachStart = false
            lastReportedPage = nil
            didEnterPrevious = false
            didEnterContinuation = false
            pendingPreviousPosition = nil
            pendingContinuationPosition = nil
            resetAutoPage()
        }

        func scroll(to characterPosition: Int, in view: UITextView) {
            guard !view.text.isEmpty else { return }
            layoutGeneration &+= 1
            let generation = layoutGeneration
            pendingScrollPosition = characterPosition
            DispatchQueue.main.async { [weak self] in
                guard let self, self.layoutGeneration == generation else { return }
                self.applyPendingScroll(in: view)
            }
        }

        @discardableResult
        func applyPendingScroll(in view: UITextView) -> Bool {
            guard !isApplyingScroll, let characterPosition = pendingScrollPosition,
                  view.bounds.width > 0, view.bounds.height > 0, !view.text.isEmpty else { return false }
            isApplyingScroll = true
            defer { isApplyingScroll = false }
            view.layoutManager.ensureLayout(for: view.textContainer)
            view.layoutIfNeeded()
            let limits = scrollLimits(for: view)
            let target: CGFloat
            if characterPosition == Int.max {
                // An end-of-chapter jump is a viewport destination, not the
                // bounding rect of a possibly invisible trailing newline.
                target = limits.maximum
            } else {
                let prefix = characterPosition == 0 && parent.pageAnimation == 3
                    ? currentSectionStart
                    : renderedPrefixLength
                let location = ReaderPositionResolver.renderedLocation(
                    position: characterPosition,
                    prefixLength: prefix,
                    renderedLength: view.text.utf16.count
                )
                let glyph = view.layoutManager.glyphIndexForCharacter(at: location)
                var point = view.layoutManager.boundingRect(
                    forGlyphRange: NSRange(location: glyph, length: 1),
                    in: view.textContainer
                ).origin
                if usesPagination {
                    let pages = pageLayout(in: view)
                    let index = characterPosition == 0 ? 0 : ReaderTextPagination.index(containing: glyph, pages: pages)
                    target = pages.isEmpty ? 0 : pages[index].offset
                } else {
                    point.y += view.textContainerInset.top
                    target = min(max(point.y - view.adjustedContentInset.top, limits.minimum), limits.maximum)
                }
            }
            view.setContentOffset(CGPoint(x: 0, y: target), animated: false)
            pendingScrollPosition = nil
            reportPage(in: view)
            reportPageRanges(in: view)
            animatePageTurn(in: view)
            return true
        }

        private var usesPagination: Bool { parent.pageAnimation != 3 || parent.isEInkMode }

        private func pageLayout(in view: UITextView) -> [ReaderTextPage] {
            if let paged = view as? ReaderLayoutTextView {
                paged.updatePagination()
                return paged.pages
            }
            let pages = ReaderTextPagination.pages(in: view)
            let size = CGSize(width: view.contentSize.width, height: (pages.last?.offset ?? 0) + view.bounds.height)
            if view.contentSize != size { view.contentSize = size }
            return pages
        }

        private func adjacentPageOffset(_ direction: Int, in view: UITextView) -> CGFloat {
            if usesPagination {
                let pages = pageLayout(in: view)
                guard !pages.isEmpty else { return 0 }
                let index = ReaderTextPagination.index(at: view.contentOffset.y, pages: pages)
                return pages[min(max(index + direction, 0), pages.count - 1)].offset
            }
            let limits = scrollLimits(for: view)
            return min(max(view.contentOffset.y + CGFloat(direction) * readingViewportHeight(for: view), limits.minimum), limits.maximum)
        }

        private func readingViewportHeight(for view: UITextView) -> CGFloat {
            max(
                view.bounds.height
                    - view.adjustedContentInset.top
                    - view.adjustedContentInset.bottom
                    - view.textContainerInset.top
                    - view.textContainerInset.bottom,
                1
            )
        }

        private func scrollLimits(for view: UITextView) -> (minimum: CGFloat, maximum: CGFloat) {
            if usesPagination {
                let pages = pageLayout(in: view)
                return ((view as? ReaderLayoutTextView)?.firstSpreadOffset ?? 0, pages.last?.offset ?? 0)
            }
            let minimum = -view.adjustedContentInset.top
            let maximum = max(
                view.contentSize.height - view.bounds.height + view.adjustedContentInset.bottom,
                minimum
            )
            return (minimum, maximum)
        }

        private func pageMetrics(for view: UITextView) -> (current: Int, total: Int) {
            if usesPagination {
                let pages = pageLayout(in: view)
                return (ReaderTextPagination.index(at: view.contentOffset.y, pages: pages) + 1, max(pages.count, 1))
            }
            let pageHeight = readingViewportHeight(for: view)
            if parent.pageAnimation == 3, currentBodyEnd > currentSectionStart {
                view.layoutManager.ensureLayout(for: view.textContainer)
                let glyphCount = view.layoutManager.numberOfGlyphs
                if glyphCount > 0 {
                    let first = min(view.layoutManager.glyphIndexForCharacter(at: currentSectionStart), glyphCount - 1)
                    let last = min(view.layoutManager.glyphIndexForCharacter(at: currentBodyEnd - 1), glyphCount - 1)
                    let start = view.layoutManager.boundingRect(
                        forGlyphRange: NSRange(location: first, length: 1), in: view.textContainer
                    ).minY + view.textContainerInset.top - view.adjustedContentInset.top
                    let end = view.layoutManager.boundingRect(
                        forGlyphRange: NSRange(location: last, length: 1), in: view.textContainer
                    ).maxY + view.textContainerInset.top - view.adjustedContentInset.top
                    let total = max(Int(ceil((end - start) / pageHeight)), 1)
                    let position = max(view.contentOffset.y - start, 0)
                    return (min(Int(floor(position / pageHeight)) + 1, total), total)
                }
            }
            let limits = scrollLimits(for: view)
            let scrollRange = max(limits.maximum - limits.minimum, 0)
            let total = max(Int(ceil(scrollRange / pageHeight)) + 1, 1)
            guard total > 1 else { return (1, 1) }
            let position = min(max(view.contentOffset.y - limits.minimum, 0), scrollRange)
            let current = position >= scrollRange - 0.5
                ? total
                : min(Int(floor(position / pageHeight)) + 1, total)
            return (current, total)
        }

        private func renderedCharacter(at offset: CGPoint, in view: UITextView) -> Int {
            guard !view.text.isEmpty else { return 0 }
            if usesPagination {
                let pages = pageLayout(in: view)
                guard !pages.isEmpty else { return 0 }
                let range = pages[ReaderTextPagination.index(at: offset.y, pages: pages)].glyphRange
                guard range.length > 0 else { return 0 }
                return view.layoutManager.characterIndexForGlyph(at: range.location)
            }
            let point = CGPoint(
                x: view.textContainerInset.left + 1,
                y: offset.y + view.textContainerInset.top + 1
            )
            let glyphCount = view.layoutManager.numberOfGlyphs
            guard glyphCount > 0 else { return 0 }
            let glyph = min(view.layoutManager.glyphIndex(for: point, in: view.textContainer), glyphCount - 1)
            let character = view.layoutManager.characterIndexForGlyph(at: glyph)
            return min(max(character, 0), view.text.utf16.count)
        }

        func contentCharacter(at offset: CGPoint, in view: UITextView) -> Int {
            let character = renderedCharacter(at: offset, in: view)
            return min(max(character - renderedPrefixLength, 0), parent.text.utf16.count)
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            guard !isRenderingAutoPage, !isApplyingContent else { return }
            guard let view = scrollView as? UITextView, !view.text.isEmpty else { return }
            if let paged = view as? ReaderLayoutTextView {
                guard !paged.isUpdatingPagination, !paged.isUpdatingLayout else { return }
                paged.updatePageMask()
            }
            if parent.isLoadingNextChapter, !didRequestLoadingCancellation {
                let textBottom = max(
                    view.contentSize.height - view.bounds.height
                        + view.adjustedContentInset.bottom - view.contentInset.bottom,
                    -view.adjustedContentInset.top
                )
                if view.contentOffset.y < textBottom - 44 {
                    didRequestLoadingCancellation = true
                    pageTransition.cancel()
                    DispatchQueue.main.async { [weak self] in self?.parent.onCancelNextLoading() }
                }
            }
            if isUserDragging {
                let delta = scrollView.contentOffset.y - lastDragOffsetY
                if abs(delta) > 0.5 { dragDirection = delta > 0 ? 1 : -1 }
                lastDragOffsetY = scrollView.contentOffset.y
            }
            let metrics = pageMetrics(for: view)
            reportPage(in: view)
            if let lastReportedPage, lastReportedPage != metrics.current {
                self.lastReportedPage = metrics.current
                let generation = layoutGeneration
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.layoutGeneration == generation else { return }
                    self.parent.onPageChanged()
                }
            } else if lastReportedPage == nil {
                lastReportedPage = metrics.current
            }
            let contentCharacter = contentCharacter(at: scrollView.contentOffset, in: view)
            let renderedCharacter = renderedCharacter(at: scrollView.contentOffset, in: view)
            if let previousBodyStart,
               let previousBodyEnd,
               renderedCharacter < currentSectionStart {
                pendingContinuationPosition = nil
                let position = min(max(renderedCharacter - previousBodyStart, 0), max(previousBodyEnd - previousBodyStart - 1, 0))
                if isUserDragging || view.isDecelerating {
                    pendingPreviousPosition = position
                    return
                }
                guard !didEnterPrevious else { return }
                didEnterPrevious = true
                let generation = layoutGeneration
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.layoutGeneration == generation else { return }
                    self.parent.onEnteredPrevious(position)
                }
                return
            }
            if let continuationSectionStart,
               let continuationBodyStart,
               renderedCharacter >= continuationSectionStart {
                pendingPreviousPosition = nil
                let position = max(renderedCharacter - continuationBodyStart, 0)
                if isUserDragging || view.isDecelerating {
                    pendingContinuationPosition = position
                    return
                }
                guard !didEnterContinuation else { return }
                didEnterContinuation = true
                let generation = layoutGeneration
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.layoutGeneration == generation else { return }
                    _ = self.parent.onEnteredContinuation(position)
                }
                return
            }
            pendingPreviousPosition = nil
            pendingContinuationPosition = nil
            guard contentCharacter != parent.readerPosition else { return }
            let generation = layoutGeneration
            DispatchQueue.main.async { [weak self] in
                guard let self, self.layoutGeneration == generation else { return }
                self.parent.readerPosition = contentCharacter
            }
        }

        func reportPage(in view: UITextView) {
            guard view.bounds.width > 0, view.bounds.height > 0 else { return }
            let metrics = pageMetrics(for: view)
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-uiPagingDiagnostics") {
                view.accessibilityLabel = "bounds=\(view.bounds.size) content=\(view.contentSize) used=\(view.layoutManager.usedRect(for: view.textContainer)) mode=\(parent.pageAnimation) pages=\(metrics.total)"
            }
            #endif
            guard metrics.current != parent.currentPage || metrics.total != parent.totalPages else { return }
            let generation = layoutGeneration
            DispatchQueue.main.async { [weak self] in
                guard let self, self.layoutGeneration == generation else { return }
                self.parent.currentPage = metrics.current
                self.parent.totalPages = metrics.total
            }
        }

        func reportPageRanges(in view: UITextView) {
            guard view.bounds.width > 0, view.bounds.height > 0 else { return }
            if !usesPagination {
                let ranges = parent.text.isEmpty
                    ? []
                    : [NSRange(location: 0, length: parent.text.utf16.count)]
                guard ranges != parent.pageRanges else { return }
                DispatchQueue.main.async { [weak self] in self?.parent.pageRanges = ranges }
                return
            }
            guard !view.text.isEmpty else { return }
            view.layoutManager.ensureLayout(for: view.textContainer)
            var ranges: [NSRange] = []
            for page in pageLayout(in: view) {
                let glyphRange = page.glyphRange
                guard glyphRange.length > 0 else { continue }
                let characterRange = view.layoutManager.characterRange(
                    forGlyphRange: glyphRange,
                    actualGlyphRange: nil
                )
                let start = max(characterRange.location - renderedPrefixLength, 0)
                let end = min(
                    characterRange.location + characterRange.length - renderedPrefixLength,
                    parent.text.utf16.count
                )
                guard end > start else { continue }
                let range = NSRange(location: start, length: end - start)
                if ranges.last?.location == range.location,
                   ranges.last?.length == range.length { continue }
                ranges.append(range)
            }
            if ranges.isEmpty {
                guard pageRangeRetryCount < 10 else { return }
                pageRangeRetryCount += 1
                let generation = layoutGeneration
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                    guard let self, self.layoutGeneration == generation else { return }
                    self.reportPageRanges(in: view)
                }
                return
            }
            pageRangeRetryCount = 0
            guard ranges != parent.pageRanges else { return }
            let generation = layoutGeneration
            DispatchQueue.main.async { [weak self] in
                guard let self, self.layoutGeneration == generation else { return }
                self.parent.pageRanges = ranges
            }
        }

        func resetPageRangeRetry() {
            pageRangeRetryCount = 0
        }

        func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
            isUserDragging = true
            lastDragOffsetY = scrollView.contentOffset.y
            dragDirection = 0
            didReachEnd = false
            didReachStart = false
        }
        func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
            if parent.pageAnimation == 3, let view = scrollView as? UITextView {
                triggerChapterBoundaryIfNeeded(in: view)
            }
            if !decelerate {
                isUserDragging = false
                flushPendingChapterTransition()
                requestDeferredRenderIfNeeded()
            }
        }
        func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
            if parent.pageAnimation == 3, let view = scrollView as? UITextView {
                triggerChapterBoundaryIfNeeded(in: view)
            }
            isUserDragging = false
            flushPendingChapterTransition()
            requestDeferredRenderIfNeeded()
        }

        private func requestDeferredRenderIfNeeded() {
            guard needsDeferredRender else { return }
            needsDeferredRender = false
            DispatchQueue.main.async { [weak self] in self?.parent.onDeferredRender() }
        }

        private func flushPendingChapterTransition() {
            let previous = pendingPreviousPosition
            let continuation = pendingContinuationPosition
            pendingPreviousPosition = nil
            pendingContinuationPosition = nil
            let generation = layoutGeneration
            if let previous, !didEnterPrevious {
                didEnterPrevious = true
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.layoutGeneration == generation else { return }
                    self.parent.onEnteredPrevious(previous)
                }
            } else if let continuation, !didEnterContinuation {
                didEnterContinuation = true
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.layoutGeneration == generation else { return }
                    _ = self.parent.onEnteredContinuation(continuation)
                }
            }
        }

        private func triggerChapterBoundaryIfNeeded(in view: UITextView) {
            let (minimum, maximum) = scrollLimits(for: view)
            let atEnd = view.contentOffset.y >= maximum - 0.5
            let atStart = view.contentOffset.y <= minimum + 0.5
            if atEnd, dragDirection > 0, continuationSectionStart == nil, !didReachEnd {
                didReachEnd = true
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                parent.onReachedEnd(contentCharacter(at: view.contentOffset, in: view))
            } else if atStart, dragDirection < 0, previousBodyStart == nil, !didReachStart {
                didReachStart = true
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                parent.onReachedStart(contentCharacter(at: view.contentOffset, in: view), nil)
            }
        }

        @objc private func tapped(_ gesture: UITapGestureRecognizer) {
            guard let view = textView, gesture.state == .ended, (view as? ReaderLayoutTextView)?.hasTextSelection != true else { return }
            let point = gesture.location(in: view)
            // UIScrollView changes its bounds origin as content scrolls, and
            // gesture locations use that content coordinate space. Convert
            // back to viewport coordinates before dividing the visible screen
            // into the 3×3 tap grid.
            let viewportX = point.x - view.bounds.minX
            let viewportY = point.y - view.bounds.minY
            let index = ReaderTapZones.index(x: viewportX, y: viewportY, size: view.bounds.size,
                                              x1: parent.tapX1, x2: parent.tapX2, y1: parent.tapY1, y2: parent.tapY2)
            let column = index % 3
            let action = index == 4 || (parent.usesTwoPages && column == 1)
                ? 0
                : (parent.clickActions.indices.contains(index) ? parent.clickActions[index] : 0)

            if parent.pageAnimation == 3, action == 1 || action == 2 {
                return
            }
            switch action {
            case 1: turnPage(1)
            case 2: turnPage(-1)
            case -1: break
            default: parent.onTapAction(action)
            }
        }

        @objc private func swiped(_ gesture: UISwipeGestureRecognizer) {
            turnPage(gesture.direction == .left ? 1 : -1)
        }

        private func turnPage(_ direction: Int) {
            guard !hasPendingScroll, !pageTransition.state.isBusy, let view = textView else { return }
            if isAutoReading { resetAutoReadForPageChange() }
            let (minimum, maximum) = scrollLimits(for: view)
            let target = adjacentPageOffset(direction, in: view)
            if direction < 0, view.contentOffset.y <= minimum + 0.5 {
                if parent.previousTitle != nil { preparePageTurn(direction, in: view) }
                parent.onReachedStart(contentCharacter(at: view.contentOffset, in: view), parent.previousSpreadChapter)
                return
            }
            if direction > 0, view.contentOffset.y >= maximum - 0.5 {
                finishChapter(in: view)
                return
            }
            preparePageTurn(direction, in: view)
            view.setContentOffset(CGPoint(x: 0, y: target), animated: false)
            view.layoutIfNeeded()
            animatePageTurn(in: view)
        }

        private func finishChapter(in view: UITextView) {
            if let position = (view as? ReaderLayoutTextView)?.continuationPosition {
                if parent.onEnteredContinuation(position) { preparePageTurn(1, in: view) }
            } else {
                if parent.continuationTitle != nil { preparePageTurn(1, in: view) }
                parent.onReachedEnd(contentCharacter(at: view.contentOffset, in: view))
            }
        }

        private func pageImage(in view: UITextView) -> UIImageView? {
            guard let view = view as? ReaderLayoutTextView else { return nil }
            let viewport = view.convert(view.bounds, to: nil)
            let frame = parent.pageBackgroundFrame.isEmpty ? .zero
                : parent.pageBackgroundFrame.offsetBy(dx: -viewport.minX, dy: -viewport.minY)
            return ReaderPageRenderer.render(view, color: parent.pageBackgroundColor ?? parent.backgroundColor,
                                             image: parent.pageBackgroundImage, imageFrame: frame)
        }

        func preparePageTurn(_ direction: Int, in view: UITextView) {
            guard !parent.isEInkMode, (0...2).contains(parent.pageAnimation), !view.text.isEmpty else { return }
            pageTransition.prepare(direction, sourceKey: primaryContentKey, in: view) { pageImage(in: view) }
        }

        func cancelTransitions() {
            pageTransition.cancel()
            resetAutoPage()
        }

        private func animatePageTurn(in view: UITextView) {
            pageTransition.finish(contentKey: primaryContentKey, offset: view.contentOffset.y, style: parent.isEInkMode ? 4 : parent.pageAnimation) {
                pageImage(in: view)
            }
        }

        private func resetAutoPage() {
            autoPageProgress = 0
            eInkElapsed = 0
            eInkPageInterval = secondsPerScreen
            autoPageTarget = nil
            autoPageOverlay?.removeFromSuperview()
            autoPageOverlay = nil
            lastTimestamp = 0
        }

        private func prepareAutoPage(in view: UITextView) -> Bool {
            let maximum = scrollLimits(for: view).maximum
            guard view.contentOffset.y < maximum - 0.5 else { return false }
            let target = adjacentPageOffset(1, in: view)
            let originalOffset = view.contentOffset
            isRenderingAutoPage = true
            view.setContentOffset(CGPoint(x: 0, y: target), animated: false)
            view.layoutIfNeeded()
            let overlay = pageImage(in: view)
            view.setContentOffset(originalOffset, animated: false)
            view.layoutIfNeeded()
            isRenderingAutoPage = false

            guard let overlay, let host = view.superview else { return false }
            overlay.isUserInteractionEnabled = false
            overlay.contentMode = .top
            overlay.clipsToBounds = true
            overlay.layer.borderColor = view.tintColor.cgColor
            overlay.layer.borderWidth = 0
            var frame = view.convert(view.bounds, to: host)
            frame.size.height = 0
            overlay.frame = frame
            host.addSubview(overlay)
            autoPageOverlay = overlay
            autoPageTarget = target
            return true
        }

        private func advancePagedAutoRead(in view: UITextView, elapsed: CFTimeInterval) {
            if autoPageOverlay == nil, !prepareAutoPage(in: view) {
                guard !didReachEnd, view.contentOffset.y >= scrollLimits(for: view).maximum - 0.5 else { return }
                didReachEnd = true
                finishChapter(in: view)
                return
            }
            didReachEnd = false
            let pageHeight = readingViewportHeight(for: view)
            autoPageProgress += pageHeight / CGFloat(secondsPerScreen) * CGFloat(elapsed)
            let revealedHeight = min(autoPageProgress, pageHeight)
            if let overlay = autoPageOverlay, let host = overlay.superview {
                var frame = view.convert(view.bounds, to: host)
                frame.size.height = revealedHeight
                overlay.frame = frame
                overlay.layer.borderWidth = revealedHeight > 0 ? 0.5 : 0
            }
            guard autoPageProgress >= pageHeight, let target = autoPageTarget else { return }
            autoPageOverlay?.removeFromSuperview()
            autoPageOverlay = nil
            autoPageTarget = nil
            autoPageProgress = 0
            view.setContentOffset(CGPoint(x: 0, y: target), animated: false)
        }

        private func advanceEInkAutoRead(in view: UITextView, elapsed: CFTimeInterval) {
            eInkElapsed += elapsed
            guard eInkElapsed >= eInkPageInterval else { return }
            eInkElapsed = 0
            eInkPageInterval = secondsPerScreen
            let maximum = scrollLimits(for: view).maximum
            guard view.contentOffset.y < maximum - 0.5 else {
                guard !didReachEnd else { return }
                didReachEnd = true
                finishChapter(in: view)
                return
            }
            didReachEnd = false
            let target = adjacentPageOffset(1, in: view)
            view.setContentOffset(CGPoint(x: 0, y: target), animated: false)
        }

        @objc private func step(_ link: CADisplayLink) {
            guard isAutoReading, !isAutoReadPaused, !isUserDragging, !hasPendingScroll, !pageTransition.state.isBusy,
                  let view = textView, view.window != nil, view.bounds.width > 0, view.bounds.height > 0 else {
                lastTimestamp = link.timestamp
                return
            }
            guard lastTimestamp > 0 else {
                lastTimestamp = link.timestamp
                return
            }
            let elapsed = link.timestamp - lastTimestamp
            lastTimestamp = link.timestamp
            if parent.isEInkMode {
                advanceEInkAutoRead(in: view, elapsed: elapsed)
                return
            }
            if parent.pageAnimation != 3 {
                advancePagedAutoRead(in: view, elapsed: elapsed)
                return
            }
            let maximum = scrollLimits(for: view).maximum
            let next = view.contentOffset.y
                + readingViewportHeight(for: view) / CGFloat(secondsPerScreen) * CGFloat(elapsed)
            if next >= maximum - 0.5 {
                view.setContentOffset(CGPoint(x: 0, y: maximum), animated: false)
                guard !didReachEnd else { return }
                didReachEnd = true
                parent.onReachedEnd(contentCharacter(at: view.contentOffset, in: view))
            } else {
                didReachEnd = false
                view.setContentOffset(CGPoint(x: 0, y: next), animated: false)
            }
        }
    }
}


enum ReaderTapZones {
    static func index(x: CGFloat, y: CGFloat, size: CGSize, x1: Double, x2: Double, y1: Double, y2: Double) -> Int {
        let x = Double(x / max(size.width, 1)), y = Double(y / max(size.height, 1))
        let column = x < x1 ? 0 : (x < x2 ? 1 : 2)
        let row = y < y1 ? 0 : (y < y2 ? 1 : 2)
        return row * 3 + column
    }
}
