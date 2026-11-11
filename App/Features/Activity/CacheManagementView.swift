import SwiftUI

@MainActor
private final class CacheManagementModel: ObservableObject {
    @Published private(set) var entries = 0
    @Published private(set) var bytes = 0
    @Published private(set) var downloadedEntries = 0
    @Published private(set) var downloadedBytes = 0
    @Published private(set) var isWorking = false
    @Published var errorMessage: String?
    private let cache = ChapterContentCache.live()

    func load() async {
        do {
            let statistics = try await cache.statistics()
            let downloaded = try await cache.downloadedStatistics()
            entries = statistics.entries
            bytes = statistics.bytes
            downloadedEntries = downloaded.entries
            downloadedBytes = downloaded.bytes
        } catch { errorMessage = error.localizedDescription }
    }

    func clear() async {
        isWorking = true
        defer { isWorking = false }
        BookDownloadModel.shared.pauseAll()
        do {
            try await cache.removeAll()
            BookDownloadModel.shared.reset()
            await load()
        } catch { errorMessage = error.localizedDescription }
    }
}

struct CacheManagementView: View {
    @StateObject private var model = CacheManagementModel()
    @State private var confirmsClear = false
    @State private var settings = ApplicationSettingsStore.shared.settings

    var body: some View {
        List {
            Section("阅读缓存") {
                Picker("容量上限", selection: cacheSetting(\.chapterCacheMB)) {
                    ForEach([16, 32, 64, 128, 256, 512, 1024, 2048, 4096], id: \.self) {
                        Text($0 >= 1024 ? "\($0 / 1024) GB" : "\($0) MB").tag($0)
                    }
                }
                Stepper(settings.prefetchChapters == 0 ? "关闭章节预加载" : "预加载 \(settings.prefetchChapters) 章", value: cacheSetting(\.prefetchChapters), in: 0...20)
                Text("默认提前缓存后续 10 章，翻章或滚动进入下一章时继续补齐；已缓存章节不重复下载。")
                    .font(.footnote).foregroundStyle(.secondary)
                Text("修改后立即生效。超限后清理临时缓存，不影响主动下载的章节。")
                    .font(.footnote).foregroundStyle(.secondary)
            }

            Section {
                ReadingLabeledContent("已下载", value: "\(model.downloadedEntries) 章")
                ReadingLabeledContent("占用空间", value: size(model.downloadedBytes))
            } header: { Text("离线下载") } footer: { Text("主动下载的章节不会被自动清理。") }
            Section {
                ReadingLabeledContent("已缓存", value: "\(max(model.entries - model.downloadedEntries, 0)) 章")
                ReadingLabeledContent("占用空间", value: size(max(model.bytes - model.downloadedBytes, 0)))
            } header: { Text("阅读缓存") } footer: { Text("阅读与预加载产生的临时正文，超出容量后自动清理。") }
            Section {
                NavigationLink("存储维护") { StorageMaintenanceView() }
            }
            Section {
                Button("清空下载和缓存", role: .destructive) { confirmsClear = true }
                    .disabled(model.entries == 0 || model.isWorking)
                    .confirmationDialog("清空下载和缓存？", isPresented: $confirmsClear, titleVisibility: .visible) {
                        Button("清空", role: .destructive) { Task { await model.clear() } }
                        Button("取消", role: .cancel) {}
                    } message: { Text("网络正文需要重新下载，本地导入的文件会保留。") }
            }
        }
        .navigationTitle("存储空间")
        .task { await model.load() }
        .overlay { if model.isWorking { ProgressView() } }
        .alert("存储操作失败", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("好") { model.errorMessage = nil }
        } message: { Text(model.errorMessage ?? "请重试") }
    }

    private func cacheSetting(_ keyPath: WritableKeyPath<ApplicationSettings, Int>) -> Binding<Int> {
        Binding(get: { settings[keyPath: keyPath] }, set: { value in
            var updated = ApplicationSettingsStore.shared.settings
            updated[keyPath: keyPath] = value
            do {
                try ApplicationSettingsStore.shared.save(updated)
                settings = updated
                Task {
                    do { try await ChapterContentCache.live().pruneIfNeeded(); await model.load() }
                    catch { model.errorMessage = error.localizedDescription }
                }
            } catch { model.errorMessage = error.localizedDescription }
        })
    }

    private func size(_ bytes: Int) -> String { ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file) }
}
