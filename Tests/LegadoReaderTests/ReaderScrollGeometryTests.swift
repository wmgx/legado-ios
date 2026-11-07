import ImageIO
import SwiftUI
import UIKit
import XCTest
@testable import Legado

private final class BackgroundPhotoProvider: NSItemProvider, @unchecked Sendable {
    let photoData: Data?
    let photoError: (any Error)?

    init(data: Data?, error: (any Error)? = nil) {
        photoData = data
        photoError = error
        super.init()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var registeredTypeIdentifiers: [String] { ["public.png"] }

    override func loadDataRepresentation(
        forTypeIdentifier typeIdentifier: String,
        completionHandler: @escaping @Sendable (Data?, (any Error)?) -> Void
    ) -> Progress {
        DispatchQueue.global(qos: .userInitiated).async { [photoData, photoError] in
            dispatchPrecondition(condition: .notOnQueue(.main))
            completionHandler(photoData, photoError)
        }
        return Progress(totalUnitCount: 1)
    }
}

@MainActor
final class ReadingPhotoPickerTests: XCTestCase {
    func testPhotoDataReturnedOnBackgroundQueueReachesMainActor() async throws {
        let expected = Data("photo-provider-data".utf8)
        let provider = BackgroundPhotoProvider(data: expected)
        let received = expectation(description: "Photo data delivered on main actor")
        let coordinator = ReadingPhotoPickerController.Coordinator { result in
            XCTAssertTrue(Thread.isMainThread)
            XCTAssertEqual(try? result?.get(), expected)
            received.fulfill()
        }

        coordinator.loadImage(from: provider)
        await fulfillment(of: [received], timeout: 5)
        withExtendedLifetime(coordinator) {}
    }

    func testPhotoProviderFailureOnBackgroundQueueReachesMainActor() async throws {
        let errors: [(any Error)?] = [CocoaError(.fileReadNoPermission), nil]
        for error in errors {
            let provider = BackgroundPhotoProvider(data: nil, error: error)
            let received = expectation(description: "Photo error delivered on main actor")
            let coordinator = ReadingPhotoPickerController.Coordinator { result in
                XCTAssertTrue(Thread.isMainThread)
                guard case .failure(let failure)? = result else {
                    XCTFail("Expected an import error")
                    received.fulfill()
                    return
                }
                XCTAssertEqual((failure as NSError).domain, NSCocoaErrorDomain)
                XCTAssertEqual((failure as NSError).code, (error as NSError?)?.code ?? NSFileReadCorruptFileError)
                received.fulfill()
            }

            coordinator.loadImage(from: provider)
            await fulfillment(of: [received], timeout: 5)
            withExtendedLifetime(coordinator) {}
        }
    }
}

@MainActor
final class ReaderBackgroundStoreTests: XCTestCase {
    func testLargeBackgroundIsDownsampledOnImportAndLegacyReload() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = directory.appendingPathComponent("background.jpg")
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let data = UIGraphicsImageRenderer(size: CGSize(width: 4096, height: 3072), format: format).jpegData(withCompressionQuality: 0.9) { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 4096, height: 3072))
        }

        for _ in 0..<3 {
            let imported = try ReaderBackgroundStore.save(data, to: target)
            XCTAssertEqual(imported.size.width, CGFloat(ReaderBackgroundStore.maximumPixelSize))
            XCTAssertEqual(imported.size.height / imported.size.width, 0.75, accuracy: 0.001)
            let restored = try XCTUnwrap(ReaderBackgroundStore.load(from: target))
            XCTAssertEqual(restored.size, imported.size)
        }
        try data.write(to: target)
        let legacy = try XCTUnwrap(ReaderBackgroundStore.load(from: target))
        XCTAssertEqual(legacy.size.width, CGFloat(ReaderBackgroundStore.maximumPixelSize))
    }

    func testCorruptReplacementPreservesExistingBackground() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = directory.appendingPathComponent("background.jpg")
        let image = UIGraphicsImageRenderer(size: CGSize(width: 40, height: 60)).image { context in
            UIColor.blue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 40, height: 60))
        }
        _ = try ReaderBackgroundStore.save(try XCTUnwrap(image.pngData()), to: target)
        let saved = try Data(contentsOf: target)

        XCTAssertThrowsError(try ReaderBackgroundStore.save(Data("not an image".utf8), to: target))
        XCTAssertEqual(try Data(contentsOf: target), saved)
        XCTAssertNotNil(ReaderBackgroundStore.load(from: target))
    }

    func testBackgroundPreservesPhotoOrientation() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let image = UIGraphicsImageRenderer(size: CGSize(width: 120, height: 60)).image { context in
            UIColor.green.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 120, height: 60))
        }
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(image.cgImage), [kCGImagePropertyOrientation: 6] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))

        let saved = try ReaderBackgroundStore.save(data as Data, to: directory.appendingPathComponent("background.jpg"))
        XCTAssertEqual(saved.imageOrientation, .up)
        XCTAssertEqual(saved.size.height / saved.size.width, 2, accuracy: 0.001)
    }
}

