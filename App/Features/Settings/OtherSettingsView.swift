import SwiftUI
import WebKit

struct SyncSettingsView: View {
    @ObservedObject private var cloud = ICloudSyncModel.shared
    var body: some View {
        Form {
            Section {
                Toggle("iCloud 同步", isOn: Binding(get: { cloud.isEnabled }, set: { cloud.setEnabled($0) }))
                if cloud.isEnabled {
                    Text(cloud.status).font(.footnote).foregroundStyle(.secondary)
                    if let date = cloud.lastSynced {
                        Text("上次同步：\(date.formatted(date: .abbreviated, time: .shortened))").font(.caption).foregroundStyle(.secondary)
                    }
                    Button("立即同步") { Task { await cloud.synchronize() } }.disabled(cloud.isSyncing)
                }
            } header: { Text("设备间同步") } footer: {
                Text("使用同一 Apple 账号同步书架、本地 TXT/EPUB、进度、书签、阅读记录、书源、RSS、规则、订阅、朗读引擎、字体、背景和设置。配置中填写的密钥也会同步至个人 iCloud；登录会话、缓存和日志留在本机。关闭同步不会删除数据。")
            }
        }
        .navigationTitle("同步")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct StartupSettingsView: View {
    @AppStorage("auto_refresh") private var autoRefresh = false
    @AppStorage("onlyUpdateRead") private var onlyUpdateRead = false
    @AppStorage("defaultHomePage") private var defaultHomePage = "bookshelf"
    var body: some View {
        Form {
            Section("启动与书架") {
                Picker("启动页面", selection: $defaultHomePage) {
                    Text("书架").tag("bookshelf")
                    Text("发现").tag("explore")
                    Text("统计").tag("statistics")
                    Text("我的").tag("settings")
                }
                Toggle("启动时更新书架", isOn: $autoRefresh)
                Toggle("自动更新仅检查读过的书", isOn: $onlyUpdateRead).disabled(!autoRefresh)
            }
            Section { Text("修改后立即生效。").font(.footnote).foregroundStyle(.secondary) }
        }
        .navigationTitle("启动与书架")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct DiagnosticsSettingsView: View {
    @State private var settings = ApplicationSettingsStore.shared.settings
    @State private var message: String?
    var body: some View {
        Form {
            Section {
                Toggle("记录运行日志", isOn: Binding(get: { settings.recordLog }, set: { enabled in
                    var value = ApplicationSettingsStore.shared.settings
                    value.recordLog = enabled
                    do { try ApplicationSettingsStore.shared.save(value); settings = value }
                    catch { message = error.localizedDescription }
                }))
                NavigationLink {
                    DiagnosticLogView()
                } label: { Label("日志与诊断", systemImage: "doc.text.magnifyingglass") }
            } header: { Text("诊断") } footer: {
                Text("日志仅保存在本机，最多保留 500 条。网络日志不记录请求正文与 Header，URL 查询参数和常见凭据会隐藏。")
            }
        }
        .navigationTitle("帮助与诊断")
        .navigationBarTitleDisplayMode(.inline)
        .alert("保存失败", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("好") { message = nil }
        } message: { Text(message ?? "") }
    }
}

struct StorageMaintenanceView: View {
    @State private var maintenance: Maintenance?
    @State private var isWorking = false
    @State private var message: String?

    private enum Maintenance: String, Identifiable {
        case webCache = "清理网页缓存"
        case database = "整理数据库"
        var id: String { rawValue }
    }

    var body: some View {
        Form {
            Section {
                Button("清理网页缓存", systemImage: "globe") { maintenance = .webCache }
                Button("整理数据库", systemImage: "externaldrive.badge.checkmark") { maintenance = .database }
            }
        }
        .navigationTitle("存储维护")
        .navigationBarTitleDisplayMode(.inline)
        .disabled(isWorking)
        .overlay { if isWorking { ProgressView("正在处理…").padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12)) } }
        .confirmationDialog(maintenance?.rawValue ?? "", isPresented: Binding(
            get: { maintenance != nil }, set: { if !$0 { maintenance = nil } }
        ), titleVisibility: .visible) {
            if let operation = maintenance {
                Button(operation.rawValue) { Task { await perform(operation) } }
            }
            Button("取消", role: .cancel) { maintenance = nil }
        } message: {
            Text(maintenance == .webCache ? "清理网页和图片的临时缓存，保留登录 Cookie、书架和阅读进度。" : "回收数据库中的空闲空间，保留全部书籍、规则和阅读记录。")
        }
        .alert("操作结果", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("好") { message = nil }
        } message: { Text(message ?? "") }
    }

    @MainActor private func perform(_ operation: Maintenance) async {
        maintenance = nil
        isWorking = true
        defer { isWorking = false }
        do {
            switch operation {
            case .webCache:
                await WKWebsiteDataStore.default().removeData(ofTypes: [WKWebsiteDataTypeDiskCache, WKWebsiteDataTypeMemoryCache, WKWebsiteDataTypeOfflineWebApplicationCache], modifiedSince: .distantPast)
                URLCache.shared.removeAllCachedResponses()
            case .database:
                let database = try LegadoDatabase(url: LegadoDatabase.defaultURL())
                try await database.compact()
            }
            DiagnosticLog.shared.record(category: "存储", message: "\(operation.rawValue)完成")
            message = "\(operation.rawValue)完成"
        } catch {
            DiagnosticLog.shared.record(.error, category: "存储", message: error.localizedDescription)
            message = error.localizedDescription
        }
    }
}

struct NetworkSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var settings = ApplicationSettingsStore.shared.settings
    @State private var errorMessage: String?
    @State private var isSaving = false
    @State private var initialSettings = ApplicationSettingsStore.shared.settings
    @State private var showsDiscard = false

    var body: some View {
        Form {
            Section {
                ReadingTextField("留空使用默认浏览器 UA", text: $settings.userAgent, axis: .vertical)
                    .textInputAutocapitalization(.never).disableAutocorrection(true)
                    .accessibilityLabel("User-Agent")
            } header: { Text("默认 User-Agent") } footer: {
                Text("书源或 RSS 单独设置的 UA 优先于此项。")
            }
            Section {
                TextField("例如 http://127.0.0.1:7890", text: $settings.proxy)
                    .keyboardType(.URL).textInputAutocapitalization(.never).disableAutocorrection(true)
                    .accessibilityLabel("全局代理")
            } header: { Text("全局代理") } footer: {
                Text("支持 HTTP、HTTPS 和 SOCKS5 地址，不含账号密码。书源代理优先于全局代理；使用代理时由代理解析域名。")
            }
            Section {
                TextEditor(text: $settings.hosts)
                    .font(.system(.footnote, design: .monospaced)).frame(minHeight: 130)
                    .textInputAutocapitalization(.never).disableAutocorrection(true)
                    .accessibilityLabel("Hosts")
            } header: { Text("自定义 Hosts") } footer: {
                Text("每行填写 IP地址 域名，例如 192.168.1.2 books.example.com。支持 IPv4、IPv6 和 # 注释。适用于应用内 HTTP/HTTPS 请求；系统网页、登录网页和系统媒体播放器使用系统网络设置。")
            }
            Section("连接") {
                Picker("请求超时", selection: $settings.timeoutSeconds) {
                    Text("跟随书源").tag(0)
                    ForEach([5, 10, 15, 30, 60, 120, 180, 300], id: \.self) { Text("\($0) 秒").tag($0) }
                }
                Stepper("搜索并发数：\(settings.concurrentSources)", value: $settings.concurrentSources, in: 1...64)
                Toggle("兼容无效证书的书源", isOn: $settings.ignoreCertificateErrors)
                Text("证书兼容开启时允许自签名或过期证书；关闭后由系统验证 HTTPS 证书。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section {
                Button("恢复本页默认值") {
                    let defaults = ApplicationSettings()
                    settings.userAgent = defaults.userAgent
                    settings.proxy = defaults.proxy
                    settings.hosts = defaults.hosts
                    settings.timeoutSeconds = defaults.timeoutSeconds
                    settings.concurrentSources = defaults.concurrentSources
                    settings.ignoreCertificateErrors = defaults.ignoreCertificateErrors
                }
            }
        }
        .navigationTitle("网络设置")
        .navigationBarBackButtonHidden(true)
        .interactiveDismissDisabled(settings != initialSettings || isSaving)
        .navigationBarTitleDisplayMode(.inline)
        .alert("放弃未保存的修改？", isPresented: $showsDiscard) {
            Button("放弃修改", role: .destructive) { dismiss() }
            Button("继续编辑", role: .cancel) {}
        }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("取消") { if settings != initialSettings { showsDiscard = true } else { dismiss() } }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("保存") { Task { await save() } }.disabled(isSaving)
            }
        }
        .disabled(isSaving)
        .alert("保存失败", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("好") { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
    }

    @MainActor private func save() async {
        isSaving = true
        defer { isSaving = false }
        do {
            let current = ApplicationSettingsStore.shared.settings
            settings.recordLog = current.recordLog
            settings.chapterCacheMB = current.chapterCacheMB
            settings.prefetchChapters = current.prefetchChapters
            try ApplicationSettingsStore.shared.save(settings)
            DiagnosticLog.shared.record(category: "设置", message: "网络设置已保存")
            dismiss()
        } catch { errorMessage = error.localizedDescription }
    }
}
