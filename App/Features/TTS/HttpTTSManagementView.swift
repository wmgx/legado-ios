import SwiftUI
import UniformTypeIdentifiers
import UIKit
@preconcurrency import AVFoundation

struct SpeechSettingsView: View {
    var bookName: String? = nil
    var bookEngine: Binding<String>? = nil
    var sampleText = "你好，欢迎开始听书。"
    var remainingMinutes = 0
    @StateObject private var model = HttpTTSLibraryModel()
    @StateObject private var preview = ReaderSpeechController()
    @State private var testText = ""
    @AppStorage("appTtsEngine") private var defaultEngine = ""
    @AppStorage("systemTtsVoice") private var voice = ""
    @AppStorage("ttsFollowSys") private var followsRate = true
    @AppStorage("ttsSpeechRate") private var rate = 5
    @AppStorage("ttsTimer") private var timer = 0
    @AppStorage("readAloudByPage") private var byPage = false
    @AppStorage("streamReadAloudAudio") private var streamsAudio = true
    @AppStorage("readAloudWakeLock") private var keepsScreenOn = false
    @AppStorage("ignoreAudioFocus") private var mixesAudio = false
    @AppStorage("pauseReadAloudWhilePhoneCalls") private var pausesForCalls = false
    @AppStorage("mediaButtonPerNext") private var mediaChangesChapter = false

    private var engineID: String {
        let value = bookEngine?.wrappedValue ?? "__global__"
        return value == "__global__" ? defaultEngine : value
    }
    private var engine: HttpTTS? { model.engines.first { String($0.id) == engineID } }

    var body: some View {
        Form {
            Section {
                enginePicker(bookEngine ?? $defaultEngine, includesDefault: bookEngine != nil)
                if engineID.isEmpty {
                    Picker("系统声音", selection: $voice) {
                        Text("默认中文声音").tag("")
                        ForEach(AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix("zh") }
                            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }, id: \.identifier) { value in
                            Text("\(value.name) · \(value.language)").tag(value.identifier)
                        }
                    }
                }
                if let engine {
                    NavigationLink(engine.openAIServiceAddress == nil ? "服务参数" : "声音与连接") {
                        httpTTSConfiguration(engine, library: model, sampleText: testText)
                    }
                }
                NavigationLink("管理在线引擎") { HttpTTSManagementView(sampleText: testText) }
            } header: { Text("声音") } footer: {
                Text(bookName.map { "引擎选择仅用于《\($0)》。服务配置由使用该引擎的书籍共享。" } ?? "默认引擎用于跟随默认设置的书籍。")
            }
            Section {
                Toggle("使用默认语速", isOn: $followsRate)
                HStack {
                    Text("朗读速度")
                    Spacer()
                    Text(String(format: "%.1f×", followsRate ? 1.0 : Double(rate + 5) / 10)).monospacedDigit()
                        .accessibilityIdentifier("speech.rateValue")
                }
                Slider(value: Binding(get: { Double(rate) }, set: { rate = Int($0); followsRate = false }), in: 0...45, step: 1)
                    .accessibilityLabel("朗读速度").accessibilityIdentifier("speech.rate")
                HStack {
                    ForEach([0, 5, 10, 15], id: \.self) { value in
                        Button(String(format: "%.1f×", Double(value + 5) / 10)) { rate = value; followsRate = false }
                            .frame(maxWidth: .infinity, minHeight: 36)
                            .background((!followsRate && rate == value ? Color.accentColor : .secondary).opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                    }
                }.buttonStyle(.borderless)
            } header: { Text("语速") } footer: { Text("所有书籍共用，修改后立即生效。") }
            Section("试听") {
                TextField("试听文本", text: $testText)
                    .accessibilityIdentifier("speech.previewText")
                Button(action: playPreview) {
                    HStack {
                        Label(preview.isSpeaking || preview.isPaused ? "停止试听" : "试听当前声音", systemImage: preview.isSpeaking || preview.isPaused ? "stop.fill" : "play.fill")
                        Spacer()
                        if preview.isBuffering { ProgressView() }
                    }
                }
                .disabled(testText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || (!engineID.isEmpty && engine == nil))
                .accessibilityIdentifier("speech.preview")
                if model.isLoading { ProgressView("正在加载引擎…") }
                else if !engineID.isEmpty && engine == nil { Text("所选引擎已移除，请重新选择。").font(.footnote).foregroundStyle(.red) }
                if let error = preview.errorMessage { Text(error).font(.footnote).foregroundStyle(.red) }
                if let error = model.errorMessage { Text(error).font(.footnote).foregroundStyle(.red) }
            }
            Section {
                Picker("定时停止", selection: $timer) {
                    ForEach(Array(Set([0, 15, 30, 45, 60, 90, 120, 180, timer])).sorted(), id: \.self) { value in
                        Text(value == 0 ? "不定时" : "\(value) 分钟").tag(value)
                    }
                }
                if remainingMinutes > 0 { Text("本次还剩 \(remainingMinutes) 分钟").font(.footnote).foregroundStyle(.secondary) }
            } header: { Text("睡眠定时") } footer: { Text("修改后立即生效。") }
            Section {
                if bookEngine != nil {
                    NavigationLink("所有书籍的默认引擎") {
                        Form { enginePicker($defaultEngine, includesDefault: false) }.navigationTitle("默认朗读引擎")
                    }
                }
                NavigationLink("更多播放设置") {
                    Form {
                        Section {
                            Toggle("按页朗读", isOn: $byPage)
                            Toggle("流式播放在线音频", isOn: $streamsAudio)
                            Toggle("朗读时保持亮屏", isOn: $keepsScreenOn)
                            Toggle("耳机上一首、下一首切换章节", isOn: $mediaChangesChapter)
                        }
                        Section {
                            Toggle("与其他音频同时播放", isOn: $mixesAudio)
                            if mixesAudio { Toggle("来电时暂停", isOn: $pausesForCalls) }
                        }
                    }.navigationTitle("播放设置")
                }
            }
        }
        .navigationTitle("朗读设置")
        .navigationBarTitleDisplayMode(.inline)
        .task { if testText.isEmpty { testText = sampleText }; await model.load() }
        .onDisappear { preview.stop() }
        .onChange(of: defaultEngine) { _ in preview.stop() }
        .onChange(of: bookEngine?.wrappedValue) { _ in preview.stop() }
        .onChange(of: voice) { _ in preview.stop() }
        .onChange(of: rate) { _ in preview.stop() }
        .onChange(of: followsRate) { _ in preview.stop() }
    }

    private func enginePicker(_ selection: Binding<String>, includesDefault: Bool) -> some View {
        Picker(includesDefault ? "本书引擎" : "默认引擎", selection: selection) {
            if includesDefault { Text("跟随默认").tag("__global__") }
            Text("系统朗读 · 无需联网").tag("")
            ForEach(model.engines) { value in Text(value.name).tag(String(value.id)) }
            if !selection.wrappedValue.isEmpty, selection.wrappedValue != "__global__",
               !model.engines.contains(where: { String($0.id) == selection.wrappedValue }) {
                Text("引擎已移除").tag(selection.wrappedValue)
            }
        }
    }

    private func playPreview() {
        if preview.isSpeaking || preview.isPaused { preview.stop(); return }
        preview.configure(followsSystemRate: followsRate, speechRate: rate, readByPage: false,
                          streamsHTTPAudio: streamsAudio, voiceIdentifier: voice, ignoresAudioFocus: mixesAudio,
                          pausesForPhoneCalls: pausesForCalls, bookName: bookName ?? "试听")
        if let engine { preview.speakHTTP(engine: engine, text: testText) }
        else { preview.speak(testText) }
    }
}