@MainActor
final class ReaderBookmarkPersistenceTests: XCTestCase {
    func testBookmarkSurvivesNewActivityAndReaderInstances() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = FileReadingActivityRepository(
            bookmarksURL: directory.appendingPathComponent("bookmarks.json"),
            recordsURL: directory.appendingPathComponent("records.json")
        )
        let book = Book(bookUrl: "demo://saved-bookmark", name: "书", author: "作者")
        let chapters = [BookChapter(url: "demo://chapter", title: "第一章", bookUrl: book.bookUrl, index: 0)]
        let original = ReadingActivityModel(repository: repository, deviceID: "test")
        await original.load()
        await original.addBookmark(book: book, chapter: chapters[0], position: 40, content: String(repeating: "正文", count: 100))
        XCTAssertNil(original.errorMessage)

        let restored = ReadingActivityModel(repository: repository, deviceID: "test")
        await restored.load()
        let reader = ReaderViewModel(demoBook: book, chapters: chapters, initialIndex: 0, content: "正文")
        XCTAssertEqual(reader.bookmarks(at: 40, in: restored.bookmarks).count, 1)
        XCTAssertTrue(reader.bookmarks(at: 80, in: restored.bookmarks).isEmpty)
        await restored.removeBookmark(try XCTUnwrap(restored.bookmarks.first))
        XCTAssertTrue(reader.bookmarks(at: 40, in: restored.bookmarks).isEmpty)
    }
}

@MainActor
final class ReaderScrollGeometryTests: XCTestCase {
    func testChapterEndJumpWaitsForViewportAndHandlesTrailingNewlines() async {
        let coordinator = configuration(pageAnimation: 0).makeCoordinator()
        let container = NSTextContainer(size: CGSize(width: 280, height: CGFloat.greatestFiniteMagnitude))
        let manager = NSLayoutManager()
        let storage = NSTextStorage(string: String(repeating: "上一章的正文，返回时应从最后一屏继续阅读。\n", count: 80) + "\n\n",
                                   attributes: [.font: UIFont.systemFont(ofSize: 20)])
        storage.addLayoutManager(manager)
        manager.addTextContainer(container)
        let view = UITextView(frame: .zero, textContainer: container)
        view.contentInsetAdjustmentBehavior = .never
        view.textContainerInset = UIEdgeInsets.zero
        coordinator.installDisplayLink(for: view)
        defer { coordinator.invalidate() }

        coordinator.scroll(to: Int.max, in: view)
        let scheduled = expectation(description: "Initial scroll attempted before viewport exists")
        DispatchQueue.main.async { scheduled.fulfill() }
        await fulfillment(of: [scheduled], timeout: 2)
        XCTAssertTrue(coordinator.hasPendingScroll)

        view.frame = CGRect(x: 0, y: 0, width: 280, height: 317)
        view.layoutIfNeeded()
        XCTAssertTrue(coordinator.applyPendingScroll(in: view))
        let lastOffset = view.contentSize.height - view.bounds.height
        XCTAssertGreaterThan(lastOffset, 0)
        XCTAssertEqual(view.contentOffset.y, lastOffset, accuracy: 0.5)
        XCTAssertFalse(coordinator.hasPendingScroll)

        coordinator.scroll(to: 0, in: view)
        let returned = expectation(description: "Normal chapter-start navigation still works")
        DispatchQueue.main.async { returned.fulfill() }
        await fulfillment(of: [returned], timeout: 2)
        XCTAssertEqual(view.contentOffset.y, 0, accuracy: 0.5)
    }

