import CryptoKit
import Foundation

public struct CachedChapterContent: Codable, Equatable, Sendable {
    public var bookURL: String
    public var chapterURL: String
    public var title: String?
    public var content: String
    public var supplementalContent: String?
    public var savedAt: Int64
    public var sourceID: String?

    public init(
        bookURL: String,
        chapterURL: String,
        title: String? = nil,
        content: String,
        supplementalContent: String? = nil,
        savedAt: Int64 = Int64(Date().timeIntervalSince1970 * 1_000),
        sourceID: String? = nil
    ) {
        self.bookURL = bookURL
        self.chapterURL = chapterURL
        self.title = title
        self.content = content
        self.supplementalContent = supplementalContent
        self.savedAt = savedAt
        self.sourceID = sourceID
    }
}

public enum ChapterContentCacheError: Error, LocalizedError, Equatable {
    case entryTooLarge(Int)
    case invalidEntry

    public var errorDescription: String? {
        switch self {
        case .entryTooLarge(let maximum): "章节正文超过缓存上限 \(maximum / 1_024 / 1_024) MB"
        case .invalidEntry: "章节缓存内容无效"
        }
    }
}

public actor ChapterContentCache {
    public static let maximumEntryBytes = 8 * 1_024 * 1_024
    public static let defaultMaximumTotalBytes = 256 * 1_024 * 1_024

    private let directory: URL
    private let downloadsDirectory: URL
    private let maximumTotalBytes: Int?

    public init(directory: URL, maximumTotalBytes: Int? = nil, downloadsDirectory: URL? = nil) {
        self.directory = directory
        self.downloadsDirectory = downloadsDirectory ?? directory.appendingPathComponent("Downloads", isDirectory: true)
        self.maximumTotalBytes = maximumTotalBytes.map { max($0, Self.maximumEntryBytes) }
    }

    public static func live() -> ChapterContentCache {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Legado/Chapters", isDirectory: true)
        let downloads = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Legado/Downloads", isDirectory: true)
        return ChapterContentCache(directory: base, downloadsDirectory: downloads)
    }

    public func load(bookURL: String, chapterURL: String) throws -> CachedChapterContent? {
        let saved = fileURL(bookURL: bookURL, chapterURL: chapterURL, downloaded: true)
        let url = FileManager.default.fileExists(atPath: saved.path) ? saved : fileURL(bookURL: bookURL, chapterURL: chapterURL)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            let value = try JSONDecoder().decode(CachedChapterContent.self, from: Data(contentsOf: url, options: .mappedIfSafe))
            guard value.bookURL == bookURL, value.chapterURL == chapterURL, !value.content.isEmpty else {
                try? FileManager.default.removeItem(at: url)
                throw ChapterContentCacheError.invalidEntry
            }
            try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
            return value
        } catch let error as ChapterContentCacheError {
            throw error
        } catch {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
    }

    public func save(_ entry: CachedChapterContent, downloaded: Bool = false) throws {
        guard !entry.bookURL.isEmpty, !entry.chapterURL.isEmpty, !entry.content.isEmpty else {
            throw ChapterContentCacheError.invalidEntry
        }
        let encoder = JSONEncoder()
        let data = try encoder.encode(entry)
        guard data.count <= Self.maximumEntryBytes else {
            throw ChapterContentCacheError.entryTooLarge(Self.maximumEntryBytes)
        }
        let saved = fileURL(bookURL: entry.bookURL, chapterURL: entry.chapterURL, downloaded: true)
        let keepsDownload = downloaded || FileManager.default.fileExists(atPath: saved.path)
        let target = keepsDownload ? saved : fileURL(bookURL: entry.bookURL, chapterURL: entry.chapterURL)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: target, options: .atomic)
        if keepsDownload {
            let temporary = fileURL(bookURL: entry.bookURL, chapterURL: entry.chapterURL)
            if FileManager.default.fileExists(atPath: temporary.path) { try FileManager.default.removeItem(at: temporary) }
        } else { try pruneIfNeeded() }
    }

    public func remove(bookURL: String, includingDownloads: Bool = true) throws {
        let prefix = digest(bookURL) + "-"
        for folder in (includingDownloads ? [directory, downloadsDirectory] : [directory]) where FileManager.default.fileExists(atPath: folder.path) {
            for url in try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
                where url.lastPathComponent.hasPrefix(prefix) {
                try FileManager.default.removeItem(at: url)
            }
        }
    }

    public func remove(bookURL: String, chapterURL: String) throws {
        for downloaded in [false, true] {
            let url = fileURL(bookURL: bookURL, chapterURL: chapterURL, downloaded: downloaded)
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        }
    }

    public func removeAll() throws {
        for folder in [directory, downloadsDirectory] where FileManager.default.fileExists(atPath: folder.path) {
            try FileManager.default.removeItem(at: folder)
        }
    }

    public func statistics() throws -> (entries: Int, bytes: Int) {
        let files = try cacheFiles() + cacheFiles(in: downloadsDirectory)
        return (files.count, files.reduce(0) { $0 + $1.size })
    }

    public func downloadedStatistics() throws -> (entries: Int, bytes: Int) {
        let files = try cacheFiles(in: downloadsDirectory)
        return (files.count, files.reduce(0) { $0 + $1.size })
    }

    public func cachedChapterURLs(bookURL: String, sourceID: String? = nil, downloadedOnly: Bool = false) throws -> Set<String> {
        let prefix = digest(bookURL) + "-"
        var chapters = Set<String>()
        for folder in (downloadedOnly ? [downloadsDirectory] : [directory, downloadsDirectory]) where FileManager.default.fileExists(atPath: folder.path) {
            for url in try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
                where url.lastPathComponent.hasPrefix(prefix) && url.pathExtension == "json" {
                guard let entry = try? JSONDecoder().decode(CachedChapterContent.self, from: Data(contentsOf: url)),
                      entry.bookURL == bookURL, !entry.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      sourceID == nil || entry.sourceID == nil || entry.sourceID == sourceID else { continue }
                chapters.insert(entry.chapterURL)
            }
        }
        return chapters
    }

    public func pruneIfNeeded() throws {
        let maximumTotalBytes = maximumTotalBytes ?? ApplicationSettingsStore.shared.settings.chapterCacheMB * 1024 * 1024
        var files = try cacheFiles().sorted { $0.modified < $1.modified }
        var total = files.reduce(0) { $0 + $1.size }
        while total > maximumTotalBytes, let oldest = files.first {
            try FileManager.default.removeItem(at: oldest.url)
            total -= oldest.size
            files.removeFirst()
        }
    }

    private func cacheFiles(in folder: URL? = nil) throws -> [(url: URL, size: Int, modified: Date)] {
        let folder = folder ?? directory
        guard FileManager.default.fileExists(atPath: folder.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ).compactMap { url in
            guard url.pathExtension == "json" else { return nil }
            let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            return (url, values.fileSize ?? 0, values.contentModificationDate ?? .distantPast)
        }
    }

    private func fileURL(bookURL: String, chapterURL: String, downloaded: Bool = false) -> URL {
        (downloaded ? downloadsDirectory : directory).appendingPathComponent("\(digest(bookURL))-\(digest(chapterURL)).json")
    }

    private func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