@MainActor
final class HttpTTSLibraryModel: ObservableObject {
    @Published private(set) var engines: [HttpTTS] = []
    @Published var errorMessage: String?
    @Published private(set) var isLoading = true

    private func repository() throws -> SQLiteConfigurationRepository {
        SQLiteConfigurationRepository(database: try LegadoDatabase(url: LegadoDatabase.defaultURL()))
    }

    func load() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            var values = try await repository().loadHttpTTS()
            if values.isEmpty { values = try bundledDefaults() }
            engines = sorted(values)
            if !values.isEmpty { try await repository().saveHttpTTS(engines) }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @discardableResult
    func save(_ value: HttpTTS) async -> Bool {
        var value = value
        value.lastUpdateTime = Int64(Date().timeIntervalSince1970 * 1_000)
        var values = engines.filter { $0.id != value.id }
        values.append(value)
        return await persist(values)
    }

    func delete(at offsets: IndexSet) async -> Bool {
        var values = engines
        values.remove(atOffsets: offsets)
        return await persist(values)
    }

    func previewImport(_ input: String) async throws -> HttpTTSImportResult {
        let parsed = try RuleImportInput.parse(input, kind: "httpTTS")
        switch parsed {
        case .json(let text): return try HttpTTS.inspectImport(Data(text.utf8))
        case .remote:
            guard let request = parsed.request() else { throw URLError(.badURL) }
            let response = try await URLSessionHTTPTransport().data(for: request)
            guard (200..<300).contains(response.statusCode) else {
                throw BookSourceImportError.invalidDocument("服务器返回 HTTP \(response.statusCode)")
            }
            let data = response.data
            guard data.count <= 5 * 1_024 * 1_024 else {
                throw BookSourceImportError.invalidDocument("引擎文件超过 5 MB")
            }
            return try HttpTTS.inspectImport(data)
        }
    }

    func importEngines(_ imported: [HttpTTS]) async -> Bool {
        var byID = Dictionary(uniqueKeysWithValues: engines.map { ($0.id, $0) })
        for value in imported { byID[value.id] = value }
        return await persist(Array(byID.values))
    }

