@preconcurrency import AVFoundation
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct ReaderView: View {
    private var usesEPUBLayout = true
    private var isStylePreview = false

    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.colorScheme) private var appColorScheme
    @EnvironmentObject private var library: BookLibraryModel
    @EnvironmentObject private var sourceLibrary: SourceLibraryModel
    @EnvironmentObject private var replaceRules: ReplaceRuleLibraryModel
    @EnvironmentObject private var activity: ReadingActivityModel
    @StateObject private var model: ReaderViewModel
    private var book: Book { model.book }
    @State private var sourceSwitchBook: Book?
    @StateObject private var speech = ReaderSpeechController()
    @ObservedObject private var downloads = BookDownloadModel.shared
    @State private var showsDownloads = false
    @State private var tocFilter = 0
    @State private var visitedChapters = Set<String>()
    @State private var showsTableOfContents = false
    @State private var tocDrag: CGFloat = 0
    @State private var showsBookmarks = false
    @State private var illustrationChapter: BookChapter?
    @State private var showsAutoReadControls = false
    @State private var showsStyleControls = false
    @State private var activeSlider: ReadingSliderPreview?
    @State private var styleSection = 0
    @State private var isAutoReading = false
    @State private var showsReaderMenu = false
    @State private var followsSystemBrightness = true
    @State private var readerBrightness = Double(UIScreen.main.brightness)
    @State private var brightnessBeforeReading = Double(UIScreen.main.brightness)
    @State private var tocSearch = ""
    @State private var tocDescending = false
    @State private var showsContentSearch = false
    @State private var showsReplaceRules = false
    @State private var showsSpeechSettings = false
    @State private var showsClickActionSettings = false
    @State private var showsContentEditor = false
    @State private var selectionRule: ReplaceRule?
    @State private var editedContent = ""
    @State private var contentEditError: String?
    @State private var backgroundImage: UIImage?
    @State private var backgroundError: String?
    @State private var showsBackgroundPicker = false
    @State private var showsFontImporter = false
    @State private var fontError: String?
    @State private var readerJumpPosition: Int?
    @State private var contentSearchQuery = ""
    @State private var readerPosition = 0
    @State private var readerPageRanges: [NSRange] = []
    @State private var speechPageIndex = 0
    @State private var currentPage = 1
    @State private var totalPages = 1
    private struct ChapterScrub {
        let generation: Int
        var fraction: Double
        let resumeSpeechPaused: Bool?
    }
    @State private var chapterScrub: ChapterScrub?
    @State private var readerRenderRevision = 0
    private struct ChapterNavigation {
        let direction: Int
        let position: Int?
        let generation: Int
    }
    @State private var pendingChapter: ChapterNavigation?
    @State private var readerBackgroundFrame = CGRect.zero
    @State private var spreadStarts: [Int: Int] = [:]
    @State private var previousSpreads: [Int: Int] = [:]
    @State private var httpTTSEngines: [HttpTTS] = []
    @State private var resumesSpeechAfterChapterLoad = false
    @State private var speechTimerTask: Task<Void, Never>?
    @State private var progressSaveTask: Task<Void, Never>?
    @State private var progressSaveGeneration = 0
    @State private var speechStartGeneration = 0
    @State private var speechTimerRemaining = 0
    @State private var isSavingBookmark = false
    @ScaledMetric(relativeTo: .body) private var toolbarIconSize = 21
    @AppStorage("textSize") private var fontSize = 20.0
    @AppStorage("letterSpacing") private var letterSpacing = 0.1
    @AppStorage("lineSpacingExtra") private var lineSpacing = 12.0
    @AppStorage("paragraphSpacing") private var paragraphSpacing = 2.0
    @AppStorage("paragraphIndent") private var paragraphIndent = "　　"
    @AppStorage("paddingLeft") private var paddingLeft = 16.0
    @AppStorage("paddingRight") private var paddingRight = 16.0
    @AppStorage("paddingTop") private var paddingTop = 6.0
    @AppStorage("paddingBottom") private var paddingBottom = 6.0
    @AppStorage("textBold") private var fontWeight = 0
    @AppStorage("textFont") private var fontPath = ""
    @AppStorage("titleMode") private var titleMode = 0
    @AppStorage("titleSize") private var titleSize = 0.0
    @AppStorage("titleTopSpacing") private var titleTopSpacing = 0.0
    @AppStorage("titleBottomSpacing") private var titleBottomSpacing = 0.0
    @AppStorage("underlineMode") private var underlineMode = 0
    @AppStorage("headerPaddingBottom") private var headerPaddingBottom = 0.0
    @AppStorage("headerPaddingLeft") private var headerPaddingLeft = 16.0
    @AppStorage("headerPaddingRight") private var headerPaddingRight = 16.0
    @AppStorage("headerPaddingTop") private var headerPaddingTop = 0.0
    @AppStorage("footerPaddingBottom") private var footerPaddingBottom = 6.0
    @AppStorage("footerPaddingLeft") private var footerPaddingLeft = 16.0
    @AppStorage("footerPaddingRight") private var footerPaddingRight = 16.0
    @AppStorage("footerPaddingTop") private var footerPaddingTop = 6.0
    @AppStorage("showHeaderLine") private var showHeaderLine = false
    @AppStorage("showFooterLine") private var showFooterLine = true
    @AppStorage("tipHeaderLeft") private var tipHeaderLeft = 2
    @AppStorage("tipHeaderMiddle") private var tipHeaderMiddle = 0
    @AppStorage("tipHeaderRight") private var tipHeaderRight = 3
    @AppStorage("tipFooterLeft") private var tipFooterLeft = 1
    @AppStorage("tipFooterMiddle") private var tipFooterMiddle = 0
    @AppStorage("tipFooterRight") private var tipFooterRight = 6
    @AppStorage("headerMode") private var headerMode = 0
    @AppStorage("footerMode") private var footerMode = 0
    @AppStorage("readerTheme") private var theme = "wechat"
    @AppStorage("readerPreviousDayTheme") private var previousDayTheme = "wechat"
    @AppStorage("autoReadSpeed") private var autoReadSpeed = 10
    @AppStorage("ttsFollowSys") private var ttsFollowSystem = true
    @AppStorage("ttsSpeechRate") private var ttsSpeechRate = 5
    @AppStorage("appTtsEngine") private var appTTSEngine = ""
    @AppStorage("systemTtsVoice") private var systemTTSVoice = ""
    @AppStorage("readAloudByPage") private var readAloudByPage = false
    @AppStorage("streamReadAloudAudio") private var streamReadAloudAudio = true
    @AppStorage("readAloudWakeLock") private var readAloudWakeLock = false
    @AppStorage("ignoreAudioFocus") private var ignoreAudioFocus = false
    @AppStorage("pauseReadAloudWhilePhoneCalls") private var pauseReadAloudWhilePhoneCalls = false
    @AppStorage("mediaButtonPerNext") private var mediaButtonPerNext = false
    @AppStorage("ttsTimer") private var ttsTimer = 0
    @AppStorage("readerFullJustify") private var fullJustify = true
    @AppStorage("readerKeepScreenOn") private var keepScreenOn = false
    @AppStorage("readerTapX1") private var tapX1 = 1.0 / 3
    @AppStorage("readerTapX2") private var tapX2 = 2.0 / 3
    @AppStorage("readerTapY1") private var tapY1 = 1.0 / 3
    @AppStorage("readerTapY2") private var tapY2 = 2.0 / 3
    @AppStorage("readerScrollsToTop") private var scrollsToTop = false
    @AppStorage("readerHideHomeIndicator") private var hideHomeIndicator = false
    @AppStorage("readerHideStatusBar") private var hideStatusBar = false
    @AppStorage("readerBrightness") private var storedReaderBrightness = 0.0
    @AppStorage("readerUseBackgroundImage") private var useBackgroundImage = false
    @AppStorage("themeMode") private var themeMode = "0"
    @AppStorage("enableReadRecord") private var enableReadRecord = true
    @State private var pageAnimation: Int
    @AppStorage("screenOrientation") private var screenOrientation = "0"
    @AppStorage("clickActionTopLeft") private var clickActionTL = 2
    @AppStorage("clickActionTopCenter") private var clickActionTC = 2
    @AppStorage("clickActionTopRight") private var clickActionTR = 1
    @AppStorage("clickActionMiddleLeft") private var clickActionML = 2
    @AppStorage("clickActionMiddleRight") private var clickActionMR = 1
    @AppStorage("clickActionBottomLeft") private var clickActionBL = 2
    @AppStorage("clickActionBottomCenter") private var clickActionBC = 1
    @AppStorage("clickActionBottomRight") private var clickActionBR = 1


    init(book: Book, chapters: [BookChapter], initialIndex: Int, source: BookSource) {
        _pageAnimation = State(initialValue: book.readConfig?.pageAnim.flatMap { $0 >= 0 ? $0 : nil }
            ?? Self.globalPageAnimation())
        _model = StateObject(wrappedValue: ReaderViewModel(
            book: book,
            chapters: chapters,
            initialIndex: initialIndex,
            source: source
        ))
    }

    init(book: Book, chapters: [BookChapter], initialIndex: Int, usesEPUBLayout: Bool = true) {
        self.usesEPUBLayout = usesEPUBLayout
        _pageAnimation = State(initialValue: book.readConfig?.pageAnim.flatMap { $0 >= 0 ? $0 : nil }
            ?? Self.globalPageAnimation())
        _model = StateObject(wrappedValue: ReaderViewModel(
            book: book,
            chapters: chapters,
            initialIndex: initialIndex
        ))
    }

    init(demoBook book: Book, chapters: [BookChapter], initialIndex: Int, content: String) {
        var readerChapters = chapters
        var readerInitialIndex = initialIndex
        var readerContent = content
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("-uiScrollRegression") {
            readerChapters = (0..<80).map {
                BookChapter(url: "demo://scroll/\($0)", title: "第\($0 + 1)章 · 连续阅读", bookUrl: book.bookUrl, index: $0)
            }
            readerInitialIndex = 20
            if arguments.contains("-uiShortChapters") { readerContent = "短章正文，继续向下可以自然读到下一章。" }
        }
        #endif
        _pageAnimation = State(initialValue: book.readConfig?.pageAnim.flatMap { $0 >= 0 ? $0 : nil }
            ?? Self.globalPageAnimation())
        #if DEBUG
        if arguments.contains("-uiReaderFailure") {
            _model = StateObject(wrappedValue: ReaderViewModel(
                book: book, chapters: readerChapters, initialIndex: readerInitialIndex,
                source: BookSource(bookSourceUrl: "https://reader-failure.invalid", bookSourceName: "正文失败测试源"),
                service: ReaderFailureTestLoader()
            ))
            return
        }
        #endif
        _model = StateObject(wrappedValue: ReaderViewModel(
            demoBook: book,
            chapters: readerChapters,
            initialIndex: readerInitialIndex,
            content: readerContent
        ))
    }


    init(stylePreview: Bool) {
        let book = Book(bookUrl: "demo://reading-style-preview", name: "阅读排版预览", author: "示例正文")
        let chapter = BookChapter(url: "demo://reading-style-preview/chapter", title: "第一章 · 窗边的光", bookUrl: book.bookUrl, index: 0)
        let paragraphs = [
            "清晨，阳光穿过窗帘，在书页上留下温暖的光影。远处传来几声鸟鸣，街道正缓缓醒来。她翻开昨天读到的那一页，继续寻找故事里的答案。",
            "这是一段用于调整阅读样式的示例正文。试着拖动上、下、左、右边距，观察文字区域如何变化；彩色区域表示对应的留白。松开滑块，设置面板就会恢复。",
            "一阵风吹过，窗外的树叶轻轻摇晃。文字在纸上安静排列，每一行都有自己的位置，每一页也留着恰到好处的空白。"
        ]
        self.init(demoBook: book, chapters: [chapter], initialIndex: 0, content: Array(repeating: paragraphs.joined(separator: "\n\n"), count: 6).joined(separator: "\n\n"))
        isStylePreview = stylePreview
        _showsStyleControls = State(initialValue: stylePreview)
    }

    var body: some View {
        if usesEPUBLayout, book.origin == "local", URL(string: book.bookUrl)?.pathExtension.lowercased() == "epub" {
            EPUBReaderView(book: book, chapters: model.chapters, initialIndex: model.currentIndex)
        } else {
            textReaderBody
        }
    }

    private var textReaderBody: some View {
        readerCanvas
        .readingTabBarHidden()
        .navigationBarBackButtonHidden(true)
        .background {
            ReaderInteractivePopEnabler()
                .frame(width: 0, height: 0)
        }
        .statusBarHidden(hideStatusBar)
        .readingHomeIndicatorHidden(hideHomeIndicator)
        .overlay(alignment: .top) {
            if showsReaderMenu {
                readerTopChrome
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.22), value: showsReaderMenu)
        .onAppear {
            if isStylePreview {
                backgroundImage = ReaderBackgroundStore.load()
                return
            }
            activity.beginReading(book)
            model.resumePreloading()
            speech.onNextChapter = { moveSpeechToChapter(direction: 1) }
            speech.onPreviousChapter = { moveSpeechToChapter(direction: -1) }
            speech.onRemoteStop = {
                speechTimerTask?.cancel()
                speechTimerRemaining = 0
                resumesSpeechAfterChapterLoad = false
            }
            UIDevice.current.isBatteryMonitoringEnabled = true
            brightnessBeforeReading = Double(UIScreen.main.brightness)
            if storedReaderBrightness >= 0.05 {
                followsSystemBrightness = false
                readerBrightness = storedReaderBrightness
                UIScreen.main.brightness = CGFloat(storedReaderBrightness)
            } else {
                readerBrightness = brightnessBeforeReading
            }
            backgroundImage = ReaderBackgroundStore.load()
            ReaderScreenOrientation.apply(screenOrientation)
            Task { await loadHTTPEngines() }
            if ProcessInfo.processInfo.arguments.contains("-uiDemoBookmarks") {
                showsBookmarks = true
            }
            if ProcessInfo.processInfo.arguments.contains("-uiDemoReaderMenu") {
                showsReaderMenu = true
            }
            if ProcessInfo.processInfo.arguments.contains("-uiDemoReaderStyle") {
                DispatchQueue.main.async { showsStyleControls = true }
            }
        }
        .onDisappear {
            guard !isStylePreview else { return }
            pendingChapter = nil
            model.cancelPreloading()
            isAutoReading = false
            UIApplication.shared.isIdleTimerDisabled = false
            if speech.isSpeaking || speech.isPaused { speech.toggle(text: "") }
            saveProgress(immediate: true)
            ReaderScreenOrientation.restoreApplicationDefault()
            activity.cancelReading(book)
            UIDevice.current.isBatteryMonitoringEnabled = false
            if !followsSystemBrightness {
                UIScreen.main.brightness = CGFloat(brightnessBeforeReading)
            }
            speechTimerTask?.cancel()
            speechTimerRemaining = 0
            speech.onNextChapter = nil
            speech.onPreviousChapter = nil
            speech.onRemoteStop = nil
        }
        .overlay(alignment: .bottom) {
            if showsReaderMenu {
                readerBottomChrome
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .overlay { tableOfContentsDrawer }
        .animation(.easeOut(duration: 0.24), value: showsTableOfContents)
        .onChange(of: showsTableOfContents) { shown in
            if shown {
                tocSearch = ""; tocDrag = 0
                Task { await downloads.refresh(book: book) }
            }
        }
        .sheet(isPresented: $showsDownloads) {
            if let source = sourceLibrary.sources.first(where: { $0.id == book.origin }) {
                BookDownloadView(book: book, chapters: model.chapters, source: source, startIndex: model.currentIndex)
                    .readingFormPresentation()
            }
        }
        .sheet(isPresented: $showsBookmarks) { bookmarksSheet }
        .sheet(item: $illustrationChapter) { chapter in
            EPUBIllustrationsView(book: book, chapter: chapter)
        }
        .overlay {
            if showsStyleControls || showsAutoReadControls {
                ReadingPreviewPanel(activeSlider: $activeSlider, expanded: showsStyleControls, dismiss: {
                    if isStylePreview { dismiss() }
                    else {
                        showsStyleControls = false
                        showsAutoReadControls = false
                    }
                }) {
                    if showsStyleControls { styleControls }
                    else { autoReadControls }
                }
            }
        }
        .onChange(of: showsStyleControls) { shown in
            if shown { showsReaderMenu = false }
            else { activeSlider = nil }
        }
        .onChange(of: showsAutoReadControls) { shown in
            if shown { showsReaderMenu = false }
            else { activeSlider = nil }
        }
        .sheet(isPresented: $showsContentSearch) { contentSearchSheet }
        .sheet(item: $sourceSwitchBook) { currentBook in
            ReadingNavigationStack {
                SourceSwitchView(book: currentBook, sources: sourceLibrary.sources) { report, source in
                    Task {
                        await progressSaveTask?.value
                        await activity.endReading(book)
                        await library.replace(oldBookURL: book.bookUrl, with: report.book)
                        pendingChapter = nil
                        spreadStarts = [:]
                        previousSpreads = [:]
                        model.applySourceSwitch(report, source: source)
                        readerPosition = report.book.durChapterPos
                        readerJumpPosition = nil
                        readerPageRanges = []
                        readerRenderRevision &+= 1
                        activity.beginReading(report.book)
                    }
                }
            }
        }
        .sheet(isPresented: $showsReplaceRules) {
            ReadingNavigationStack { ReplaceRuleManagementView() }
        }
        .sheet(isPresented: $showsSpeechSettings) {
            ReadingNavigationStack {
                speechSettings.toolbar {
                    ToolbarItem(placement: .confirmationAction) { Button("完成") { showsSpeechSettings = false } }
                }
            }
            .readingFormPresentation()
        }
        .sheet(isPresented: $showsContentEditor) { contentEditor }
        .sheet(item: $selectionRule, content: selectionRuleEditor)
        .task(id: model.chapterLoadGeneration) {
            guard !isStylePreview else { return }
            let needsInitialPosition = !model.hasLoadedCurrentChapter
            if let pending = progressSaveTask {
                let pendingGeneration = progressSaveGeneration
                await pending.value
                // A newer page callback may have scheduled another save while
                // this chapter task was waiting. Never erase that newer task's
                // handle, or a subsequent chapter transition could skip it.
                if progressSaveGeneration == pendingGeneration {
                    progressSaveTask = nil
                }
            }
            readerJumpPosition = nil
            readerPageRanges = []
            if needsInitialPosition { readerPosition = model.requestedPosition }
            await model.load(rules: model.usesReplaceRules ? replaceRules.rules : [])
            guard !Task.isCancelled else { return }
            if needsInitialPosition {
                readerPosition = pageAnimation == 3
                    ? continuousPosition(model.requestedPosition, content: model.content)
                    : min(model.requestedPosition, max(model.content.utf16.count - 1, 0))
            }
            if let chapter = model.currentChapter, !model.content.isEmpty {
                visitedChapters.insert(chapter.title)
                await library.updateProgress(for: book, chapter: chapter, position: readerPosition)
            }
            if resumesSpeechAfterChapterLoad, !model.content.isEmpty {
                resumesSpeechAfterChapterLoad = false
                startConfiguredSpeech()
            }
        }
        .task(id: "\(model.chapterLoadGeneration):\(pageAnimation == 3):\(model.hasLoadedCurrentChapter):\(model.scrollRevision)") {
            guard model.hasLoadedCurrentChapter else { return }
            if pageAnimation == 3 {
                await model.prepareContinuousReading(rules: model.usesReplaceRules ? replaceRules.rules : [])
            } else {
                await model.loadAdjacentChapters(rules: model.usesReplaceRules ? replaceRules.rules : [])
            }
        }
        .onAppear { updateIdleTimer() }
        .onChange(of: model.chapterLoadGeneration) { generation in
            if chapterScrub?.generation != generation { chapterScrub = nil }
            if let request = pendingChapter, request.generation != generation { pendingChapter = nil }
        }
        .onChange(of: keepScreenOn) { _ in
            updateIdleTimer()
        }
        .onChange(of: adjacentReadiness) { _ in
            guard let request = pendingChapter else { return }
            guard request.generation == model.chapterLoadGeneration else { pendingChapter = nil; return }
            let ready = request.direction < 0 ? model.isPreviousWindowReady : model.isContinuationWindowReady
            guard ready else { return }
            pendingChapter = nil
            if pageAnimation != 3 {
                advanceToPreparedPagedChapter(request.direction, position: request.position)
            } else if request.direction < 0 {
                advanceToPreparedPreviousChapter()
            } else {
                readerRenderRevision &+= 1
            }
        }
        .onChange(of: isAutoReading) { _ in
            updateIdleTimer()
        }
        .onChange(of: speech.isSpeaking) { _ in
            updateIdleTimer()
        }
        .onChange(of: speech.completionCount) { _ in
            if readAloudByPage {
                continueSpeechToNextPage()
            } else {
                continueSpeechToNextChapter()
            }
        }
        .onChange(of: speech.currentCharacterPosition) { position in
            guard speech.isSpeaking || speech.isPaused else { return }
            let position = min(max(position, 0), model.content.utf16.count)
            readerPosition = position
            readerJumpPosition = nil
            DispatchQueue.main.async { readerJumpPosition = position }
        }
        .onChange(of: ttsTimer) { _ in
            if speech.isSpeaking || speech.isPaused { scheduleSpeechTimer() }
        }
        .onChange(of: ttsSpeechRate) { _ in restartSpeechAfterReaderLayoutChange() }
        .onChange(of: ttsFollowSystem) { _ in restartSpeechAfterReaderLayoutChange() }
        .onChange(of: systemTTSVoice) { _ in restartSpeechAfterReaderLayoutChange() }
        .onChange(of: appTTSEngine) { _ in restartSpeechAfterReaderLayoutChange() }
        .onChange(of: streamReadAloudAudio) { _ in restartSpeechAfterReaderLayoutChange() }
        .onReceive(NotificationCenter.default.publisher(for: .legadoConfigurationChanged).receive(on: RunLoop.main)) { _ in
            backgroundImage = ReaderBackgroundStore.load()
        }
        .onChange(of: readAloudByPage) { _ in
            restartSpeechAfterReaderLayoutChange()
        }
        .onChange(of: readAloudWakeLock) { _ in
            updateIdleTimer()
        }
        .onChange(of: scenePhase) { phase in
            guard !isStylePreview else { return }
            if phase == .active {
                if !followsSystemBrightness {
                    UIScreen.main.brightness = CGFloat(readerBrightness)
                }
                activity.beginReading(book)
            } else {
                isAutoReading = false
                if !followsSystemBrightness {
                    UIScreen.main.brightness = CGFloat(brightnessBeforeReading)
                }
                saveProgress(immediate: true)
                activity.cancelReading(book)
            }
        }
        .onChange(of: screenOrientation) { value in
            ReaderScreenOrientation.apply(value)
        }
        .onChange(of: themeMode) { _ in
            isAutoReading = false
            readerJumpPosition = nil
            currentPage = 1
            totalPages = 1
        }
        .onChange(of: pageAnimation) { value in
            pendingChapter = nil
            isAutoReading = false
            saveProgress(immediate: true)
            readerJumpPosition = readerPosition
            currentPage = 1
            totalPages = 1
            UserDefaults.standard.set(value, forKey: "pageAnim")
            guard !isStylePreview else { return }
            let updatedBook = model.useGlobalPageAnimation()
            Task { await library.addOrUpdate(updatedBook) }
        }
        .environment(\.colorScheme, resolvedStyle.isDark ? .dark : appColorScheme)
        .preference(key: ReaderDarkAppearanceKey.self, value: resolvedStyle.isDark)
    }


    private var readerCanvas: some View {
        ZStack {
            readerContent
            readerMenuDismissOverlay
        }
        .background {
            GeometryReader { geometry in
                ZStack {
                    backgroundColor
                    if let backgroundImage = activeBackgroundImage {
                        Image(uiImage: backgroundImage)
                            .resizable()
                            .scaledToFill()
                    }
                }
                .onAppear { readerBackgroundFrame = geometry.frame(in: .global) }
                .onChange(of: geometry.frame(in: .global)) { readerBackgroundFrame = $0 }
            }
            .clipped()
            .ignoresSafeArea()
        }
    }

    @ViewBuilder private var readerContent: some View {
        if pageAnimation != 3,
           (model.isLoading && model.content.isEmpty) || (model.content.isEmpty && !model.hasLoadedCurrentChapter) {
            VStack(spacing: 14) {
                ProgressView()
                    .controlSize(.regular)
                Text("正在打开本章")
                    .font(.subheadline.weight(.medium))
                Text(model.title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .foregroundStyle(foregroundColor)
            .background(backgroundColor.ignoresSafeArea())
            .contentShape(Rectangle())
            .onTapGesture { showsReaderMenu.toggle() }
            .transition(.opacity)
        } else if pageAnimation != 3, model.content.isEmpty && model.hasLoadedCurrentChapter {
            VStack(spacing: 18) {
                Image(systemName: "text.page.slash").font(.largeTitle)
                Text(model.currentChapterError == nil ? "正文为空" : "本章加载失败").font(.title3.weight(.semibold))
                Text(model.currentChapterError ?? "本章暂无正文。")
                    .font(.subheadline).multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                readerRecoveryActions
                Button("打开阅读菜单") { showsReaderMenu = true }
                    .accessibilityIdentifier("reader.failureMenu")
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .foregroundStyle(foregroundColor)
            .background(backgroundColor.ignoresSafeArea())
        } else {
            GeometryReader { geometry in
                let twoPages = UIDevice.current.userInterfaceIdiom == .pad
                    && geometry.size.width > geometry.size.height
                VStack(spacing: 0) {
                    if headerVisible {
                        readerTipBar(isHeader: true)
                            .overlay { marginGuides(group: "页眉", top: headerPaddingTop, bottom: headerPaddingBottom, left: headerPaddingLeft, right: headerPaddingRight) }
                    }
                    readerSurface(twoPages: twoPages)
                        .overlay { if showsClickActionSettings { clickActionSettings } }
                        .clipped()
                        .padding(.top, CGFloat(max(paddingTop, 0)))
                        .padding(.bottom, CGFloat(max(paddingBottom, 0)))
                        .overlay { marginGuides(group: "正文", top: paddingTop, bottom: paddingBottom, left: paddingLeft, right: paddingRight) }
                    if footerVisible {
                        readerTipBar(isHeader: false)
                            .overlay { marginGuides(group: "页脚", top: footerPaddingTop, bottom: footerPaddingBottom, left: footerPaddingLeft, right: footerPaddingRight) }
                    }
                }
                .frame(maxWidth: twoPages ? .infinity : readingColumnMaxWidth)
                .frame(maxWidth: .infinity)
                .overlay(alignment: .bottom) {
                    if let error = model.currentChapterError, !showsReaderMenu {
                        VStack(spacing: 10) {
                            Text(model.content.isEmpty ? "本章加载失败" : "本章加载不完整").font(.subheadline.weight(.semibold))
                            Text(error).font(.caption).lineLimit(2).multilineTextAlignment(.center)
                            readerRecoveryActions
                            Button("打开阅读菜单") { showsReaderMenu = true }
                                .accessibilityIdentifier("reader.failureMenu")
                        }
                        .padding(16)
                        .frame(maxWidth: .infinity)
                        .foregroundStyle(foregroundColor)
                        .background(backgroundColor)
                    }
                }
            }
        }
    }

    private var readerRecoveryActions: some View {
        HStack(spacing: 16) {
            Button {
                Task {
                    if pageAnimation == 3, model.scrollChapters.contains(where: { $0.id == model.currentIndex }) {
                        await model.retryContinuousChapter(index: model.currentIndex, rules: model.usesReplaceRules ? replaceRules.rules : [])
                    } else {
                        await model.load(rules: model.usesReplaceRules ? replaceRules.rules : [], forceRefresh: true)
                    }
                }
            } label: {
                Label(model.scrollRetries.contains(model.currentIndex) ? "重试中…" : "重试本章", systemImage: "arrow.clockwise")
            }
            .disabled(model.isLoading || model.scrollRetries.contains(model.currentIndex))
            .accessibilityIdentifier("reader.retryChapter")
            if model.canEditContent {
                Button(action: openSourceSwitch) {
                    Label("换源", systemImage: "arrow.triangle.2.circlepath")
                }
                .accessibilityIdentifier("reader.failureChangeSource")
            }
        }
        .readingSecondaryButtonStyle()
    }

    private func openSourceSwitch() {
        stopSpeechIfNeeded()
        isAutoReading = false
        saveProgress(immediate: true)
        showsReaderMenu = false
        sourceSwitchBook = model.bookForSourceSwitch(position: readerPosition)
    }

    @ViewBuilder private func readerSurface(twoPages: Bool) -> some View {
        if pageAnimation == 3 {
            ReaderScrollView(
                configuration: readerTextConfiguration(twoPages: twoPages),
                chapters: model.scrollChapters,
                resetID: model.scrollRevision,
                activeIndex: model.currentIndex,
                loadingAhead: model.isLoadingScrollAhead,
                loadingBehind: model.isLoadingScrollBehind,
                onNeedChapters: { direction in
                    Task { await model.extendContinuousReading(direction: direction, rules: model.usesReplaceRules ? replaceRules.rules : []) }
                },
                onPositionChanged: { index, position in
                    if index != model.currentIndex {
                        saveProgress(immediate: true)
                        model.updateContinuousPosition(chapter: index)
                        readerJumpPosition = nil
                    }
                    let resolved = min(max(position, 0), model.content.utf16.count)
                    if readerPosition != resolved { readerPosition = resolved }
                },
                onRetainChapters: { model.retainContinuousChapters($0) }
            )
        } else {
            readerTextConfiguration(twoPages: twoPages)
        }
    }

    private func readerTextConfiguration(twoPages: Bool = false) -> ReaderTextView {
        ReaderTextView(
            text: readerDisplayText,
            title: model.title,
            previousTitle: model.canGoPrevious ? model.previousTitle : nil,
            previousText: pageAnimation == 3 ? model.previousContent : "",
            isPreviousReady: model.isPreviousWindowReady,
            continuationTitle: model.canGoNext ? model.continuationTitle : nil,
            continuationText: pageAnimation == 3 || twoPages ? model.continuationContent : "",
            isContinuationReady: model.isContinuationWindowReady && (!twoPages || model.continuationChapterError == nil),
            isVolume: model.currentChapter?.isVolume == true,
            fontSize: fontSize,
            fontPath: fontPath,
            letterSpacing: letterSpacing,
            lineSpacing: lineSpacing,
            paragraphSpacing: paragraphSpacing,
            paragraphIndent: paragraphIndent,
            paddingLeft: paddingLeft,
            paddingRight: paddingRight,
            paddingTop: 0,
            paddingBottom: 0,
            headerInset: 0,
            footerInset: 0,
            fontWeight: fontWeight,
            titleMode: titleMode,
            titleSize: titleSize,
            titleTopSpacing: titleTopSpacing,
            titleBottomSpacing: titleBottomSpacing,
            underlineMode: underlineMode,
            isSelectable: true,
            fullJustify: fullJustify,
            pageAnimation: pageAnimation,
            isEInkMode: themeMode == "3",
            clickActions: clickActions,
            backgroundColor: activeBackgroundImage == nil ? resolvedStyle.background : .clear,
            foregroundColor: resolvedStyle.foreground,
            requestedPosition: pageAnimation == 3 ? readerPosition : model.requestedPosition,
            jumpPosition: readerJumpPosition,
            renderRevision: readerRenderRevision,
            chapterRevision: model.chapterLoadGeneration,
            chapterIndex: model.currentIndex,
            usesTwoPages: twoPages,
            spreadStartPosition: model.requestedPosition == Int.max
                ? (spreadStarts[model.currentIndex] ?? 0) : min(model.requestedPosition, model.content.utf16.count),
            previousSpreadChapter: previousSpreads[model.currentIndex],
            pageBackgroundColor: resolvedStyle.background,
            pageBackgroundImage: activeBackgroundImage,
            pageBackgroundFrame: readerBackgroundFrame,
            readerPosition: $readerPosition,
            pageRanges: $readerPageRanges,
            currentPage: $currentPage,
            totalPages: $totalPages,
            isAutoReading: isAutoReading,
            isAutoReadPaused: pausesAutoReading,
            isLoadingNextChapter: isWaitingForNextChapter,
            secondsPerScreen: Double(autoReadSpeed),
            onReachedEnd: { boundaryPosition in
                if pageAnimation == 3 {
                    requestNextChapter()
                    return
                }
                if model.canGoNext {
                    showsReaderMenu = false
                    readerPosition = boundaryPosition
                    readerJumpPosition = nil
                    // Keep every chapter in its own TextKit document. Appending
                    // text here makes the absolute UTF-16 offset belong to the
                    // previous chapter while progress is saved under the next.
                    advanceToPreparedPagedChapter(1)
                } else {
                    isAutoReading = false
                }
            },
            onReachedStart: { boundaryPosition, spreadChapter in
                if pageAnimation == 3 {
                    requestPreviousChapter()
                    return
                }
                guard model.canGoPrevious else { return }
                showsReaderMenu = false
                readerPosition = boundaryPosition
                readerJumpPosition = nil
                if let spreadChapter {
                    pendingChapter = nil
                    saveProgress(immediate: true)
                    model.select(index: spreadChapter, position: Int.max)
                    return
                }
                advanceToPreparedPagedChapter(-1)
            },
            onEnteredPrevious: { position in
                guard pageAnimation == 3, model.canGoPrevious, model.hasPreviousWindow else { return }
                saveProgress(immediate: true)
                readerPosition = continuousPosition(position, content: model.previousContent)
                readerJumpPosition = nil
                model.promotePrevious(position: readerPosition)
            },
            onEnteredContinuation: { position in
                guard model.canGoNext, model.hasContinuationWindow else { return false }
                if pageAnimation != 3 {
                    let finished = position >= model.continuationContent.utf16.count
                    if finished, !model.hasChapterAfterContinuation {
                        isAutoReading = false
                        return false
                    }
                    let origin = model.currentIndex
                    advanceToPreparedPagedChapter(1, position: position)
                    if finished {
                        saveProgress(immediate: true)
                        model.goNext()
                        readerPosition = 0
                        spreadStarts[model.currentIndex] = 0
                        previousSpreads[model.currentIndex] = origin
                    }
                    return true
                }
                saveProgress(immediate: true)
                readerPosition = continuousPosition(position, content: model.continuationContent)
                readerJumpPosition = nil
                model.promoteContinuation(position: readerPosition)
                return true
            },
            onDeferredRender: { readerRenderRevision &+= 1 },
            onCancelNextLoading: { pendingChapter = nil },
            onPageChanged: pageDidChange,
            onTapAction: handleTapAction,
            onAddPurification: addPurificationRule,
            tapX1: tapX1, tapX2: tapX2, tapY1: tapY1, tapY2: tapY2, scrollsToTop: scrollsToTop
        )
    }

    @ViewBuilder private var readerMenuDismissOverlay: some View {
        if showsReaderMenu {
            Color.black
                .opacity(resolvedStyle.id == "night" ? 0.08 : 0.03)
                .ignoresSafeArea()
                .contentShape(ReaderMenuDismissShape())
                .onTapGesture { showsReaderMenu = false }
                .accessibilityHidden(true)
        }
    }

    private var readingColumnMaxWidth: CGFloat {
        UIDevice.current.userInterfaceIdiom == .pad ? 760 : .greatestFiniteMagnitude
    }

    private var adjacentReadiness: Int {
        (model.isPreviousWindowReady ? 1 : 0) | (model.isContinuationWindowReady ? 2 : 0)
    }

    private var readerDisplayText: String {
        if !model.content.isEmpty { return model.content }
        if pageAnimation == 3 {
            return String(repeating: "\n", count: 80)
        }
        if model.isLoading || !model.hasLoadedCurrentChapter {
            return "正文正在后台加载…\n\n你可以继续向下滚动，下一章已经提前生成。"
        }
        let reason = model.diagnostics.first?.message ?? "当前书源没有返回正文。"
        return "本章加载失败\n\n\(reason)\n\n本章位置会保留，请继续向下进入下一章。"
    }

    private func continuousPosition(_ position: Int, content: String) -> Int {
        let length = content.isEmpty ? 80 : content.utf16.count
        return min(max(position, 0), max(length - 1, 0))
    }

    private var activeBackgroundImage: UIImage? {
        themeMode != "3" && useBackgroundImage ? backgroundImage : nil
    }

    private var backgroundColor: Color {
        Color(uiColor: resolvedStyle.background)
    }

    private var foregroundColor: Color {
        Color(uiColor: resolvedStyle.foreground)
    }

    private var resolvedStyle: ReaderStylePreset {
        themeMode == "3" ? .eInk : ReaderStylePreset.resolve(theme)
    }

    private var headerVisible: Bool {
        switch headerMode {
        case 1: true
        case 2: false
        default: hideStatusBar
        }
    }

    private var footerVisible: Bool { footerMode == 0 }

    private var isWaitingForNextChapter: Bool {
        pendingChapter?.direction == 1 && pendingChapter?.generation == model.chapterLoadGeneration
    }
    private var isWaitingForPreviousChapter: Bool {
        pendingChapter?.direction == -1 && pendingChapter?.generation == model.chapterLoadGeneration
    }

    private var pausesAutoReading: Bool {
        isWaitingForNextChapter
            || isWaitingForPreviousChapter
            || showsReaderMenu
            || showsTableOfContents
            || showsBookmarks
            || illustrationChapter != nil
            || showsAutoReadControls
            || showsStyleControls
            || showsContentSearch
            || showsReplaceRules
            || showsSpeechSettings
            || showsClickActionSettings
            || showsContentEditor
    }


    private func readerTipBar(isHeader: Bool) -> some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            readerTipRow(
                isHeader ? [tipHeaderLeft, tipHeaderMiddle, tipHeaderRight] : [tipFooterLeft, tipFooterMiddle, tipFooterRight],
                date: context.date,
                showDivider: isHeader ? showHeaderLine : showFooterLine,
                isHeader: isHeader
            )
            .padding(.top, isHeader ? headerPaddingTop : footerPaddingTop)
            .padding(.bottom, isHeader ? headerPaddingBottom : footerPaddingBottom)
        }
        .allowsHitTesting(false)
    }

    private func readerTipRow(_ values: [Int], date: Date, showDivider: Bool, isHeader: Bool) -> some View {
        HStack(spacing: 8) {
            Text(readerTipText(values[0], date: date))
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(readerTipText(values[1], date: date))
                .frame(maxWidth: .infinity, alignment: .center)
            Text(readerTipText(values[2], date: date))
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .font(.system(size: 12))
        .foregroundStyle(foregroundColor)
        .lineLimit(1)
        .padding(.leading, isHeader ? headerPaddingLeft : footerPaddingLeft)
        .padding(.trailing, isHeader ? headerPaddingRight : footerPaddingRight)
        .overlay(alignment: .bottom) {
            if showDivider { Divider().overlay(foregroundColor.opacity(0.35)) }
        }
    }

    private func readerTipText(_ value: Int, date: Date) -> String {
        let time = date.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))
        let batteryValue = UIDevice.current.batteryLevel
        let battery = batteryValue >= 0 ? Int((batteryValue * 100).rounded()) : 100
        let chapterCount = max(model.chapters.filter { !$0.isVolume }.count, 1)
        let readableIndex = model.chapters.prefix(model.currentIndex + 1).filter { !$0.isVolume }.count
        let chapterFraction = chapterPageFraction
        let progress = min(max((Double(max(readableIndex - 1, 0)) + chapterFraction) / Double(chapterCount), 0), 1)
        let progressText = String(format: "%.1f%%", progress * 100)
        switch value {
        case 1: return model.title
        case 2: return time
        case 3: return "▰"
        case 4: return "\(currentPage)/\(totalPages)"
        case 5: return progressText
        case 6: return "\(currentPage)/\(totalPages)  \(progressText)"
        case 7: return book.name
        case 8: return "\(time) ▰"
        case 9: return "\(time) \(battery)%"
        case 10: return "\(battery)%"
        case 11: return "\(readableIndex)/\(chapterCount)"
        default: return ""
        }
    }

    private var readerChromeTint: Color {
        .primary
    }

    @ViewBuilder private var readerChromeBackground: some View {
        if resolvedStyle.id == "night" {
            Color(uiColor: .secondarySystemBackground)
        } else {
            Color(uiColor: .systemBackground)
        }
    }

    private var bookProgress: Double {
        let chapter = max(model.chapters.filter { !$0.isVolume }.count, 1)
        let readable = model.chapters.prefix(model.currentIndex + 1).filter { !$0.isVolume }.count
        let pagePart = chapterReadingProgress
        return min(max((Double(max(readable - 1, 0)) + pagePart) / Double(chapter), 0), 1)
    }

    private var chapterPageFraction: Double {
        guard totalPages > 1 else { return 1 }
        return min(max(Double(max(currentPage - 1, 0)) / Double(totalPages - 1), 0), 1)
    }

    private var chapterReadingProgress: Double {
        if pageAnimation != 3 { return chapterPageFraction }
        return min(max(Double(readerPosition) / Double(max(model.content.utf16.count - 1, 1)), 0), 1)
    }

    private var chapterProgressBinding: Binding<Double> {
        Binding(get: { chapterScrub?.fraction ?? chapterReadingProgress }, set: { fraction in
            chapterScrub?.fraction = fraction
            seekChapter(to: fraction)
        })
    }

    private func editChapterProgress(_ editing: Bool) {
        if editing {
            let paused: Bool? = speech.isSpeaking || speech.isPaused ? speech.isPaused : nil
            let scrub = ChapterScrub(generation: model.chapterLoadGeneration, fraction: chapterReadingProgress, resumeSpeechPaused: paused)
            isAutoReading = false
            stopSpeechIfNeeded()
            pendingChapter = nil
            progressSaveTask?.cancel()
            chapterScrub = scrub
        } else if let scrub = chapterScrub {
            chapterScrub = nil
            guard scrub.generation == model.chapterLoadGeneration else { return }
            seekChapter(to: scrub.fraction, resumeSpeechPaused: scrub.resumeSpeechPaused)
        }
    }

    private func seekChapter(to fraction: Double, resumeSpeechPaused: Bool? = nil) {
        guard !model.content.isEmpty else { return }
        let position = ReaderPositionResolver.chapterPosition(fraction: fraction, text: model.content,
            pageRanges: pageAnimation == 3 ? [] : readerPageRanges)
        readerPosition = position
        if let scrub = chapterScrub {
            guard scrub.generation == model.chapterLoadGeneration else { return }
            readerJumpPosition = position
            return
        }
        let paused = resumeSpeechPaused ?? (speech.isSpeaking || speech.isPaused ? speech.isPaused : nil)
        pendingChapter = nil
        isAutoReading = false
        stopSpeechIfNeeded()
        readerJumpPosition = nil
        let generation = model.chapterLoadGeneration
        let speechGeneration = speechStartGeneration
        DispatchQueue.main.async {
            guard model.chapterLoadGeneration == generation, speechStartGeneration == speechGeneration, chapterScrub == nil else { return }
            readerJumpPosition = position
            if let paused { configureSpeech(); startConfiguredSpeech(startsPaused: paused) }
        }
        saveProgress(immediate: true)
    }


    private var readerTopChrome: some View {
        HStack(spacing: 4) {
            readerChromeIconButton("chevron.backward", label: "返回") { dismiss() }
            VStack(alignment: .leading, spacing: 3) {
                Text(book.name)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                HStack(spacing: 4) {
                    Text(model.title).lineLimit(1)
                    if model.loadedFromCache {
                        Image(systemName: "arrow.down.circle")
                            .accessibilityLabel("已缓存")
                    }
                    Spacer(minLength: 4)
                    Text("全书 \(bookProgress.formatted(.percent.precision(.fractionLength(0))))")
                        .monospacedDigit().fixedSize()
                        .accessibilityLabel("全书进度")
                        .accessibilityValue(bookProgress.formatted(.percent.precision(.fractionLength(0))))
                        .accessibilityIdentifier("reader.bookProgress")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            readerChromeIconButton(bookmarkSaved ? "bookmark.fill" : "bookmark", label: "书签") {
                addBookmark()
            }
            .accessibilityValue(bookmarkSaved ? "已添加" : "添加当前位置")
            .disabled(isSavingBookmark)
            readerMoreMenu
        }
        .foregroundStyle(readerChromeTint)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity)
        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
        .background { readerChromeBackground.ignoresSafeArea(edges: .top) }
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color(uiColor: .separator).opacity(0.35)).frame(height: 0.5)
        }
    }

    private var readerMoreMenu: some View {
        Menu {
            Button("搜索正文", systemImage: "magnifyingglass") {
                showsReaderMenu = false
                showsContentSearch = true
            }
            if book.origin == "local", URL(string: book.bookUrl)?.pathExtension.lowercased() == "epub" {
                Button("本章插图", systemImage: "photo.on.rectangle") {
                    showsReaderMenu = false
                    illustrationChapter = model.currentChapter
                }
            }
            Button("书签列表", systemImage: "bookmark") {
                showsReaderMenu = false
                showsBookmarks = true
            }
            Button(isAutoReading ? "停止自动阅读" : "自动阅读", systemImage: isAutoReading ? "stop" : "play") {
                if isAutoReading {
                    isAutoReading = false
                } else {
                    showsReaderMenu = false
                    showsAutoReadControls = true
                }
            }
            Button("编辑本章正文", systemImage: "square.and.pencil") {
                editedContent = model.content
                contentEditError = nil
                showsContentEditor = true
            }.disabled(!model.canEditContent || model.content.isEmpty)
            Button("重新获取本章", systemImage: "arrow.clockwise") { refreshCurrentChapter() }
                .disabled(model.isLoading || !model.canEditContent)
            Divider()
            Button(resolvedStyle.id == "night" ? "切换为日间" : "切换为夜间", systemImage: resolvedStyle.id == "night" ? "sun.max" : "moon") {
                toggleNightTheme()
            }
            .disabled(themeMode == "3")
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 20, weight: .regular))
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("更多")
    }

    private var readerBottomChrome: some View {
        VStack(spacing: 12) {
            if speech.isSpeaking || speech.isPaused || speech.errorMessage != nil || chapterScrub?.resumeSpeechPaused != nil {
                speechPlaybackControls.disabled(chapterScrub != nil)
            }
            readerChapterControls
            Rectangle().fill(Color(uiColor: .separator).opacity(0.35)).frame(height: 0.5)
            LazyVGrid(columns: readerToolbarColumns, spacing: 12) {
                readerChromeAction("list.bullet", "目录") {
                    showsReaderMenu = false
                    showsTableOfContents = true
                }
                if model.canEditContent {
                    readerChromeAction("arrow.triangle.2.circlepath", "换源", action: openSourceSwitch)
                    .accessibilityIdentifier("reader.changeSource")
                    .accessibilityValue(book.originName)
                }
                readerChromeAction("headphones", "朗读", isActive: speech.isSpeaking) {
                    Task { await loadHTTPEngines(); handleTapAction(13) }
                }
                readerChromeAction("gearshape", "设置") {
                    showsReaderMenu = false
                    showsStyleControls = true
                }
            }
        }
        .foregroundStyle(readerChromeTint)
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 10)
        .frame(maxWidth: .infinity)
        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
        .background { readerChromeBackground.ignoresSafeArea(edges: .bottom) }
        .overlay(alignment: .top) {
            Rectangle().fill(Color(uiColor: .separator).opacity(0.35)).frame(height: 0.5)
        }
    }

    private var speechPlaybackControls: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let error = speech.errorMessage {
                HStack {
                    Text(error).font(.caption).foregroundStyle(.red).lineLimit(2)
                    Spacer()
                    Button("重试朗读") { readerPosition = speech.currentCharacterPosition; toggleSpeech() }
                    Button { showsSpeechSettings = true } label: { Image(systemName: "slider.horizontal.3") }
                        .accessibilityLabel("朗读设置")
                }
            } else {
                HStack(spacing: 18) {
                    Button { speech.previousSegment() } label: { Image(systemName: "backward.end.fill") }
                        .accessibilityLabel("朗读上一段")
                    Button { handleTapAction(13) } label: { Image(systemName: speech.isPaused ? "play.fill" : "pause.fill") }
                        .accessibilityLabel(speech.isPaused ? "继续朗读" : "暂停朗读")
                    Button { speech.nextSegment() } label: { Image(systemName: "forward.end.fill") }
                        .accessibilityLabel("朗读下一段")
                    if speech.isBuffering { ProgressView().accessibilityLabel("正在准备音频") }
                    Spacer()
                    Button { showsSpeechSettings = true } label: { Image(systemName: "slider.horizontal.3") }
                        .accessibilityLabel("朗读设置")
                    Button("停止朗读") { toggleSpeech() }
                }
                .buttonStyle(.plain)
                .frame(minHeight: 36)
            }
        }
    }

    private var readerToolbarColumns: [GridItem] {
        let count = dynamicTypeSize.isAccessibilitySize ? (model.canEditContent ? 3 : 2) : (model.canEditContent ? 4 : 3)
        return Array(repeating: GridItem(.flexible(), spacing: 0), count: count)
    }

    private var readerChapterControls: some View {
        HStack(spacing: 16) {
            readerChromeIconButton("chevron.left", label: "上一章") { moveChapter(-1) }
                .disabled(!model.canGoPrevious)
                .opacity(model.canGoPrevious ? 1 : 0.25)
            VStack(spacing: 8) {
                HStack {
                    let chapterCount = model.chapters.filter { !$0.isVolume }.count
                    let chapterNumber = model.chapters.prefix(model.currentIndex + 1).filter { !$0.isVolume }.count
                    if #available(iOS 16.0, *) {
                        ViewThatFits(in: .horizontal) {
                            Text("第 \(chapterNumber) 章 / 共 \(chapterCount) 章").fixedSize()
                            Text("\(chapterNumber) / \(chapterCount) 章").fixedSize()
                        }
                    } else {
                        Text("\(chapterNumber) / \(chapterCount) 章").fixedSize()
                    }
                    Spacer(minLength: 8)
                    Text("本章 \((chapterScrub?.fraction ?? chapterReadingProgress).formatted(.percent.precision(.fractionLength(0))))")
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                Slider(value: chapterProgressBinding, in: 0...1, onEditingChanged: { editChapterProgress($0) })
                    .tint(readerChromeTint)
                    .disabled(model.content.isEmpty)
                    .accessibilityLabel("本章进度")
                    .accessibilityValue((chapterScrub?.fraction ?? chapterReadingProgress).formatted(.percent.precision(.fractionLength(0))))
                    .accessibilityIdentifier("reader.chapterProgress")
            }
            readerChromeIconButton("chevron.right", label: "下一章") { moveChapter(1) }
                .disabled(!model.canGoNext)
                .opacity(model.canGoNext ? 1 : 0.25)
        }
    }

    private func readerChromeIconButton(_ icon: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 19, weight: .regular))
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private func readerChromeAction(_ icon: String, _ title: String, isActive: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: min(toolbarIconSize, 28), weight: .regular))
                    .frame(height: 28)
                Text(title)
                    .font(.caption)
                    .foregroundStyle(isActive ? Color.primary : .secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 58)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }

    private var readerBrightnessBinding: Binding<Double> {
        Binding(
            get: { followsSystemBrightness ? Double(UIScreen.main.brightness) : readerBrightness },
            set: { value in
                if followsSystemBrightness { brightnessBeforeReading = Double(UIScreen.main.brightness) }
                followsSystemBrightness = false
                readerBrightness = value
                storedReaderBrightness = value
                UIScreen.main.brightness = CGFloat(value)
            }
        )
    }

    private func toggleNightTheme() {
        if resolvedStyle.id == "night" {
            theme = previousDayTheme == "night" ? "wechat" : previousDayTheme
        } else {
            previousDayTheme = resolvedStyle.id
            theme = "night"
        }
    }

    private func moveChapter(_ direction: Int) {
        pendingChapter = nil
        stopSpeechIfNeeded()
        if pageAnimation != 3 {
            advanceToPreparedPagedChapter(direction, position: 0)
            return
        }
        saveProgress(immediate: true)
        readerJumpPosition = nil
        if direction < 0 { model.goPrevious() } else { model.goNext() }
        readerPosition = model.requestedPosition
    }

    private func advanceToPreparedPagedChapter(_ direction: Int, position: Int? = nil) {
        guard (direction < 0 ? model.canGoPrevious : model.canGoNext) else { pendingChapter = nil; return }
        let ready = direction < 0 ? model.isPreviousWindowReady : model.isContinuationWindowReady
        guard ready else {
            pendingChapter = ChapterNavigation(direction: direction, position: position, generation: model.chapterLoadGeneration)
            return
        }
        pendingChapter = nil
        saveProgress(immediate: true)
        readerJumpPosition = nil
        if direction < 0 { model.goPrevious(position: position ?? Int.max) }
        else { model.goNext(position: position ?? 0) }
        if model.requestedPosition != Int.max {
            spreadStarts[model.currentIndex] = model.requestedPosition
            previousSpreads[model.currentIndex] = nil
        }
        readerPosition = min(model.requestedPosition, max(model.content.utf16.count - 1, 0))
    }

    private func requestNextChapter() {
        if pageAnimation == 3 {
            guard model.canGoNext else { isAutoReading = false; return }
            Task { await model.extendContinuousReading(direction: 1, rules: model.usesReplaceRules ? replaceRules.rules : []) }
            return
        }
        guard model.canGoNext, model.hasContinuationWindow else {
            isAutoReading = false
            return
        }
        if model.isContinuationWindowReady {
            pendingChapter = nil
            readerRenderRevision &+= 1
        } else {
            pendingChapter = ChapterNavigation(direction: 1, position: nil, generation: model.chapterLoadGeneration)
        }
    }

    private func requestPreviousChapter() {
        guard model.canGoPrevious, model.hasPreviousWindow else { return }
        if model.isPreviousWindowReady {
            advanceToPreparedPreviousChapter()
        } else {
            pendingChapter = ChapterNavigation(direction: -1, position: nil, generation: model.chapterLoadGeneration)
        }
    }

    private func advanceToPreparedPreviousChapter() {
        guard model.canGoPrevious, model.hasPreviousWindow, model.isPreviousWindowReady else { return }
        pendingChapter = nil
        saveProgress(immediate: true)
        readerJumpPosition = nil
        let position = max(model.previousContent.utf16.count - 1, 0)
        readerPosition = position
        model.promotePrevious(position: position)
    }

    private func startAutoReading() {
        stopSpeechIfNeeded()
        showsReaderMenu = false
        isAutoReading = true
    }

    private func updateIdleTimer() {
        guard !isStylePreview else { return }
        UIApplication.shared.isIdleTimerDisabled = keepScreenOn || isAutoReading
            || (readAloudWakeLock && speech.isSpeaking)
    }

    private func pageDidChange() {
        guard !isStylePreview, chapterScrub == nil else { return }
        saveProgress()
        guard enableReadRecord else { return }
        Task { await activity.checkpoint(book) }
    }


    private var autoReadControls: some View {
        VStack(spacing: 0) {
            HStack {
                Text("自动阅读").font(.headline)
                Spacer()
                Button("继续阅读") { showsAutoReadControls = false }
            }.padding(.horizontal, 16).frame(minHeight: 48)
            Divider()
            Form {
                Section {
                    valueSlider("自动翻页速度", value: Binding(
                        get: { Double(autoReadSpeed) },
                        set: { autoReadSpeed = max(1, min(Int($0.rounded()), 120)) }
                    ), range: 1...120, format: { "\(Int($0))s" })
                } footer: {
                    Text("数值表示自动阅读一屏所用的秒数，范围 1–120 秒。")
                }
                Section {
                    Button("目录", systemImage: "list.bullet") {
                        showsAutoReadControls = false
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { showsTableOfContents = true }
                    }
                    Button("开始自动阅读", systemImage: "play.fill") {
                        showsAutoReadControls = false
                        startAutoReading()
                    }
                    Button("主菜单", systemImage: "menubar.rectangle") {
                        showsAutoReadControls = false
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { showsReaderMenu = true }
                    }
                    Button("停止自动阅读", systemImage: "stop.fill", role: .destructive) {
                        isAutoReading = false
                        showsAutoReadControls = false
                    }
                    Button("设置", systemImage: "gearshape") {
                        showsAutoReadControls = false
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { showsStyleControls = true }
                    }
                }
            }
            .readingScrollContentBackgroundHidden()
        }
        .background(ReadingTheme.canvas).foregroundStyle(.primary).tint(.primary)
    }


    private var styleControls: some View {
        VStack(spacing: 0) {
            HStack {
                Button("恢复默认值") { restoreCurrentStyleDefaults() }
                    .accessibilityHint("恢复当前分类的默认设置")
                Spacer()
                Text("阅读设置").font(.headline)
                Spacer()
                Button("完成") {
                    if isStylePreview { dismiss() }
                    else { showsStyleControls = false }
                }
            }
            .font(.subheadline).frame(minHeight: 44).padding(.horizontal, 16).padding(.top, 4)
            Divider()
            VStack(spacing: 0) {
                Picker("样式分类", selection: $styleSection) {
                    Text("文字").tag(0)
                    Text("布局").tag(1)
                    Text("外观").tag(2)
                    Text("翻页").tag(3)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .accessibilityIdentifier("reader.style.categories")
                .onChange(of: styleSection) { _ in activeSlider = nil }

                Form {
                    switch styleSection {
                    case 0: typographyStyleSections
                    case 1: marginStyleSections
                    case 2:
                        backgroundStyleSection
                        Section("正文") { Toggle("两端对齐", isOn: $fullJustify) }
                        screenStyleSection
                    default: otherStyleSections
                    }
                }
                .pickerStyle(.menu)
                .readingScrollContentBackgroundHidden()
                .accessibilityIdentifier("reader.settingsForm")
                .id(styleSection)
            }
        }
        .background(ReadingTheme.canvas).foregroundStyle(.primary).tint(.primary)
        .readingPhotoPicker(isPresented: $showsBackgroundPicker) { data in
            backgroundError = nil
            do {
                backgroundImage = try ReaderBackgroundStore.save(data)
                useBackgroundImage = true
            } catch {
                backgroundError = error.localizedDescription
            }
        } onError: { error in
            backgroundError = error.localizedDescription
        }
        .fileImporter(
            isPresented: $showsFontImporter,
            allowedContentTypes: [.font, .data],
            allowsMultipleSelection: false
        ) { result in
            fontError = nil
            do {
                guard let source = try result.get().first else { return }
                fontPath = try ReaderFontStore.install(from: source)
            } catch {
                fontError = error.localizedDescription
            }
        }
    }

    private func restoreCurrentStyleDefaults() {
        activeSlider = nil
        switch styleSection {
        case 0:
            fontSize = 20
            letterSpacing = 0.1
            lineSpacing = 12
            paragraphSpacing = 2
            paragraphIndent = "　　"
            fontWeight = 0
            fontPath = ""
            titleMode = 0
            titleSize = 0
            titleTopSpacing = 0
            titleBottomSpacing = 0
            underlineMode = 0
        case 1:
            paddingLeft = 16
            paddingRight = 16
            paddingTop = 6
            paddingBottom = 6
            headerPaddingLeft = 16
            headerPaddingRight = 16
            headerPaddingTop = 0
            headerPaddingBottom = 0
            footerPaddingLeft = 16
            footerPaddingRight = 16
            footerPaddingTop = 6
            footerPaddingBottom = 6
            headerMode = 0
            footerMode = 0
            showHeaderLine = false
            showFooterLine = true
            tipHeaderLeft = 2
            tipHeaderMiddle = 0
            tipHeaderRight = 3
            tipFooterLeft = 1
            tipFooterMiddle = 0
            tipFooterRight = 6
        case 2:
            theme = "wechat"
            previousDayTheme = "wechat"
            useBackgroundImage = false
            backgroundError = nil
            fullJustify = true
            screenOrientation = "0"
            keepScreenOn = false
            hideHomeIndicator = false
            hideStatusBar = false
        default:
            pageAnimation = 0
            scrollsToTop = false
        }
    }

    @ViewBuilder private var typographyStyleSections: some View {
        Section("字号与间距") {
            valueSlider("字号", value: $fontSize, range: 5...50, format: { "\(Int($0))" })
            valueSlider("字间距", value: $letterSpacing, range: -0.5...0.5, step: 0.01, format: { String(format: "%.2f", $0) })
            valueSlider("行间距", value: $lineSpacing, range: 0...50, format: { "\(Int($0))" })
            valueSlider("段距", value: $paragraphSpacing, range: 0...50, format: { String(format: "%.1f", $0) })
        }
        Section {
            DisclosureGroup("字体与段落") {
                Picker("字重", selection: $fontWeight) {
                    Text("正常").tag(0)
                    Text("粗体").tag(1)
                    Text("细体").tag(2)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("段落缩进")
                    TextField("请输入缩进字符", text: $paragraphIndent)
                        .textInputAutocapitalization(.never)
                        .accessibilityLabel("段落缩进字符")
                    Text("控制每段开头的缩进，默认两个全角空格；清空后不缩进。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Button(fontPath.isEmpty ? "选择字体文件" : "更换字体文件", systemImage: "textformat") {
                    showsFontImporter = true
                }
                if !fontPath.isEmpty {
                    HStack {
                        Text("当前字体")
                        Spacer()
                        Text(URL(fileURLWithPath: fontPath).lastPathComponent)
                            .foregroundStyle(.secondary)
                    }
                    Button("恢复默认字体", role: .destructive) { fontPath = "" }
                }
                if let fontError {
                    Text(fontError).font(.footnote).foregroundStyle(.red)
                }
                Picker("下划线", selection: $underlineMode) {
                    Text("关闭").tag(0)
                    Text("实线").tag(1)
                    Text("虚线").tag(2)
                }
                Toggle("两端对齐", isOn: $fullJustify)
            }
            DisclosureGroup("章节标题") {
                Picker("标题模式", selection: $titleMode) {
                    Text("左对齐").tag(0)
                    Text("居中").tag(1)
                    Text("隐藏").tag(2)
                }
                .pickerStyle(.segmented)
                valueSlider("标题字号增量", value: $titleSize, range: -10...30, format: { String(format: "%+.0f", $0) })
                valueSlider("标题上间距", value: $titleTopSpacing, range: 0...100, format: { "\(Int($0))" })
                valueSlider("标题下间距", value: $titleBottomSpacing, range: 0...100, format: { "\(Int($0))" })
            }
        }
    }

    @ViewBuilder private var marginStyleSections: some View {
        Section("正文边距") {
            valueSlider("左边距", value: $paddingLeft, range: 0...100, marginID: "正文左边距", format: { "\(Int($0))" })
            valueSlider("右边距", value: $paddingRight, range: 0...100, marginID: "正文右边距", format: { "\(Int($0))" })
            valueSlider("上边距", value: $paddingTop, range: 0...100, marginID: "正文上边距", format: { "\(Int($0))" })
            valueSlider("下边距", value: $paddingBottom, range: 0...100, marginID: "正文下边距", format: { "\(Int($0))" })
        }
        Section("页眉页脚") {
            DisclosureGroup("页眉") {
                Picker("页眉显示", selection: $headerMode) {
                    Text("状态栏显示时隐藏").tag(0)
                    Text("显示").tag(1)
                    Text("隐藏").tag(2)
                }
                if headerMode != 2 {
                    tipPicker("页眉左", selection: $tipHeaderLeft)
                    tipPicker("页眉中", selection: $tipHeaderMiddle)
                    tipPicker("页眉右", selection: $tipHeaderRight)
                    Toggle("页眉分隔线", isOn: $showHeaderLine)
                    valueSlider("左边距", value: $headerPaddingLeft, range: 0...100, marginID: "页眉左边距", format: { "\(Int($0))" })
                    valueSlider("右边距", value: $headerPaddingRight, range: 0...100, marginID: "页眉右边距", format: { "\(Int($0))" })
                    valueSlider("上边距", value: $headerPaddingTop, range: 0...100, marginID: "页眉上边距", format: { "\(Int($0))" })
                    valueSlider("下边距", value: $headerPaddingBottom, range: 0...100, marginID: "页眉下边距", format: { "\(Int($0))" })
                }
            }
            DisclosureGroup("页脚") {
                Picker("页脚显示", selection: $footerMode) {
                    Text("显示").tag(0)
                    Text("隐藏").tag(1)
                }
                if footerMode != 1 {
                    tipPicker("页脚左", selection: $tipFooterLeft)
                    tipPicker("页脚中", selection: $tipFooterMiddle)
                    tipPicker("页脚右", selection: $tipFooterRight)
                    Toggle("页脚分隔线", isOn: $showFooterLine)
                    valueSlider("左边距", value: $footerPaddingLeft, range: 0...100, marginID: "页脚左边距", format: { "\(Int($0))" })
                    valueSlider("右边距", value: $footerPaddingRight, range: 0...100, marginID: "页脚右边距", format: { "\(Int($0))" })
                    valueSlider("上边距", value: $footerPaddingTop, range: 0...100, marginID: "页脚上边距", format: { "\(Int($0))" })
                    valueSlider("下边距", value: $footerPaddingBottom, range: 0...100, marginID: "页脚下边距", format: { "\(Int($0))" })
                }
            }
        }
    }

    private var backgroundStyleSection: some View {
        Section("阅读背景") {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(ReaderStylePreset.legadoDefaults) { preset in
                        let isSelected = resolvedStyle.id == preset.id && activeBackgroundImage == nil
                        Button {
                            useBackgroundImage = false
                            theme = preset.id
                        } label: {
                            VStack(spacing: 6) {
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(Color(uiColor: preset.background))
                                    .frame(width: 54, height: 72)
                                    .overlay {
                                    Text("文字")
                                        .font(.caption)
                                        .foregroundStyle(Color(uiColor: preset.foreground))
                                }
                                .overlay {
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .strokeBorder(
                                            Color(uiColor: preset.foreground).opacity(isSelected ? 0.4 : 0.12),
                                            lineWidth: isSelected ? 1.25 : 0.75
                                        )
                                }
                                .overlay(alignment: .topTrailing) {
                                    if isSelected {
                                        Image(systemName: "checkmark")
                                            .font(.system(size: 10, weight: .semibold))
                                            .foregroundStyle(Color(uiColor: preset.foreground))
                                            .padding(6)
                                    }
                                }
                                Text(preset.name)
                                    .font(.caption2)
                                    .foregroundStyle(isSelected ? .primary : .secondary)
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(preset.name)
                        .accessibilityAddTraits(isSelected ? .isSelected : [])
                    }
                }
            }
            Button("选择背景图片", systemImage: "photo") {
                backgroundError = nil
                showsBackgroundPicker = true
            }
            if backgroundImage != nil {
                HStack(spacing: 0) {
                    Text("使用背景图片")
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        .contentShape(Rectangle())
                        .onTapGesture { useBackgroundImage.toggle() }
                        .accessibilityHidden(true)
                    Toggle("使用背景图片", isOn: $useBackgroundImage)
                        .labelsHidden()
                        .fixedSize()
                }
                Button("删除背景图片", systemImage: "trash", role: .destructive) {
                    ReaderBackgroundStore.remove()
                    backgroundImage = nil
                    useBackgroundImage = false
                }
            }
            if let backgroundError {
                Text(backgroundError).font(.footnote).foregroundStyle(.red)
            }
        }
    }

    @ViewBuilder private var otherStyleSections: some View {
        Section("翻页动画") {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(Self.pageAnimationChoices, id: \.0) { choice in
                        Button {
                            pageAnimation = choice.value
                        } label: {
                            VStack(spacing: 6) {
                                Image(systemName: choice.icon)
                                    .font(.headline)
                                Text(choice.title)
                                    .font(.caption2)
                            }
                            .foregroundStyle(pageAnimation == choice.value ? ReadingTheme.onAccent : Color.primary)
                            .frame(width: 58, height: 54)
                            .background(
                                pageAnimation == choice.value ? ReadingTheme.accentFill : Color.secondary.opacity(0.1),
                                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                            )
                                .overlay {
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .strokeBorder(pageAnimation == choice.value ? ReadingTheme.selectionBorder : .clear, lineWidth: 1)
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(pageAnimation == choice.value ? .isSelected : [])
                    }
                }
            }
            Text(pageAnimation == 3
                ? "滚动模式连续滚动；其余模式按整屏翻页。左右滑动或点击左右三分之一区域翻页，点击中间区域打开菜单。"
                : "当前模式按整屏翻页；左右滑动或点击左右三分之一区域翻页，点击中间区域打开菜单。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        Section("翻页操作") {
            Button("点击区域设置") {
                showsStyleControls = false
                isAutoReading = false
                showsClickActionSettings = true
            }
            Toggle("顶部返回章首", isOn: $scrollsToTop)
        }
    }

    private static let pageAnimationChoices: [(value: Int, title: String, icon: String)] = [
        (0, "覆盖", "rectangle.on.rectangle"),
        (1, "滑动", "rectangle.portrait.and.arrow.right"),
        (2, "仿真", "book.pages"),
        (3, "滚动", "arrow.up.and.down"),
        (4, "无动画", "rectangle")
    ]

    private func valueSlider(
        _ title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        step: Double = 1,
        marginID: String? = nil,
        format: @escaping (Double) -> String
    ) -> some View {
        ReadingPreviewSlider(title: title, id: marginID ?? title, value: value, range: range,
                             step: step, format: format, activeSlider: $activeSlider)
    }

    @ViewBuilder private func marginGuides(group: String, top: Double, bottom: Double, left: Double, right: Double) -> some View {
        if let activeSlider, activeSlider.id.hasPrefix(group) {
            GeometryReader { geometry in
                ZStack {
                    marginBand(isActive: activeSlider.id == "\(group)上边距")
                        .frame(width: geometry.size.width, height: min(CGFloat(top), geometry.size.height))
                        .frame(maxHeight: .infinity, alignment: .top)
                    marginBand(isActive: activeSlider.id == "\(group)下边距")
                        .frame(width: geometry.size.width, height: min(CGFloat(bottom), geometry.size.height))
                        .frame(maxHeight: .infinity, alignment: .bottom)
                    marginBand(isActive: activeSlider.id == "\(group)左边距")
                        .frame(width: min(CGFloat(left), geometry.size.width), height: geometry.size.height)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    marginBand(isActive: activeSlider.id == "\(group)右边距")
                        .frame(width: min(CGFloat(right), geometry.size.width), height: geometry.size.height)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
                .overlay(alignment: .top) {
                    Text("\(activeSlider.id) \(Int(activeSlider.displayValue)) pt")
                        .font(.caption.weight(.semibold))
                        .padding(6)
                        .background(.regularMaterial, in: Capsule())
                }
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }

    private func marginBand(isActive: Bool) -> some View {
        // One muted hue for every edge; only the current edge is emphasized.
        let tint = Color(red: 0.43, green: 0.51, blue: 0.57)
        return tint.opacity(isActive ? 0.22 : 0.09)
            .overlay {
                Rectangle().strokeBorder(tint.opacity(isActive ? 0.6 : 0.24), lineWidth: 1)
            }
    }

    private static let readerTipChoices: [(Int, String)] = [
        (0, "无"), (7, "书名"), (1, "标题"), (2, "时间"), (3, "电量"),
        (10, "电量%"), (4, "页数"), (5, "进度(%)"), (11, "进度(xx/yyy)"),
        (6, "页数及进度"), (8, "时间及电量"), (9, "时间及电量%")
    ]

    private func tipPicker(_ title: String, selection: Binding<Int>) -> some View {
        Picker(title, selection: selection) {
            ForEach(Self.readerTipChoices, id: \.0) { value, name in
                Text(name).tag(value)
            }
        }
    }


    private var clickActions: [Int] {
        // Keep persisted action IDs stable; the removed sync action becomes a no-op.
        [clickActionTL, clickActionTC, clickActionTR, clickActionML, 0, clickActionMR, clickActionBL, clickActionBC, clickActionBR]
            .map { $0 == 12 ? -1 : $0 }
    }

    private static let tapActionChoices: [(Int, String)] = [
        (-1, "无动作"), (0, "菜单"), (1, "下一页"), (2, "上一页"),
        (3, "下一章"), (4, "上一章"), (5, "朗读上一段"), (6, "朗读下一段"),
        (7, "添加书签"), (8, "编辑正文"), (9, "替换(启用/禁用)"), (10, "目录"),
        (11, "搜索正文"), (13, "暂停/继续朗读")
    ]

    private var clickActionSettings: some View {
        ReaderTapZoneEditor(x1: $tapX1, x2: $tapX2, y1: $tapY1, y2: $tapY2,
                            actions: clickActions, choices: Self.tapActionChoices,
                            actionBinding: clickActionBinding) { showsClickActionSettings = false }
    }

    private func clickActionBinding(at index: Int) -> Binding<Int> {
        let binding: Binding<Int> = switch index {
        case 0: $clickActionTL
        case 1: $clickActionTC
        case 2: $clickActionTR
        case 3: $clickActionML
        case 5: $clickActionMR
        case 6: $clickActionBL
        case 7: $clickActionBC
        default: $clickActionBR
        }
        return Binding(
            get: { binding.wrappedValue == 12 ? -1 : binding.wrappedValue },
            set: { binding.wrappedValue = $0 }
        )
    }

    private func handleTapAction(_ action: Int) {
        if isStylePreview {
            showsStyleControls = true
            return
        }
        switch action {
        case 0: showsReaderMenu.toggle()
        case 3: if model.canGoNext { moveChapter(1) }
        case 4: if model.canGoPrevious { moveChapter(-1) }
        case 5: speech.previousSegment()
        case 6: speech.nextSegment()
        case 7: addBookmark()
        case 8:
            guard model.canEditContent else { return }
            showsReaderMenu = false
            editedContent = model.content
            contentEditError = nil
            showsContentEditor = true
        case 9:
            showsReaderMenu = false
            let updatedBook = model.toggleReplaceRules(position: readerPosition)
            Task {
                await library.addOrUpdate(updatedBook)
            }
        case 10:
            showsReaderMenu = false
            showsTableOfContents = true
        case 11:
            showsReaderMenu = false
            showsContentSearch = true
        case 13:
            isAutoReading = false
            guard speech.isSpeaking || speech.isPaused else { toggleSpeech(); return }
            configureSpeech()
            if let engine = selectedHTTPEngine {
                speech.pauseOrResumeHTTP(engine: engine, text: model.content, continuesAcrossChapters: true)
            } else {
                speech.pauseOrResume(text: model.content, continuesAcrossChapters: true)
            }
        default: break
        }
    }


    @ViewBuilder private var screenStyleSection: some View {
                Section("屏幕") {
                    Picker("屏幕方向", selection: $screenOrientation) {
                        Text("跟随系统").tag("0")
                        Text("竖向").tag("1")
                        Text("横向").tag("2")
                        Text("跟随传感器").tag("3")
                        Text("反向竖屏").tag("4")
                        Text("反向横屏").tag("5")
                    }
                    Toggle("阅读时不自动锁屏", isOn: $keepScreenOn)
                    if #available(iOS 16.0, *) {
                        Toggle("阅读时隐藏小横条", isOn: $hideHomeIndicator)
                    }
                    Toggle("隐藏状态栏", isOn: $hideStatusBar)
                }
        Section {
            Toggle("使用系统亮度", isOn: $followsSystemBrightness)
                .onChange(of: followsSystemBrightness) { enabled in
                    if enabled {
                    followsSystemBrightness = true
                    storedReaderBrightness = 0
                    UIScreen.main.brightness = CGFloat(brightnessBeforeReading)
                    readerBrightness = brightnessBeforeReading
                    } else if storedReaderBrightness < 0.05 {
                        brightnessBeforeReading = Double(UIScreen.main.brightness)
                        readerBrightness = max(brightnessBeforeReading, 0.05)
                        storedReaderBrightness = readerBrightness
                    }
                }
            if !followsSystemBrightness {
                Slider(value: readerBrightnessBinding, in: 0.05...1) { Text("阅读亮度") }
                    .accessibilityLabel("阅读亮度")
            }
        } header: { Text("亮度") } footer: {
            Text("开启后由系统控制亮度。手动调节仅在阅读时生效，退出阅读后恢复原先亮度。")
        }
    }

    private var contentEditor: some View {
        ReadingNavigationStack {
            VStack(spacing: 0) {
                TextEditor(text: $editedContent)
                    .font(.body.monospaced())
                    .padding(8)
                if let contentEditError {
                    Text(contentEditError)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .padding(.horizontal)
                        .padding(.bottom, 8)
                }
            }
            .navigationTitle(model.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { showsContentEditor = false }
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button("重置") { refreshEditorFromSource() }
                    Button("保存") { saveEditedContent() }
                        .disabled(editedContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    private func selectionRuleEditor(_ rule: ReplaceRule) -> some View {
        ReplaceRuleEditorView(rule: rule, sampleTitle: model.title, sampleContent: model.content,
                              bookName: model.book.name, sourceURL: book.origin) { _ in
            if !model.usesReplaceRules {
                let updated = model.toggleReplaceRules(position: readerPosition)
                Task { await library.addOrUpdate(updated) }
            } else { model.select(index: model.currentIndex, position: readerPosition) }
        }.environmentObject(replaceRules).readingFormPresentation()
    }

    private func addPurificationRule(_ selected: String) {
        guard !selected.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        stopSpeechIfNeeded()
        isAutoReading = false
        var rule = ReplaceRule(id: Int64(Date().timeIntervalSince1970 * 1000),
                               name: "净化：" + String(selected.replacingOccurrences(of: "\n", with: " ").prefix(20)), pattern: selected)
        rule.isRegex = false
        rule.scope = model.book.name
        selectionRule = rule
    }

    private func refreshCurrentChapter() {
        stopSpeechIfNeeded()
        Task {
            await model.load(rules: replaceRules.rules, forceRefresh: true)
            readerPosition = min(readerPosition, model.content.utf16.count)
        }
    }

    private func refreshEditorFromSource() {
        contentEditError = nil
        Task {
            await model.load(rules: replaceRules.rules, forceRefresh: true)
            editedContent = model.content
            if let error = model.diagnostics.first(where: { $0.severity == .error }) {
                contentEditError = error.message
            }
        }
    }

    private func saveEditedContent() {
        contentEditError = nil
        Task {
            do {
                try await model.saveEditedContent(editedContent)
                readerPosition = min(readerPosition, editedContent.utf16.count)
                showsContentEditor = false
            } catch {
                contentEditError = error.localizedDescription
            }
        }
    }


    private var tableOfContentsDrawer: some View {
        GeometryReader { geometry in
            if showsTableOfContents {
                ZStack(alignment: .leading) {
                    Button { showsTableOfContents = false } label: {
                        Color.black.opacity(0.35).ignoresSafeArea()
                    }
                    .buttonStyle(.plain).accessibilityLabel("关闭目录")
                    tableOfContents
                        .frame(width: min(420, geometry.size.width * 0.88))
                        .frame(maxHeight: .infinity)
                        .background(Color(uiColor: .systemGroupedBackground))
                        .shadow(color: .black.opacity(0.2), radius: 16, x: 4)
                        .offset(x: tocDrag)
                        .simultaneousGesture(DragGesture(minimumDistance: 20)
                            .onChanged { value in
                                guard abs(value.translation.width) > abs(value.translation.height) else { return }
                                tocDrag = min(value.translation.width, 0)
                            }
                            .onEnded { value in
                                if tocDrag < -70 || (tocDrag < 0 && value.predictedEndTranslation.width < -120) {
                                    showsTableOfContents = false
                                }
                                withAnimation(.easeOut(duration: 0.2)) { tocDrag = 0 }
                            })
                        .accessibilityAddTraits(.isModal)
                        .accessibilityAction(.escape) { showsTableOfContents = false }
                        .accessibilityElement(children: .contain)
                        .accessibilityIdentifier("reader.toc.drawer")
                        .transition(.move(edge: .leading))
                }
            }
        }
    }

    private var tableOfContents: some View {
        let read = readChapterTitles
        let cached = downloads.cachedURLs[book.bookUrl] ?? []
        return ScrollViewReader { proxy in
            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("目录").font(.title3.weight(.semibold))
                        Spacer()
                        Button { showsTableOfContents = false } label: {
                            Image(systemName: "xmark").frame(width: 36, height: 36)
                        }.accessibilityLabel("关闭")
                    }
                    HStack {
                        Text(book.name).lineLimit(1)
                        Spacer(minLength: 8)
                        Text("\(tocReadableChapterCount) 章").monospacedDigit()
                    }
                    .font(.caption).foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        TextField("搜索章节", text: $tocSearch)
                            .textInputAutocapitalization(.never).disableAutocorrection(true)
                            .submitLabel(.search)
                        if !tocSearch.isEmpty {
                            Button { tocSearch = "" } label: { Image(systemName: "xmark.circle.fill") }
                                .accessibilityLabel("清除章节搜索")
                        }
                    }
                    .font(.subheadline).padding(10)
                    .background(Color(uiColor: .tertiarySystemFill), in: RoundedRectangle(cornerRadius: 10))
                    HStack(spacing: 4) {
                        Button {
                            tocSearch = ""; tocFilter = 0
                            if let chapter = model.currentChapter { proxy.scrollTo(chapter.id, anchor: .center) }
                        } label: { Image(systemName: "location").frame(width: 40, height: 40) }
                        .accessibilityLabel("定位当前章节").disabled(model.currentChapter == nil)
                        Menu {
                            Picker("章节状态", selection: $tocFilter) {
                                Text("全部章节").tag(0)
                                Text("未读").tag(1)
                                Text("已读").tag(2)
                                Text("已下载").tag(3)
                                Text("可下载").tag(4)
                            }
                        } label: {
                            Label(["全部章节", "未读", "已读", "已下载", "可下载"][tocFilter], systemImage: "line.3.horizontal.decrease")
                        }.accessibilityLabel("筛选章节")
                        Spacer(minLength: 0)
                        Button { tocDescending.toggle() } label: {
                            Image(systemName: "arrow.up.arrow.down").frame(width: 40, height: 40)
                        }.accessibilityLabel(tocDescending ? "切换为正序" : "切换为倒序")
                        if book.origin != "local" {
                            Button { showsTableOfContents = false; showsDownloads = true } label: {
                                Image(systemName: "arrow.down.circle").frame(width: 40, height: 40)
                            }.accessibilityLabel("下载章节")
                                .disabled(!sourceLibrary.sources.contains(where: { $0.id == book.origin }))
                        }
                    }
                    .font(.subheadline)
                }
                .padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 10)
                Divider()
                List(tocChapters) { chapter in
                    if chapter.isVolume {
                        Text(chapter.title).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                            .id(chapter.id)
                    } else {
                        let isCurrent = chapter.id == model.currentChapter?.id
                        let isRead = read.contains(chapter.title)
                        let isDownloaded = book.origin == "local" || cached.contains(chapter.url)
                        Button {
                            guard let index = model.chapters.firstIndex(where: { $0.id == chapter.id }) else { return }
                            stopSpeechIfNeeded()
                            saveProgress(immediate: true)
                            readerJumpPosition = nil
                            pendingChapter = nil
                            spreadStarts[index] = 0
                            previousSpreads[index] = nil
                            model.select(index: index)
                            readerPosition = 0
                            showsTableOfContents = false
                        } label: {
                            BookChapterStatusRow(chapter: chapter, isCurrent: isCurrent, isRead: isRead, isDownloaded: isDownloaded)
                        }
                        .buttonStyle(.plain)
                        .id(chapter.id)
                        .accessibilityIdentifier(isCurrent ? "reader.toc.current" : "reader.toc.chapter.\(chapter.index)")
                        .listRowBackground(isCurrent ? ReadingTheme.accent.opacity(0.08) : Color.clear)
                        .listRowSeparator(.hidden)
                        .listRowInsets(.init(top: 0, leading: 16, bottom: 0, trailing: 16))
                    }
                }
                .listStyle(.plain).readingScrollContentBackgroundHidden()
                .id(tocFilter)
                .overlay {
                    if tocChapters.isEmpty { Text("没有符合条件的章节").font(.subheadline).foregroundStyle(.secondary) }
                }
                .readingScrollDismissesKeyboard()
                .task(id: "\(model.currentChapter?.id ?? "")|\(tocDescending)|\(tocSearch.isEmpty)|\(model.chapters.count)") {
                    guard tocSearch.isEmpty, tocFilter == 0, let chapter = model.currentChapter else { return }
                    await Task.yield()
                    guard !Task.isCancelled else { return }
                    proxy.scrollTo(chapter.id, anchor: .center)
                }
            }
            .safeAreaInset(edge: .bottom) {
                if let progress = downloads.progress[book.bookUrl], progress.stage != .finished || !progress.failures.isEmpty {
                    BookDownloadProgressView(bookURL: book.bookUrl).padding(16).background(ReadingTheme.groupedCanvas)
                }
            }
            .foregroundStyle(.primary).tint(.primary)
            .background(ReadingTheme.canvas)
        }
    }

    private var tocReadableChapterCount: Int {
        model.chapters.filter { !$0.isVolume }.count
    }

    private var contentSearchSheet: some View {
        ReadingNavigationStack {
            Group {
                if contentSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    ReadingUnavailableView("搜索正文", systemImage: "magnifyingglass", description: Text("输入本章正文关键字"))
                } else if contentSearchResults.isEmpty {
                    ReadingUnavailableView.search(text: contentSearchQuery)
                } else {
                    List(contentSearchResults) { paragraph in
                        Button {
                            readerPosition = paragraph.id
                            readerJumpPosition = nil
                            DispatchQueue.main.async { readerJumpPosition = paragraph.id }
                            showsContentSearch = false
                        } label: {
                            Text(paragraph.text)
                                .foregroundStyle(.primary)
                                .lineLimit(3)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
            }
            .navigationTitle("正文搜索")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $contentSearchQuery, prompt: "搜索本章")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { showsContentSearch = false }
                }
            }
        }
    }

    private var contentSearchResults: [ReaderParagraph] {
        let query = contentSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }
        return model.paragraphs.filter { $0.text.localizedCaseInsensitiveContains(query) }
    }

    private var readChapterTitles: Set<String> {
        let saved = library.books.first(where: { $0.bookUrl == book.bookUrl })?.readConfig?.readChapterTitles
        return Set(saved ?? book.readConfig?.readChapterTitles ?? []).union(visitedChapters)
    }

    private var tocChapters: [BookChapter] {
        let read = readChapterTitles
        let cached = downloads.cachedURLs[book.bookUrl] ?? []
        let eligible = model.chapters.filter { chapter in
            if chapter.isVolume { return tocFilter == 0 }
            switch tocFilter {
            case 1: return !read.contains(chapter.title)
            case 2: return read.contains(chapter.title)
            case 3: return book.origin == "local" || cached.contains(chapter.url)
            case 4: return book.origin != "local" && !cached.contains(chapter.url)
            default: return true
            }
        }
        let query = tocSearch.trimmingCharacters(in: .whitespacesAndNewlines)
        let filtered = query.isEmpty ? eligible : eligible.filter { $0.title.localizedCaseInsensitiveContains(query) }
        return tocDescending ? Array(filtered.reversed()) : filtered
    }


    private var bookmarksSheet: some View {
        ReadingNavigationStack {
            Group {
                let bookmarks = activity.bookmarks(for: book)
                if bookmarks.isEmpty {
                    ReadingUnavailableView(
                        "本书还没有书签",
                        systemImage: "bookmark",
                        description: Text("阅读时点击顶部书签按钮即可记录当前位置。")
                    )
                } else {
                    List(bookmarks) { bookmark in
                        Button {
                            jump(to: bookmark)
                        } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(bookmark.chapterName).font(.headline).foregroundStyle(.primary)
                                if !bookmark.bookText.isEmpty {
                                    Text(bookmark.bookText).font(.subheadline).foregroundStyle(.secondary).lineLimit(3)
                                }
                                Text("位置 \(bookmark.chapterPosition)").font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .swipeActions {
                            Button("删除", role: .destructive) { Task { await activity.removeBookmark(bookmark) } }
                        }
                    }
                }
            }
            .navigationTitle("书签")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { showsBookmarks = false } } }
        }
    }

    private var bookmarkSaved: Bool {
        let page = currentPage - 1
        let range = pageAnimation != 3 && readerPageRanges.indices.contains(page) ? readerPageRanges[page] : nil
        return !model.bookmarks(at: readerPosition, in: activity.bookmarks, pageRange: range).isEmpty
    }

    private func addBookmark() {
        guard !isSavingBookmark, !bookmarkSaved, let chapter = model.currentChapter else { return }
        let currentBook = book
        let position = readerPosition
        let content = model.content
        isSavingBookmark = true
        Task {
            defer { isSavingBookmark = false }
            await activity.addBookmark(
                book: currentBook,
                chapter: chapter,
                position: position,
                content: content
            )
        }
    }

    private func jump(to bookmark: Bookmark) {
        guard let index = bookmark.resolvedChapterIndex(in: model.chapters) else { return }
        stopSpeechIfNeeded()
        pendingChapter = nil
        saveProgress(immediate: true)
        spreadStarts[index] = bookmark.chapterPosition
        previousSpreads[index] = nil
        model.select(index: index, position: bookmark.chapterPosition)
        readerPosition = bookmark.chapterPosition
        readerJumpPosition = nil
        showsBookmarks = false
    }


    private func saveProgress(immediate: Bool = false) {
        guard !isStylePreview else { return }
        guard let chapter = model.currentChapter else { return }
        let position = (speech.isSpeaking || speech.isPaused) ? speech.currentCharacterPosition : readerPosition
        let markRead = !model.content.isEmpty && model.hasLoadedCurrentChapter
        if markRead { visitedChapters.insert(chapter.title) }
        let currentBook = book
        progressSaveGeneration &+= 1
        progressSaveTask?.cancel()
        progressSaveTask = Task { @MainActor [weak library] in
            if !immediate { try? await Task.sleep(nanoseconds: 100_000_000) }
            guard !Task.isCancelled, let library else { return }
            await library.updateProgress(for: currentBook, chapter: chapter, position: position,
                                         markRead: markRead)
        }
    }


    private func stopSpeechIfNeeded() {
        speechStartGeneration &+= 1
        if speech.isSpeaking || speech.isPaused { speech.toggle(text: "") }
    }

    private func restartSpeechAfterReaderLayoutChange() {
        readerPageRanges = []
        guard speech.isSpeaking || speech.isPaused else { return }
        let paused = speech.isPaused
        readerPosition = min(speech.currentCharacterPosition, model.content.utf16.count)
        speechStartGeneration &+= 1
        speech.stop()
        configureSpeech()
        startConfiguredSpeech(startsPaused: paused)
    }

    private func toggleSpeech() {
        isAutoReading = false
        configureSpeech()
        if speech.isSpeaking || speech.isPaused {
            speechStartGeneration &+= 1
            speech.stop()
            speechTimerTask?.cancel()
            speechTimerRemaining = 0
            return
        }
        scheduleSpeechTimer()
        startConfiguredSpeech()
    }

    private func startConfiguredSpeech(startsPaused: Bool = false) {
        if readAloudByPage {
            guard !readerPageRanges.isEmpty else {
                guard !model.content.isEmpty else { return }
                let generation = speechStartGeneration
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    guard generation == speechStartGeneration,
                          readAloudByPage,
                          !speech.isSpeaking,
                          !speech.isPaused else { return }
                    startConfiguredSpeech(startsPaused: startsPaused)
                }
                return
            }
            let pageIndex = readerPageRanges.firstIndex { readerPosition < NSMaxRange($0) }
                ?? max(readerPageRanges.count - 1, 0)
            speechPageIndex = pageIndex
            speakPage(at: pageIndex, from: readerPosition, startsPaused: startsPaused)
            return
        }
        let content = model.content as NSString
        guard content.length > 0 else { return }
        let proposed = min(max(readerPosition, 0), content.length - 1)
        let start = content.rangeOfComposedCharacterSequence(at: proposed).location
        let text = content.substring(from: start)
        if let engine = selectedHTTPEngine {
            speech.speakHTTP(
                engine: engine,
                text: text,
                continuesAcrossChapters: true,
                characterOffset: start, startsPaused: startsPaused
            )
            prefetchNextChapterSpeech(engine: engine)
        } else {
            speech.speak(text, continuesAcrossChapters: true, characterOffset: start, startsPaused: startsPaused)
        }
    }

    private func speakPage(at index: Int, from position: Int? = nil, startsPaused: Bool = false) {
        guard readerPageRanges.indices.contains(index) else {
            continueSpeechToNextChapter()
            return
        }
        let range = readerPageRanges[index]
        let start = min(max(position ?? range.location, range.location), NSMaxRange(range))
        let pageRange = NSRange(location: start, length: max(NSMaxRange(range) - start, 0))
        guard pageRange.length > 0 else {
            continueSpeechToNextPage()
            return
        }
        let pageText = (model.content as NSString).substring(with: pageRange)
        if let engine = selectedHTTPEngine {
            speech.speakHTTP(
                engine: engine,
                text: pageText,
                continuesAcrossChapters: true,
                characterOffset: start, startsPaused: startsPaused
            )
        } else {
            speech.speak(pageText, continuesAcrossChapters: true, characterOffset: start, startsPaused: startsPaused)
        }
    }

    private func continueSpeechToNextPage() {
        guard readAloudByPage, readerPageRanges.indices.contains(speechPageIndex) else {
            continueSpeechToNextChapter()
            return
        }
        readerPosition = NSMaxRange(readerPageRanges[speechPageIndex])
        guard readerPageRanges.indices.contains(speechPageIndex + 1) else {
            continueSpeechToNextChapter()
            return
        }
        speechPageIndex += 1
        let nextPosition = readerPageRanges[speechPageIndex].location
        readerPosition = nextPosition
        readerJumpPosition = nextPosition
        speakPage(at: speechPageIndex)
    }

    private func prefetchNextChapterSpeech(engine: HttpTTS) {
        let generation = speechStartGeneration
        let chapter = model.chapterLoadGeneration
        Task {
            guard let content = await model.nextSpeechContent(
                rules: model.usesReplaceRules ? replaceRules.rules : []
            ), selectedHTTPEngine?.id == engine.id, generation == speechStartGeneration,
               chapter == model.chapterLoadGeneration, speech.isSpeaking || speech.isPaused else { return }
            speech.prefetchHTTP(engine: engine, text: content, limit: 10)
        }
    }

    private func continueSpeechToNextChapter() {
        pendingChapter = nil
        guard model.canGoNext else {
            speechTimerTask?.cancel()
            speechTimerRemaining = 0
            return
        }
        saveProgress(immediate: true)
        resumesSpeechAfterChapterLoad = true
        readerJumpPosition = nil
        model.goNext()
        previousSpreads[model.currentIndex] = nil
        spreadStarts[model.currentIndex] = 0
        readerPosition = model.requestedPosition
    }

    private func moveSpeechToChapter(direction: Int) {
        pendingChapter = nil
        let canMove = direction < 0 ? model.canGoPrevious : model.canGoNext
        guard canMove else { return }
        speech.stop()
        saveProgress(immediate: true)
        resumesSpeechAfterChapterLoad = true
        readerJumpPosition = nil
        if direction < 0 { model.goPrevious() } else { model.goNext() }
        previousSpreads[model.currentIndex] = nil
        spreadStarts[model.currentIndex] = 0
        readerPosition = model.requestedPosition
    }

    private func scheduleSpeechTimer() {
        speechTimerTask?.cancel()
        speechTimerRemaining = ttsTimer
        guard speechTimerRemaining > 0 else { return }
        speechTimerTask = Task { @MainActor in
            do {
                while speechTimerRemaining > 0 {
                    try await Task.sleep(nanoseconds: 60 * 1_000_000_000)
                    if !speech.isSpeaking && !speech.isPaused && !resumesSpeechAfterChapterLoad && chapterScrub?.resumeSpeechPaused == nil {
                        speechTimerRemaining = 0
                        break
                    }
                    if !speech.isPaused, chapterScrub == nil { speechTimerRemaining -= 1 }
                    if speechTimerRemaining == 0 {
                        speech.stop()
                        resumesSpeechAfterChapterLoad = false
                    }
                }
            } catch { }
        }
    }

    private func configureSpeech() {
        speech.configure(
            followsSystemRate: ttsFollowSystem,
            speechRate: ttsSpeechRate,
            readByPage: readAloudByPage,
            streamsHTTPAudio: streamReadAloudAudio,
            voiceIdentifier: systemTTSVoice,
            ignoresAudioFocus: ignoreAudioFocus,
            pausesForPhoneCalls: pauseReadAloudWhilePhoneCalls,
            mediaButtonPerNext: mediaButtonPerNext,
            bookName: model.book.name,
            chapterTitle: model.title,
            author: model.book.author
        )
    }

    private static func globalPageAnimation() -> Int {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: "pageAnim") == nil,
           let legacy = defaults.object(forKey: "readerPageAnimation") as? NSNumber {
            defaults.set(legacy.intValue, forKey: "pageAnim")
        }
        return defaults.integer(forKey: "pageAnim")
    }

    private var selectedHTTPEngine: HttpTTS? {
        let value = model.book.readConfig?.ttsEngine ?? appTTSEngine
        guard let id = Int64(value) else { return nil }
        return httpTTSEngines.first { $0.id == id }
    }

    private var speechSettings: some View {
        let content = model.content as NSString
        let proposed = min(max(readerPosition, 0), max(content.length - 1, 0))
        let start = content.length > 0 ? content.rangeOfComposedCharacterSequence(at: proposed).location : 0
        return SpeechSettingsView(bookName: book.name, bookEngine: bookTTSEngineBinding,
                                  sampleText: String(content.substring(from: start).prefix(160)), remainingMinutes: speechTimerRemaining)
            .onAppear { if speech.isSpeaking { handleTapAction(13) } }
            .onDisappear { Task { await loadHTTPEngines() } }
    }

    private var bookTTSEngineBinding: Binding<String> {
        Binding(
            get: { model.book.readConfig?.ttsEngine ?? "__global__" },
            set: { value in
                let updated = model.setTTSEngine(value == "__global__" ? nil : value)
                restartSpeechAfterReaderLayoutChange()
                Task { await library.addOrUpdate(updated) }
            }
        )
    }

    private func loadHTTPEngines() async {
        guard let database = try? LegadoDatabase(url: LegadoDatabase.defaultURL()) else { return }
        let repository = SQLiteConfigurationRepository(database: database)
        var values = (try? await repository.loadHttpTTS()) ?? []
        if values.isEmpty,
           let url = Bundle.main.url(forResource: "httpTTS", withExtension: "json"),
           let data = try? Data(contentsOf: url),
           let defaults = try? JSONDecoder().decode([HttpTTS].self, from: data) {
            values = defaults
            try? await repository.saveHttpTTS(values)
        }
        httpTTSEngines = values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        if !appTTSEngine.isEmpty, !values.contains(where: { String($0.id) == appTTSEngine }) { appTTSEngine = "" }
    }
}

#if DEBUG
private struct ReaderFailureTestLoader: ChapterContentLoading {
    func loadContent(book: Book, chapter: BookChapter, source: BookSource, nextChapterURL: String?, maxPages: Int) async -> ChapterContentReport {
        .init(content: ProcessInfo.processInfo.arguments.contains("-uiReaderPartialFailure") ? "本章只加载了第一页正文。" : "",
              diagnostics: [.init(severity: .error, code: "content.request", message: "测试书源正文请求失败", rule: chapter.url)])
    }
}
#endif
