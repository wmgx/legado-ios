import SwiftUI
import UIKit

struct SourceEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var library: SourceLibraryModel
    let original: BookSource?
    let onSaved: ((BookSource) -> Void)?
    @State private var document: BookSourceEditorDocument
    @State private var jsonText: String
    @State private var mode = 0
    @State private var sectionID = "basic"
    @State private var errorMessage: String?
    @State private var validation: [BookSourceIssue] = []
    @State private var debugSource: BookSource?
    @State private var isSaving = false
    @State private var showsDiscard = false
    private let initialJSON: String

    init(source: BookSource? = nil, onSaved: ((BookSource) -> Void)? = nil) {
        self.onSaved = onSaved
        original = source
        let doc = try! BookSourceEditorDocument(source: source ?? BookSource(bookSourceUrl: "", bookSourceName: ""))
        let json = (try? doc.json()) ?? "{}"
        initialJSON = json
        _document = State(initialValue: doc)
        _jsonText = State(initialValue: json)
    }

    private var isDirty: Bool { mode == 1 ? jsonText != initialJSON : (try? document.json()) != initialJSON }
    private var currentSection: BookSourceEditorSection { BookSourceEditorSchema.sections.first { $0.id == sectionID }! }

    var body: some View {
        ReadingNavigationStack {
            VStack(spacing: 0) {
                Picker("编辑模式", selection: Binding(get: { mode }, set: { value in switchMode(value) })) {
                    Text("字段编辑").tag(0)
                    Text("JSON").tag(1)
                }.pickerStyle(.segmented).padding(.horizontal).padding(.vertical, 8)
                if mode == 1 {
                    SyntaxCodeEditor(text: $jsonText, language: .json)
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack {
                            ForEach(BookSourceEditorSchema.sections) { section in
                                Button(section.title) { sectionID = section.id }
                                    .readingChoiceButtonStyle(isSelected: sectionID == section.id)
                            }
                            Button("选项") { sectionID = "options" }
                                .readingChoiceButtonStyle(isSelected: sectionID == "options")
                        }.padding(.horizontal)
                    }.padding(.vertical, 6)
                    Form {
                        if sectionID == "options" { options }
                        else {
                            Section(currentSection.title) {
                                ForEach(currentSection.fields) { field in
                                    if ["bookSourceName", "bookSourceUrl", "bookSourceGroup", "bookSourceComment"].contains(field.path) {
                                        VStack(alignment: .leading, spacing: 6) {
                                            Text(field.title).font(.subheadline)
                                            ReadingTextField(field.title, text: string(field.path), axis: .vertical)
                                                .textInputAutocapitalization(.never).autocorrectionDisabled()
                                                .accessibilityIdentifier("source.field.\(field.path)")
                                        }
                                    } else {
                                        NavigationLink {
                                            RuleCodeFieldView(title: field.title, path: field.path, text: string(field.path),
                                                              language: field.isJavaScript ? .javascript : .rule, help: field.help)
                                        } label: {
                                            VStack(alignment: .leading, spacing: 5) {
                                                Text(field.title)
                                                Text(document.value(at: field.path)?.stringValue.isEmpty == false ? document.value(at: field.path)!.stringValue : field.path)
                                                    .font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(2)
                                            }
                                        }
                                    }
                                }
                            }
                            Section {
                                Text("点击规则字段可全屏编辑。支持 @css:、XPath、$. JSONPath、@js:、{{key}}、{{page}} 和 ## 替换语法。未识别的扩展字段保留在 JSON 中。")
                                    .font(.footnote).foregroundStyle(.secondary)
                            }
                        }
                        if !validation.isEmpty {
                            Section("静态检查") {
                                ForEach(validation) { issue in
                                    Label("\(issue.field)：\(issue.message)", systemImage: issue.severity == .error ? "xmark.circle" : "exclamationmark.triangle")
                                        .font(.footnote).foregroundStyle(issue.severity == .error ? .red : .orange)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle(original == nil ? "新建书源" : "编辑书源")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { if isDirty { showsDiscard = true } else { dismiss() } }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu("更多", systemImage: "ellipsis.circle") {
                        Button("格式化 JSON", systemImage: "text.alignleft") { perform { try synchronize(); jsonText = try document.json() } }
                        Button("校验配置", systemImage: "checkmark.shield") { check() }
                        Button("调试当前草稿", systemImage: "stethoscope") { perform { try synchronize(); debugSource = try document.source() } }
                        Button("复制 JSON", systemImage: "doc.on.doc") { perform { try synchronize(); UIPasteboard.general.string = try document.json() } }
                        Button("粘贴 JSON", systemImage: "doc.on.clipboard") {
                            perform {
                                guard let value = UIPasteboard.general.string else { return }
                                let pasted = try BookSourceEditorDocument(json: value)
                                _ = try JSONDecoder().decode(BookSource.self, from: Data(pasted.json().utf8))
                                document = pasted
                                jsonText = try pasted.json()
                            }
                        }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isSaving ? "保存中" : "保存", action: save).disabled(isSaving)
                }
            }
            .readingNavigationDestination(isPresented: Binding(
                get: { debugSource != nil },
                set: { if !$0 { debugSource = nil } }
            )) {
                if let debugSource { SourceDebugView(source: debugSource) }
            }
            .alert("无法完成操作", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("好", role: .cancel) {}
            } message: { Text(errorMessage ?? "") }
            .alert("放弃未保存的修改？", isPresented: $showsDiscard) {
                Button("放弃修改", role: .destructive) { dismiss() }
                Button("继续编辑", role: .cancel) {}
            }
        }
        .interactiveDismissDisabled(isDirty || isSaving)
    }

    private var options: some View {
        Group {
            Section("书源类型") {
                Picker("类型", selection: Binding(get: { Int(document.value(at: "bookSourceType")?.stringValue ?? "0") ?? 0 },
                    set: { document.set(.number(Double($0)), at: "bookSourceType") })) {
                    Text("文本").tag(0); Text("音频").tag(1); Text("图片").tag(2); Text("文件").tag(3); Text("视频").tag(4)
                }
            }
            Section("开关") {
                Toggle("启用书源", isOn: boolean("enabled", fallback: true))
                Toggle("启用发现", isOn: boolean("enabledExplore", fallback: true))
                Toggle("Cookie Jar", isOn: boolean("enabledCookieJar", fallback: true))
                Toggle("事件监听", isOn: boolean("eventListener"))
                Toggle("定制按钮", isOn: boolean("customButton"))
            }
            Section("排序与状态") {
                ForEach(["customOrder", "weight", "lastUpdateTime", "respondTime"], id: \.self) { key in
                    HStack {
                        Text(["customOrder": "排序编号", "weight": "搜索权重", "lastUpdateTime": "更新时间 (ms)", "respondTime": "响应时间 (ms)"][key]!)
                        TextField(key, text: number(key)).keyboardType(.numbersAndPunctuation).multilineTextAlignment(.trailing)
                    }
                }
            }
        }
    }

    private func string(_ path: String) -> Binding<String> {
        Binding(get: { document.value(at: path)?.stringValue ?? "" }, set: { document.set($0.isEmpty ? nil : .string($0), at: path) })
    }
    private func boolean(_ path: String, fallback: Bool = false) -> Binding<Bool> {
        Binding(get: { if case .bool(let value) = document.value(at: path) { return value }; return fallback },
                set: { document.set(.bool($0), at: path) })
    }
    private func number(_ path: String) -> Binding<String> {
        Binding(get: { document.value(at: path)?.stringValue ?? "0" }, set: { document.set(.string($0), at: path) })
    }
    private func synchronize() throws { if mode == 1 { document = try BookSourceEditorDocument(json: jsonText) } }
    private func switchMode(_ next: Int) {
        guard next != mode else { return }
        perform {
            if next == 0 { try synchronize() }
            else { jsonText = try document.json() }
            mode = next
        }
    }
    private func perform(_ action: () throws -> Void) {
        do { try action() } catch { errorMessage = readable(error) }
    }
    private func readable(_ error: Error) -> String {
        if case DecodingError.typeMismatch(_, let context) = error {
            return "\(context.codingPath.map(\.stringValue).joined(separator: "."))：字段类型不正确。\(context.debugDescription)"
        }
        return error.localizedDescription
    }
    private func check() {
        perform {
            try synchronize()
            let source = try JSONDecoder().decode(BookSource.self, from: Data(document.json().utf8))
            validation = BookSourceValidator.validate(source)
            if validation.isEmpty { errorMessage = "静态检查通过。可通过“调试当前草稿”验证实际请求及解析结果。" }
        }
    }
    private func save() {
        perform {
            try synchronize()
            var source = try document.source()
            if library.sources.contains(where: { $0.id == source.id && $0.id != original?.id }) {
                throw BookSourceImportError.duplicate(source.id)
            }
            source.lastUpdateTime = Int64(Date().timeIntervalSince1970 * 1_000)
            isSaving = true
            Task {
                let saved = await library.saveSource(source, replacing: original?.id)
                isSaving = false
                if saved { onSaved?(source); dismiss() }
                else {
                    let message = library.notice?.detail ?? "保存失败"
                    library.notice = nil
                    errorMessage = message
                }
            }
        }
    }
}