    func restoreDefaults() async {
        do {
            let defaults = try bundledDefaults()
            var byID = Dictionary(uniqueKeysWithValues: engines.filter { $0.id >= 0 }.map { ($0.id, $0) })
            for value in defaults { byID[value.id] = value }
            await persist(Array(byID.values))
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func exportData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(engines)
    }

    private func bundledDefaults() throws -> [HttpTTS] {
        guard let url = Bundle.main.url(forResource: "httpTTS", withExtension: "json") else {
            throw CocoaError(.fileNoSuchFile)
        }
        return try JSONDecoder().decode([HttpTTS].self, from: Data(contentsOf: url))
    }

    @discardableResult
    private func persist(_ values: [HttpTTS]) async -> Bool {
        do {
            let values = sorted(values)
            try await repository().saveHttpTTS(values)
            engines = values
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    private func sorted(_ values: [HttpTTS]) -> [HttpTTS] {
        values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

struct HttpTTSImportRequest: Identifiable {
    let id = UUID()
    let input: String
}

struct HttpTTSManagementView: View {
    @Environment(\.dismiss) private var dismiss
    var sampleText = "选好声音和语速后，就可以开始听书了。"
    @StateObject private var model = HttpTTSLibraryModel()
    @StateObject private var preview = ReaderSpeechController()
    @State private var previewID: Int64?
    @State private var editing: HttpTTS?
    @State private var loggingIn: HttpTTS?
    @State private var importRequest: HttpTTSImportRequest?
    @State private var importsFile = false
    @State private var showsScanner = false
    @State private var showsService = false
    @State private var exportsFile = false
    @State private var search = ""
    @State private var isSelecting = false
    @State private var selectedIDs = Set<Int64>()
    @State private var deletingIDs = Set<Int64>()
    @State private var confirmsDelete = false
    @State private var testTask: Task<Void, Never>?
    @State private var isTesting = false
    @State private var testResults: [Int64: String] = [:]
    @State private var exportDocument = ConfigurationJSONDocument(data: Data("[]".utf8))
    @AppStorage("appTtsEngine") private var defaultEngine = ""

    private var visibleEngines: [HttpTTS] {
        let values = model.engines.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) }
        return values.filter { String($0.id) == defaultEngine } + values.filter { String($0.id) != defaultEngine }
    }

    var body: some View {
        List {
            Section {
                ForEach(visibleEngines) { engine in engineRow(engine) }
                    .onDelete { offsets in confirmDeletion(Set(offsets.map { visibleEngines[$0].id })) }
            } footer: {
                Text("\(model.engines.count) 个引擎")
            }
        }
        .readingListTopMargin(8)
        .overlay { if model.isLoading { ProgressView("正在加载引擎…") } }
        .navigationTitle(isSelecting ? "已选 \(selectedIDs.count) 项" : "朗读引擎")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .readingTabBarHidden()
        .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .always), prompt: "搜索引擎名称")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                if isSelecting { Button("取消") { testTask?.cancel(); isSelecting = false; selectedIDs = [] } }
                else { Button { dismiss() } label: { Image(systemName: "chevron.left") }.accessibilityLabel("返回") }
            }
            ToolbarItemGroup(placement: .topBarTrailing) {
                if isSelecting {
                    Menu("选择") {
                        Button("全选当前列表") { selectedIDs.formUnion(visibleEngines.map(\.id)) }
                        Button("取消全选") { selectedIDs = [] }
                        Button("仅选择失败项") { selectedIDs = Set(testResults.filter { $0.value.hasPrefix("失败") }.keys) }
                    }.disabled(isTesting)
                } else {
                    Button("选择") { preview.stop(); isSelecting = true }.disabled(model.engines.isEmpty)
                    Menu("添加引擎", systemImage: "plus") {
                        Button("连接自建服务", systemImage: "server.rack") { showsService = true }
                        Button("扫码添加", systemImage: "qrcode.viewfinder") { showsScanner = true }
                        Button("链接或 JSON", systemImage: "link") { importRequest = .init(input: "") }
                        Button("从文件导入", systemImage: "doc") { importsFile = true }
                        Divider()
                        Button("恢复内置引擎", systemImage: "arrow.counterclockwise") { Task { await model.restoreDefaults() } }
                        Button("手动编辑规则", systemImage: "curlybraces") { editing = HttpTTS() }
                    }
                    Menu("更多", systemImage: "ellipsis.circle") {
                        Button("导出全部引擎", systemImage: "square.and.arrow.up") { exportEngines(model.engines) }
                        Button("清除朗读缓存", systemImage: "trash") { Task { await HttpTTSAudioCache.shared.clear() } }
                    }
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if isSelecting {
                HStack {
                    Button(isTesting ? "停止测试" : "测试") { if isTesting { testTask?.cancel() } else { startTests() } }
                        .disabled(selectedIDs.isEmpty)
                    Spacer()
                    Button("导出") { exportEngines(model.engines.filter { selectedIDs.contains($0.id) }) }.disabled(selectedIDs.isEmpty || isTesting)
                    Spacer()
                    Button("删除", role: .destructive) { confirmDeletion(selectedIDs) }.disabled(selectedIDs.isEmpty || isTesting)
                }
                .font(.subheadline.weight(.semibold)).padding(.horizontal, 24).frame(minHeight: 54)
                .background(.ultraThinMaterial)
            }
        }
        .alert("删除朗读引擎？", isPresented: $confirmsDelete) {
            Button("取消", role: .cancel) {}
            Button("删除 \(deletingIDs.count) 个引擎", role: .destructive) {
                let ids = deletingIDs
                Task {
                    if ids.contains(previewID ?? 0) { preview.stop() }
                    if await model.delete(at: IndexSet(model.engines.indices.filter { ids.contains(model.engines[$0].id) })) {
                        selectedIDs.subtract(ids)
                        if ids.contains(where: { String($0) == defaultEngine }) { defaultEngine = "" }
                    }
                }
            }
        } message: { Text("将删除 \(deletingIDs.count) 个引擎配置。若包含默认引擎，默认朗读将恢复为系统声音。") }
        .task { await model.load() }
        .onDisappear { preview.stop(); testTask?.cancel() }
        .sheet(item: $editing) { engine in
            ReadingNavigationStack { HttpTTSEditorView(engine: engine) { value in await model.save(value) } }.readingFormPresentation()
        }
        .sheet(item: $loggingIn) { engine in
            ReadingNavigationStack { httpTTSConfiguration(engine, library: model, sampleText: sampleText) }.readingFormPresentation()
        }
        .sheet(item: $importRequest) { request in HttpTTSImportView(input: request.input, library: model).readingFormPresentation() }
        .sheet(isPresented: $showsScanner) {
            QRCodeImportView(subject: "朗读引擎") { importRequest = .init(input: $0) }.readingFormPresentation()
        }
        .sheet(isPresented: $showsService) {
            ReadingNavigationStack { HttpTTSServiceSetupView(library: model) }.readingFormPresentation()
        }
        .fileImporter(isPresented: $importsFile, allowedContentTypes: [.json, .data]) { result in
            do {
                let url = try result.get()
                let accessing = url.startAccessingSecurityScopedResource()
                defer { if accessing { url.stopAccessingSecurityScopedResource() } }
                let data = try Data(contentsOf: url)
                guard let input = String(data: data, encoding: .utf8) else { throw CocoaError(.fileReadInapplicableStringEncoding) }
                importRequest = .init(input: input)
            } catch { model.errorMessage = error.localizedDescription }
        }
        .fileExporter(isPresented: $exportsFile, document: exportDocument, contentType: .json, defaultFilename: "httpTTS") { result in
            if case .failure(let error) = result { model.errorMessage = error.localizedDescription }
        }
        .alert("在线朗读引擎", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("确定", role: .cancel) { model.errorMessage = nil }
        } message: { Text(model.errorMessage ?? "") }
    }

    @ViewBuilder
    private func engineRow(_ engine: HttpTTS) -> some View {
        if isSelecting {
            Button {
                if !selectedIDs.insert(engine.id).inserted { selectedIDs.remove(engine.id) }
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: selectedIDs.contains(engine.id) ? "checkmark.circle.fill" : "circle").font(.title3)
                    engineTitle(engine)
                }.contentShape(Rectangle())
            }.buttonStyle(.plain).disabled(isTesting).accessibilityIdentifier("speech.select.\(engine.id)")
        } else {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    Button { loggingIn = engine } label: {
                        HStack {
                            engineTitle(engine)
                            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                        }.contentShape(Rectangle())
                    }.accessibilityIdentifier("speech.configure.\(engine.id)")
                    Button {
                        if previewID != engine.id { preview.stop() }
                        previewID = engine.id
                        preview.configure(followsSystemRate: true, speechRate: 5, readByPage: false)
                        preview.toggleHTTP(engine: engine, text: sampleText)
                    } label: {
                        Image(systemName: previewID == engine.id && preview.isSpeaking ? "stop.circle" : "play.circle")
                            .font(.title2).frame(width: 44, height: 44)
                    }.accessibilityLabel(previewID == engine.id && preview.isSpeaking ? "停止试听" : "试听")
                        .accessibilityIdentifier("speech.preview.\(engine.id)")
                    Menu {
                        Button("设为默认") { defaultEngine = String(engine.id) }.disabled(defaultEngine == String(engine.id))
                        Button("导出此引擎") { exportEngines([engine]) }
                        Button("删除", role: .destructive) { confirmDeletion([engine.id]) }
                    } label: { Image(systemName: "ellipsis").frame(width: 36, height: 44) }
                        .accessibilityLabel("管理 \(engine.name)")
                }
                if previewID == engine.id {
                    if preview.isBuffering { ProgressView("正在准备音频…") }
                    else if preview.isSpeaking { Text("正在朗读").font(.caption).accessibilityIdentifier("speech.enginePlayback") }
                    if let error = preview.errorMessage {
                        Text(error).font(.caption).foregroundStyle(.red).accessibilityIdentifier("speech.engineError")
                    }
                }
            }.buttonStyle(.borderless)
        }
    }

    private func engineTitle(_ engine: HttpTTS) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(engine.name).font(.body).lineLimit(2).foregroundStyle(.primary)
            if let result = testResults[engine.id] {
                Text(result).font(.caption).foregroundStyle(result.hasPrefix("失败") ? Color.red : Color.secondary)
                    .lineLimit(2).accessibilityIdentifier("speech.testResult.\(engine.id)")
            } else if defaultEngine == String(engine.id) {
                Text("默认引擎").font(.caption).foregroundStyle(.secondary)
            }
        }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 5)
    }

    private func confirmDeletion(_ ids: Set<Int64>) { deletingIDs = ids; confirmsDelete = true }

    private func exportEngines(_ engines: [HttpTTS]) {
        do {
            exportDocument = .init(data: try JSONEncoder().encode(engines))
            exportsFile = true
        } catch { model.errorMessage = error.localizedDescription }
    }

    private func startTests() {
        preview.stop()
        let values = model.engines.filter { selectedIDs.contains($0.id) }
        let text = String(sampleText.prefix(100))
        isTesting = true
        testTask = Task { @MainActor in
            defer { isTesting = false; testTask = nil }
            for engine in values {
                guard !Task.isCancelled else { break }
                testResults[engine.id] = "正在检测…"
                do { try await Self.probe(engine, text: text); testResults[engine.id] = "音频可播放" }
                catch {
                    if Task.isCancelled { testResults[engine.id] = "已取消"; break }
                    testResults[engine.id] = "失败：" + error.localizedDescription
                }
            }
        }
    }

    nonisolated private static func probe(_ engine: HttpTTS, text: String) async throws {
        try await withThrowingTaskGroup(of: Bool.self) { group in
            group.addTask {
                let audio = try await HttpTTSService().audio(engine: engine, text: text, speechRate: 10)
                _ = try AVAudioPlayer(data: audio.data)
                return true
            }
            group.addTask { try await Task.sleep(nanoseconds: 12_000_000_000); throw URLError(.timedOut) }
            defer { group.cancelAll() }
            _ = try await group.next()
        }
    }
}

