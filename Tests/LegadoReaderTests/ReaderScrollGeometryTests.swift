import ImageIO
import SwiftUI
import UIKit
import XCTest
@testable import Legado

@MainActor private final class LiveSliderFixtureState: ObservableObject {
    @Published var value = 0.0
    @Published var active: ReadingSliderPreview?
}

private struct LiveSliderFixture: View {
    @ObservedObject var state: LiveSliderFixtureState

    var body: some View {
        // AppStorage's projected binding can capture a particular render's
        // value. The floating row must use live events, not this old getter.
        let snapshot = state.value
        let value = Binding(get: { snapshot }, set: { state.value = $0 })
        VStack {
            ReadingPreviewSlider(title: "右边距", id: "正文右边距", value: value, range: 0...100,
                                 step: 1, format: { "\(Int($0))" }, activeSlider: $state.active)
            if let active = state.active {
                // Render the same row as the floating overlay directly. Its
                // UIKit view need not remain in the hierarchy when SwiftUI
                // renders a noninteractive overlay.
                ReadingSliderRow(preview: active)
            }
        }
        .padding()
    }
}

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
    func testPageRendererKeepsBlankRegionsOpaqueWithoutRenderingTheWindow() throws {
        let host = UIView(frame: CGRect(x: 0, y: 0, width: 300, height: 200))
        host.backgroundColor = .green
        let page = ReaderLayoutTextView()
        page.frame = CGRect(x: 24, y: 70, width: 120, height: 100)
        page.paginates = true
        page.attributedText = NSAttributedString(string: "旧页文字", attributes: [.font: UIFont.systemFont(ofSize: 20)])
        host.addSubview(page)
        page.layoutIfNeeded()
        XCTAssertNil(page.window)
        let outgoing = try XCTUnwrap(ReaderPageRenderer.render(page, color: .red))
        let oldImage = try XCTUnwrap(outgoing.image)
        let oldData = oldImage.pngData()
        outgoing.frame = page.frame
        host.addSubview(outgoing)
        page.attributedText = NSAttributedString(string: "新页文字", attributes: [.font: UIFont.systemFont(ofSize: 20)])
        page.invalidatePagination()
        let incoming = try XCTUnwrap(ReaderPageRenderer.render(page, color: .blue))
        let newImage = try XCTUnwrap(incoming.image)
        func blankPixel(_ image: UIImage) throws -> [UInt8] {
            let source = try XCTUnwrap(image.cgImage)
            let crop = try XCTUnwrap(source.cropping(to: CGRect(x: 110 * image.scale, y: 75 * image.scale, width: 1, height: 1)))
            var pixel = [UInt8](repeating: 0, count: 4)
            return try pixel.withUnsafeMutableBytes { bytes in
                let context = try XCTUnwrap(CGContext(data: bytes.baseAddress, width: 1, height: 1,
                    bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
                context.draw(crop, in: CGRect(x: 0, y: 0, width: 1, height: 1))
                return Array(bytes)
            }
        }
        let oldPixel = try blankPixel(oldImage), newPixel = try blankPixel(newImage)
        XCTAssertGreaterThan(oldPixel[0], 240)
        XCTAssertLessThan(oldPixel[2], 10)
        XCTAssertGreaterThan(newPixel[2], 240)
        XCTAssertLessThan(newPixel[0], 10)
        XCTAssertEqual(oldPixel[3], 255)
        XCTAssertEqual(newPixel[3], 255)
        XCTAssertFalse(outgoing.layer.isHidden)
        XCTAssertEqual(oldImage.pngData(), oldData)
        let background = UIGraphicsImageRenderer(size: CGSize(width: 240, height: 100)).image { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 120, height: 100))
            UIColor.blue.setFill()
            context.fill(CGRect(x: 120, y: 0, width: 120, height: 100))
        }
        let illustrated = try XCTUnwrap(ReaderPageRenderer.render(page, color: .white, image: background,
            imageFrame: CGRect(x: 0, y: 0, width: 240, height: 100))?.image)
        let backgroundPixel = try blankPixel(illustrated)
        XCTAssertGreaterThan(backgroundPixel[0], 240)
        XCTAssertLessThan(backgroundPixel[2], 10)
    }

    func testWithinChapterTurnsCoverTheBlankAreaBelowFinalPunctuation() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
        let controller = UIViewController()
        controller.view.backgroundColor = .white
        window.rootViewController = controller
        window.makeKeyAndVisible()
        let reader = configuration(pageAnimation: 0)
        let coordinator = reader.makeCoordinator()
        let view = ReaderLayoutTextView()
        view.frame = CGRect(x: 24, y: 70, width: 280, height: 317)
        view.paginates = true
        view.backgroundColor = .white
        view.contentInsetAdjustmentBehavior = .never
        view.attributedText = NSAttributedString(string: String(repeating: "末行标点。”\n", count: 80),
            attributes: ReaderTypography(configuration: reader).bodyAttributes)
        controller.view.addSubview(view)
        view.delegate = coordinator
        coordinator.installDisplayLink(for: view)
        defer { coordinator.invalidate(); window.isHidden = true; previous?.makeKeyAndVisible() }
        view.layoutIfNeeded()
        let first = try XCTUnwrap(view.pages.first)
        let characters = view.layoutManager.characterRange(forGlyphRange: first.glyphRange, actualGlyphRange: nil)
        XCTAssertTrue((view.text as NSString).substring(with: characters).trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("。”"))
        XCTAssertLessThan(first.visibleHeight, view.bounds.height - view.textContainerInset.top - view.textContainerInset.bottom)

        for (direction, index) in [(UISwipeGestureRecognizer.Direction.left, 1), (.right, 0)] {
            let swipe = UISwipeGestureRecognizer()
            swipe.direction = direction
            coordinator.perform(NSSelectorFromString("swiped:"), with: swipe)
            XCTAssertEqual(view.contentOffset.y, view.pages[index].offset, accuracy: 0.5)
            let cover = try XCTUnwrap(controller.view.subviews.last { $0 !== view })
            XCTAssertEqual(cover.frame, view.frame)
            XCTAssertNil(cover.layer.mask)
            let snapshots = cover.subviews.compactMap { $0 as? UIImageView }
            XCTAssertEqual(snapshots.count, 2, "Both pages must use full, opaque snapshots during a turn")
            for snapshot in snapshots {
                XCTAssertTrue(snapshot.isOpaque)
                XCTAssertNil(snapshot.layer.mask)
                XCTAssertEqual(snapshot.image?.size, view.bounds.size)
            }
            try await Task.sleep(nanoseconds: 450_000_000)
            XCTAssertNil(cover.superview)
        }
    }

    func testRepeatedChapterButtonChangesInSwiftUIKeepTheReaderResponsive() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
        func reader(_ chapter: Int, revision: Int, preview: String = "") -> ReaderTextView {
            var value = configuration(pageAnimation: 0,
                text: String(repeating: "第\(chapter)章正文，切章以后仍然可以正常翻页。\n", count: 80),
                continuationText: preview)
            value.chapterIndex = chapter
            value.chapterRevision = revision
            value.usesTwoPages = true
            return value
        }
        let controller = UIHostingController(rootView: reader(0, revision: 0))
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible() }
        func textView(in view: UIView) -> ReaderLayoutTextView? {
            (view as? ReaderLayoutTextView) ?? view.subviews.lazy.compactMap { textView(in: $0) }.first
        }
        func hasCover(_ view: UIView) -> Bool {
            view.superview?.subviews.contains { $0 !== view && $0.subviews.contains { $0 is UIImageView } } == true
        }
        try await Task.sleep(nanoseconds: 100_000_000)
        for (revision, chapter) in [1, 0, 1, 0].enumerated() {
            let next = reader(chapter, revision: revision + 1)
            controller.rootView = next
            for _ in 0..<40 {
                try await Task.sleep(nanoseconds: 50_000_000)
                controller.view.layoutIfNeeded()
                if let view = textView(in: controller.view), view.text == next.text,
                   (view.delegate as? ReaderTextView.Coordinator)?.pageTransition.state == .idle { break }
            }
            let view = try XCTUnwrap(textView(in: controller.view))
            XCTAssertEqual(view.text, next.text)
            XCTAssertFalse(hasCover(view), "Completed chapter transitions must remove their outgoing page")
            XCTAssertEqual(view.contentOffset.y, 0, accuracy: 0.5)
            let coordinator = try XCTUnwrap(view.delegate as? ReaderTextView.Coordinator)
            XCTAssertEqual(coordinator.pageTransition.state, .idle)
            let swipe = UISwipeGestureRecognizer()
            swipe.direction = .left
            coordinator.perform(NSSelectorFromString("swiped:"), with: swipe)
            XCTAssertGreaterThan(view.contentOffset.y, 0, "A chapter button must not leave page turning locked")
            if revision == 0 {
                let animation = try XCTUnwrap(coordinator.pageTransition.animator)
                animation.pauseAnimation()
                XCTAssertEqual(coordinator.pageTransition.state, .animating)
                controller.rootView = reader(chapter, revision: revision + 1, preview: "下一章预加载完成。")
                try await Task.sleep(nanoseconds: 100_000_000)
                XCTAssertEqual(coordinator.pageTransition.state, .animating, "Preloading must not remove an active turn")
                animation.continueAnimation(withTimingParameters: nil, durationFactor: 1)
            }
            try await Task.sleep(nanoseconds: 600_000_000)
        }
    }

    func testPageTransitionCancelsFailedRenderingAndIgnoresOldCompletions() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
        let host = UIView(frame: CGRect(x: 0, y: 0, width: 280, height: 317))
        let controller = UIViewController()
        controller.view = host
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true; previous?.makeKeyAndVisible() }
        let view = ReaderLayoutTextView()
        view.frame = host.bounds
        view.paginates = true
        view.attributedText = NSAttributedString(string: "文字页。", attributes: [.font: UIFont.systemFont(ofSize: 20)])
        host.addSubview(view)
        view.layoutIfNeeded()
        let transition = ReaderPageTransition()
        func render() -> UIImageView? { ReaderPageRenderer.render(view, color: .white) }
        transition.prepare(1, sourceKey: 1, in: view, render: render)
        XCTAssertEqual(transition.state, .waiting(contentKey: 1, offset: 0, direction: 1))
        transition.prepare(-1, sourceKey: 1, in: view) { XCTFail("Reversing a pending turn must reuse its outgoing page"); return nil }
        XCTAssertEqual(transition.state, .waiting(contentKey: 1, offset: 0, direction: -1))
        transition.finish(contentKey: 2, offset: 0, style: 0) { nil }
        XCTAssertEqual(transition.state, .idle)
        XCTAssertEqual(host.subviews.count, 1)

        view.usesTwoPages = true
        for direction in [1, -1] {
            transition.prepare(direction, sourceKey: 4, in: view, render: render)
            transition.finish(contentKey: 5, offset: 0, style: 2, render: render)
            let cover = try XCTUnwrap(host.subviews.last)
            let front = cover.subviews[3]
            let back = try XCTUnwrap(cover.subviews.last)
            XCTAssertEqual(front.bounds.width, view.bounds.width / 2)
            XCTAssertEqual(front.layer.position.x, view.bounds.width / 2)
            XCTAssertEqual(front.layer.anchorPoint.x, direction > 0 ? 0 : 1)
            XCTAssertEqual(back.layer.anchorPoint.x, direction > 0 ? 1 : 0)
            XCTAssertEqual(front.layer.transform.m11, -1, accuracy: 0.001)
            XCTAssertLessThan(cover.layer.sublayerTransform.m34, 0)
            let animation = try XCTUnwrap(transition.animator)
            animation.pauseAnimation()
            animation.fractionComplete = 0.5
            try await Task.sleep(nanoseconds: 50_000_000)
            let moving = try XCTUnwrap(front.layer.presentation())
            XCTAssertLessThan(abs(moving.transform.m11), 0.99, "The leaf must visibly rotate between its endpoints")
            let incoming = try XCTUnwrap(back.layer.presentation())
            XCTAssertLessThan(abs(incoming.transform.m11), 0.99, "The back of the leaf must animate too")
            let rotation = CATransform3DMakeRotation(direction > 0 ? -.pi / 2 : .pi / 2, 0, 1, 0)
            XCTAssertGreaterThan(moving.transform.m13 * rotation.m13, 0, "The front must turn toward the reader")
            XCTAssertLessThan(incoming.transform.m13 * rotation.m13, 0, "The back must follow the same leaf")
            XCTAssertEqual(moving.transform.m41, 0, accuracy: 0.001, "Both columns must not slide together")
            animation.continueAnimation(withTimingParameters: nil, durationFactor: 1)
            for _ in 0..<30 {
                if transition.state == .idle { break }
                try await Task.sleep(nanoseconds: 50_000_000)
            }
            XCTAssertEqual(transition.state, .idle)
            XCTAssertEqual(host.subviews.count, 1)
        }
        for style in [0, 1] {
            transition.prepare(1, sourceKey: 4, in: view, render: render)
            transition.finish(contentKey: 5, offset: 0, style: style, render: render)
            let cover = try XCTUnwrap(host.subviews.last)
            XCTAssertEqual(cover.subviews.count, 2)
            for page in cover.subviews {
                XCTAssertTrue(page is UIImageView)
                XCTAssertEqual(page.bounds.size, view.bounds.size)
                XCTAssertTrue(page.subviews.isEmpty)
            }
            let outgoing = try XCTUnwrap(cover.subviews.first { $0.transform.tx != 0 })
            XCTAssertEqual(outgoing.transform.tx, -view.bounds.width)
            transition.cancel()
        }
        view.usesTwoPages = false
        transition.prepare(1, sourceKey: 2, in: view, render: render)
        transition.finish(contentKey: 3, offset: 0, style: 2, render: render)
        XCTAssertEqual(transition.state, .animating)
        transition.cancel()
        transition.prepare(-1, sourceKey: 3, in: view, render: render)
        try await Task.sleep(nanoseconds: 450_000_000)
        XCTAssertEqual(transition.state, .waiting(contentKey: 3, offset: 0, direction: -1))
        transition.finish(contentKey: 4, offset: 0, style: 4, render: render)
        XCTAssertEqual(transition.state, .idle)
        XCTAssertEqual(host.subviews.count, 1)
    }

    func testFloatingSliderTracksLiveValuesEvenWhenItsBindingCapturedTheStartingValue() async throws {
        let state = LiveSliderFixtureState()
        let controller = UIHostingController(rootView: LiveSliderFixture(state: state))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousKeyWindow = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true; previousKeyWindow?.makeKeyAndVisible() }
        try await Task.sleep(nanoseconds: 100_000_000)
        controller.view.layoutIfNeeded()
        func sliders(in view: UIView) -> [UISlider] {
            (view as? UISlider).map { [$0] } ?? view.subviews.flatMap { sliders(in: $0) }
        }
        let original = try XCTUnwrap(sliders(in: controller.view).first)
        original.sendActions(for: .touchDown)
        for value in [Float(24), Float(67)] {
            original.value = value
            original.sendActions(for: .valueChanged)
            let updated = expectation(description: "Live preview rendered")
            DispatchQueue.main.async { updated.fulfill() }
            await fulfillment(of: [updated], timeout: 3)
            for _ in 0..<30 {
                controller.view.setNeedsLayout()
                controller.view.layoutIfNeeded()
                if sliders(in: controller.view).contains(where: { $0 !== original && abs($0.value - value) < 0.01 }) { break }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            XCTAssertEqual(state.value, Double(value), accuracy: 0.01)
            XCTAssertEqual(state.active?.displayValue ?? -1, Double(value), accuracy: 0.01)
            let floating = try XCTUnwrap(sliders(in: controller.view).first { $0 !== original })
            XCTAssertEqual(floating.value, value, accuracy: 0.01)
            XCTAssertEqual(floating.accessibilityValue, "\(Int(value))")
        }
        original.sendActions(for: .touchUpInside)
        XCTAssertNil(state.active)
    }

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
        let coordinator = configuration(pageAnimation: 0).makeCoordinator()
        let view = ReaderLayoutTextView()
        view.paginates = true
        view.contentInsetAdjustmentBehavior = .never
        view.textContainerInset = UIEdgeInsets.zero
        view.frame = CGRect(x: 0, y: 0, width: 280, height: 317)
        view.attributedText = NSAttributedString(string: String(repeating: "恢复阅读后每一行都应完整，不能露出下一页的半行文字。\n", count: 70),
                                                 attributes: [.font: UIFont.systemFont(ofSize: 28)])
        view.invalidatePagination()
        view.layoutIfNeeded()
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
        XCTAssertEqual(view.contentOffset.y, page.offset, accuracy: 0.5)
        view.frame.size.height = 389.5
        view.invalidatePagination()
        view.layoutIfNeeded()
        await restore(position)
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
        await restore(Int.max)
        XCTAssertEqual(view.contentOffset.y, view.pages.last?.offset ?? -1, accuracy: 0.5)
    }

    func testTwoPageSpreadsKeepConsecutiveTextAndRestoreAfterRotation() async throws {
        let reader = configuration(pageAnimation: 0)
        let coordinator = reader.makeCoordinator()
        let view = ReaderLayoutTextView()
        view.paginates = true
        view.usesTwoPages = true
        view.contentInsetAdjustmentBehavior = .never
        view.frame = CGRect(x: 0, y: 0, width: 1040, height: 600)
        view.attributedText = NSAttributedString(string: String(repeating: "双页应先读左页，再接右页；旋转以后仍从原来的文字继续。\n", count: 100),
                                                 attributes: ReaderTypography(configuration: reader).bodyAttributes)
        view.delegate = coordinator
        coordinator.installDisplayLink(for: view)
        defer { coordinator.invalidate() }
        view.layoutIfNeeded()
        let leaves = ReaderTextPagination.pages(in: view)
        XCTAssertEqual(view.pages.count, (leaves.count + 1) / 2)
        XCTAssertEqual(view.textContainer.size.width, (view.bounds.width - 24) / 2 - view.textContainerInset.left - view.textContainerInset.right, accuracy: 0.5)
        var nextGlyph = 0
        for (index, spread) in view.pages.enumerated() {
            XCTAssertEqual(spread.glyphRange.location, nextGlyph)
            XCTAssertEqual(spread.offset, leaves[index * 2].offset)
            nextGlyph = NSMaxRange(spread.glyphRange)
        }
        XCTAssertEqual(nextGlyph, view.layoutManager.numberOfGlyphs)
        let spread = view.pages[1]
        let swipe = UISwipeGestureRecognizer()
        swipe.direction = .left
        coordinator.perform(NSSelectorFromString("swiped:"), with: swipe)
        XCTAssertEqual(view.contentOffset.y, spread.offset, accuracy: 0.5)
        let right = try XCTUnwrap(view.subviews.compactMap { $0 as? ReaderLayoutTextView }.first)
        XCTAssertEqual(right.contentOffset.y, try XCTUnwrap(spread.secondOffset), accuracy: 0.5)
        XCTAssertEqual(right.frame.maxX, view.bounds.width, accuracy: 0.5)
        let rightIndex = ReaderTextPagination.index(at: right.contentOffset.y, pages: right.pages)
        XCTAssertEqual(right.pages[rightIndex].glyphRange, leaves[3].glyphRange)

        let position = view.layoutManager.characterIndexForGlyph(at: leaves[3].glyphRange.location) + 2
        view.usesTwoPages = false
        view.frame.size = CGSize(width: 760, height: 1000)
        view.layoutIfNeeded()
        coordinator.scroll(to: position, in: view)
        let restored = expectation(description: "Restored after rotating to a single page")
        DispatchQueue.main.async { restored.fulfill() }
        await fulfillment(of: [restored], timeout: 2)
        let glyph = view.layoutManager.glyphIndexForCharacter(at: position)
        let page = view.pages[ReaderTextPagination.index(containing: glyph, pages: view.pages)]
        XCTAssertEqual(view.contentOffset.y, page.offset, accuracy: 0.5)
        XCTAssertTrue(view.subviews.compactMap { $0 as? ReaderLayoutTextView }.isEmpty)

        view.usesTwoPages = true
        view.frame.size = CGSize(width: 1040, height: 600)
        view.attributedText = NSAttributedString(string: "章末仅一页。", attributes: ReaderTypography(configuration: reader).bodyAttributes)
        view.invalidatePagination()
        view.layoutIfNeeded()
        XCTAssertEqual(view.pages.count, 1)
        XCTAssertNil(view.pages[0].secondOffset)
        XCTAssertTrue(view.subviews.compactMap { $0 as? ReaderLayoutTextView }.first?.isHidden == true)
    }

    func testChapterEndUsesNextChapterOnTheRightAndContinuesAfterIt() async throws {
        var continuedAt: Int?
        var canContinue = true
        var returned = false
        let reader = configuration(pageAnimation: 0, reachedStart: { _, _ in returned = true },
                                   enteredContinuation: { continuedAt = $0; return canContinue })
        let coordinator = reader.makeCoordinator()
        let view = ReaderLayoutTextView()
        view.frame = CGRect(x: 0, y: 0, width: 1040, height: 600)
        view.paginates = true
        view.usesTwoPages = true
        let typography = ReaderTypography(configuration: reader)
        view.attributedText = NSAttributedString(string: "上一章末页。", attributes: typography.bodyAttributes)
        let heading = "下一章\n"
        let next = NSMutableAttributedString(string: heading, attributes: typography.headingAttributes)
        next.append(NSAttributedString(string: String(repeating: "接着阅读下一章，翻页之后不能重复右页已经展示过的内容。\n", count: 100),
                                       attributes: typography.bodyAttributes))
        view.continuationBodyStart = heading.utf16.count
        view.continuationText = next
        view.delegate = coordinator
        coordinator.installDisplayLink(for: view)
        defer { coordinator.invalidate() }
        view.layoutIfNeeded()
        let right = try XCTUnwrap(view.subviews.compactMap { $0 as? ReaderLayoutTextView }.first)
        XCTAssertFalse(right.isHidden)
        XCTAssertEqual(right.text, next.string)
        let consumed = try XCTUnwrap(view.continuationPosition)
        XCTAssertGreaterThan(consumed, 0)
        XCTAssertLessThan(consumed, next.length - heading.utf16.count)
        let swipe = UISwipeGestureRecognizer()
        swipe.direction = .left
        coordinator.perform(NSSelectorFromString("swiped:"), with: swipe)
        XCTAssertEqual(continuedAt, consumed)

        view.spreadStartCharacter = heading.utf16.count + consumed
        view.attributedText = next
        view.continuationText = nil
        view.invalidatePagination()
        view.layoutIfNeeded()
        coordinator.renderedPrefixLength = heading.utf16.count
        coordinator.scroll(to: consumed, in: view)
        let restored = expectation(description: "Continued after the previewed next-chapter page")
        DispatchQueue.main.async { restored.fulfill() }
        await fulfillment(of: [restored], timeout: 2)
        let leaves = ReaderTextPagination.pages(in: view)
        XCTAssertEqual(view.contentOffset.y, leaves[1].offset, accuracy: 0.5)
        XCTAssertEqual(view.pages[1].glyphRange.location, leaves[1].glyphRange.location)
        XCTAssertEqual(view.pages[1].secondOffset, leaves[2].offset)
        swipe.direction = .right
        coordinator.perform(NSSelectorFromString("swiped:"), with: swipe)
        XCTAssertTrue(returned, "Going back must return to the cross-chapter spread, without repeating its right page")

        canContinue = false
        view.spreadStartCharacter = 0
        view.attributedText = NSAttributedString(string: "本章末页。", attributes: typography.bodyAttributes)
        view.continuationBodyStart = 0
        view.continuationText = NSAttributedString(string: "全书最后一章。", attributes: typography.bodyAttributes)
        view.layoutIfNeeded()
        swipe.direction = .left
        coordinator.perform(NSSelectorFromString("swiped:"), with: swipe)
        XCTAssertEqual(continuedAt, "全书最后一章。".utf16.count)
        XCTAssertEqual(view.text, "本章末页。")
        XCTAssertFalse(right.isHidden)
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

    func testLandscapeScrollPairsConsecutiveLeavesWithoutLosingGlyphs() {
        var config = configuration()
        config.usesTwoPages = true
        let layout = ReaderScrollChapterLayout(chapter: chapter(0), configuration: config, width: 1100, viewportHeight: 700)
        XCTAssertEqual(layout.columnWidth, 538)
        XCTAssertNotNil(layout.blocks.first?.secondGlyphRange)
        var next = 0
        for block in layout.blocks {
            XCTAssertEqual(block.glyphRange.location, next)
            if let second = block.secondGlyphRange {
                XCTAssertGreaterThan(second.location, block.glyphRange.location)
                XCTAssertGreaterThan(block.secondTop, block.top)
            }
            next = NSMaxRange(block.glyphRange)
        }
        XCTAssertEqual(next, layout.manager.numberOfGlyphs)
    }

    func testCloudMergePreservesNewerEditsAndDoesNotUploadJoiningDeviceDefaults() {
        let remote = ReadingCloudValue(data: Data("remote".utf8), modifiedAt: 10, device: "a")
        let local = ReadingCloudValue(data: Data("local".utf8), modifiedAt: 20, device: "b")
        let defaults = ReadingCloudValue(data: Data("defaults".utf8), modifiedAt: 0, device: "z")
        XCTAssertEqual(defaults.merging(server: remote), remote)
        XCTAssertEqual(local.merging(server: remote), local)
        XCTAssertEqual(remote.merging(server: local), local)
        let deletion = ReadingCloudValue(data: Data(), modifiedAt: 30, device: "c")
        XCTAssertEqual(local.merging(server: deletion), deletion)
        XCTAssertFalse(ICloudSyncModel.preferenceKeys.contains("textFont"))
        XCTAssertFalse(ICloudSyncModel.preferenceKeys.contains("readerBrightness"))
    }

    func testSpeechSegmentsPreserveUnicodeAndOriginalCharacterOffsets() {
        let text = "  开始。\n\n" + String(repeating: "一段很长的正文，包含👨‍👩‍👧‍👦和标点。", count: 40) + "\n结束。  "
        let segments = ReaderSpeechSegment.split(text, maximumUTF16Length: 64)
        XCTAssertGreaterThan(segments.count, 3)
        for segment in segments {
            XCTAssertEqual(segment.text, (text as NSString).substring(with: segment.range))
            XCTAssertLessThanOrEqual(segment.range.length, 64)
            XCTAssertFalse(segment.text.contains("�"))
        }
        let expected = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.joined()
        XCTAssertEqual(segments.map(\.text).joined(), expected)
        XCTAssertEqual(ReaderSpeechSegment.split(" \n\t ").count, 0)
        let page = ReaderSpeechSegment.split(text, maximumUTF16Length: 64, byParagraph: false)
        XCTAssertEqual(page.map(\.text).joined(), text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    func testCloudProgressResolvesChapterTitlesAndPreservesNewerLocalReading() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var book = Book(bookUrl: "cloud-test", name: "同步测试", author: "作者")
        book.durChapterTime = 100
        let chapters = [BookChapter(url: "c0", title: "起点", bookUrl: book.bookUrl, index: 0),
                        BookChapter(url: "c2", title: "灯塔", bookUrl: book.bookUrl, index: 2)]
        let library = BookLibraryModel(repository: InMemoryBookRepository(books: [book]), localDirectory: directory.appendingPathComponent("books"),
            chapterRepository: InMemoryBookChapterRepository(values: [book.bookUrl: chapters]))
        await library.load()
        var remote = book
        remote.durChapterIndex = 1
        remote.durChapterTitle = "灯塔"
        remote.durChapterPos = 120
        remote.durChapterTime = 200
        await library.applySyncedReadingState(progress: [book.bookUrl: BookProgress(book: remote)], configurations: [:])
        XCTAssertEqual(library.books.first?.durChapterIndex, 2)
        XCTAssertEqual(library.books.first?.durChapterPos, 120)
        await library.updateProgress(for: book, chapter: chapters[0], position: 48)
        await library.applySyncedReadingState(progress: [book.bookUrl: BookProgress(book: remote)], configurations: [:])
        XCTAssertEqual(library.books.first?.durChapterIndex, 0)
        XCTAssertEqual(library.books.first?.durChapterPos, 48)
        let file = directory.appendingPathComponent("同步正文.txt")
        let text = "第一章 起点\n\n跨设备同步后的正文。\n"
        try Data(text.utf8).write(to: file)
        let metadata = Book(bookUrl: "local://remote-device", name: "iCloud 本地正文", author: "作者")
        try await library.importSyncedBook(from: file, metadata: metadata)
        let imported = try XCTUnwrap(library.books.first { $0.name == metadata.name })
        let restored = try XCTUnwrap(URL(string: imported.bookUrl))
        XCTAssertTrue(restored.isFileURL)
        XCTAssertNotEqual(restored, file)
        XCTAssertEqual(try String(contentsOf: restored, encoding: .utf8), text)
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

    private func configuration(fontSize: Double = 20, pageAnimation: Int = 3,
                               text: String = "",
                               continuationText: String = "",
                               reachedStart: @escaping (Int, Int?) -> Void = { _, _ in },
                               enteredContinuation: @escaping (Int) -> Bool = { _ in false }) -> ReaderTextView {
        .init(text: text, title: "", previousTitle: nil, previousText: "", isPreviousReady: false,
              continuationTitle: continuationText.isEmpty ? nil : "下一章", continuationText: continuationText,
              isContinuationReady: !continuationText.isEmpty, isVolume: false,
              fontSize: fontSize, fontPath: "", letterSpacing: 0, lineSpacing: 8, paragraphSpacing: 12,
              paragraphIndent: "　　", paddingLeft: 20, paddingRight: 20, paddingTop: 16, paddingBottom: 16,
              headerInset: 0, footerInset: 0, fontWeight: 0, titleMode: 0, titleSize: 4,
              titleTopSpacing: 16, titleBottomSpacing: 24, underlineMode: 0, isSelectable: false,
              fullJustify: true, pageAnimation: pageAnimation, isEInkMode: false, clickActions: Array(repeating: 0, count: 9),
              backgroundColor: .white, foregroundColor: .black, requestedPosition: 0, jumpPosition: nil,
              renderRevision: 0, readerPosition: .constant(0), pageRanges: .constant([]),
              currentPage: .constant(1), totalPages: .constant(1), isAutoReading: false,
              isAutoReadPaused: false, isLoadingNextChapter: false, secondsPerScreen: 10,
              onReachedEnd: { _ in }, onReachedStart: reachedStart, onEnteredPrevious: { _ in },
              onEnteredContinuation: enteredContinuation, onDeferredRender: {}, onCancelNextLoading: {},
              onPageChanged: {}, onTapAction: { _ in })
    }
}
