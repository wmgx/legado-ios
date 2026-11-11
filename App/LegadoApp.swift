import SwiftUI

@main
struct LegadoApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @UIApplicationDelegateAdaptor(LegadoAppDelegate.self) private var appDelegate
    @StateObject private var sourceLibrary: SourceLibraryModel
    @StateObject private var bookLibrary: BookLibraryModel
    @StateObject private var replaceRuleLibrary: ReplaceRuleLibraryModel
    @StateObject private var readingActivity: ReadingActivityModel
    @StateObject private var rssLibrary: RSSLibraryModel
    @StateObject private var ruleSubscriptions: RuleSubscriptionModel
    @StateObject private var ttsLibrary = HttpTTSLibraryModel()
    @State private var pendingTTSImport: HttpTTSImportRequest?

    init() {
        AppDiagnostics.shared.start()
        SourceWebViewExecutorRegistry.shared.register(WKSourceWebViewExecutor())
        let demo = ProcessInfo.processInfo.arguments.contains("-uiDemo")
        _sourceLibrary = StateObject(wrappedValue: demo
            ? SourceLibraryModel.demo(sources: DemoContent.sources)
            : SourceLibraryModel.live())
        _bookLibrary = StateObject(wrappedValue: demo
            ? BookLibraryModel.demo(books: DemoContent.books)
            : BookLibraryModel.live())
        _replaceRuleLibrary = StateObject(wrappedValue: demo
            ? ReplaceRuleLibraryModel.demo()
            : ReplaceRuleLibraryModel.live())
        _readingActivity = StateObject(wrappedValue: demo
            ? ReadingActivityModel.demo(bookmarks: DemoContent.bookmarks, records: DemoContent.readRecords)
            : ReadingActivityModel.live())
        _rssLibrary = StateObject(wrappedValue: RSSLibraryModel.live())
        _ruleSubscriptions = StateObject(wrappedValue: RuleSubscriptionModel())
    }

    var body: some Scene {
        WindowGroup {
            RootTabView()
                .environmentObject(sourceLibrary)
                .environmentObject(bookLibrary)
                .environmentObject(replaceRuleLibrary)
                .environmentObject(readingActivity)
                .environmentObject(rssLibrary)
                .environmentObject(ruleSubscriptions)
                .task {
                    await sourceLibrary.load()
                    if let index = ProcessInfo.processInfo.arguments.firstIndex(of: "-uiAutomationImportURL"),
                       ProcessInfo.processInfo.arguments.indices.contains(index + 1),
                       let url = URL(string: ProcessInfo.processInfo.arguments[index + 1]) {
                        await sourceLibrary.handleDeepLink(url)
                        if ProcessInfo.processInfo.arguments.contains("-uiAutomation") {
                            sourceLibrary.notice = nil
                        }
                    }
                    await bookLibrary.load()
                    await replaceRuleLibrary.load()
                    await readingActivity.load()
                    await rssLibrary.load()
                    await ruleSubscriptions.load()
                    if !ProcessInfo.processInfo.arguments.contains("-uiDemo") {
                        await ICloudSyncModel.shared.attach(bookLibrary, sources: sourceLibrary, rules: replaceRuleLibrary,
                            rss: rssLibrary, subscriptions: ruleSubscriptions, activity: readingActivity)
                    }
                    if UserDefaults.standard.bool(forKey: "auto_refresh") {
                        await bookLibrary.checkForUpdates(sources: sourceLibrary.sources, onlyRead: UserDefaults.standard.bool(forKey: "onlyUpdateRead"))
                    }
                    await ruleSubscriptions.checkAutomaticUpdates(bookSources: sourceLibrary, rssSources: rssLibrary, replaceRules: replaceRuleLibrary)
                }
                .onReceive(bookLibrary.$books.receive(on: RunLoop.main)) { _ in ICloudSyncModel.shared.localStateChanged() }
                .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification).receive(on: RunLoop.main)) { _ in
                    ICloudSyncModel.shared.localStateChanged()
                }
                .onReceive(sourceLibrary.$sources) { _ in Task { await ICloudSyncModel.shared.refreshConfiguration() } }
                .onReceive(replaceRuleLibrary.$rules) { _ in Task { await ICloudSyncModel.shared.refreshConfiguration() } }
                .onReceive(rssLibrary.$sources) { _ in Task { await ICloudSyncModel.shared.refreshConfiguration() } }
                .onReceive(ruleSubscriptions.$values) { _ in Task { await ICloudSyncModel.shared.refreshConfiguration() } }
                .onReceive(readingActivity.$bookmarks) { _ in Task { await ICloudSyncModel.shared.refreshConfiguration() } }
                .onReceive(readingActivity.$readRecords) { _ in Task { await ICloudSyncModel.shared.refreshConfiguration() } }
                .onReceive(bookLibrary.$groups) { _ in ICloudSyncModel.shared.localStateChanged() }
                .onReceive(NotificationCenter.default.publisher(for: .legadoConfigurationChanged).receive(on: RunLoop.main)) { _ in
                    Task { await ICloudSyncModel.shared.refreshConfiguration() }
                }
                .onChange(of: scenePhase) { phase in
                    if phase == .active { Task {
                        await ICloudSyncModel.shared.refreshConfiguration()
                        await ICloudSyncModel.shared.synchronize()
                    } }
                }
                .onOpenURL { url in
                    Task {
                        if url.scheme?.lowercased() == "legado", url.host?.lowercased() == "import",
                           url.path.lowercased() == "/httptts" {
                            pendingTTSImport = .init(input: url.absoluteString)
                            return
                        }
                        if url.isFileURL, url.pathExtension.lowercased() == "json" {
                            let accessing = url.startAccessingSecurityScopedResource()
                            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
                            if let data = try? Data(contentsOf: url), (try? HttpTTS.decodeImport(data)) != nil,
                               let text = String(data: data, encoding: .utf8) {
                                pendingTTSImport = .init(input: text)
                                return
                            }
                        }
                        if url.isFileURL && url.pathExtension.lowercased() == "epub" {
                            let file = LocalBookImportFile(url: url)
                            await bookLibrary.load()
                            await bookLibrary.importPickedLocalFiles([file])
                            sourceLibrary.notice = .init(kind: bookLibrary.errorMessage == nil ? .success : .error,
                                                         title: bookLibrary.errorMessage == nil ? "EPUB 已加入书架" : "导入失败",
                                                         detail: bookLibrary.errorMessage ?? url.lastPathComponent)
                            return
                        }
                        await sourceLibrary.load()
                        if url.scheme?.lowercased() == "legado", url.path.lowercased() == "/replacerule" {
                            await replaceRuleLibrary.load()
                            await replaceRuleLibrary.importText(url.absoluteString)
                            if let notice = replaceRuleLibrary.notice {
                                sourceLibrary.notice = .init(kind: notice.kind == .error ? .error : .success, title: notice.title, detail: notice.detail)
                                replaceRuleLibrary.notice = nil
                            }
                        } else { await sourceLibrary.handleDeepLink(url) }
                    }
                }
                .sheet(item: $pendingTTSImport) { request in
                    HttpTTSImportView(input: request.input, library: ttsLibrary).readingFormPresentation()
                }
        }
    }
}

final class LegadoAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        ReaderScreenOrientation.supportedOrientations
    }
}