struct HttpTTSImportView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var library: HttpTTSLibraryModel
    @State private var input: String
    @State private var engines: [HttpTTS] = []
    @State private var notes: [HttpTTS] = []
    @State private var selected = Set<Int64>()
    @State private var working = false
    @State private var error: String?
    @State private var imported = false
    @State private var usesAsDefault = true
    @AppStorage("appTtsEngine") private var defaultEngine = ""

    init(input: String, library: HttpTTSLibraryModel) {
        _input = State(initialValue: input)
        self.library = library
    }

    var body: some View {
        ReadingNavigationStack {
            Form {
                if imported {
                    Section {
                        Label("已导入 \(selected.count) 个引擎", systemImage: "checkmark.circle.fill")
                        ForEach(engines.filter { selected.contains($0.id) }) { engine in
                            if engine.loginUi?.isEmpty == false {
                                NavigationLink("配置参数 · \(engine.name)") { httpTTSConfiguration(engine, library: library) }
                            }
                        }
                        Text("已保存配置，可用性尚未检测。请先试听；书籍选择“跟随默认”即可使用默认引擎。")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                } else if engines.isEmpty {
                    Section {
                        Button("从剪贴板粘贴", systemImage: "doc.on.clipboard") { input = UIPasteboard.general.string ?? "" }
                        TextEditor(text: $input).frame(minHeight: 180)
                            .autocorrectionDisabled().textInputAutocapitalization(.never)
                            .accessibilityIdentifier("speech.importInput")
                        Button("读取并预览") { Task { await preview() } }.disabled(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || working)
                    } header: { Text("引擎链接或 JSON") }
                    footer: { Text("支持 HTTP(S) 地址、JSON 和 legado://import/httpTTS?src=…，读取后选择需要导入的引擎。") }
                } else {
                    Section {
                        ForEach(engines) { engine in
                            Toggle(isOn: Binding(get: { selected.contains(engine.id) }, set: { if $0 { selected.insert(engine.id) } else { selected.remove(engine.id) } })) {
                                VStack(alignment: .leading) {
                                    Text(engine.name)
                                    Text(importState(engine)).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    } header: { Text("选择引擎（\(selected.count)/\(engines.count)）").accessibilityIdentifier("speech.importCount") }
                    if !notes.isEmpty {
                        Section("说明与不完整记录（\(notes.count) 条，不导入）") {
                            ForEach(Array(notes.enumerated()), id: \.offset) { _, note in
                                Text(note.name.isEmpty ? "缺少名称或请求地址" : note.name)
                                    .font(.footnote).foregroundStyle(.secondary)
                            }
                        }
                    }
                    Section {
                        if selected.count == 1 { Toggle("设为默认引擎", isOn: $usesAsDefault) }
                        Text("相同 ID 的引擎将被替换。导入不会执行引擎脚本，开始试听或朗读时才会运行。")
                            .font(.footnote).foregroundStyle(.secondary)
                        Button("重新输入") { engines = []; notes = []; selected = [] }
                    }
                }
                if working { ProgressView("正在处理…") }
                if let error { Text(error).foregroundStyle(.red) }
            }
            .navigationTitle(imported ? "导入完成" : "导入朗读引擎")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(imported ? "完成" : "取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if !imported, !engines.isEmpty {
                        Button("导入") { Task {
                            working = true
                            let values = engines.filter { selected.contains($0.id) }
                            if await library.importEngines(values) {
                                if usesAsDefault, values.count == 1 { defaultEngine = String(values[0].id) }
                                imported = true
                            } else { error = library.errorMessage }
                            working = false
                        } }.disabled(selected.isEmpty || working)
                    }
                }
            }
            .task { await library.load(); if !input.isEmpty { await preview() } }
        }
    }

    private func importState(_ engine: HttpTTS) -> String {
        guard let old = library.engines.first(where: { $0.id == engine.id }) else { return "新增" }
        return engine.lastUpdateTime > old.lastUpdateTime ? "更新 · 将替换已有引擎" : "已有 · 选择后覆盖"
    }

    private func preview() async {
        working = true; error = nil
        defer { working = false }
        do {
            let result = try await library.previewImport(input)
            engines = result.engines
            notes = result.notes
            selected = Set(engines.filter { engine in
                !library.engines.contains { $0.id == engine.id && $0.lastUpdateTime >= engine.lastUpdateTime }
            }.map(\.id))
        } catch { self.error = error.localizedDescription }
    }
}

@MainActor @ViewBuilder
private func httpTTSConfiguration(_ engine: HttpTTS, library: HttpTTSLibraryModel, sampleText: String = "你好，欢迎开始听书。") -> some View {
    if engine.openAIServiceAddress != nil {
        HttpTTSServiceSetupView(library: library, engine: engine, sampleText: sampleText)
    } else if engine.loginUi?.isEmpty == false {
        HttpTTSLoginView(engine: engine, library: library)
    } else {
        HttpTTSEditorView(engine: engine) { value in await library.save(value) }
    }
}

private struct HttpTTSServiceSetupView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var library: HttpTTSLibraryModel
    let original: HttpTTS?
    private let initialValues: [String]
    @State private var showsDiscard = false
    @State private var showsAdvanced = false
    @State private var name: String
    @State private var address: String
    @State private var apiKey: String
    @State private var voiceChoice: String
    @State private var customVoice: String
    @State private var testText: String
    @State private var voices: [HttpTTSVoice] = []
    @State private var voiceNote: String?
    @State private var voiceTask: Task<Void, Never>?
    @State private var loadingVoices = false
    @State private var hasTested = false
    @State private var error: String?
    @State private var saving = false
    @State private var usesAsDefault = true
    @State private var newID = Int64(Date().timeIntervalSince1970 * 1000)
    @StateObject private var preview = ReaderSpeechController()
    @AppStorage("appTtsEngine") private var defaultEngine = ""

    private static let names = ["zh-CN-YunxiNeural": "云希 · 男声", "zh-CN-XiaoxiaoNeural": "晓晓 · 女声",
                                "zh-CN-XiaoyiNeural": "晓伊 · 女声", "zh-CN-YunjianNeural": "云健 · 男声",
                                "zh-CN-YunxiaNeural": "云夏 · 男声", "zh-CN-YunyangNeural": "云扬 · 男声"]
    private var voice: String { voiceChoice == "custom" ? customVoice.trimmingCharacters(in: .whitespacesAndNewlines) : voiceChoice }
    private var voiceIDs: [String] { voices.isEmpty ? ["zh-CN-YunxiNeural", "zh-CN-XiaoxiaoNeural"] : voices.map(\.id) }
    private var valid: Bool { !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !voice.isEmpty }
    private var previewID: Int64 { -newID }

    init(library: HttpTTSLibraryModel, engine: HttpTTS? = nil, sampleText: String = "你好，欢迎开始听书。") {
        self.library = library
        original = engine
        let raw = engine.map { BookSourceRuntimeStore.shared.get(sourceID: $0.sourceKey, key: "loginInfo") } ?? "{}"
        let values = (try? JSONSerialization.jsonObject(with: Data(raw.utf8))) as? [String: String] ?? [:]
        let voice = values["voice"] ?? "zh-CN-YunxiNeural"
        _name = State(initialValue: engine?.name ?? "自建 TTS")
        _address = State(initialValue: engine?.openAIServiceAddress ?? "")
        _apiKey = State(initialValue: values["apiKey"] ?? "")
        _voiceChoice = State(initialValue: Self.names[voice] == nil ? "custom" : voice)
        _customVoice = State(initialValue: Self.names[voice] == nil ? voice : "")
        _testText = State(initialValue: String(sampleText.prefix(160)))
        _usesAsDefault = State(initialValue: engine == nil)
        initialValues = [engine?.name ?? "自建 TTS", engine?.openAIServiceAddress ?? "", values["apiKey"] ?? "", voice, String(engine == nil)]
    }

    private var isDirty: Bool { [name, address, apiKey, voice, String(usesAsDefault)] != initialValues }

    var body: some View {
        Form {
            Section {
                HStack {
                    Text("名称")
                    TextField("给服务起个名字", text: $name).multilineTextAlignment(.trailing)
                        .accessibilityIdentifier("speech.serviceName")
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("服务地址")
                    HStack {
                        TextField("tts.example.com", text: $address)
                            .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                            .accessibilityIdentifier("speech.serviceAddress")
                        if !address.isEmpty {
                            Button { address = "" } label: {
                                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary).frame(width: 32, height: 44)
                            }.buttonStyle(.borderless).accessibilityLabel("清空服务地址")
                        }
                    }
                }
                HStack {
                    Text("密钥")
                    SecureField("无需鉴权可留空", text: $apiKey)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().multilineTextAlignment(.trailing)
                        .foregroundStyle(.primary)
                        .accessibilityIdentifier("speech.serviceKey")
                    if !apiKey.isEmpty { Text("已填写").font(.caption).foregroundStyle(.secondary) }
                }
                Button { loadVoices() } label: {
                    HStack {
                        Text("连接并获取声音")
                        Spacer()
                        if loadingVoices { ProgressView() }
                    }
                }.disabled(address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || loadingVoices || saving)
                    .accessibilityIdentifier("speech.serviceConnect")
                if !voices.isEmpty {
                    Label("已连接 · \(voices.count) 个中文声音", systemImage: "checkmark.circle")
                        .font(.footnote).foregroundStyle(.secondary).accessibilityIdentifier("speech.serviceConnection")
                }
                if let error { Text(error).font(.footnote).foregroundStyle(.red).accessibilityIdentifier("speech.serviceError") }
            } header: { Text("服务") } footer: { Text("支持 OpenAI 兼容接口。可填域名或完整地址，接口路径会自动补全。") }
            Section {
                Picker("声音", selection: $voiceChoice) {
                    ForEach(voiceIDs, id: \.self) { id in Text(Self.names[id] ?? id).tag(id) }
                    if voiceChoice != "custom", !voiceIDs.contains(voiceChoice) { Text(Self.names[voiceChoice] ?? voiceChoice).tag(voiceChoice) }
                    Text("其他音色…").tag("custom")
                }.accessibilityIdentifier("speech.serviceVoice")
                if voiceChoice == "custom" {
                    TextField("服务提供的音色 ID", text: $customVoice)
                        .autocorrectionDisabled().textInputAutocapitalization(.never)
                        .accessibilityIdentifier("speech.serviceCustomVoice")
                }
            } header: { Text("声音") } footer: { if let voiceNote { Text(voiceNote) } }
            Section("试听") {
                ReadingTextField("试听文本", text: $testText, axis: .vertical)
                    .lineLimit(3)
                    .accessibilityIdentifier("speech.serviceText")
                Button { playPreview() } label: {
                    Label(preview.isSpeaking || preview.isPaused ? "停止试听" : "测试并试听",
                          systemImage: preview.isSpeaking || preview.isPaused ? "stop.fill" : "play.fill")
                }.disabled(!valid || testText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || loadingVoices || saving)
                    .accessibilityIdentifier("speech.servicePreview")
                if hasTested {
                    if preview.isBuffering { ProgressView("正在准备音频…") }
                    else if preview.isSpeaking {
                        Label("连接成功，正在试听", systemImage: "checkmark.circle")
                            .font(.footnote).accessibilityIdentifier("speech.servicePlayback")
                    } else if preview.completionCount > 0, preview.errorMessage == nil {
                        Label("试听完成", systemImage: "checkmark.circle").font(.footnote)
                    }
                    if let message = preview.errorMessage { Text(message).font(.footnote).foregroundStyle(.red) }
                }
            }
            Section {
                if let original, defaultEngine == String(original.id) { Label("当前默认引擎", systemImage: "checkmark.circle") }
                else { Toggle("设为默认引擎", isOn: $usesAsDefault) }
            }
            if original != nil {
                Section {
                    Button("高级规则") { showsAdvanced = true }.disabled(isDirty)
                } footer: { Text(isDirty ? "请先保存服务配置，再编辑高级规则。" : "请求脚本与解析规则，仅在需要调整接口时编辑。") }
            }
        }
        .sheet(isPresented: $showsAdvanced) {
            if let original {
                ReadingNavigationStack {
                    HttpTTSEditorView(engine: original) { value in
                        guard await library.save(value) else { return false }
                        dismiss()
                        return true
                    }
                }.readingFormPresentation()
            }
        }
        .interactiveDismissDisabled(isDirty || saving)
        .alert("放弃未保存的修改？", isPresented: $showsDiscard) {
            Button("放弃修改", role: .destructive) { dismiss() }
            Button("继续编辑", role: .cancel) {}
        }
        .readingScrollDismissesKeyboard()
        .navigationTitle(original == nil ? "连接自建服务" : "声音与连接").navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("取消") { if isDirty { showsDiscard = true } else { dismiss() } } }
            ToolbarItem(placement: .confirmationAction) { Button(saving ? "保存中…" : "保存") { save() }.disabled(!valid || saving || loadingVoices) }
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("收起键盘") { dismissKeyboard() }
            }
        }
        .onChange(of: [address, apiKey]) { _ in
            voiceTask?.cancel(); loadingVoices = false; voices = []; voiceNote = nil; resetPreview()
        }
        .onChange(of: [name, voice, testText]) { _ in resetPreview() }
        .onDisappear { voiceTask?.cancel(); resetPreview() }
    }

    private func resetPreview() {
        if hasTested {
            preview.stop()
            BookSourceRuntimeStore.shared.put(sourceID: "httpTts:\(previewID)", key: "loginInfo", value: "")
        }
        hasTested = false; error = nil
    }

    private func dismissKeyboard() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }

    private func makeEngine(id: Int64) throws -> HttpTTS {
        let generated = try HttpTTS.openAICompatible(id: id, name: name, address: address)
        var engine = try original?.updatingOpenAIServiceAddress(address) ?? generated
        engine.id = id; engine.name = generated.name
        engine.lastUpdateTime = Int64(Date().timeIntervalSince1970 * 1000)
        return engine
    }

    private func loginInfo() throws -> String {
        let raw = original.map { BookSourceRuntimeStore.shared.get(sourceID: $0.sourceKey, key: "loginInfo") } ?? "{}"
        var values = (try? JSONSerialization.jsonObject(with: Data(raw.utf8))) as? [String: Any] ?? [:]
        values["apiKey"] = apiKey.trimmingCharacters(in: .whitespacesAndNewlines); values["voice"] = voice
        return String(decoding: try JSONSerialization.data(withJSONObject: values), as: UTF8.self)
    }

    private func playPreview() {
        dismissKeyboard()
        if preview.isSpeaking || preview.isPaused { preview.stop(); return }
        do {
            error = nil
            let engine = try makeEngine(id: previewID)
            BookSourceRuntimeStore.shared.put(sourceID: engine.sourceKey, key: "loginInfo", value: try loginInfo())
            preview.configure(followsSystemRate: true, speechRate: 5, readByPage: false)
            hasTested = true
            preview.speakHTTP(engine: engine, text: testText)
        } catch { self.error = error.localizedDescription }
    }

    private func loadVoices() {
        dismissKeyboard()
        resetPreview(); voiceNote = nil; loadingVoices = true
        let address = address, key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        voiceTask = Task { @MainActor in
            defer { if !Task.isCancelled { loadingVoices = false; voiceTask = nil } }
            do {
                let result = try await HttpTTSService().voices(address: address, apiKey: key)
                guard !Task.isCancelled else { return }
                voices = result
                if result.isEmpty { voiceNote = "没有返回声音列表，可选择常用声音或填写音色 ID。" }
                else if original == nil, !result.contains(where: { $0.id == voice }) { voiceChoice = result[0].id }
            } catch {
                guard !Task.isCancelled else { return }
                if case HTTPClientError.statusResponse(let response) = error {
                    if response.statusCode == 404 || response.statusCode == 405 {
                        voiceNote = "服务未提供声音列表，可选择常用声音或填写音色 ID。"
                    } else if response.statusCode == 401 || response.statusCode == 403 {
                        self.error = "连接被拒绝，请检查密钥或服务访问权限。"
                    } else { self.error = error.localizedDescription }
                } else { self.error = error.localizedDescription }
            }
        }
    }

    private func save() {
        dismissKeyboard()
        resetPreview(); saving = true
        Task { @MainActor in
            defer { saving = false }
            do {
                let engine = try makeEngine(id: original?.id ?? newID)
                let info = try loginInfo()
                guard await library.importEngines([engine]) else { error = library.errorMessage; return }
                BookSourceRuntimeStore.shared.put(sourceID: engine.sourceKey, key: "loginInfo", value: info)
                if usesAsDefault { defaultEngine = String(engine.id) }
                dismiss()
            } catch { self.error = error.localizedDescription }
        }
    }
}