public protocol ChapterContentLoading: Sendable {
    func loadContent(
        book: Book,
        chapter: BookChapter,
        source: BookSource,
        nextChapterURL: String?,
        maxPages: Int
    ) async -> ChapterContentReport
}

extension NetworkBookService: ChapterContentLoading {}

public struct ChapterCacheJob: Sendable, Equatable {
    public var chapter: BookChapter
    public var nextChapterURL: String?

    public init(chapter: BookChapter, nextChapterURL: String?) {
        self.chapter = chapter
        self.nextChapterURL = nextChapterURL
    }
}

public enum ChapterCachePlanner {
    public static func plan(chapters: [BookChapter], startIndex: Int, limit: Int? = nil) -> [ChapterCacheJob] {
        guard !chapters.isEmpty, limit.map({ $0 > 0 }) ?? true else { return [] }
        let start = min(max(startIndex, 0), chapters.count - 1)
        var jobs: [ChapterCacheJob] = []
        for index in chapters.indices where index >= start && !chapters[index].isVolume {
            let nextURL = chapters[(index + 1)...].first(where: { !$0.isVolume })?.url
            jobs.append(.init(chapter: chapters[index], nextChapterURL: nextURL))
            if let limit, jobs.count >= limit { break }
        }
        return jobs
    }
}

public struct CoordinatedChapterContent: Sendable {
    public var report: ChapterContentReport
    public var loadedFromCache: Bool

