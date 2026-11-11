import SwiftUI
#if SWIFT_PACKAGE
import LegadoCore
#endif

@MainActor
final class BookDetailViewModel: ObservableObject {
    enum State: Equatable { case idle, loading, findingSource, ready, failed }

    @Published private(set) var state: State = .idle
    @Published private(set) var book: Book
    @Published private(set) var chapters: [BookChapter] = []
    @Published private(set) var diagnostics: [RuleDiagnostic] = []

    @Published private(set) var source: BookSource
    private var searchBook: SearchBook?
    private let service: NetworkBookService
    private let updateCoordinator: BookUpdateCoordinator
    private let sourceSwitchService: BookSourceSwitchService

    init(
        searchBook: SearchBook,
        source: BookSource,
        service: NetworkBookService = .init(),
        chapterRepository: any BookChapterRepository = AppBookChapterRepository.live()
    ) {
        self.searchBook = searchBook
        self.source = source
        self.service = service
        let chapters = chapterRepository
        updateCoordinator = BookUpdateCoordinator(repository: chapters, loader: service)
        sourceSwitchService = BookSourceSwitchService(
            detailLoader: service,
            chapterLoader: service,
            contentLoader: service,
            chapterRepository: chapters
        )
        var book = Book(
            bookUrl: searchBook.bookURL,
            name: searchBook.name,
            author: searchBook.author,
            origin: source.bookSourceUrl
        )
        book.originName = source.bookSourceName
        book.coverUrl = searchBook.coverURL
        book.intro = searchBook.intro
        book.kind = searchBook.kind
        self.book = book
    }

    init(book: Book, source: BookSource, service: NetworkBookService = .init()) {
        searchBook = nil
        self.book = book
        self.source = source
        self.service = service
        let chapters = AppBookChapterRepository.live()
        updateCoordinator = BookUpdateCoordinator(repository: chapters, loader: service)
        sourceSwitchService = BookSourceSwitchService(
            detailLoader: service,
            chapterLoader: service,
            contentLoader: service,
            chapterRepository: chapters
        )
    }

    init(demoBook: Book, source: BookSource, chapters: [BookChapter]) {
        searchBook = nil
        book = demoBook
        self.source = source
        service = .init()
        updateCoordinator = .init()
        sourceSwitchService = .init()
        self.chapters = chapters
        state = .ready
    }

    func load(sources: [BookSource] = []) async {
        guard state == .idle else { return }
        state = .loading
        if searchBook == nil {
            let stored = await updateCoordinator.storedChapters(bookURL: book.bookUrl)
            if !stored.isEmpty {
                chapters = stored
                state = .ready
            }
        }
        if let searchBook {
            let detail = await service.loadDetail(searchBook: searchBook, source: source)
            let details = detail.book
            book.name = details.name
            book.author = details.author
            book.originName = details.originName
            if !details.tocUrl.isEmpty { book.tocUrl = details.tocUrl }
            book.type = details.type
            book.kind = details.kind ?? book.kind
            book.coverUrl = details.coverUrl ?? book.coverUrl
            book.intro = details.intro ?? book.intro
            book.charset = details.charset ?? book.charset
            book.wordCount = details.wordCount ?? book.wordCount
            book.latestChapterTitle = details.latestChapterTitle ?? book.latestChapterTitle
            book.originOrder = details.originOrder
            book.variable = details.variable ?? book.variable
            diagnostics += detail.diagnostics
        }
        let toc = await updateCoordinator.refresh(book: book, source: source)
        if !toc.chapters.isEmpty { chapters = toc.chapters }
        diagnostics += toc.diagnostics
        book = toc.book
        if !chapters.isEmpty {
            state = .ready
            return
        }

        state = .findingSource
        if let available = await sourceSwitchService.firstAvailableSource(for: book, sources: sources) {
            applySourceSwitch(available.report, source: available.source)
        } else {
            state = .failed
        }
    }

    func applySourceSwitch(_ report: BookSourceSwitchReport, source: BookSource) {
        searchBook = nil
        book = report.book
        chapters = report.chapters
        diagnostics = report.diagnostics
        self.source = source
        state = .ready
    }

    func toggleCanUpdate() { book.canUpdate.toggle() }

    func restoreLibraryBook(from stored: Book, sources: [BookSource] = []) {
        guard state == .idle, stored.bookUrl == book.bookUrl else { return }
        if stored.origin != source.id,
           let resolved = sources.first(where: { $0.id == stored.origin }) {
            source = resolved
            searchBook = nil
        }
        book = stored
        book.origin = source.id
        book.originName = source.bookSourceName
    }

    func restoreSourceAfterReading(from books: [Book], sources: [BookSource]) {
        guard state == .ready,
              let stored = books.first(where: { $0.bookUrl == book.bookUrl })
                ?? books.first(where: { $0.name == book.name && $0.author == book.author }),
              stored.bookUrl != book.bookUrl || stored.origin != book.origin,
              let source = sources.first(where: { $0.id == stored.origin }) else { return }
        book = stored
        self.source = source
        searchBook = nil
        chapters = []
        diagnostics = []
        state = .idle
    }

    func restoreUserSettings(from stored: Book) {
        guard stored.bookUrl == book.bookUrl else { return }
        book.group = stored.group
        book.order = stored.order
        book.customTag = stored.customTag
        book.customCoverUrl = stored.customCoverUrl
        book.customIntro = stored.customIntro
        book.canUpdate = stored.canUpdate
        book.readConfig = stored.readConfig
        book.syncTime = stored.syncTime
    }

    func restoreReadingProgress(from stored: Book) {
        guard stored.bookUrl == book.bookUrl, stored.durChapterTime > book.durChapterTime else { return }
        let chapterIndex = stored.durChapterTitle.flatMap { title in
            chapters.firstIndex { !$0.isVolume && $0.title == title }
        } ?? stored.durChapterIndex
        guard chapters.indices.contains(chapterIndex), !chapters[chapterIndex].isVolume else { return }
        book.durChapterIndex = chapterIndex
        book.durChapterTitle = chapters[chapterIndex].title
        book.durChapterPos = stored.durChapterPos
        book.durChapterTime = stored.durChapterTime
    }

    func refresh(sources: [BookSource] = []) async {
        chapters = []
        diagnostics = []
        state = .idle
        await load(sources: sources)
    }

}