private struct HttpTTSEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var engine: HttpTTS
    let onSave: (HttpTTS) async -> Bool
    private let original: HttpTTS
    private let initialLoginInfo: String
    @State private var showsDiscard = false
    @State private var isSaving = false
    @State private var saveError: String?
    @State private var previewID = -Int64(Date().timeIntervalSince1970 * 1000)
    @StateObject private var speech = ReaderSpeechController()
    @State private var testText = "这是一段在线朗读引擎测试文本。"
    @State private var loginInfo: String
    @AppStorage("ttsFollowSys") private var followsRate = true
    @AppStorage("ttsSpeechRate") private var rate = 5
    @AppStorage("streamReadAloudAudio") private var streamsAudio = true

    init(engine: HttpTTS, onSave: @escaping (HttpTTS) async -> Bool) {
        original = engine
        initialLoginInfo = BookSourceRuntimeStore.shared.get(sourceID: engine.sourceKey, key: "loginInfo")
        _engine = State(initialValue: engine)
        self.onSave = onSave
        _loginInfo = State(initialValue: initialLoginInfo)
    }

    var body: some View {
        Form {
            Section("基本信息") {
                TextField("名称", text: $engine.name)
                fieldLabel("请求地址")
                TextEditor(text: $engine.url).font(.body.monospaced()).frame(minHeight: 90)
                    .accessibilityLabel("请求地址")
                    .autocorrectionDisabled().textInputAutocapitalization(.never)
            }
            Section("试听") {
                TextField("试听文本", text: $testText)
                Button(speech.isSpeaking ? "停止试听" : "试听此引擎", systemImage: speech.isSpeaking ? "stop.fill" : "play.fill") {
                    var previewEngine = engine
                    previewEngine.id = previewID
                    BookSourceRuntimeStore.shared.put(sourceID: previewEngine.sourceKey, key: "loginInfo", value: loginInfo)
                    speech.configure(followsSystemRate: followsRate, speechRate: rate, readByPage: false, streamsHTTPAudio: streamsAudio)
                    speech.toggleHTTP(engine: previewEngine, text: testText)
                }
                .disabled(engine.url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || testText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if speech.isBuffering { ProgressView("正在准备音频…") }
                if let error = speech.errorMessage { Text(error).foregroundStyle(.red).font(.footnote) }
            }
            Section {
                DisclosureGroup("高级配置") {
                    TextField("音频类型正则（可选）", text: optional(\.contentType))
                    TextField("并发率（可选）", text: optional(\.concurrentRate))
                    Toggle("启用 Cookie", isOn: optionalBool(\.enabledCookieJar))
                    fieldLabel("Header")
                    TextEditor(text: optional(\.header)).frame(minHeight: 80).accessibilityLabel("Header")
                    fieldLabel("JS 库")
                    TextEditor(text: optional(\.jsLib)).frame(minHeight: 100).accessibilityLabel("JS 库")
                    fieldLabel("登录地址/脚本")
                    TextEditor(text: optional(\.loginUrl)).frame(minHeight: 80).accessibilityLabel("登录地址/脚本")
                    fieldLabel("登录 UI")
                    TextEditor(text: optional(\.loginUi)).frame(minHeight: 80).accessibilityLabel("登录 UI")
                    fieldLabel("登录信息 JSON")
                    TextEditor(text: $loginInfo).frame(minHeight: 80).accessibilityLabel("登录信息 JSON")
                    fieldLabel("登录检查 JS")
                    TextEditor(text: optional(\.loginCheckJs)).frame(minHeight: 100).accessibilityLabel("登录检查 JS")
                }
            } footer: { Text("已有引擎通常只需填写服务参数。请求头和脚本仅在调试或自建引擎时修改。") }
        }
        .accessibilityIdentifier("speech.engineForm")
        .readingScrollDismissesKeyboard()
        .navigationTitle(engine.name.isEmpty ? "新建在线朗读引擎" : "高级规则 · " + engine.name)
        .navigationBarBackButtonHidden(true)
        .interactiveDismissDisabled(engine != original || loginInfo != initialLoginInfo || isSaving)
        .alert("放弃未保存的修改？", isPresented: $showsDiscard) {
            Button("放弃修改", role: .destructive) { dismiss() }
            Button("继续编辑", role: .cancel) {}
        }
        .alert("保存失败", isPresented: Binding(get: { saveError != nil }, set: { if !$0 { saveError = nil } })) {
            Button("好") { saveError = nil }
        } message: { Text(saveError ?? "") }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("取消") { if engine != original || loginInfo != initialLoginInfo { showsDiscard = true } else { dismiss() } } }
            ToolbarItem(placement: .confirmationAction) {
                Button("保存") {
                    isSaving = true
                    Task { @MainActor in
                        defer { isSaving = false }
                        guard await onSave(engine) else { saveError = "未能保存引擎，请重试。"; return }
                        BookSourceRuntimeStore.shared.put(sourceID: engine.sourceKey, key: "loginInfo", value: loginInfo)
                        dismiss()
                    }
                }
                    .disabled(engine.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || engine.url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .disabled(isSaving)
        .onDisappear {
            speech.stop()
            BookSourceRuntimeStore.shared.put(sourceID: "httpTts:\(previewID)", key: "loginInfo", value: "")
        }
    }

    private func fieldLabel(_ value: String) -> some View {
        Text(value).font(.subheadline.weight(.medium))
    }

    private func optional(_ keyPath: WritableKeyPath<HttpTTS, String?>) -> Binding<String> {
        Binding(get: { engine[keyPath: keyPath] ?? "" }, set: { engine[keyPath: keyPath] = $0.isEmpty ? nil : $0 })
    }

    private func optionalBool(_ keyPath: WritableKeyPath<HttpTTS, Bool?>) -> Binding<Bool> {
        Binding(get: { engine[keyPath: keyPath] == true }, set: { engine[keyPath: keyPath] = $0 })
    }
}

private struct HttpTTSLoginRow: Decodable, Identifiable {
    var name = ""
    var type = "text"
    var action: String?
    var chars: [String?]?
    var `default`: String?
    var viewName: String?
    var id: String { "\(name)-\(type)" }

    private enum CodingKeys: String, CodingKey { case name, type, action, chars, `default`, viewName }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        name = try values.decodeIfPresent(String.self, forKey: .name) ?? ""
        type = try values.decodeIfPresent(String.self, forKey: .type) ?? "text"
        action = try values.decodeIfPresent(String.self, forKey: .action)
        chars = try values.decodeIfPresent([String?].self, forKey: .chars)
        `default` = try values.decodeIfPresent(String.self, forKey: .default)
        viewName = try values.decodeIfPresent(String.self, forKey: .viewName)
    }
}

