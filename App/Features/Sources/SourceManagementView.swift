import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct SourceManagementView: View {
    @EnvironmentObject private var library: SourceLibraryModel
    @Environment(\.dismiss) private var dismiss
    @State private var showsImporter = false
    @State private var pickedImportFiles: [SourceImportFile] = []
    @State private var importPickerHasDismissed = true
    @State private var showsNewSource = false
    @State private var showsQRImporter = false
    @State private var showsTextImporter = false
    @State private var showsGroupManager = false
    @State private var showsBatchGroups = false
    @State private var showsBatchTest = false
    @State private var testSourceIDs: Set<String> = []
    @State private var confirmsDelete = false
    @State private var exportsFile = false
    @State private var exportDocument = ConfigurationJSONDocument(data: Data("[]".utf8))
    @State private var selectedGroup: String?
    @State private var searchText = ""
    @State private var isSelecting = false
    @State private var selectedSourceIDs = Set<String>()
    @AppStorage("bookSourceSort") private var sortMode = "manual"
    @AppStorage("bookSourceSortDescending") private var sortDescending = false

    private var filteredSources: [BookSource] {
        let filtered = library.sources.filter { source in
            let matchesGroup: Bool
            if let selectedGroup {
                matchesGroup = selectedGroup.isEmpty ? source.groups.isEmpty : source.hasGroup(selectedGroup)
            } else {
                matchesGroup = true
            }
            let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
            return matchesGroup && (query.isEmpty
                || source.bookSourceName.localizedCaseInsensitiveContains(query)
                || source.bookSourceUrl.localizedCaseInsensitiveContains(query)
                || source.groups.contains(where: { $0.localizedCaseInsensitiveContains(query) }))
        }
        guard sortMode != "manual" else { return filtered }
        return filtered.sorted { lhs, rhs in
            sortDescending ? isOrdered(rhs, before: lhs) : isOrdered(lhs, before: rhs)
        }
    }

    private func isOrdered(_ lhs: BookSource, before rhs: BookSource) -> Bool {
        switch sortMode {
        case "weight":
            return lhs.weight == rhs.weight ? lhs.bookSourceName.localizedStandardCompare(rhs.bookSourceName) == .orderedAscending : lhs.weight < rhs.weight
        case "name": return lhs.bookSourceName.localizedStandardCompare(rhs.bookSourceName) == .orderedAscending
        case "url": return lhs.bookSourceUrl.localizedStandardCompare(rhs.bookSourceUrl) == .orderedAscending
        case "update": return lhs.lastUpdateTime == rhs.lastUpdateTime ? lhs.bookSourceName < rhs.bookSourceName : lhs.lastUpdateTime > rhs.lastUpdateTime
        case "respond": return lhs.respondTime == rhs.respondTime ? lhs.bookSourceName < rhs.bookSourceName : lhs.respondTime < rhs.respondTime
        case "enabled": return lhs.enabled == rhs.enabled ? lhs.bookSourceName < rhs.bookSourceName : lhs.enabled && !rhs.enabled
        default: return lhs.customOrder < rhs.customOrder
        }
    }

    var body: some View {
        Group {
            if library.sources.isEmpty, !library.isWorking {
                ReadingUnavailableView {
                    Label("还没有书源", systemImage: "network")
                } description: {
                    Text("新建书源，或从文件、链接、JSON、二维码导入。")
                } actions: {
                    Menu("添加书源") { addSourceActions }
                        .readingProminentButtonStyle()
                }
            } else {
                List {
                    Section {
                        Picker("分组", selection: $selectedGroup) {
                            Text("全部").tag(String?.none)
                            Text("未分组").tag(String?.some(""))
                            ForEach(library.groups, id: \.self) { group in
                                Text(group).tag(String?.some(group))
                            }
                        }
                    }
                    Section {
                        ForEach(filteredSources) { source in
                            if isSelecting {
                                Button {
                                    if !selectedSourceIDs.insert(source.id).inserted { selectedSourceIDs.remove(source.id) }
                                } label: {
                                    HStack(spacing: 10) {
                                        Image(systemName: selectedSourceIDs.contains(source.id) ? "checkmark.circle.fill" : "circle")
                                            .font(.title3)
                                            .foregroundStyle(selectedSourceIDs.contains(source.id) ? ReadingTheme.accent : .secondary)
                                        SourceRow(source: source)
                                    }
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            } else {
                                NavigationLink {
                                    SourceDetailView(source: source)
                                } label: {
                                    SourceRow(source: source)
                                }
                                .swipeActions(edge: .leading) {
                                    Button(source.enabled ? "停用" : "启用") { Task { await library.setEnabled(!source.enabled, for: source.id) } }
                                        .tint(source.enabled ? .orange : .green)
                                }
                                .contextMenu {
                                    Button(source.enabled ? "停用" : "启用") { Task { await library.setEnabled(!source.enabled, for: source.id) } }
                                    NavigationLink {
                                        SearchView(fixedSource: source)
                                    } label: {
                                        Label("搜索", systemImage: "magnifyingglass")
                                    }
                                    Button(source.enabledExplore ? "停用发现" : "启用发现", systemImage: "safari") {
                                        Task { await library.setExploreEnabled(!source.enabledExplore, for: source.id) }
                                    }
                                    Button("删除", systemImage: "trash", role: .destructive) {
                                        Task { await library.remove(sourceIDs: [source.id]) }
                                    }
                                }
                            }
                        }
                        .onDelete { offsets in
                            let ids = Set(offsets.compactMap { filteredSources.indices.contains($0) ? filteredSources[$0].id : nil })
                            Task { await library.remove(sourceIDs: ids) }
                        }
                    } header: {
                        Text("\(filteredSources.count) 个书源")
                    } footer: {
                        Text("共 \(library.sources.count) 个书源，\(library.sources.filter(\.enabled).count) 个已启用")
                    }
                }
                .listStyle(.insetGrouped)
                .readingScrollContentBackgroundHidden()
                .background(ReadingTheme.groupedCanvas)
                .overlay {
                    if library.isWorking { ProgressView() }
                }
            }
        }
        .navigationTitle(isSelecting ? "已选 \(selectedSourceIDs.count) 项" : "书源")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .readingTabBarHidden()
        .background(ReadingTheme.groupedCanvas)
        .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "名称、地址或分组")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                if isSelecting {
                    Button("取消") { isSelecting = false; selectedSourceIDs = [] }
                } else {
                    Button { dismiss() } label: { Image(systemName: "chevron.left") }.accessibilityLabel("返回")
                }
            }
            ToolbarItemGroup(placement: .topBarTrailing) {
                if isSelecting {
                    Button(selectedSourceIDs.isSuperset(of: Set(filteredSources.map(\.id))) ? "取消全选" : "全选") {
                        let visible = Set(filteredSources.map(\.id))
                        if selectedSourceIDs.isSuperset(of: visible) { selectedSourceIDs.subtract(visible) }
                        else { selectedSourceIDs.formUnion(visible) }
                    }
                } else {
                    Button("选择") { isSelecting = true }.disabled(library.sources.isEmpty)
                    Menu("添加书源", systemImage: "plus") { addSourceActions }
                    Menu("更多", systemImage: "ellipsis.circle") {
                        Button("测试当前列表", systemImage: "checkmark.circle") { testSourceIDs = Set(filteredSources.map(\.id)); showsBatchTest = true }
                        Menu("排序", systemImage: "arrow.up.arrow.down") {
                            Toggle("倒序", isOn: $sortDescending)
                            Picker("排序方式", selection: $sortMode) {
                                Text("手动排序").tag("manual")
                                Text("自动排序").tag("weight")
                                Text("按名称").tag("name")
                                Text("按网址").tag("url")
                                Text("按更新时间").tag("update")
                                Text("按响应时间").tag("respond")
                                Text("按启用状态").tag("enabled")
                            }
                        }
                        Button("管理分组", systemImage: "folder") { showsGroupManager = true }
                        Button("导出全部书源", systemImage: "square.and.arrow.up") { exportSources(library.sources) }
                    }
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if isSelecting {
                HStack {
                    Button("测试") { testSourceIDs = selectedSourceIDs; showsBatchTest = true }
                    Spacer()
                    Menu("启停") {
                        Button("启用所选") { Task { await library.setEnabled(true, for: selectedSourceIDs) } }
                        Button("停用所选") { Task { await library.setEnabled(false, for: selectedSourceIDs) } }
                    }
                    Spacer()
                    Button("分组") { showsBatchGroups = true }
                    Spacer()
                    Button("导出") { exportSources(library.sources.filter { selectedSourceIDs.contains($0.id) }) }
                    Spacer()
                    Button("删除", role: .destructive) { confirmsDelete = true }
                }
                .disabled(selectedSourceIDs.isEmpty)
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 20).frame(minHeight: 54)
                .background(.ultraThinMaterial)
            }
        }
        .alert("删除所选书源？", isPresented: $confirmsDelete) {
            Button("取消", role: .cancel) {}
            Button("删除 \(selectedSourceIDs.count) 个书源", role: .destructive) {
                let ids = selectedSourceIDs
                Task { await library.remove(sourceIDs: ids); if library.notice?.kind != .error { selectedSourceIDs.subtract(ids) } }
            }
        } message: { Text("将移除所选书源配置，书架中的书籍与已缓存正文会保留。") }
        .sheet(isPresented: $showsBatchTest) {
            ReadingNavigationStack {
                SourceBatchTestView(sourceIDs: testSourceIDs).environmentObject(library)
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("完成") { showsBatchTest = false } } }
            }.readingFormPresentation()
        }
        .fileExporter(isPresented: $exportsFile, document: exportDocument, contentType: .json, defaultFilename: "bookSources") { result in
            if case .failure(let error) = result { library.notice = .init(kind: .error, title: "导出失败", detail: error.localizedDescription) }
        }
        .sheet(isPresented: $showsNewSource) { SourceEditorView().environmentObject(library) }
        .sheet(isPresented: $showsQRImporter) {
            QRCodeImportView { value in Task { await library.previewInput(value) } }
        }
        .sheet(isPresented: $showsTextImporter) {
            SourceTextImportView()
                .environmentObject(library)
        }
        .sheet(isPresented: $showsGroupManager) {
            SourceGroupManagerView().environmentObject(library)
        }
        .sheet(isPresented: $showsBatchGroups) {
            SourceBatchGroupView(sourceIDs: selectedSourceIDs).environmentObject(library)
        }
        .sheet(isPresented: $showsImporter, onDismiss: {
            importPickerHasDismissed = true
            previewPickedFilesWhenReady()
        }) {
            SourceFileImportPicker { files in
                pickedImportFiles = files
                showsImporter = false
                previewPickedFilesWhenReady()
            } onCancel: {
                showsImporter = false
            }
        }
    }

    private func exportSources(_ sources: [BookSource]) {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            exportDocument = .init(data: try encoder.encode(sources))
            exportsFile = true
        } catch { library.notice = .init(kind: .error, title: "导出失败", detail: error.localizedDescription) }
    }

    @ViewBuilder
    private var addSourceActions: some View {
        Button("扫码添加", systemImage: "qrcode.viewfinder") { showsQRImporter = true }
        Button("链接或 JSON", systemImage: "link") { showsTextImporter = true }
        Button("从文件导入", systemImage: "doc", action: presentFileImporter)
        Divider()
        Button("手动编辑规则", systemImage: "curlybraces") { showsNewSource = true }
    }

    private func presentFileImporter() {
        pickedImportFiles = []
        importPickerHasDismissed = false
        showsImporter = true
    }

    private func previewPickedFilesWhenReady() {
        // Import-copy mode can dismiss before returning URLs. Other providers
        // return URLs first, so wait for both events instead of assuming order.
        guard importPickerHasDismissed, !pickedImportFiles.isEmpty else { return }
        let files = pickedImportFiles
        pickedImportFiles = []
        Task { await library.previewPickedFiles(files) }
    }
}

