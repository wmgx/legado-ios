import SwiftUI
#if SWIFT_PACKAGE
import LegadoCore
#endif

@MainActor
final class BookDownloadModel: ObservableObject {
    static let shared = BookDownloadModel()

    struct Progress {
        enum Stage { case downloading, paused, finished }
        var id = UUID()
        let name: String
        let total: Int
        var succeeded = Set<String>()
        var failures: [String: String] = [:]
        var stage: Stage = .downloading
        var title: String {
            switch stage {
            case .downloading: "正在下载"
            case .paused: "已暂停"
            case .finished:
                if failures.isEmpty { "下载完成" }
                else if succeeded.isEmpty { "下载失败" }
                else { "部分完成" }
            }
        }
    }

    @Published private(set) var progress: [String: Progress] = [:]
    @Published private(set) var cachedURLs: [String: Set<String>] = [:]
    private let cache: ChapterContentCache
    private let coordinator: ChapterContentCoordinator
    private(set) var tasks: [String: Task<Void, Never>] = [:]
    private var requests: [String: (book: Book, source: BookSource, jobs: [ChapterCacheJob])] = [:]

    init(loader: any ChapterContentLoading = NetworkBookService(), cache: ChapterContentCache = .live()) {
        self.cache = cache
        coordinator = .init(loader: loader, cache: cache)
    }

    func refresh(book: Book) async {
        if let urls = try? await cache.cachedChapterURLs(bookURL: book.bookUrl, sourceID: book.origin, downloadedOnly: true) {
            cachedURLs[book.bookUrl] = urls
        }
    }

    func start(book: Book, source: BookSource, chapters: [BookChapter], startIndex: Int, limit: Int?) {
        let jobs = ChapterCachePlanner.plan(chapters: chapters, startIndex: startIndex, limit: limit)
        guard !jobs.isEmpty else { return }
        pause(book.bookUrl)
        requests[book.bookUrl] = (book, source, jobs)
        progress[book.bookUrl] = Progress(name: book.name, total: jobs.count)
        resume(book.bookUrl)
    }

    func pause(_ bookURL: String) {
        tasks.removeValue(forKey: bookURL)?.cancel()
        if progress[bookURL]?.stage == .downloading { progress[bookURL]?.stage = .paused }
    }

    func pauseAll() { for bookURL in Array(tasks.keys) { pause(bookURL) } }

    func reset() {
        pauseAll()
        progress = [:]
        cachedURLs = [:]
        requests = [:]
    }

    func resume(_ bookURL: String) {
        guard let request = requests[bookURL], var state = progress[bookURL] else { return }
        tasks[bookURL]?.cancel()
        let id = UUID()
        state.id = id
        state.stage = .downloading
        state.failures = [:]
        progress[bookURL] = state
        let jobs = request.jobs.filter { !state.succeeded.contains($0.chapter.url) }
        let coordinator = coordinator, cache = cache
        tasks[bookURL] = Task { [weak self] in
            await withTaskGroup(of: (String, String?).self) { group in
                var next = 0
                func enqueue() {
                    guard next < jobs.count else { return }
                    let job = jobs[next]
                    next += 1
                    group.addTask {
                        guard !Task.isCancelled else { return (job.chapter.url, "已暂停") }
                        let loaded = await coordinator.load(book: request.book, chapter: job.chapter,
                                                            source: request.source, nextChapterURL: job.nextChapterURL)
                        guard !Task.isCancelled else { return (job.chapter.url, "已暂停") }
                        let report = loaded.report
                        if let error = report.diagnostics.first(where: { $0.severity == .error }) {
                            return (job.chapter.url, error.message)
                        }
                        guard !report.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                            return (job.chapter.url, "正文为空")
                        }
                        do {
                            try await cache.save(.init(bookURL: bookURL, chapterURL: job.chapter.url, title: report.title,
                                                       content: report.content, supplementalContent: report.supplementalContent,
                                                       sourceID: request.source.id), downloaded: true)
                            return (job.chapter.url, nil)
                        } catch { return (job.chapter.url, error.localizedDescription) }
                    }
                }
                for _ in 0..<min(3, jobs.count) { enqueue() }
                while let (url, error) = await group.next() {
                    guard !Task.isCancelled, let self, self.progress[bookURL]?.id == id,
                          self.progress[bookURL]?.stage == .downloading else { group.cancelAll(); break }
                    if let error { self.progress[bookURL]?.failures[url] = error }
                    else {
                        self.progress[bookURL]?.succeeded.insert(url)
                        self.cachedURLs[bookURL, default: []].insert(url)
                    }
                    enqueue()
                }
            }
            guard !Task.isCancelled, let self, self.progress[bookURL]?.id == id else { return }
            self.progress[bookURL]?.stage = .finished
            self.tasks[bookURL] = nil
        }
    }
}