private struct HttpTTSLoginView: View {
    @Environment(\.dismiss) private var dismiss
    let engine: HttpTTS
    @ObservedObject var library: HttpTTSLibraryModel
    @State private var initialValues: [String: String] = [:]
    @State private var showsDiscard = false
    @State private var showsAdvanced = false
    @State private var rows: [HttpTTSLoginRow] = []
    @State private var values: [String: String] = [:]
    @State private var errorMessage: String?
    @State private var isRunning = false
    @State private var pendingFieldAction: Task<Void, Never>?

    var body: some View {
        Form {
            if rows.isEmpty, errorMessage == nil {
                ProgressView("正在生成登录表单…")
            }
            ForEach(rows) { row in
                switch row.type {
                case "password":
                    SecureField(label(for: row), text: binding(for: row))
                        .onChange(of: values[row.name]) { _ in scheduleFieldAction(row.action) }
                case "select":
                    Picker(label(for: row), selection: binding(for: row)) {
                        ForEach(options(for: row), id: \.self) { Text($0).tag($0) }
                    }
                    .onChange(of: values[row.name]) { _ in runAction(row.action) }
                case "toggle":
                    Picker(label(for: row), selection: binding(for: row)) {
                        ForEach(options(for: row), id: \.self) { Text($0).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: values[row.name]) { _ in runAction(row.action) }
                case "button":
                    Button(label(for: row)) { runAction(row.action) }
                default:
                    TextField(label(for: row), text: binding(for: row))
                        .onChange(of: values[row.name]) { _ in scheduleFieldAction(row.action) }
                }
            }
            if let errorMessage { Text(errorMessage).foregroundStyle(.red).font(.footnote) }
            Section {
                Button("高级规则") { showsAdvanced = true }.disabled(values != initialValues || isRunning)
            } footer: { Text(values != initialValues ? "请先保存参数，再编辑高级规则。" : "修改服务参数会影响使用此引擎的书籍。") }
        }
        .sheet(isPresented: $showsAdvanced) {
            ReadingNavigationStack {
                HttpTTSEditorView(engine: engine) { value in
                    guard await library.save(value) else { return false }
                    dismiss()
                    return true
                }
            }.readingFormPresentation()
        }
        .navigationBarBackButtonHidden(true)
        .interactiveDismissDisabled(values != initialValues || isRunning)
        .alert("放弃未保存的修改？", isPresented: $showsDiscard) {
            Button("放弃修改", role: .destructive) { dismiss() }
            Button("继续编辑", role: .cancel) {}
        }
        .navigationTitle("服务参数 · \(engine.name)")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("取消") { if values != initialValues { showsDiscard = true } else { dismiss() } } }
            ToolbarItem(placement: .confirmationAction) {
                Button(isRunning ? "执行中…" : (engine.loginUrl?.isEmpty == false ? "登录" : "保存参数")) { saveAndLogin() }.disabled(isRunning)
            }
        }
        .task { loadRows(); initialValues = values }
        .onDisappear { pendingFieldAction?.cancel() }
    }

    private func loadRows() {
        do {
            values = decodeLoginInfo()
            let json = try renderedLoginUI()
            rows = try JSONDecoder().decode([HttpTTSLoginRow].self, from: Data(json.utf8))
            for row in rows where row.type != "button" && values[row.name] == nil {
                values[row.name] = row.default ?? options(for: row).first ?? ""
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func renderedLoginUI() throws -> String {
        guard var raw = engine.loginUi?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return "[]"
        }
        let script: String?
        if raw.hasPrefix("@js:") {
            script = String(raw.dropFirst(4))
        } else if raw.hasPrefix("<js>"), raw.hasSuffix("</js>") {
            script = String(raw.dropFirst(4).dropLast(5))
        } else {
            script = nil
        }
        if let script {
            let result = try JavaScriptRuleEvaluator().evaluate(
                script: script,
                result: .object(values.mapValues(JSONValue.string)),
                executionContext: .init(source: engine.bookSourceAdapter)
            )
            raw = result.value.stringValue
        }
        return raw
    }

    private func decodeLoginInfo() -> [String: String] {
        let raw = BookSourceRuntimeStore.shared.get(sourceID: engine.sourceKey, key: "loginInfo")
        guard let data = raw.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return object.mapValues { String(describing: $0) }
    }

    private func binding(for row: HttpTTSLoginRow) -> Binding<String> {
        Binding(get: { values[row.name] ?? row.default ?? "" }, set: { values[row.name] = $0 })
    }

    private func options(for row: HttpTTSLoginRow) -> [String] {
        let options = row.chars?.compactMap { $0 } ?? []
        return options.isEmpty ? [row.default ?? ""] : options
    }

    private func label(for row: HttpTTSLoginRow) -> String {
        guard let value = row.viewName, value.count >= 2,
              value.first == "'", value.last == "'" else { return row.name }
        return String(value.dropFirst().dropLast())
    }

    private func runAction(_ action: String?) {
        guard let action, !action.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        isRunning = true
        errorMessage = nil
        let engine = engine
        let values = values
        Task { @MainActor in
            defer { isRunning = false }
            do {
                _ = try await Task.detached {
                    try JavaScriptRuleEvaluator().evaluate(
                        script: "\(engine.loginUrl ?? "")\n\(action)",
                        result: .object(values.mapValues(JSONValue.string)),
                        executionContext: .init(source: engine.bookSourceAdapter)
                    )
                }.value
                if engine.loginUi?.hasPrefix("@js:") == true { loadRows() }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func scheduleFieldAction(_ action: String?) {
        guard action?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else { return }
        pendingFieldAction?.cancel()
        pendingFieldAction = Task { @MainActor in
            do {
                try await Task.sleep(nanoseconds: 600_000_000)
                runAction(action)
            } catch { }
        }
    }

    private func saveAndLogin() {
        isRunning = true
        errorMessage = nil
        do {
            let data = try JSONSerialization.data(withJSONObject: values, options: [.sortedKeys])
            let raw = String(decoding: data, as: UTF8.self)
            BookSourceRuntimeStore.shared.put(sourceID: engine.sourceKey, key: "loginInfo", value: raw)
            let engine = engine
            let values = values
            Task { @MainActor in
                do {
                    if let login = engine.loginUrl?.trimmingCharacters(in: .whitespacesAndNewlines), !login.isEmpty {
                        _ = try await Task.detached {
                            try JavaScriptRuleEvaluator().evaluate(
                                script: "\(login)\nif (typeof login === 'function') login.apply(this);",
                                result: .object(values.mapValues(JSONValue.string)),
                                executionContext: .init(source: engine.bookSourceAdapter)
                            )
                        }.value
                    }
                    dismiss()
                } catch {
                    errorMessage = error.localizedDescription
                    isRunning = false
                }
            }
        } catch {
            errorMessage = error.localizedDescription
            isRunning = false
        }
    }
}

struct ConfigurationJSONDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var data: Data

    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
