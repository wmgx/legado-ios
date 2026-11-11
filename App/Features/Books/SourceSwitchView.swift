import SwiftUI

@MainActor
final class SourceSwitchViewModel: ObservableObject {
    enum State: Equatable { case idle, searching, ready, empty }

    @Published private(set) var state: State = .idle
    @Published private(set) var candidates: [BookSourceCandidate] = []
    @Published private(set) var switchingID: String?
    @Published private(set) var errorMessage: String?
    @Published private(set) var verified: [String: BookSourceSwitchReport] = [:]
    @Published private(set) var checked = Set<String>()

    private let book: Book
    var bookName: String { book.name }
    private let service: BookSourceSwitchService
    private var selectionGeneration = 0

    init(book: Book, service: BookSourceSwitchService = .init(), candidates: [BookSourceCandidate] = []) {
        self.book = book
        self.service = service
        self.candidates = candidates
        state = candidates.isEmpty ? .idle : .ready
    }

    func load(sources: [BookSource]) async {
        guard state == .idle else { return }
        state = .searching
        let generation = selectionGeneration
        for await update in await service.validatedCandidateUpdates(for: book, sources: sources) {
            guard !Task.isCancelled else { state = candidates.isEmpty ? .idle : .ready; return }
            guard generation == selectionGeneration else { return }
            switch update {
            case .checking(let candidate): candidates.append(candidate)
            case .checked(let candidate, let report):
                checked.insert(candidate.id)
                verified[candidate.id] = report
            }
        }
        guard !Task.isCancelled else { state = candidates.isEmpty ? .idle : .ready; return }
        state = candidates.isEmpty ? .empty : .ready
    }

    func select(_ candidate: BookSourceCandidate, sources: [BookSource]) async -> (BookSourceSwitchReport, BookSource)? {
        guard switchingID == nil, let report = verified[candidate.id],
              let source = sources.first(where: { $0.bookSourceUrl == candidate.book.origin }) else { return nil }
        switchingID = candidate.id
        let generation = selectionGeneration
        errorMessage = nil
        defer { switchingID = nil }
        do { try await service.saveDirectory(for: report) }
        catch {
            errorMessage = "换源目录保存失败，已保留当前书源和进度。\(error.localizedDescription)"
            return nil
        }
        guard generation == selectionGeneration, !Task.isCancelled else { return nil }
        return (report, source)
    }

    func retry(_ candidate: BookSourceCandidate, sources: [BookSource]) async {
        guard checked.contains(candidate.id), verified[candidate.id] == nil,
              let source = sources.first(where: { $0.id == candidate.book.origin }) else { return }
        let generation = selectionGeneration
        checked.remove(candidate.id)
        let report = await service.prepareSwitch(current: book, candidate: candidate.book, source: source, persistsDirectory: false)
        guard generation == selectionGeneration, !Task.isCancelled else { return }
        checked.insert(candidate.id)
        verified[candidate.id] = report
    }

    var sortedCandidates: [BookSourceCandidate] {
        candidates.sorted {
            let left = verified[$0.id] != nil ? 0 : checked.contains($0.id) ? 2 : 1
            let right = verified[$1.id] != nil ? 0 : checked.contains($1.id) ? 2 : 1
            return left == right ? $0.score > $1.score : left < right
        }
    }

    func clearError() { errorMessage = nil }
    func cancelSelection() { selectionGeneration &+= 1 }
}

struct SourceSwitchView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model: SourceSwitchViewModel
    let sources: [BookSource]
    let onSwitched: @MainActor (BookSourceSwitchReport, BookSource) -> Void

    init(
        book: Book,
        sources: [BookSource],
        demoCandidates: [BookSourceCandidate] = [],
        onSwitched: @escaping @MainActor (BookSourceSwitchReport, BookSource) -> Void
    ) {
        self.sources = sources
        self.onSwitched = onSwitched
        _model = StateObject(wrappedValue: SourceSwitchViewModel(book: book, candidates: demoCandidates))
    }

    var body: some View {
        Group {
            if model.candidates.isEmpty && (model.state == .searching || model.state == .idle) {
                VStack(spacing: 14) {
                    ProgressView()
                    Text("正在查找同名作品并校验目录、正文…").foregroundStyle(.secondary)
                }
            } else if model.state == .empty {
                ReadingUnavailableView(
                    "没有可用换源",
                    systemImage: "arrow.triangle.2.circlepath",
                    description: Text("仅显示书名一致的候选，并优先匹配作者。请确认其他书源已启用且支持搜索。")
                )
            } else {
                List {
                    if model.state == .searching {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text("正在查找并校验，已通过的结果可直接换源")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    ForEach(model.sortedCandidates) { candidate in candidateRow(candidate) }
                }
                .listStyle(.insetGrouped)
                .readingScrollContentBackgroundHidden()
                .background(ReadingTheme.canvas)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(ReadingTheme.canvas)
        .navigationTitle("为《\(model.bookName)》换源")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
        }
        .task { await model.load(sources: sources) }
        .onDisappear { model.cancelSelection() }
        .alert("换源失败", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.clearError() } }
        )) {
            Button("好") { model.clearError() }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    private func candidateRow(_ candidate: BookSourceCandidate) -> some View {
        let available = model.verified[candidate.id] != nil
        let failed = model.checked.contains(candidate.id) && !available
        return HStack {
            Button {
                Task {
                    if let (report, source) = await model.select(candidate, sources: sources) {
                        onSwitched(report, source)
                        dismiss()
                    }
                }
            } label: {
                HStack(spacing: 13) {
                    Image(systemName: "network")
                        .foregroundStyle(ReadingTheme.accent)
                        .frame(width: 42, height: 42)
                        .background(ReadingTheme.accentSoft.opacity(0.55), in: RoundedRectangle(cornerRadius: 13))
                    VStack(alignment: .leading, spacing: 5) {
                        Text(candidate.book.originName).font(.headline).foregroundStyle(.primary)
                        Text(candidate.book.author.isEmpty ? "作者信息缺失" : candidate.book.author)
                            .font(.subheadline).foregroundStyle(.secondary)
                        Text(available ? "目录和当前章节正文可读" : failed ? "目录或正文验证失败，暂不可用" : "正在校验目录和当前章节正文…")
                            .font(.caption).foregroundStyle(available ? .green : .secondary)
                        if let latest = candidate.book.latestChapterTitle, !latest.isEmpty {
                            Text(latest).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    Spacer()
                    if model.switchingID == candidate.id || !model.checked.contains(candidate.id) {
                        ProgressView()
                    } else if available {
                        Image(systemName: "arrow.right.circle.fill").foregroundStyle(ReadingTheme.coral)
                    } else {
                        Image(systemName: "exclamationmark.circle").foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 5)
            }
            .disabled(model.switchingID != nil || !available)
            .accessibilityIdentifier("sourceSwitch.candidate.\(candidate.id)")
            if failed {
                Button("重试") { Task { await model.retry(candidate, sources: sources) } }
                    .buttonStyle(.borderless)
                    .disabled(model.switchingID != nil)
            }
        }
    }
}