private struct SourceFileImportPicker: UIViewControllerRepresentable {
    let onPick: @MainActor ([SourceImportFile]) -> Void
    let onCancel: @MainActor () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        // Ask the provider to import copies, including JSON files whose provider
        // does not support opening documents in place. Multi-select gives Files
        // an explicit confirmation action for the selected files.
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.item], asCopy: true)
        picker.allowsMultipleSelection = true
        picker.shouldShowFileExtensions = true
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}

    @MainActor
    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        private let parent: SourceFileImportPicker

        init(parent: SourceFileImportPicker) { self.parent = parent }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            parent.onCancel()
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            // Hold the picker grants before dismissing, until the model has
            // finished its coordinated background reads.
            parent.onPick(urls.map { SourceImportFile(url: $0) })
        }
    }
}

private struct SourceTextImportView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var library: SourceLibraryModel
    @State private var mode = 0
    @State private var value = ""

    var body: some View {
        ReadingNavigationStack {
            Form {
                Picker("导入方式", selection: $mode) {
                    Text("URL").tag(0)
                    Text("粘贴 JSON").tag(1)
                }
                .pickerStyle(.segmented)

                Section(mode == 0 ? "书源 URL" : "书源 JSON") {
                    Button("从剪贴板粘贴", systemImage: "doc.on.clipboard") {
                        value = UIPasteboard.general.string ?? ""
                        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                        mode = trimmed.hasPrefix("{") || trimmed.hasPrefix("[") ? 1 : 0
                    }
                    if mode == 0 {
                        TextField("https://example.com/sources.json", text: $value)
                            .textInputAutocapitalization(.never)
                            .keyboardType(.URL)
                    } else {
                        SyntaxCodeEditor(text: $value, language: .json)
                            .frame(minHeight: 220)
                    }
                }
                Section {
                    Text("导入前可预览并选择书源。地址相同的书源将被替换。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("导入书源")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("导入") {
                        let input = value
                        let selectedMode = mode
                        dismiss()
                        Task {
                            try? await Task.sleep(nanoseconds: 350_000_000)
                            if selectedMode == 0 { await library.previewRemoteURL(input) }
                            else { await library.previewText(input) }
                        }
                    }
                    .disabled(value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}

private struct SourceRow: View {
    let source: BookSource

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(source.bookSourceName).font(.body).lineLimit(2)
                if !source.enabled { Text("已停用").font(.caption).foregroundStyle(.secondary) }
            }
            Text(source.groups.isEmpty ? (URL(string: source.bookSourceUrl)?.host ?? source.bookSourceUrl) : source.groups.joined(separator: " · "))
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 2)
    }
}

private struct SourceGroupManagerView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var library: SourceLibraryModel
    @State private var newGroup = ""
    @State private var renaming: String?
    @State private var renamedValue = ""

    var body: some View {
        ReadingNavigationStack {
            List {
                Section("新建分组") {
                    HStack {
                        TextField("例如：文学", text: $newGroup)
                        Button("添加") {
                            let value = newGroup
                            newGroup = ""
                            let ungrouped = Set(library.sources.filter { $0.groups.isEmpty }.map(\.id))
                            Task { await library.addGroup(value, to: ungrouped) }
                        }
                        .disabled(BookSource.parseGroups(newGroup).isEmpty)
                    }
                    Text("添加后，所有未分组的书源都会加入该分组。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section {
                    ForEach(library.groups, id: \.self) { group in
                        HStack {
                            NavigationLink {
                                SourceGroupContentsView(group: group)
                            } label: {
                                HStack {
                                    Label(group, systemImage: "folder.fill")
                                    Spacer()
                                    Text("\(library.sources.filter { $0.hasGroup(group) }.count) 个书源")
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Menu {
                                Button("重命名", systemImage: "pencil") {
                                    renaming = group
                                    renamedValue = group
                                }
                                Button("删除分组", systemImage: "trash", role: .destructive) {
                                    Task { await library.deleteGroup(group) }
                                }
                            } label: { Image(systemName: "ellipsis.circle") }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("\(group)分组操作")
                        }
                    }
                } header: {
                    Text("已有分组")
                } footer: {
                    Text("点击分组可查看其中的书源。")
                }
            }
            .navigationTitle("书源分组")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
            .alert("重命名分组", isPresented: Binding(
                get: { renaming != nil },
                set: { if !$0 { renaming = nil } }
            )) {
                TextField("分组名称", text: $renamedValue)
                Button("取消", role: .cancel) { renaming = nil }
                Button("保存") {
                    if let old = renaming { Task { await library.renameGroup(old, to: renamedValue) } }
                    renaming = nil
                }
            }
        }
    }
}

private struct SourceGroupContentsView: View {
    @EnvironmentObject private var library: SourceLibraryModel
    let group: String

    private var sources: [BookSource] {
        library.sources.filter { $0.hasGroup(group) }
    }

    var body: some View {
        List {
            Section {
                ForEach(sources) { source in
                    NavigationLink {
                        SourceDetailView(source: source)
                    } label: {
                        SourceRow(source: source)
                    }
                }
                if sources.isEmpty {
                    Text("该分组暂无书源")
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("\(sources.count) 个书源")
            }
        }
        .listStyle(.insetGrouped)
        .readingScrollContentBackgroundHidden()
        .background(ReadingTheme.groupedCanvas)
        .navigationTitle(group)
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct SourceBatchGroupView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var library: SourceLibraryModel
    let sourceIDs: Set<String>
    @State private var customGroup = ""

    var body: some View {
        ReadingNavigationStack {
            List {
                Section("已选择 \(sourceIDs.count) 个书源") {
                    HStack {
                        TextField("输入新分组", text: $customGroup)
                        Button("加入") {
                            let value = customGroup
                            customGroup = ""
                            Task { await library.addGroup(value, to: sourceIDs) }
                        }
                        .disabled(BookSource.parseGroups(customGroup).isEmpty)
                    }
                }
                Section("加入现有分组") {
                    ForEach(library.groups, id: \.self) { group in
                        Button { Task { await library.addGroup(group, to: sourceIDs) } } label: {
                            Label(group, systemImage: "folder.badge.plus")
                        }
                    }
                }
                Section("从分组移除") {
                    ForEach(library.groups, id: \.self) { group in
                        Button(role: .destructive) {
                            Task { await library.removeGroup(group, from: sourceIDs) }
                        } label: { Label(group, systemImage: "folder.badge.minus") }
                    }
                }
            }
            .navigationTitle("批量归组")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }
    }
}

private struct SourceDetailView: View {
    @EnvironmentObject private var library: SourceLibraryModel
    let source: BookSource
    @State private var showsEditor = false
    @State private var editedSourceID: String?
    private var current: BookSource { library.sources.first { $0.id == (editedSourceID ?? source.id) } ?? source }

    var body: some View {
        List {
            Section("基本信息") {
                ReadingLabeledContent("名称", value: current.bookSourceName)
                ReadingLabeledContent("地址", value: current.bookSourceUrl)
                ReadingLabeledContent("分组", value: current.bookSourceGroup ?? "未分组")
                ReadingLabeledContent("类型", value: String(current.bookSourceType))
            }
            Section("能力") {
                CapabilityRow(title: "搜索", available: current.searchUrl?.isEmpty == false)
                CapabilityRow(title: "发现", available: current.exploreUrl?.isEmpty == false)
                CapabilityRow(title: "详情", available: current.ruleBookInfo != nil)
                CapabilityRow(title: "目录", available: current.ruleToc != nil)
                CapabilityRow(title: "正文", available: current.ruleContent != nil)
            }
            Section("状态") {
                Toggle("启用书源", isOn: Binding(
                    get: { library.sources.first(where: { $0.id == current.id })?.enabled ?? current.enabled },
                    set: { value in Task { await library.setEnabled(value, for: current.id) } }
                ))
                Toggle("启用发现", isOn: Binding(
                    get: { library.sources.first(where: { $0.id == current.id })?.enabledExplore ?? current.enabledExplore },
                    set: { value in Task { await library.setExploreEnabled(value, for: current.id) } }
                ))
            }
            Section("兼容检查") {
                NavigationLink {
                    SearchView(fixedSource: current)
                } label: {
                    Label("搜索此书源", systemImage: "magnifyingglass")
                }
                NavigationLink {
                    SourceDebugView(source: current)
                } label: {
                    Label("运行端到端调试", systemImage: "stethoscope")
                }
                Text("使用你输入的关键词，逐步验证搜索、详情、目录和正文规则。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if current.loginUrl?.isEmpty == false {
                Section("账户") {
                    NavigationLink {
                        SourceLoginView(source: current)
                    } label: {
                        Label("登录此书源", systemImage: "person.badge.key.fill")
                    }
                    Text("登录 Cookie 与阅读请求共享；若书源提供检测脚本，会在页面载入后自动验证。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            if let comment = current.bookSourceComment, !comment.isEmpty {
                Section("说明") { Text(comment) }
            }
        }
        .navigationTitle(current.bookSourceName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("编辑") { showsEditor = true }
            }
        }
        .sheet(isPresented: $showsEditor) {
            SourceEditorView(source: current) { editedSourceID = $0.id }.environmentObject(library)
        }
    }
}

struct SourceImportReviewView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var library: SourceLibraryModel
    let pending: SourceLibraryModel.PendingImport
    @State private var selectedIDs: Set<String>
    @State private var importError: String?
    @State private var isImporting = false
    @State private var keepOriginalName = false
    @State private var keepOriginalGroup = false
    @State private var keepOriginalEnabled = false
    @State private var showComments = false
    @State private var customGroup = ""
    @State private var addCustomGroup = true

    init(pending: SourceLibraryModel.PendingImport) {
        self.pending = pending
        _selectedIDs = State(initialValue: Set(pending.items.filter { $0.existing == nil || $0.state == "更新" }.map(\.id)))
    }

    var body: some View {
        ReadingNavigationStack {
            List {
                Section {
                    HStack(spacing: 10) {
                        importCountCard(
                            title: "有效",
                            count: pending.validCount,
                            color: .green,
                            systemImage: "checkmark.circle.fill"
                        )
                        importCountCard(
                            title: "失效",
                            count: pending.invalidCount,
                            color: .red,
                            systemImage: "xmark.circle.fill"
                        )
                        importCountCard(
                            title: "总计",
                            count: pending.totalCount,
                            color: .secondary,
                            systemImage: "doc.text.fill"
                        )
                    }
                    .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16))

                    Label("仅格式有效的书源可被选择和导入，实际可用性请在导入后测试", systemImage: "checkmark.shield.fill")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                if !pending.items.isEmpty {
                    Section("导入设置") {
                        HStack {
                            TextField("自定义分组", text: $customGroup)
                            Toggle("追加", isOn: $addCustomGroup).labelsHidden()
                        }
                        Toggle("保留原名称", isOn: $keepOriginalName)
                        Toggle("保留原分组", isOn: $keepOriginalGroup)
                        Toggle("保留原启用状态", isOn: $keepOriginalEnabled)
                        Toggle("显示书源备注", isOn: $showComments)
                    }
                }

                Section("有效书源（\(pending.validCount)）") {
                    ForEach(pending.items) { item in
                        Button {
                            if !selectedIDs.insert(item.id).inserted { selectedIDs.remove(item.id) }
                        } label: {
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: selectedIDs.contains(item.id) ? "checkmark.square.fill" : "square")
                                    .foregroundStyle(selectedIDs.contains(item.id) ? ReadingTheme.accent : .secondary)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(item.source.bookSourceName).foregroundStyle(.primary)
                                    HStack {
                                        Text(item.state)
                                            .font(.caption.bold())
                                            .foregroundStyle(item.state == "新增" ? .green : item.state == "更新" ? .orange : .secondary)
                                        Text(item.source.bookSourceUrl)
                                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                    if showComments, let comment = item.source.bookSourceComment, !comment.isEmpty {
                                        Text(comment).font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }
                }

                if !pending.invalidItems.isEmpty {
                    Section("失效书源（\(pending.invalidCount)）") {
                        ForEach(pending.invalidItems) { item in
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.red)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(item.source.bookSourceName.isEmpty ? "未命名书源" : item.source.bookSourceName)
                                        .foregroundStyle(.primary)
                                    if !item.source.bookSourceUrl.isEmpty {
                                        Text(item.source.bookSourceUrl)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                    Text(item.issues.map(\.message).joined(separator: "；"))
                                        .font(.caption)
                                        .foregroundStyle(.red)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("书源导入预检")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
                        library.cancelPendingImport()
                        dismiss()
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu("选择") {
                        Button("全选") { selectedIDs = Set(pending.items.map(\.id)) }
                        Button("取消全选") { selectedIDs.removeAll() }
                        Button("仅选择新增") {
                            selectedIDs = Set(pending.items.filter { $0.existing == nil }.map(\.id))
                        }
                        Button("仅选择更新") {
                            selectedIDs = Set(pending.items.filter { $0.existing != nil }.map(\.id))
                        }
                    }
                    .disabled(pending.items.isEmpty)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("导入") {
                        let ids = selectedIDs
                        isImporting = true
                        Task {
                            await library.commitPendingImport(
                                selectedIDs: ids,
                                keepOriginalName: keepOriginalName,
                                keepOriginalGroup: keepOriginalGroup,
                                keepOriginalEnabled: keepOriginalEnabled,
                                customGroup: customGroup.isEmpty ? nil : customGroup,
                                addCustomGroup: addCustomGroup
                            )
                            isImporting = false
                            if library.pendingImport == nil { dismiss() }
                            else {
                                let message = library.notice?.detail ?? "保存失败，请重试"
                                library.notice = nil
                                importError = message
                            }
                        }
                    }
                    .disabled(selectedIDs.isEmpty || isImporting)
                }
            }
        }
        .interactiveDismissDisabled()
        .alert("导入保存失败", isPresented: Binding(get: { importError != nil }, set: { if !$0 { importError = nil } })) {
            Button("好", role: .cancel) {}
        } message: { Text(importError ?? "") }
    }

    private func importCountCard(
        title: String,
        count: Int,
        color: Color,
        systemImage: String
    ) -> some View {
        VStack(spacing: 5) {
            Label(title, systemImage: systemImage)
                .font(.caption.weight(.semibold))
                .foregroundStyle(color)
            Text("\(count)")
                .font(.title2.bold())
                .foregroundStyle(.primary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(color.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
    }
}

private struct CapabilityRow: View {
    let title: String
    let available: Bool

    var body: some View {
        ReadingLabeledContent(title) {
            Image(systemName: available ? "checkmark.circle.fill" : "minus.circle")
                .foregroundStyle(available ? .green : .secondary)
                .accessibilityLabel(available ? "已配置" : "未配置")
        }
    }
}
