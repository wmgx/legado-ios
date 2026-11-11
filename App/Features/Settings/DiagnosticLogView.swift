import SwiftUI
import UniformTypeIdentifiers

struct DiagnosticLogView: View {
    @State private var entries: [DiagnosticLogEntry] = []
    @State private var query = ""
    @State private var level = "all"
    @State private var confirmsClear = false
    @State private var exportsLog = false
    @State private var exportText = ""
    @State private var errorMessage: String?

    private var filtered: [DiagnosticLogEntry] {
        entries.filter {
            (level == "all" || $0.level.rawValue == level)
                && (query.isEmpty || "\($0.category) \($0.message)".localizedCaseInsensitiveContains(query))
        }
    }

    var body: some View {
        List {
            Section {
                Picker("级别", selection: $level) {
                    Text("全部").tag("all")
                    Text("信息").tag("info")
                    Text("警告").tag("warning")
                    Text("错误").tag("error")
                }.pickerStyle(.segmented)
                Text("\(entries.count) 条日志 · 下拉刷新")
                    .font(.footnote).foregroundStyle(.secondary)
            } footer: {
                Text("在“帮助与诊断”开启记录后，会保存网络请求、JS 输出和运行错误。崩溃诊断由 iOS 延迟提供，可搜索“系统诊断”查看。")
            }
            if filtered.isEmpty {
                ReadingUnavailableView(query.isEmpty ? "暂无日志" : "没有匹配的日志", systemImage: "doc.text.magnifyingglass")
            } else {
                ForEach(filtered) { entry in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(entry.category).font(.caption.weight(.semibold))
                            Text(levelTitle(entry.level)).font(.caption)
                                .foregroundStyle(entry.level == .error ? .red : .secondary)
                            Spacer()
                            Text(entry.date, format: .dateTime.month().day().hour().minute().second())
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        Text(entry.message).font(.system(.footnote, design: .monospaced)).textSelection(.enabled)
                    }.padding(.vertical, 3)
                }
            }
        }
        .navigationTitle("日志与诊断")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, prompt: "搜索内容或分类")
        .task { reload() }
        .refreshable { reload() }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu("日志操作", systemImage: "ellipsis") {
                    Button("刷新", systemImage: "arrow.clockwise") { reload() }
                    Button("导出全部日志", systemImage: "square.and.arrow.up") {
                        exportText = DiagnosticLog.shared.export()
                        exportsLog = true
                    }.disabled(entries.isEmpty)
                    Button("清空日志", systemImage: "trash", role: .destructive) { confirmsClear = true }
                        .disabled(entries.isEmpty)
                }
            }
        }
        .confirmationDialog("清空全部日志？", isPresented: $confirmsClear, titleVisibility: .visible) {
            Button("清空日志", role: .destructive) {
                do { try DiagnosticLog.shared.clear(); reload() }
                catch { errorMessage = error.localizedDescription }
            }
        }
        .fileExporter(isPresented: $exportsLog, document: DiagnosticLogDocument(text: exportText), contentType: .plainText, defaultFilename: "阅读诊断日志") { result in
            if case .failure(let error) = result { errorMessage = error.localizedDescription }
        }
        .alert("日志操作失败", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("好") { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
    }

    private func reload() { entries = DiagnosticLog.shared.snapshot() }
    private func levelTitle(_ level: DiagnosticLogEntry.Level) -> String {
        switch level { case .info: "信息"; case .warning: "警告"; case .error: "错误" }
    }
}

private struct DiagnosticLogDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.plainText] }
    var text: String
    init(text: String) { self.text = text }
    init(configuration: ReadConfiguration) throws {
        text = String(decoding: configuration.file.regularFileContents ?? Data(), as: UTF8.self)
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { .init(regularFileWithContents: Data(text.utf8)) }
}
