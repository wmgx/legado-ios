import SwiftUI
import UIKit

struct ReplaceRuleEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var library: ReplaceRuleLibraryModel
    @State private var rule: ReplaceRule
    @State private var mode: Int
    @State private var testTitle = "第一章 开始"
    @State private var testContent = "在这里粘贴需要净化的正文。"
    @State private var testBook = ""
    @State private var testSource = ""
    @State private var testResult: ReplaceRuleTestResult?
    @State private var errorMessage: String?
    @State private var isTesting = false
    @State private var isSaving = false
    @State private var showsDiscard = false
    private let original: ReplaceRule
    private let onSaved: ((ReplaceRule) -> Void)?

    init(rule: ReplaceRule, startsWithTest: Bool = false, sampleTitle: String? = nil,
         sampleContent: String? = nil, bookName: String = "", sourceURL: String = "",
         onSaved: ((ReplaceRule) -> Void)? = nil) {
        original = rule
        self.onSaved = onSaved
        _testTitle = State(initialValue: sampleTitle ?? "第一章 开始")
        _testContent = State(initialValue: sampleContent ?? "在这里粘贴需要净化的正文。")
        _testBook = State(initialValue: bookName)
        _testSource = State(initialValue: sourceURL)
        _rule = State(initialValue: rule)
        _mode = State(initialValue: startsWithTest ? 1 : 0)
    }

    var body: some View {
        ReadingNavigationStack {
            VStack(spacing: 0) {
                Picker("模式", selection: $mode) { Text("编辑规则").tag(0); Text("测试规则").tag(1) }
                    .pickerStyle(.segmented).padding()
                Form { if mode == 0 { configuration } else { testForm } }
            }
            .navigationTitle(rule.name.isEmpty ? "净化规则" : rule.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { if rule != original { showsDiscard = true } else { dismiss() } }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu("更多", systemImage: "ellipsis.circle") {
                        Button("复制规则 JSON", systemImage: "doc.on.doc") { UIPasteboard.general.string = json }
                        Button("粘贴规则 JSON", systemImage: "doc.on.clipboard") {
                            do {
                                guard let text = UIPasteboard.general.string else { return }
                                var pasted = try JSONDecoder().decode(ReplaceRule.self, from: Data(text.utf8))
                                pasted.id = rule.id
                                pasted.sortOrder = rule.sortOrder
                                rule = pasted
                            } catch { errorMessage = error.localizedDescription }
                        }
                        ReadingShareLink(item: json) { Label("分享规则", systemImage: "square.and.arrow.up") }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isSaving ? "保存中" : "保存") {
                        isSaving = true
                        Task {
                            let saved = await library.save(rule)
                            isSaving = false
                            if saved { onSaved?(rule); dismiss() }
                            else {
                                let message = library.notice?.detail ?? "保存失败"
                                library.notice = nil
                                errorMessage = message
                            }
                        }
                    }.disabled(isSaving || isTesting)
                }
            }
            .alert("规则提示", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("好", role: .cancel) {}
            } message: { Text(errorMessage ?? "") }
            .confirmationDialog("放弃未保存的修改？", isPresented: $showsDiscard, titleVisibility: .visible) {
                Button("放弃修改", role: .destructive) { dismiss() }
            }
            .onChange(of: rule) { _ in testResult = nil }
            .onChange(of: testTitle + testContent + testBook + testSource) { _ in testResult = nil }
        }
        .interactiveDismissDisabled(rule != original || isSaving)
    }

    private var configuration: some View {
        Group {
            Section("基本信息") {
                TextField("名称", text: $rule.name)
                TextField("分组", text: optional(\.group))
                Toggle("启用", isOn: $rule.isEnabled)
            }
            Section("匹配与替换") {
                Toggle("使用正则表达式", isOn: $rule.isRegex)
                NavigationLink {
                    RuleCodeFieldView(title: "匹配内容", path: "pattern", text: $rule.pattern, language: .regex)
                } label: { fieldPreview("匹配内容", value: rule.pattern) }
                NavigationLink {
                    RuleCodeFieldView(title: "替换为", path: "replacement", text: $rule.replacement,
                        language: rule.isRegex && rule.replacement.hasPrefix("@js:") ? .javascript : .regex)
                } label: { fieldPreview("替换为（留空即删除）", value: rule.replacement) }
                Text("正则替换使用 $1、$2 引用捕获组；以 @js: 开头可运行 JavaScript，result 为当前匹配文本，可读取 book 和 chapter。普通文本替换按字面匹配。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("作用范围") {
                Toggle("章节标题", isOn: $rule.scopeTitle)
                Toggle("正文", isOn: $rule.scopeContent)
                ReadingTextField("限定书名或书源（留空为全部）", text: optional(\.scope), axis: .vertical)
                ReadingTextField("排除书名或书源", text: optional(\.excludeScope), axis: .vertical)
            }
            Section("执行设置") {
                HStack {
                    Text("超时 (ms)")
                    TextField("3000", value: $rule.timeoutMillisecond, format: .number.grouping(.never))
                        .keyboardType(.numbersAndPunctuation).multilineTextAlignment(.trailing)
                }
                HStack {
                    Text("排序编号")
                    TextField("0", value: $rule.sortOrder, format: .number.grouping(.never))
                        .keyboardType(.numbersAndPunctuation).multilineTextAlignment(.trailing)
                }
                Text("超时小于等于 0 时使用 3000 ms。单次正则最多运行 60 秒。规则按排序编号依次执行；资源超限或超时会保留原文并报告错误。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    private var testForm: some View {
        Group {
            Section("测试上下文") {
                TextField("书名（用于作用范围判断）", text: $testBook)
                TextField("书源地址（用于作用范围判断）", text: $testSource).textInputAutocapitalization(.never)
                TextField("章节标题", text: $testTitle)
                NavigationLink {
                    RuleCodeFieldView(title: "测试正文", path: "测试输入", text: $testContent)
                } label: { fieldPreview("正文", value: testContent) }
            }
            Section {
                Button { runTest() } label: {
                    HStack { Label(isTesting ? "测试中…" : "运行当前草稿", systemImage: "play.fill"); Spacer(); if isTesting { ProgressView() } }
                }.disabled(isTesting)
                if !rule.isEnabled { Text("规则处于停用状态，结果将保持原文。可在编辑页启用后测试。").font(.footnote).foregroundStyle(.secondary) }
            }
            if let result = testResult {
                Section("测试结果 · \(result.elapsedMilliseconds.formatted(.number.precision(.fractionLength(1)))) ms") {
                    Label(result.report.effectiveRuleIDs.isEmpty ? "未改变文本（请检查匹配、启用状态及作用范围）" : "规则已生效",
                          systemImage: result.report.effectiveRuleIDs.isEmpty ? "info.circle" : "checkmark.circle")
                    ReadingLabeledContent("标题", value: result.report.title)
                    Text(result.report.content.isEmpty ? "（正文为空）" : result.report.content)
                        .font(.body.monospaced()).textSelection(.enabled)
                }
                if !result.report.diagnostics.isEmpty {
                    Section("执行错误") {
                        ForEach(result.report.diagnostics) { diagnostic in Text(diagnostic.message).foregroundStyle(.red) }
                    }
                }
            }
        }
    }

    private var json: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(rule)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }
    private func optional(_ path: WritableKeyPath<ReplaceRule, String?>) -> Binding<String> {
        Binding(get: { rule[keyPath: path] ?? "" }, set: { rule[keyPath: path] = $0.isEmpty ? nil : $0 })
    }
    private func fieldPreview(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
            Text(value.isEmpty ? "未填写" : value).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(3)
        }
    }
    private func runTest() {
        let snapshot = rule
        let title = testTitle, content = testContent, book = testBook, source = testSource
        isTesting = true
        testResult = nil
        Task {
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    try ReplaceRuleTester().test(rule: snapshot, title: title, content: content, bookName: book, sourceURL: source)
                }.value
                if rule == snapshot, title == testTitle, content == testContent, book == testBook, source == testSource { testResult = result }
            } catch { errorMessage = error.localizedDescription }
            isTesting = false
        }
    }
}
