import SwiftUI

@MainActor
final class ExploreSourceViewModel: ObservableObject {
    enum State: Equatable { case idle, loading, ready, empty, failed }

    let source: BookSource
    @Published private(set) var kinds: [ExploreKind] = []
    @Published private(set) var selectedKind: ExploreKind?
    @Published private(set) var books: [SearchBook] = []
    @Published private(set) var diagnostics: [RuleDiagnostic] = []
    @Published private(set) var state: State = .idle
    @Published private(set) var isLoadingMore = false

    private let service: BookExploreService
    private var page = 1
    private var canLoadMore = false
    private var paginationTask: Task<Void, Never>?

    init(source: BookSource, service: BookExploreService = .init()) {
        self.source = source
        self.service = service
    }

    deinit { paginationTask?.cancel() }

    func load() async {
        guard state == .idle else { return }
        await reload()
    }

    func reload() async {
        paginationTask?.cancel()
        selectedKind = nil
        kinds = []
        books = []
        diagnostics = []
        page = 1
        canLoadMore = false
        state = .loading

        let report = await service.kinds(for: source)
        guard !Task.isCancelled else { return }
        kinds = report.kinds.filter { $0.navigableURL != nil }
        diagnostics = report.diagnostics
        guard let first = kinds.first else {
            state = diagnostics.contains(where: { $0.severity == .error }) ? .failed : .empty
            return
        }
        await select(kind: first)
    }

    func select(kind: ExploreKind) async {
        guard kind.navigableURL != nil else { return }
        paginationTask?.cancel()
        selectedKind = kind
        books = []
        diagnostics = []
        page = 1
        canLoadMore = false
        state = .loading

        if ProcessInfo.processInfo.arguments.contains("-uiDemo") {
            books = DemoContent.exploreBooks
            state = .ready
            canLoadMore = true
            return
        }

        let outcome = await service.explore(source: source, kind: kind, page: page)
        guard !Task.isCancelled, selectedKind?.id == kind.id else { return }
        diagnostics = outcome.diagnostics
        books = outcome.books
        canLoadMore = !outcome.books.isEmpty
        state = books.isEmpty ? (outcome.diagnostics.isEmpty ? .empty : .failed) : .ready
    }

    func loadNextPageIfNeeded(current book: SearchBook) {
        guard book.id == books.last?.id,
              canLoadMore,
              !isLoadingMore,
              let kind = selectedKind else { return }
        isLoadingMore = true
        let nextPage = page + 1
        paginationTask = Task { [service, source] in
            if ProcessInfo.processInfo.arguments.contains("-uiDemo") {
                try? await Task.sleep(nanoseconds: 300_000_000)
                guard !Task.isCancelled else { return }
                canLoadMore = false
                isLoadingMore = false
                return
            }
            let outcome = await service.explore(source: source, kind: kind, page: nextPage)
            guard !Task.isCancelled, selectedKind?.id == kind.id else {
                isLoadingMore = false
                return
            }
            let knownURLs = Set(books.map(\.bookURL))
            books.append(contentsOf: outcome.books.filter { !knownURLs.contains($0.bookURL) })
            diagnostics += outcome.diagnostics
            page = nextPage
            canLoadMore = !outcome.books.isEmpty
            isLoadingMore = false
        }
    }
}

struct ExploreView: View {
    @EnvironmentObject private var sourceLibrary: SourceLibraryModel

    private var sources: [BookSource] {
        sourceLibrary.sources
            .filter { $0.enabled && $0.enabledExplore && !($0.exploreUrl?.isEmpty ?? true) }
            .sorted {
                if $0.customOrder != $1.customOrder { return $0.customOrder < $1.customOrder }
                return $0.bookSourceName.localizedStandardCompare($1.bookSourceName) == .orderedAscending
            }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ReadingPageHeader(title: "发现") {
                    NavigationLink { SearchView() } label: {
                        ReadingToolbarIcon(systemName: "magnifyingglass")
                    }
                    .accessibilityLabel("搜索")
                }
                VStack(alignment: .leading, spacing: 24) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("分类与榜单").font(.title3.bold())
                            .accessibilityAddTraits(.isHeader)
                        Spacer()
                        Text("\(sources.count)个书源").font(.caption).foregroundStyle(.secondary)
                    }
                    if sources.isEmpty {
                        ReadingUnavailableView {
                            Label("暂无发现书源", systemImage: "books.vertical")
                        } description: {
                            Text("添加带有发现分类的书源，即可在这里浏览书籍。")
                        } actions: {
                            NavigationLink("管理书源") { SourceManagementView() }
                                .readingProminentButtonStyle()
                        }
                    } else {
                        LazyVStack(spacing: 0) {
                            ForEach(sources) { source in
                                NavigationLink { ExploreSourceView(source: source) } label: {
                                    HStack(spacing: 12) {
                                        ExploreSourceRow(source: source)
                                        Spacer(minLength: 0)
                                        Image(systemName: "chevron.right")
                                            .font(.caption).foregroundStyle(.tertiary)
                                    }
                                    .padding(.vertical, 8)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                if source.id != sources.last?.id {
                                    Rectangle().fill(ReadingTheme.separator).frame(height: 0.5)
                                        .padding(.leading, 58)
                                }
                            }
                        }
                    }
                    NavigationLink { SourceManagementView() } label: {
                        HStack(spacing: 14) {
                            Image(systemName: "slider.horizontal.3")
                                .font(.system(size: 20))
                                .frame(width: 40, height: 44)
                            VStack(alignment: .leading, spacing: 5) {
                                Text("管理书源").font(.subheadline.weight(.semibold))
                                Text("添加与整理阅读来源").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                            Image(systemName: "arrow.up.right").font(.subheadline)
                        }
                        .foregroundStyle(ReadingTheme.ink)
                        .padding(18)
                        .background(ReadingTheme.groupedCanvas, in: RoundedRectangle(cornerRadius: 18))
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 32)
            }
        }
        .background(ReadingTheme.canvas)
        .navigationBarHidden(true)
    }
}