    func testWholeLinePageBoundariesCoverEveryGlyphAfterReflow() {
        for height in [CGFloat(317), 619.3, 803.5] {
            for size in [20.0, 28.0, 34.0] {
                let reader = configuration(fontSize: size, pageAnimation: 0)
                let container = NSTextContainer(size: CGSize(width: 280, height: CGFloat.greatestFiniteMagnitude))
                let manager = NSLayoutManager()
                let text = String(repeating: "他说：“他们说的没错……打仗打的就是国力。”🌙\n\n韩信笑着说道。\n", count: 50) + "\n\n"
                let storage = NSTextStorage(string: text, attributes: ReaderTypography(configuration: reader).bodyAttributes)
                storage.addLayoutManager(manager)
                manager.addTextContainer(container)
                let view = UITextView(frame: CGRect(x: 0, y: 0, width: 280, height: height), textContainer: container)
                view.textContainerInset = UIEdgeInsets.zero
                let pages = ReaderTextPagination.pages(in: view)
                XCTAssertGreaterThan(pages.count, 2)
                var nextGlyph = 0
                for page in pages {
                    XCTAssertEqual(page.glyphRange.location, nextGlyph)
                    XCTAssertGreaterThan(page.glyphRange.length, 0)
                    XCTAssertLessThanOrEqual(page.visibleHeight, height)
                    nextGlyph = NSMaxRange(page.glyphRange)
                }
                XCTAssertEqual(nextGlyph, manager.numberOfGlyphs)
                manager.enumerateLineFragments(forGlyphRange: NSRange(location: 0, length: manager.numberOfGlyphs)) { _, _, _, range, _ in
                    let characters = manager.characterRange(forGlyphRange: range, actualGlyphRange: nil)
                    if (text as NSString).substring(with: characters).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return }
                    let page = pages[ReaderTextPagination.index(containing: range.location, pages: pages)]
                    XCTAssertLessThanOrEqual(NSMaxRange(range), NSMaxRange(page.glyphRange), "A line must belong to exactly one page")
                    let ink = manager.boundingRect(forGlyphRange: range, in: container)
                    XCTAssertGreaterThanOrEqual(ink.minY, page.offset - 0.01)
                    XCTAssertLessThanOrEqual(ink.maxY, page.offset + page.visibleHeight + 0.01)
                    XCTAssertLessThanOrEqual(ink.maxY, page.offset + height + 0.01)
                }
            }
        }
    }

    func testRestoringInsideALineAndChangingChapterUseTheNewPageBoundaries() async {
        func trace(_ stage: String) {
            FileHandle.standardError.write(Data("Pagination restoration: \(stage)\n".utf8))
        }
        trace("create view")
        let coordinator = configuration(pageAnimation: 0).makeCoordinator()
        let view: ReaderLayoutTextView
        if #available(iOS 16.0, *) { view = ReaderLayoutTextView(usingTextLayoutManager: false) }
        else { view = ReaderLayoutTextView(frame: .zero) }
        view.paginates = true
        view.contentInsetAdjustmentBehavior = .never
        view.textContainerInset = UIEdgeInsets.zero
        view.frame = CGRect(x: 0, y: 0, width: 280, height: 317)
        view.attributedText = NSAttributedString(string: String(repeating: "恢复阅读后每一行都应完整，不能露出下一页的半行文字。\n", count: 70),
                                                 attributes: [.font: UIFont.systemFont(ofSize: 28)])
        view.invalidatePagination()
        view.layoutIfNeeded()
        trace("initial layout complete")
        coordinator.installDisplayLink(for: view)
        defer { coordinator.invalidate() }
        guard view.pages.count > 2 else { XCTFail("Expected a multipage layout"); return }
        let page = view.pages[min(2, view.pages.count - 1)]
        let characters = view.layoutManager.characterRange(forGlyphRange: page.glyphRange, actualGlyphRange: nil)
        let position = characters.location + 2
        @MainActor func restore(_ position: Int) async {
            coordinator.scroll(to: position, in: view)
            let applied = expectation(description: "Restored with complete layout")
            DispatchQueue.main.async { applied.fulfill() }
            await fulfillment(of: [applied], timeout: 2)
        }
        await restore(position)
        trace("initial restoration complete")
        XCTAssertEqual(view.contentOffset.y, page.offset, accuracy: 0.5)
        view.frame.size.height = 389.5
        view.invalidatePagination()
        view.layoutIfNeeded()
        trace("resized layout complete")
        await restore(position)
        trace("resized restoration complete")
        let glyph = view.layoutManager.glyphIndexForCharacter(at: position)
        let rebuilt = view.pages[ReaderTextPagination.index(containing: glyph, pages: view.pages)]
        XCTAssertEqual(view.contentOffset.y, rebuilt.offset, accuracy: 0.5)
        let mask = view.layer.mask as? CAShapeLayer
        XCTAssertEqual(mask?.path?.boundingBoxOfPath.height ?? -1, rebuilt.visibleHeight, accuracy: 0.5)

        view.invalidatePagination()
        view.attributedText = NSAttributedString(string: String(repeating: "上一章的最后一页也必须使用重新计算的边界。\n", count: 40) + "\n\n",
                                                 attributes: [.font: UIFont.systemFont(ofSize: 23)])
        view.invalidatePagination()
        view.layoutIfNeeded()
        trace("replacement layout complete")
        await restore(Int.max)
        trace("chapter end restoration complete")
        XCTAssertEqual(view.contentOffset.y, view.pages.last?.offset ?? -1, accuracy: 0.5)
    }

    func testPrependingAndRecyclingStayWithinOnePhysicalPixel() async throws {
        let chapters = (4...6).map { chapter($0) }
        let fixture = host(chapters: chapters, active: 5)
        defer { fixture.coordinator.displayLink?.invalidate(); fixture.window.isHidden = true }
        let coordinator = fixture.coordinator, view = fixture.view
        let layout = view.collectionViewLayout as! ReaderContinuousLayout
        let row = try XCTUnwrap(coordinator.blocks.firstIndex { $0.chapter.chapter.id == 5 })
        let id = coordinator.blocks[row].id
        view.setContentOffset(CGPoint(x: 0, y: layout.frames[row].minY + 71.25), animated: false)
        let screenY = layout.frames[row].minY - view.contentOffset.y
        let chapterLayout = coordinator.blocks[row].chapter

        coordinator.parent = surface(chapters: [chapter(2), chapter(3)] + chapters, active: 5)
        coordinator.update(view)
        let insertedRow = try XCTUnwrap(coordinator.blocks.firstIndex { $0.id == id })
        XCTAssertEqual(layout.frames[insertedRow].minY - view.contentOffset.y, screenY, accuracy: 1 / fixture.window.screen.scale)
        XCTAssertTrue(coordinator.blocks[insertedRow].chapter === chapterLayout)

        coordinator.parent = surface(chapters: [chapter(5), chapter(6), chapter(7)], active: 5)
        coordinator.update(view)
        let recycledRow = try XCTUnwrap(coordinator.blocks.firstIndex { $0.id == id })
        XCTAssertEqual(layout.frames[recycledRow].minY - view.contentOffset.y, screenY, accuracy: 1 / fixture.window.screen.scale)
        XCTAssertTrue(coordinator.blocks[recycledRow].chapter === chapterLayout)
    }

    func testAppendingAndNaturalChapterChangesDoNotRebuildVisibleText() async throws {
        let chapters = (0...2).map { chapter($0) }
        let fixture = host(chapters: chapters, active: 0)
        defer { fixture.coordinator.displayLink?.invalidate(); fixture.window.isHidden = true }
        let coordinator = fixture.coordinator, view = fixture.view
        let original = try XCTUnwrap(coordinator.blocks.first?.chapter)
        view.setContentOffset(CGPoint(x: 0, y: 123.75), animated: false)
        let offset = view.contentOffset
        coordinator.parent = surface(chapters: chapters + [chapter(3), chapter(4)], active: 1)
        coordinator.update(view)
        XCTAssertEqual(view.contentOffset.y, offset.y, accuracy: 0.01)
        XCTAssertTrue(coordinator.blocks[0].chapter === original)
        XCTAssertEqual(Set(coordinator.blocks.map { $0.chapter.chapter.id }), Set(0...4))
    }

    func testReflowKeepsTheSameTextLineAtTheSameScreenPosition() async throws {
        let fixture = host(chapters: [chapter(0), chapter(1)], active: 0)
        defer { fixture.coordinator.displayLink?.invalidate(); fixture.window.isHidden = true }
        let coordinator = fixture.coordinator, view = fixture.view
        let old = try XCTUnwrap(coordinator.blocks.first?.chapter)
        let glyph = old.manager.glyphIndexForCharacter(at: old.bodyStart + 200)
        let lineY = old.manager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil).minY
        let startOfLine = old.manager.characterIndexForGlyph(at: old.manager.glyphIndex(
            for: CGPoint(x: 0, y: lineY + 0.5), in: old.container))
        let layout = view.collectionViewLayout as! ReaderContinuousLayout
        let chapterY = layout.frames[0].minY
        view.setContentOffset(CGPoint(x: 0, y: chapterY + lineY + 3.25), animated: false)
        let previousScreenY = chapterY + lineY - view.contentOffset.y
        coordinator.parent = surface(chapters: [chapter(0), chapter(1)], active: 0, fontSize: 25)
        coordinator.update(view)
        let new = try XCTUnwrap(coordinator.blocks.first?.chapter)
        let newGlyph = new.manager.glyphIndexForCharacter(at: startOfLine)
        let newLineY = new.manager.lineFragmentRect(forGlyphAt: newGlyph, effectiveRange: nil).minY
        XCTAssertEqual(layout.frames[0].minY + newLineY - view.contentOffset.y, previousScreenY, accuracy: 1 / fixture.window.screen.scale)
    }

    func testChunksCoverAllGlyphsAndDoNotRetainTheirChapter() async {
        weak var released: ReaderScrollChapterLayout?
        autoreleasepool {
            let layout = ReaderScrollChapterLayout(chapter: chapter(0), configuration: configuration(), width: 390)
            released = layout
            XCTAssertGreaterThan(layout.blocks.count, 2)
            var nextGlyph = 0
            for block in layout.blocks {
                XCTAssertEqual(block.glyphRange.location, nextGlyph)
                XCTAssertGreaterThan(block.height, 0)
                nextGlyph = NSMaxRange(block.glyphRange)
            }
            XCTAssertEqual(nextGlyph, layout.manager.numberOfGlyphs)
            XCTAssertTrue(layout.storage.string.contains("👨‍👩‍👧‍👦"))
        }
        XCTAssertNil(released, "Recycled TextKit chapter layouts must be released")
    }

    func testShortLastChapterCanReachTheTopWithoutChangingTheRequestedChapter() async throws {
        let short = ReaderScrollChapter(id: 8, title: "短章", content: "仅一行正文")
        let fixture = host(chapters: [chapter(7), short], active: 8)
        defer { fixture.coordinator.displayLink?.invalidate(); fixture.window.isHidden = true }
        let layout = fixture.view.collectionViewLayout as! ReaderContinuousLayout
        let row = try XCTUnwrap(fixture.coordinator.blocks.firstIndex { $0.chapter.chapter.id == 8 })
        XCTAssertEqual(fixture.view.contentOffset.y, layout.frames[row].minY, accuracy: 1 / fixture.window.screen.scale)
    }

    func testRepeatedShortChapterPrependingDoesNotAccumulateOffsetDrift() async throws {
        func short(_ index: Int) -> ReaderScrollChapter {
            .init(id: index, title: "第\(index + 1)章 · 连续阅读", content: "短章正文，继续向下可以自然读到下一章。")
        }
        let fixture = host(chapters: (20...22).map(short), active: 20)
        defer { fixture.coordinator.displayLink?.invalidate(); fixture.window.isHidden = true }
        for first in stride(from: 19, through: 0, by: -1) {
            fixture.coordinator.parent = surface(chapters: (first...22).map(short), active: 20)
            fixture.coordinator.update(fixture.view)
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let layout = fixture.view.collectionViewLayout as! ReaderContinuousLayout
        let row = try XCTUnwrap(fixture.coordinator.blocks.firstIndex { $0.chapter.chapter.id == 20 })
        XCTAssertEqual(fixture.view.contentOffset.y, layout.frames[row].minY,
                       accuracy: 1 / fixture.window.screen.scale)
        XCTAssertTrue(fixture.view.accessibilityValue?.contains("chapter=20 ") == true,
                      fixture.view.accessibilityValue ?? "Missing viewport report")
    }

    func testFractionalPixelBoundariesBelongToTheFollowingRow() {
        let layout = ReaderContinuousLayout()
        let frames = (0..<100).map { CGRect(x: 0, y: CGFloat($0 * 5) / 3, width: 390, height: 5.0 / 3) }
        layout.install(frames: frames, size: CGSize(width: 390, height: 500.0 / 3), correction: 0)
        for index in frames.indices {
            XCTAssertEqual(layout.row(at: frames[index].minY), index)
        }
    }

    func testPrependingPreservesTheChapterBelowTopPadding() async throws {
        func short(_ index: Int) -> ReaderScrollChapter {
            .init(id: index, title: "短章\(index)", content: "短章正文")
        }
        let fixture = host(chapters: [short(20)], active: 20)
        defer { fixture.coordinator.displayLink?.invalidate(); fixture.window.isHidden = true }
        // A short initial chapter can settle at offset zero with its heading
        // still below the reading area's top padding.
        fixture.view.setContentOffset(.zero, animated: false)
        fixture.coordinator.parent = surface(chapters: (19...21).map(short), active: 20)
        fixture.coordinator.update(fixture.view)
        try await Task.sleep(nanoseconds: 10_000_000)
        let layout = fixture.view.collectionViewLayout as! ReaderContinuousLayout
        let row = try XCTUnwrap(fixture.coordinator.blocks.firstIndex { $0.chapter.chapter.id == 20 })
        XCTAssertEqual(layout.frames[row].minY - fixture.view.contentOffset.y, 16,
                       accuracy: 1 / fixture.window.screen.scale)
        XCTAssertTrue(fixture.view.accessibilityValue?.contains("chapter=20 ") == true,
                      fixture.view.accessibilityValue ?? "Missing viewport report")
    }

    private func chapter(_ index: Int) -> ReaderScrollChapter {
        .init(id: index, title: "第\(index)章", content: String(repeating: "正文包含中文、英文 words 与家庭表情👨‍👩‍👧‍👦，用于验证连续阅读的排版和位置。\n", count: 100))
    }

    private func host(chapters: [ReaderScrollChapter], active: Int) -> (window: UIWindow, view: ReaderScrollCollectionView, coordinator: ReaderScrollView.Coordinator) {
        let parent = surface(chapters: chapters, active: active)
        let coordinator = parent.makeCoordinator()
        let view = coordinator.makeView()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let controller = UIViewController()
        controller.view.addSubview(view)
        view.frame = window.bounds
        window.rootViewController = controller
        window.makeKeyAndVisible()
        coordinator.update(view)
        view.layoutIfNeeded()
        return (window, view, coordinator)
    }

    private func surface(chapters: [ReaderScrollChapter], active: Int, fontSize: Double = 20) -> ReaderScrollView {
        .init(configuration: configuration(fontSize: fontSize), chapters: chapters,
              resetID: 0, activeIndex: active, loadingAhead: false, loadingBehind: false,
              onNeedChapters: { _ in }, onPositionChanged: { _, _ in },
              onRetainChapters: { _ in })
    }

    private func configuration(fontSize: Double = 20, pageAnimation: Int = 3) -> ReaderTextView {
        .init(text: "", title: "", previousTitle: nil, previousText: "", isPreviousReady: false,
              continuationTitle: nil, continuationText: "", isContinuationReady: false, isVolume: false,
              fontSize: fontSize, fontPath: "", letterSpacing: 0, lineSpacing: 8, paragraphSpacing: 12,
              paragraphIndent: "　　", paddingLeft: 20, paddingRight: 20, paddingTop: 16, paddingBottom: 16,
              headerInset: 0, footerInset: 0, fontWeight: 0, titleMode: 0, titleSize: 4,
              titleTopSpacing: 16, titleBottomSpacing: 24, underlineMode: 0, isSelectable: false,
              fullJustify: true, pageAnimation: pageAnimation, isEInkMode: false, clickActions: Array(repeating: 0, count: 9),
              backgroundColor: .white, foregroundColor: .black, requestedPosition: 0, jumpPosition: nil,
              renderRevision: 0, readerPosition: .constant(0), pageRanges: .constant([]),
              currentPage: .constant(1), totalPages: .constant(1), isAutoReading: false,
              isAutoReadPaused: false, isLoadingNextChapter: false, secondsPerScreen: 10,
              onReachedEnd: { _ in }, onReachedStart: { _ in }, onEnteredPrevious: { _ in },
              onEnteredContinuation: { _ in }, onDeferredRender: {}, onCancelNextLoading: {},
              onPageChanged: {}, onTapAction: { _ in })
    }
}
