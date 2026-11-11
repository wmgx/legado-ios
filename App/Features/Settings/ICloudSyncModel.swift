@preconcurrency import CloudKit
import CryptoKit
import SwiftUI

struct ReadingCloudValue: Codable, Equatable, Sendable {
    let data: Data
    let modifiedAt: Int64
    let device: String

    func merging(server: Self) -> Self {
        // Joining a device must not publish its defaults over existing cloud settings.
        if modifiedAt == 0 { return server }
        if server.modifiedAt != modifiedAt { return server.modifiedAt > modifiedAt ? server : self }
        return server.device > device ? server : self
    }
}

struct ReadingCloudFile: Codable, Equatable, Sendable {
    let name: String
    let digest: String
}

private struct ReadingCloudState: Codable {
    var values: [String: ReadingCloudValue]
    var observed: [String: Data]
}

@MainActor
final class ICloudSyncModel: ObservableObject {
    static let shared = ICloudSyncModel()
    static let containerIdentifier = "iCloud." + (Bundle.main.bundleIdentifier ?? "com.epiboly.legado")
    static let preferenceKeys = Set(["appTtsEngine", "autoReadSpeed", "auto_refresh", "bookSourceSort", "bookSourceSortDescending", "bookshelfLayout", "clickActionBottomCenter", "clickActionBottomLeft", "clickActionBottomRight", "clickActionMiddleLeft", "clickActionMiddleRight", "clickActionTopCenter", "clickActionTopLeft", "clickActionTopRight", "defaultHomePage", "enableReadRecord", "epubFontScale", "epubPublisherStyles", "epubScroll", "epubTheme", "footerMode", "footerPaddingBottom", "footerPaddingLeft", "footerPaddingRight", "footerPaddingTop", "headerMode", "headerPaddingBottom", "headerPaddingLeft", "headerPaddingRight", "headerPaddingTop", "ignoreAudioFocus", "legado.applicationSettings.v1", "letterSpacing", "lineSpacingExtra", "mediaButtonPerNext", "onlyUpdateRead", "paddingBottom", "paddingLeft", "paddingRight", "paddingTop", "pageAnim", "paragraphIndent", "paragraphSpacing", "pauseReadAloudWhilePhoneCalls", "precisionSearch", "readAloudByPage", "readAloudWakeLock", "readRecordSort", "readerTapX1", "readerTapX2", "readerTapY1", "readerTapY2", "readerScrollsToTop", "readerFullJustify", "readerHideHomeIndicator", "readerHideStatusBar", "readerKeepScreenOn", "readerPreviousDayTheme", "readerShowBrightness", "readerTheme", "readerUseBackgroundImage", "screenOrientation", "showFooterLine", "showHeaderLine", "sourceTestKeyword", "streamReadAloudAudio", "systemTtsVoice", "textBold", "textSize", "themeMode", "tipFooterLeft", "tipFooterMiddle", "tipFooterRight", "tipHeaderLeft", "tipHeaderMiddle", "tipHeaderRight", "titleBottomSpacing", "titleMode", "titleSize", "titleTopSpacing", "ttsFollowSys", "ttsSpeechRate", "ttsTimer", "underlineMode"])
    @Published private(set) var isEnabled = UserDefaults.standard.bool(forKey: "iCloudReadingSync")
    @Published private(set) var isSyncing = false
    @Published private(set) var status = "尚未开启"
    @Published private(set) var lastSynced: Date?
    private weak var library: BookLibraryModel?
    private weak var sources: SourceLibraryModel?
    private weak var rules: ReplaceRuleLibraryModel?
    private weak var rss: RSSLibraryModel?
    private weak var subscriptions: RuleSubscriptionModel?
    private weak var activity: ReadingActivityModel?
    private let defaults = UserDefaults.standard
    private let device: String
    private var values: [String: ReadingCloudValue]
    private var observed: [String: Data]
    private var files: [String: URL] = [:]
    private var fileDescriptors: [String: ReadingCloudFile] = [:]
    private var fileStamps: [String: String] = [:]
    private var scheduled: Task<Void, Never>?
    private var applying = false
    private var refreshing = false
    private var refreshAgain = false
    private var needsSync = false
    private var seen: [String: Set<String>]
    private static var stateURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Legado/icloud-state.json")
    }
    private static var downloads: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Legado/iCloudDownloads", isDirectory: true)
    }

    private init() {
        let id = defaults.string(forKey: "iCloudReadingDevice") ?? UUID().uuidString
        defaults.set(id, forKey: "iCloudReadingDevice")
        device = id
        let state = (try? Data(contentsOf: Self.stateURL)).flatMap { try? JSONDecoder().decode(ReadingCloudState.self, from: $0) }
        values = state?.values ?? [:]
        observed = state?.observed ?? [:]
        lastSynced = defaults.object(forKey: "iCloudLastSynced") as? Date
        seen = defaults.data(forKey: "iCloudSeenCollections").flatMap { try? JSONDecoder().decode([String: Set<String>].self, from: $0) } ?? [:]
    }

    nonisolated static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    nonisolated static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return try encoder.encode(value)
    }
    nonisolated static func bookKey(_ book: Book) -> String {
        let name = book.name.trimmingCharacters(in: .whitespacesAndNewlines).precomposedStringWithCanonicalMapping
        let author = book.author.trimmingCharacters(in: .whitespacesAndNewlines).precomposedStringWithCanonicalMapping
        return digest(Data((name + "\u{0}" + author).utf8))
    }
    private func remember(_ key: String, data: Data, timestamp: Int64? = nil) {
        guard observed[key] != data else { return }
        observed[key] = data
        guard values[key]?.data != data else { return }
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        let time = timestamp ?? (values[key] == nil ? 0 : max(now, (values[key]?.modifiedAt ?? 0) + 1))
        if timestamp != nil, let old = values[key], old.modifiedAt >= time { return }
        values[key] = .init(data: data, modifiedAt: time, device: device)
        needsSync = true
    }
    private func capture<T: Codable & Identifiable>(_ prefix: String, items: [T]) throws {
        var current = Set<String>()
        for item in items {
            let key = prefix + "." + Self.digest(Data(String(describing: item.id).utf8))
            current.insert(key)
            remember(key, data: try Self.encode(item))
        }
        for key in (seen[prefix] ?? []).subtracting(current) { remember(key, data: Data()) }
        seen[prefix] = current
    }
    private func captureShelf() throws {
        guard let library else { return }
        var current = Set<String>()
        for var book in library.books {
            let key = "shelf." + Self.bookKey(book)
            current.insert(key)
            if book.origin == "local" { book.bookUrl = "local://" + Self.bookKey(book); book.tocUrl = ""; book.originName = ""; book.coverUrl = nil }
            book.durChapterIndex = 0; book.durChapterPos = 0; book.durChapterTime = 0; book.durChapterTitle = nil
            book.readConfig = nil; book.lastCheckTime = 0; book.lastCheckCount = 0
            remember(key, data: try Self.encode(book))
        }
        for key in (seen["shelf"] ?? []).subtracting(current) { remember(key, data: Data()) }
        seen["shelf"] = current
        try capture("group", items: library.groups)
    }
    func attach(_ library: BookLibraryModel, sources: SourceLibraryModel, rules: ReplaceRuleLibraryModel,
                rss: RSSLibraryModel, subscriptions: RuleSubscriptionModel, activity: ReadingActivityModel) async {
        self.library = library; self.sources = sources; self.rules = rules
        self.rss = rss; self.subscriptions = subscriptions; self.activity = activity
        localStateChanged()
        await refreshConfiguration()
        if isEnabled { schedule() }
    }
    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        defaults.set(enabled, forKey: "iCloudReadingSync")
        scheduled?.cancel()
        status = enabled ? "等待同步" : "已关闭，本机与云端数据均保留"
        if enabled { Task { localStateChanged(); await refreshConfiguration(); schedule() } }
    }
    func localStateChanged() {
        guard isEnabled, !applying, let library else { return }
        let before = values
        do {
            for book in library.books {
                let key = Self.bookKey(book)
                if book.durChapterTime > 0 { remember("progress." + key, data: try Self.encode(BookProgress(book: book)), timestamp: book.durChapterTime) }
                var config = book.readConfig ?? BookReadConfig()
                config.epubLocation = nil
                remember("book." + key, data: try Self.encode(config))
            }
            for key in Self.preferenceKeys {
                let object = defaults.object(forKey: key).map { ["value": $0] } ?? ["removed": true]
                remember("setting." + key, data: try PropertyListSerialization.data(fromPropertyList: object, format: .binary, options: 0))
            }
            let path = defaults.string(forKey: "textFont") ?? ""
            remember("selectedFont", data: try Self.encode(path.isEmpty ? "" : URL(fileURLWithPath: path).lastPathComponent))
            try captureShelf()
            if before != values {
                try persist(); schedule()
                if before.filter({ $0.key.hasPrefix("shelf.") }) != values.filter({ $0.key.hasPrefix("shelf.") }) {
                    Task { await refreshConfiguration() }
                }
            }
        } catch { status = "本机同步记录保存失败：\(error.localizedDescription)" }
    }
    func refreshConfiguration() async {
        guard isEnabled, !applying, let library, let sources, let rules, let rss, let subscriptions, let activity else { return }
        guard !refreshing else { refreshAgain = true; return }
        refreshing = true
        defer {
            refreshing = false
            if refreshAgain { refreshAgain = false; Task { await refreshConfiguration() } }
        }
        do {
            let before = values
            let repository = SQLiteConfigurationRepository(database: try LegadoDatabase(url: LegadoDatabase.defaultURL()))
            try capture("source", items: sources.sources)
            try capture("replace", items: rules.rules)
            try capture("rss", items: rss.sources)
            try capture("subscription", items: subscriptions.values)
            try capture("bookmark", items: activity.bookmarks)
            try capture("history", items: activity.readRecords)
            try capture("toc", items: await repository.loadTxtTocRules())
            try capture("tts", items: await repository.loadHttpTTS())
            try capture("keyboard", items: await repository.loadKeyboardAssists())
            try capture("server", items: await repository.loadServers())
            if applying { return }
            var wanted: [String: URL] = [:]
            var names: [String: String] = [:]
            let fonts = (try? FileManager.default.contentsOfDirectory(at: ReaderFontStore.directory, includingPropertiesForKeys: nil)) ?? []
            for font in fonts where ["ttf", "otf", "ttc"].contains(font.pathExtension.lowercased()) {
                wanted["font." + Self.digest(Data(font.lastPathComponent.utf8))] = font
            }
            if FileManager.default.fileExists(atPath: ReaderBackgroundStore.url.path) { wanted["background"] = ReaderBackgroundStore.url }
            for book in library.books where book.origin == "local" {
                if let url = URL(string: book.bookUrl), url.isFileURL, FileManager.default.fileExists(atPath: url.path) {
                    let key = "file." + Self.bookKey(book)
                    wanted[key] = url
                    names[key] = String(book.name.prefix(80)).replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "\\", with: "_") + "." + url.pathExtension.lowercased()
                }
            }
            for (key, url) in wanted {
                let attributes = try url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
                let stamp = "\(url.path)|\(attributes.fileSize ?? 0)|\(attributes.contentModificationDate?.timeIntervalSince1970 ?? 0)"
                if fileStamps[key] != stamp {
                    let name = names[key] ?? url.lastPathComponent
                    let descriptor = try await Task.detached(priority: .utility) {
                        ReadingCloudFile(name: name, digest: Self.digest(try Data(contentsOf: url, options: .mappedIfSafe)))
                    }.value
                    guard isEnabled, !applying else { return }
                    fileDescriptors[key] = descriptor
                    fileStamps[key] = stamp
                }
                files[key] = url
                if let descriptor = fileDescriptors[key] { remember(key, data: try Self.encode(descriptor)) }
            }
            for key in (seen["files"] ?? []).subtracting(wanted.keys) {
                let stillOnShelf = key.hasPrefix("file.") && library.books.contains { "file." + Self.bookKey($0) == key }
                if !stillOnShelf { remember(key, data: Data()) }
                files[key] = nil; fileDescriptors[key] = nil
            }
            seen["files"] = Set(wanted.keys)
            if before != values { try persist(); schedule() }
        } catch { status = "配置暂未同步，本机数据已保留：\(error.localizedDescription)" }
    }
    private func persist() throws {
        try FileManager.default.createDirectory(at: Self.stateURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Self.encode(ReadingCloudState(values: values, observed: observed)).write(to: Self.stateURL, options: .atomic)
        defaults.set(try Self.encode(seen), forKey: "iCloudSeenCollections")
    }
    private func schedule(after seconds: Double = 3) {
        if isSyncing { needsSync = true; return }
        scheduled?.cancel()
        scheduled = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) } catch { return }
            await self?.synchronize()
        }
    }
    private var configurationValues: [String: ReadingCloudValue] { values.filter { !$0.key.hasPrefix("progress.") } }
    private func record(_ id: CKRecord.ID, database: CKDatabase, metadataOnly: Bool = false) async throws -> CKRecord? {
        let results = try await database.records(for: [id], desiredKeys: metadataOnly ? [] : nil)
        guard let result = results[id] else { throw CocoaError(.fileReadUnknown) }
        do { return try result.get() }
        catch { if (error as? CKError)?.code == .unknownItem { return nil }; throw error }
    }
    private static func payload(_ record: CKRecord) throws -> Data? {
        if let data = record["payload"] as? Data { return data }
        if let url = (record["payloadAsset"] as? CKAsset)?.fileURL { return try Data(contentsOf: url, options: .mappedIfSafe) }
        return nil
    }
    private static func value(in record: CKRecord) throws -> ReadingCloudValue? {
        guard let data = try payload(record), let timestamp = record["modifiedAt"] as? NSNumber,
              timestamp.int64Value >= 0, let device = record["device"] as? String else { return nil }
        return .init(data: data, modifiedAt: timestamp.int64Value, device: device)
    }
    private func setPayload(_ data: Data, record: CKRecord, temporary: URL) throws {
        if data.count <= 800_000 {
            record["payload"] = data as CKRecordValue; record["payloadAsset"] = nil
        } else {
            let url = temporary.appendingPathComponent(UUID().uuidString)
            try data.write(to: url, options: .atomic)
            record["payload"] = nil; record["payloadAsset"] = CKAsset(fileURL: url)
        }
    }
    func synchronize() async {
        guard isEnabled, let library else { return }
        // CloudKit can raise an Objective-C exception before Swift error handling without signing.
        guard let team = Bundle.main.object(forInfoDictionaryKey: "LegadoCloudKitTeam") as? String, !team.isEmpty else {
            status = "此版本尚未配置 iCloud 签名，暂时无法同步"
            return
        }
        if refreshing { schedule(after: 1); return }
        guard !isSyncing else { needsSync = true; return }
        isSyncing = true; needsSync = false; status = "正在同步…"
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("LegadoCloud-" + UUID().uuidString, isDirectory: true)
        var retryDelay: Double = 3
        defer {
            try? FileManager.default.removeItem(at: temporary)
            isSyncing = false
            if needsSync { needsSync = false; schedule(after: retryDelay) }
        }
        do {
            try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
            let container = CKContainer(identifier: Self.containerIdentifier)
            guard try await container.accountStatus() == .available else { status = "请在系统设置中登录 iCloud 后重试"; return }
            let database = container.privateCloudDatabase
            let id = CKRecord.ID(recordName: "configuration")
            let metadata = try await record(id, database: database, metadataOnly: true)
            let localData = try Self.encode(configurationValues)
            let missingFiles = values.contains { Self.isFileKey($0.key) && !$0.value.data.isEmpty && files[$0.key] == nil }
            if missingFiles || metadata?.recordChangeTag != defaults.string(forKey: "iCloudConfigurationTag") || Self.digest(localData) != defaults.string(forKey: "iCloudConfigurationDigest") {
                let cloud = try await record(id, database: database) ?? CKRecord(recordType: "ReadingState", recordID: id)
                let serverData = try Self.payload(cloud)
                let remote = try serverData.map { try JSONDecoder().decode([String: ReadingCloudValue].self, from: $0) } ?? [:]
                for (key, server) in remote where !key.hasPrefix("progress.") {
                    values[key] = values[key].map { $0.merging(server: server) } ?? server
                }
                guard isEnabled, !Task.isCancelled else { return }
                try await synchronizeFiles(database: database, temporary: temporary)
                applying = true
                do { try await applyConfiguration(); applying = false }
                catch { applying = false; throw error }
                let merged = try Self.encode(configurationValues)
                let saved: CKRecord
                if merged != serverData {
                    try setPayload(merged, record: cloud, temporary: temporary)
                    cloud["modifiedAt"] = NSNumber(value: Int64(Date().timeIntervalSince1970 * 1000))
                    cloud["device"] = device as CKRecordValue
                    saved = try await database.save(cloud)
                } else { saved = cloud }
                defaults.set(saved.recordChangeTag, forKey: "iCloudConfigurationTag")
                defaults.set(Self.digest(merged), forKey: "iCloudConfigurationDigest")
            }
            localStateChanged()
            let keys = library.books.map { "progress." + Self.bookKey($0) }
            for start in stride(from: 0, to: keys.count, by: 100) {
                guard isEnabled, !Task.isCancelled else { return }
                let ids = keys[start..<min(start + 100, keys.count)].map { CKRecord.ID(recordName: $0) }
                let fetched = try await database.records(for: ids)
                var saves: [CKRecord] = []
                for id in ids {
                    guard let result = fetched[id] else { throw CocoaError(.fileReadUnknown) }
                    let cloud: CKRecord
                    switch result {
                    case .success(let value): cloud = value
                    case .failure(let error):
                        guard (error as? CKError)?.code == .unknownItem else { throw error }
                        cloud = CKRecord(recordType: "ReadingState", recordID: id)
                    }
                    let server = try Self.value(in: cloud)
                    guard let merged = values[id.recordName].map({ local in server.map { local.merging(server: $0) } ?? local }) ?? server else { continue }
                    values[id.recordName] = merged
                    if merged != server {
                        cloud["payload"] = merged.data as CKRecordValue
                        cloud["modifiedAt"] = NSNumber(value: merged.modifiedAt); cloud["device"] = merged.device as CKRecordValue
                        saves.append(cloud)
                    }
                }
                if !saves.isEmpty {
                    let results = try await database.modifyRecords(saving: saves, deleting: [], savePolicy: .ifServerRecordUnchanged, atomically: false)
                    for (id, result) in results.saveResults {
                        if case .failure(let error) = result {
                            if let conflict = error as? CKError, conflict.code == .serverRecordChanged,
                               let record = conflict.serverRecord, let server = try Self.value(in: record), let local = values[id.recordName] {
                                values[id.recordName] = local.merging(server: server); needsSync = true
                            } else { throw error }
                        }
                    }
                }
            }
            guard isEnabled else { return }
            applying = true
            var progress: [String: BookProgress] = [:]
            var configurations: [String: (expected: BookReadConfig?, value: BookReadConfig)] = [:]
            for book in library.books {
                let key = Self.bookKey(book)
                if let data = values["progress." + key]?.data, let value = try? JSONDecoder().decode(BookProgress.self, from: data), value.durChapterIndex >= 0, value.durChapterPos >= 0 { progress[book.bookUrl] = value }
                if let data = values["book." + key]?.data, let config = try? JSONDecoder().decode(BookReadConfig.self, from: data) { configurations[book.bookUrl] = (book.readConfig, config) }
            }
            await library.applySyncedReadingState(progress: progress, configurations: configurations)
            applying = false
            try persist()
            localStateChanged()
            await refreshConfiguration()
            lastSynced = Date(); defaults.set(lastSynced, forKey: "iCloudLastSynced"); status = "已同步"
        } catch {
            applying = false
            try? persist()
            if let error = error as? CKError, error.code == .missingEntitlement || error.code == .badContainer {
                status = "此版本尚未配置 iCloud 签名，暂时无法同步"
            } else {
                status = "同步暂未完成，本机修改已保留。\(error.localizedDescription)"
                retryDelay = (error as? CKError)?.code == .serverRecordChanged ? 3 : min(max((error as? CKError)?.retryAfterSeconds ?? 30, 5), 120)
                needsSync = true
            }
        }
    }
    private func synchronizeFiles(database: CKDatabase, temporary: URL) async throws {
        for (key, value) in values where Self.isFileKey(key) && !value.data.isEmpty {
            guard isEnabled, !Task.isCancelled else { throw CancellationError() }
            let descriptor = try JSONDecoder().decode(ReadingCloudFile.self, from: value.data)
            guard descriptor.name == URL(fileURLWithPath: descriptor.name).lastPathComponent,
                  !descriptor.name.isEmpty, descriptor.digest.count == 64, descriptor.digest.allSatisfy({ $0.isHexDigit }) else { throw CocoaError(.fileReadCorruptFile) }
            if let url = files[key], fileDescriptors[key] == descriptor {
                let id = CKRecord.ID(recordName: "blob." + descriptor.digest)
                if try await record(id, database: database, metadataOnly: true) == nil {
                    let copy = temporary.appendingPathComponent(descriptor.digest)
                    if !FileManager.default.fileExists(atPath: copy.path) { try FileManager.default.copyItem(at: url, to: copy) }
                    let cloud = CKRecord(recordType: "ReaderFile", recordID: id)
                    cloud["file"] = CKAsset(fileURL: copy)
                    do { _ = try await database.save(cloud) }
                    catch { guard (error as? CKError)?.code == .serverRecordChanged else { throw error } }
                }
            } else {
                let target = Self.downloads.appendingPathComponent(descriptor.digest, isDirectory: true).appendingPathComponent(descriptor.name)
                if !FileManager.default.fileExists(atPath: target.path) {
                    guard let record = try await record(CKRecord.ID(recordName: "blob." + descriptor.digest), database: database),
                          let source = (record["file"] as? CKAsset)?.fileURL else { throw CocoaError(.fileReadNoSuchFile) }
                    try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try FileManager.default.copyItem(at: source, to: target)
                }
                guard Self.digest(try Data(contentsOf: target, options: .mappedIfSafe)) == descriptor.digest else { throw CocoaError(.fileReadCorruptFile) }
                files[key] = target; fileDescriptors[key] = descriptor
            }
        }
    }
    private nonisolated static func isFileKey(_ key: String) -> Bool { key == "background" || key.hasPrefix("font.") || key.hasPrefix("file.") }
    private func merged<T: Codable & Identifiable>(_ prefix: String, current: [T]) throws -> [T] {
        var items = Dictionary(current.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        for (key, value) in values where key.hasPrefix(prefix + ".") {
            if value.data.isEmpty {
                for id in items.keys where prefix + "." + Self.digest(Data(String(describing: id).utf8)) == key { items[id] = nil }
            } else {
                let item = try JSONDecoder().decode(T.self, from: value.data)
                guard key == prefix + "." + Self.digest(Data(String(describing: item.id).utf8)) else { throw CocoaError(.fileReadCorruptFile) }
                items[item.id] = item
            }
        }
        return Array(items.values)
    }
    private func applyConfiguration() async throws {
        guard let library, let sources, let rules, let rss, let subscriptions, let activity else { return }
        try await sources.applySyncedSources(try merged("source", current: sources.sources))
        try await rules.applySyncedRules(try merged("replace", current: rules.rules))
        try await rss.applySyncedSources(try merged("rss", current: rss.sources))
        let repository = SQLiteConfigurationRepository(database: try LegadoDatabase(url: LegadoDatabase.defaultURL()))
        let toc: [TxtTocRule] = try merged("toc", current: await repository.loadTxtTocRules())
        for item in toc where !item.rule.isEmpty { _ = try NSRegularExpression(pattern: item.rule, options: .anchorsMatchLines) }
        try await repository.saveTxtTocRules(toc)
        try await repository.saveHttpTTS(try merged("tts", current: await repository.loadHttpTTS()))
        try await repository.saveRuleSubs(try merged("subscription", current: subscriptions.values))
        try await repository.saveKeyboardAssists(try merged("keyboard", current: await repository.loadKeyboardAssists()))
        try await repository.saveServers(try merged("server", current: await repository.loadServers()))
        await subscriptions.load()
        await library.applySyncedGroups(try merged("group", current: library.groups))
        try await activity.applySyncedActivity(bookmarks: merged("bookmark", current: activity.bookmarks), records: merged("history", current: activity.readRecords))
        for (key, value) in values where key.hasPrefix("font.") && !value.data.isEmpty {
            if let source = files[key] { _ = try ReaderFontStore.install(from: source) }
        }
        if let background = values["background"] {
            if background.data.isEmpty { ReaderBackgroundStore.remove() }
            else if let source = files["background"], source != ReaderBackgroundStore.url {
                guard ReaderBackgroundStore.load(from: source) != nil else { throw CocoaError(.fileReadCorruptFile) }
                try FileManager.default.createDirectory(at: ReaderBackgroundStore.url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data(contentsOf: source).write(to: ReaderBackgroundStore.url, options: .atomic)
                NotificationCenter.default.post(name: .legadoConfigurationChanged, object: nil)
            }
        }
        for (key, value) in values where key.hasPrefix("shelf.") {
            guard isEnabled else { return }
            if value.data.isEmpty {
                let urls = Set(library.books.filter { "shelf." + Self.bookKey($0) == key }.map(\.bookUrl))
                await library.removeSyncedBooks(urls)
            } else {
                var remote = try JSONDecoder().decode(Book.self, from: value.data)
                guard key == "shelf." + Self.bookKey(remote) else { throw CocoaError(.fileReadCorruptFile) }
                if let local = library.books.first(where: { Self.bookKey($0) == Self.bookKey(remote) }) {
                    // Each device keeps its valid local path or source URL for the same logical book.
                    remote.bookUrl = local.bookUrl; remote.tocUrl = local.tocUrl; remote.origin = local.origin
                    remote.originName = local.originName; remote.coverUrl = local.coverUrl
                    remote.durChapterIndex = local.durChapterIndex; remote.durChapterPos = local.durChapterPos
                    remote.durChapterTime = local.durChapterTime; remote.durChapterTitle = local.durChapterTitle; remote.readConfig = local.readConfig
                    var baseline = remote
                    if baseline.origin == "local" { baseline.bookUrl = "local://" + Self.bookKey(baseline); baseline.tocUrl = ""; baseline.originName = ""; baseline.coverUrl = nil }
                    baseline.durChapterIndex = 0; baseline.durChapterPos = 0; baseline.durChapterTime = 0; baseline.durChapterTitle = nil
                    baseline.readConfig = nil; baseline.lastCheckTime = 0; baseline.lastCheckCount = 0
                    observed[key] = try Self.encode(baseline)
                    let fileKey = "file." + Self.bookKey(remote)
                    if local.origin == "local", let source = files[fileKey], source != URL(string: local.bookUrl) {
                        observed[fileKey] = values[fileKey]?.data
                        try await library.importSyncedBook(from: source, metadata: remote, replacing: local.bookUrl)
                        continue
                    }
                    await library.addOrUpdate(remote)
                } else if remote.origin == "local" {
                    guard let source = files["file." + Self.bookKey(remote)] else { throw CocoaError(.fileReadNoSuchFile) }
                    observed["book." + Self.bookKey(remote)] = try Self.encode(BookReadConfig())
                    try await library.importSyncedBook(from: source, metadata: remote)
                } else {
                    observed["book." + Self.bookKey(remote)] = try Self.encode(BookReadConfig())
                    await library.addOrUpdate(remote)
                }
            }
        }
        for key in Self.preferenceKeys {
            if let data = values["setting." + key]?.data,
               let object = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] {
                if key == ApplicationSettingsStore.key, let data = object["value"] as? Data {
                    try ApplicationSettingsStore.shared.save(JSONDecoder().decode(ApplicationSettings.self, from: data))
                    if let value = defaults.object(forKey: key) {
                        observed["setting." + key] = try PropertyListSerialization.data(fromPropertyList: ["value": value], format: .binary, options: 0)
                    }
                } else if let value = object["value"] { defaults.set(value, forKey: key) }
                else if object["removed"] as? Bool == true { defaults.removeObject(forKey: key) }
            }
        }
        if let data = values["selectedFont"]?.data, let name = try? JSONDecoder().decode(String.self, from: data) {
            guard name.isEmpty || name == URL(fileURLWithPath: name).lastPathComponent else { throw CocoaError(.fileReadCorruptFile) }
            defaults.set(name.isEmpty ? "" : ReaderFontStore.directory.appendingPathComponent(name).path, forKey: "textFont")
        }
    }
}