private struct ExploreSourceRow: View {
    let source: BookSource

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: source.bookSourceType == 1 ? "headphones" : "books.vertical")
                .font(.system(size: 20))
                .foregroundStyle(ReadingTheme.accent)
                .frame(width: 44, height: 48)
                .background(ReadingTheme.groupedCanvas, in: RoundedRectangle(cornerRadius: 12))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(source.bookSourceName)
                    .font(.body.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                Text(source.groups.isEmpty ? (URL(string: source.bookSourceUrl)?.host ?? source.bookSourceUrl) : source.groups.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 7)
        .contentShape(Rectangle())
    }
}

private struct ExploreSourceView: View {
    @StateObject private var model: ExploreSourceViewModel

    init(source: BookSource) {
        _model = StateObject(wrappedValue: ExploreSourceViewModel(source: source))
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                if model.kinds.count > 1 { kindPicker }
                content
                if model.isLoadingMore { ProgressView("继续加载…").padding(.vertical, 12) }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .background(ReadingTheme.canvas)
        .navigationTitle(model.source.bookSourceName)
        .navigationBarTitleDisplayMode(.inline)
        .task { await model.load() }
        .refreshable { await model.reload() }
    }

    private var kindPicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(model.kinds) { kind in
                    Button(kind.title) { Task { await model.select(kind: kind) } }
                        .font(.subheadline.weight(.medium))
                        .padding(.horizontal, 12)
                        .frame(minHeight: 44)
                        .foregroundStyle(model.selectedKind?.id == kind.id ? Color.primary : .secondary)
                        .overlay(alignment: .bottom) {
                            if model.selectedKind?.id == kind.id {
                                Rectangle().fill(Color.primary).frame(height: 2)
                            }
                        }
                        .accessibilityAddTraits(model.selectedKind?.id == kind.id ? .isSelected : [])
                }
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .idle, .loading:
            ProgressView("正在加载小说…")
                .frame(maxWidth: .infinity)
                .padding(.vertical, 80)
        case .empty:
            ReadingUnavailableView(
                "暂无小说",
                systemImage: "books.vertical",
                description: Text("当前书源或分类暂时没有内容，可以下拉刷新。")
            )
            .padding(.vertical, 40)
        case .failed where model.books.isEmpty:
            ReadingUnavailableView(
                "加载失败",
                systemImage: "exclamationmark.triangle",
                description: Text(model.diagnostics.first?.message ?? "书源发现规则解析失败。")
            )
            .padding(.vertical, 40)
        default:
            ForEach(model.books) { book in
                NavigationLink {
                    BookDetailView(searchBook: book, source: model.source)
                } label: {
                    ExploreBookRow(book: book)
                }
                .buttonStyle(.plain)
                .onAppear { model.loadNextPageIfNeeded(current: book) }
            }
        }
    }
}

private struct ExploreBookRow: View {
    let book: SearchBook

    var body: some View {
        HStack(alignment: .top, spacing: 13) {
            BookCoverArtwork(title: book.name, author: book.author, remoteURL: book.coverURL, width: 52, height: 74)
            VStack(alignment: .leading, spacing: 6) {
                Text(book.name)
                    .font(.body.weight(.medium))
                    .foregroundStyle(ReadingTheme.ink)
                    .lineLimit(2)
                Text(book.author.isEmpty ? "未知作者" : book.author)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if let kind = book.kind, !kind.isEmpty {
                    Text(kind)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if let intro = book.intro, !intro.isEmpty {
                    Text(intro)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
                .padding(.top, 4)
        }
        .padding(.vertical, 12)
        .overlay(alignment: .bottom) {
            Rectangle().fill(ReadingTheme.separator).frame(height: 0.5)
                .padding(.leading, 65)
        }
    }
}