    public init(report: ChapterContentReport, loadedFromCache: Bool) {
        self.report = report
        self.loadedFromCache = loadedFromCache
    }
}

public actor ChapterContentCoordinator {
    private let loader: any ChapterContentLoading
    private let cache: ChapterContentCache
    private struct RequestKey: Hashable {
        let bookURL: String
        let chapterURL: String
        let sourceID: String
        let nextChapterURL: String?
        let maxPages: Int
    }
    private struct Request {
        let id: UUID
        let task: Task<CoordinatedChapterContent, Never>
    }
    private var inFlight: [RequestKey: Request] = [:]

    public init(loader: any ChapterContentLoading = NetworkBookService(), cache: ChapterContentCache = .live()) {
        self.loader = loader
        self.cache = cache
    }

    public func load(
        book: Book,
        chapter: BookChapter,
        source: BookSource,
        nextChapterURL: String? = nil,
        maxPages: Int = 20,
        forceRefresh: Bool = false
    ) async -> CoordinatedChapterContent {
        if !forceRefresh, let cached = try? await cache.load(bookURL: book.bookUrl, chapterURL: chapter.url),
                  cached.sourceID == nil || cached.sourceID == source.id {
            return .init(report: .init(
                title: cached.title,
                content: cached.content,
                supplementalContent: cached.supplementalContent
            ), loadedFromCache: true)
        }
        guard !Task.isCancelled else {
            return .init(report: .init(diagnostics: [
                .init(severity: .error, code: "content.cancelled", message: "章节加载已取消", rule: chapter.url)
            ]), loadedFromCache: false)
        }
        let key = RequestKey(bookURL: book.bookUrl, chapterURL: chapter.url, sourceID: source.id,
                             nextChapterURL: nextChapterURL, maxPages: maxPages)
        if forceRefresh {
            inFlight.removeValue(forKey: key)?.task.cancel()
        } else if let request = inFlight[key] {
            return await request.task.value
        }
        let id = UUID()
        // Keep the shared fetch alive if a rolling preload window is cancelled:
        // a foreground chapter load may already be waiting for this same fetch.
        let task = Task { [loader] in
            let report = await loader.loadContent(book: book, chapter: chapter, source: source,
                                                  nextChapterURL: nextChapterURL, maxPages: maxPages)
            await self.saveContent(report, book: book, chapter: chapter, source: source)
            return CoordinatedChapterContent(report: report, loadedFromCache: false)
        }
        inFlight[key] = Request(id: id, task: task)
        let result = await task.value
        if inFlight[key]?.id == id { inFlight[key] = nil }
        return result
    }

    public func saveContent(_ report: ChapterContentReport, book: Book, chapter: BookChapter, source: BookSource) async {
        if !Task.isCancelled, !report.diagnostics.contains(where: { $0.severity == .error }),
           !report.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            try? await cache.save(.init(
                bookURL: book.bookUrl,
                chapterURL: chapter.url,
                title: report.title,
                content: report.content,
                supplementalContent: report.supplementalContent,
                sourceID: source.id
            ))
        }
    }

    public func saveEditedContent(book: Book, chapter: BookChapter, title: String?, content: String) async throws {
        let value = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { throw ChapterContentCacheError.invalidEntry }
        try await cache.save(.init(
            bookURL: book.bookUrl,
            chapterURL: chapter.url,
            title: title,
            content: content,
            sourceID: book.origin
        ))
    }

    @discardableResult
    public func prefetch(
        book: Book,
        chapter: BookChapter,
        source: BookSource,
        nextChapterURL: String? = nil
    ) async -> Bool {
        guard !Task.isCancelled else { return false }
        if let cached = try? await cache.load(bookURL: book.bookUrl, chapterURL: chapter.url),
           cached.sourceID == nil || cached.sourceID == source.id { return false }
        let result = await load(book: book, chapter: chapter, source: source, nextChapterURL: nextChapterURL)
        return !Task.isCancelled && !result.report.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !result.report.diagnostics.contains(where: { $0.severity == .error })
    }

    public func invalidate(bookURL: String) async {
        for key in inFlight.keys.filter({ $0.bookURL == bookURL }) {
            inFlight.removeValue(forKey: key)?.task.cancel()
        }
        try? await cache.remove(bookURL: bookURL, includingDownloads: false)
    }
}
