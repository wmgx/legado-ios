import SwiftUI

struct BookDownloadView: View {
    let book: Book
    let chapters: [BookChapter]
    let source: BookSource
    let startIndex: Int
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var library: BookLibraryModel
    @State private var startError: String?
    @ObservedObject private var downloads = BookDownloadModel.shared
    @State private var wholeBook = true
    @State private var count = "50"

    private var readable: [BookChapter] { chapters.filter { !$0.isVolume } }
    private var number: Int { min(max(Int(count) ?? 0, 0), readable.count) }
    private var cachedCount: Int { readable.filter { downloads.cachedURLs[book.bookUrl]?.contains($0.url) == true }.count }

    var body: some View {
        ReadingNavigationStack {
            Form {
                Section {
                    Text(book.name).font(.headline)
                    ReadingLabeledContent("已下载", value: "\(cachedCount) / \(readable.count) 章")
                }
                if let progress = downloads.progress[book.bookUrl] {
                    Section {
                        BookDownloadProgressView(bookURL: book.bookUrl)
                        if !progress.failures.isEmpty {
                            if let message = progress.failures.values.first {
                                Text(String(message.prefix(160))).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                if downloads.progress[book.bookUrl]?.stage != .downloading {
                    Section {
                        Picker("范围", selection: $wholeBook) {
                            Text("整本书").tag(true)
                            Text("从当前章起").tag(false)
                        }.pickerStyle(.segmented)
                        if !wholeBook {
                            HStack {
                                Text("章节数")
                                TextField("50", text: $count).keyboardType(.numberPad)
                                    .multilineTextAlignment(.trailing).accessibilityIdentifier("download.chapterCount")
                                Text("章").foregroundStyle(.secondary)
                            }
                            HStack {
                                ForEach([10, 50, 100], id: \.self) { value in
                                    Button("\(value) 章") { count = String(value) }
                                        .frame(maxWidth: .infinity, minHeight: 32)
                                }
                            }.buttonStyle(.borderless)
                        }
                        Button("开始下载") {
                            Task {
                                if !library.contains(book) { await library.addOrUpdate(book) }
                                guard library.contains(book) else { startError = library.errorMessage ?? "无法保存到书架"; return }
                                downloads.start(book: book, source: source, chapters: chapters,
                                                startIndex: wholeBook ? 0 : startIndex, limit: wholeBook ? nil : number)
                            }
                        }.disabled(readable.isEmpty || (!wholeBook && number == 0))
                            .accessibilityIdentifier("download.start")
                    } header: { Text("下载范围") } footer: { Text("跳过已有正文，已下载章节不会被自动清理。") }
                }
            }
            .navigationTitle("下载章节").navigationBarTitleDisplayMode(.inline)
            .readingScrollDismissesKeyboard()
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("收起键盘") { UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil) }
                }
            }
        }
        .task { await downloads.refresh(book: book) }
        .alert("无法开始下载", isPresented: Binding(get: { startError != nil }, set: { if !$0 { startError = nil } })) {
            Button("好") { startError = nil }
        } message: { Text(startError ?? "请重试") }
    }
}

struct BookDownloadProgressView: View {
    let bookURL: String
    @ObservedObject private var downloads = BookDownloadModel.shared

    var body: some View {
        if let progress = downloads.progress[bookURL] {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(progress.title).font(.subheadline.weight(.medium))
                    Spacer()
                    Text("\(progress.succeeded.count) / \(progress.total)")
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        .accessibilityIdentifier("download.completed")
                }
                ProgressView(value: Double(progress.succeeded.count), total: Double(max(progress.total, 1)))
                    .tint(ReadingTheme.accent)
                HStack {
                    if progress.stage == .downloading { Button("暂停") { downloads.pause(bookURL) } }
                    else if progress.stage == .paused { Button("继续下载") { downloads.resume(bookURL) } }
                    else if !progress.failures.isEmpty { Button("重试失败章节") { downloads.resume(bookURL) } }
                    Spacer()
                    if !progress.failures.isEmpty { Text("失败 \(progress.failures.count) 章").foregroundStyle(.red) }
                }.font(.caption).buttonStyle(.borderless)
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("章节下载")
            .accessibilityValue("\(progress.succeeded.count)/\(progress.total)")
            .accessibilityIdentifier("download.progress")
        }
    }
}

struct BookChapterStatusRow: View {
    let chapter: BookChapter
    let isCurrent: Bool
    let isRead: Bool
    let isDownloaded: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(chapter.title)
                    .font(isCurrent ? .subheadline.weight(.semibold) : .subheadline)
                    .foregroundStyle(Color.primary.opacity(isRead && !isCurrent ? 0.68 : 1)).lineLimit(2)
                if chapter.isVip {
                    Image(systemName: "lock").font(.caption).foregroundStyle(.secondary).accessibilityLabel("付费章节")
                }
            }
            HStack {
                Text(isCurrent ? "正在阅读" : (isRead ? "已读" : "未读"))
                Spacer()
                Label(isDownloaded ? "已下载" : "可下载", systemImage: isDownloaded ? "checkmark.circle" : "arrow.down.circle")
            }.font(.caption2).foregroundStyle(Color.primary.opacity(0.68))
        }
        .frame(maxWidth: .infinity, minHeight: 38, alignment: .leading)
        .padding(.vertical, 8)
        .overlay(alignment: .bottom) { Rectangle().fill(ReadingTheme.separator).frame(height: 0.5) }
        .contentShape(Rectangle())
    }
}
