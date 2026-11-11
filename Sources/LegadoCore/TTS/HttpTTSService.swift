import Foundation
import CryptoKit

public enum HttpTTSServiceError: Error, LocalizedError, Sendable {
    case emptyText
    case emptyAudio
    case audioTooLarge
    case invalidContentType(expected: String, actual: String, body: String)
    case textResponse(contentType: String, body: String)

    public var errorDescription: String? {
        switch self {
        case .emptyText:
            "朗读文本为空"
        case .emptyAudio:
            "朗读引擎返回了空音频"
        case .audioTooLarge:
            "本段朗读音频过大，请检查引擎配置"
        case .invalidContentType(let expected, let actual, let body):
            "TTS 返回类型不匹配（期望 \(expected)，实际 \(actual)）：\(body)"
        case .textResponse(_, let body):
            Self.responseMessage(body)
        }
    }

    private static func responseMessage(_ body: String) -> String {
        let value = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any]
        let nested = value?["error"] as? [String: Any]
        let message = [value?["err_msg"], value?["message"], value?["msg"], value?["detail"], nested?["message"], value?["error"]]
            .compactMap { $0 as? String }.first { !$0.isEmpty }
        let plain = body.trimmingCharacters(in: .whitespacesAndNewlines)
        let detail = String((message ?? (plain.hasPrefix("<") || plain.hasPrefix("{") ? "未提供音频" : plain)).prefix(160))
        if detail.localizedCaseInsensitiveContains("auth") {
            return "朗读服务鉴权失败，请更新声源或检查凭据（\(detail)）"
        }
        return "朗读服务返回错误：\(detail.isEmpty ? "未提供音频" : detail)"
    }
}

public struct HttpTTSAudio: Sendable {
    public var data: Data
    public var contentType: String?
    public var finalURL: URL

    public init(data: Data, contentType: String?, finalURL: URL) {
        self.data = data
        self.contentType = contentType
        self.finalURL = finalURL
    }
}

public struct HttpTTSVoice: Decodable, Hashable, Identifiable, Sendable {
    public let name: String
    public let language: String?
    public let gender: String?
    public var id: String { name }
}

public struct HttpTTSAudioStream: Sendable {
    public var contentType: String?
    public var finalURL: URL
    public var expectedContentLength: Int64?
    public var chunks: AsyncThrowingStream<Data, Error>
    public var isIncremental: Bool

    public init(
        contentType: String?,
        finalURL: URL,
        expectedContentLength: Int64?,
        chunks: AsyncThrowingStream<Data, Error>,
        isIncremental: Bool
    ) {
        self.contentType = contentType
        self.finalURL = finalURL
        self.expectedContentLength = expectedContentLength
        self.chunks = chunks
        self.isIncremental = isIncremental
    }
}

public actor HttpTTSAudioCache {
    public static let shared = HttpTTSAudioCache()
    private let directory: URL
    private let maximumBytes: Int64

    public init(directory: URL? = nil, maximumBytes: Int64 = 128 * 1_024 * 1_024) {
        self.directory = directory ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Legado/httpTTS_cache", isDirectory: true)
        self.maximumBytes = maximumBytes
    }

    public func data(for key: String) -> Data? {
        let url = directory.appendingPathComponent(key + ".audio")
        guard let data = try? Data(contentsOf: url) else { return nil }
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
        return data
    }

    public func store(_ data: Data, for key: String) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: directory.appendingPathComponent(key + ".audio"), options: .atomic)
            trimIfNeeded()
        } catch { }
    }

    public func clear() { try? FileManager.default.removeItem(at: directory) }

    private func trimIfNeeded() {
        let keys: Set<URLResourceKey> = [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        ) else { return }
        var entries: [(URL, Int64, Date)] = files.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: keys), values.isRegularFile == true else { return nil }
            return (url, Int64(values.fileSize ?? 0), values.contentModificationDate ?? .distantPast)
        }
        var total = entries.reduce(Int64(0)) { $0 + $1.1 }
        guard total > maximumBytes else { return }
        entries.sort { $0.2 < $1.2 }
        for entry in entries where total > maximumBytes {
            try? FileManager.default.removeItem(at: entry.0)
            total -= entry.1
        }
    }
}

public actor HttpTTSService {
    private let urlBuilder: LegadoURLBuilder
    private let networkPolicy: SourceNetworkPolicy
    private let transport: any HTTPTransport
    private let cache: HttpTTSAudioCache

    public init(
        urlBuilder: LegadoURLBuilder = .init(),
        networkPolicy: SourceNetworkPolicy = .shared,
        transport: any HTTPTransport = URLSessionHTTPTransport(),
        cache: HttpTTSAudioCache = .shared
    ) {
        self.urlBuilder = urlBuilder
        self.networkPolicy = networkPolicy
        self.transport = transport
        self.cache = cache
    }

    public func voices(address: String, apiKey: String) async throws -> [HttpTTSVoice] {
        let engine = try HttpTTS.openAICompatible(id: 0, name: "服务", address: address)
        guard let endpoint = engine.openAIServiceAddress, let base = URL(string: endpoint),
              var url = URLComponents(url: base.deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("voices"), resolvingAgainstBaseURL: false) else { throw URLError(.badURL) }
        url.queryItems = [.init(name: "language", value: "zh-CN")]
        guard let address = url.url else { throw URLError(.badURL) }
        var request = URLRequest(url: address, timeoutInterval: 15)
        if !apiKey.isEmpty { request.setValue("Bearer " + apiKey, forHTTPHeaderField: "Authorization") }
        let response = try await transport.data(for: request)
        guard (200..<300).contains(response.statusCode) else { throw HTTPClientError.statusResponse(response) }
        guard response.data.count <= 2 * 1024 * 1024 else { throw BookSourceImportError.invalidDocument("声音列表超过 2 MB") }
        struct VoiceList: Decodable { let voices: [HttpTTSVoice] }
        let voices = try JSONDecoder().decode(VoiceList.self, from: response.data).voices
        var seen = Set<String>()
        return voices.filter { !$0.name.isEmpty && seen.insert($0.id).inserted }
    }

    public func audio(engine: HttpTTS, text: String, speechRate: Int) async throws -> HttpTTSAudio {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw HttpTTSServiceError.emptyText }
        let source = engine.bookSourceAdapter
        let cacheKey = try Self.cacheKey(engine: engine, text: text, speechRate: speechRate)
        if let data = await cache.data(for: cacheKey) {
            return .init(data: data, contentType: engine.contentType, finalURL: cacheURL(engine: engine))
        }
        let context = URLTemplateContext(
            key: text,
            variables: [
                "speakText": text,
                "speakSpeed": String(speechRate)
            ],
            source: source
        )
        var lastError: Error = HttpTTSServiceError.emptyText
        for attempt in 0..<3 {
            try Task.checkCancellation()
            do {
                let prepared = try urlBuilder.prepare(
                    engine.url,
                    context: context,
                    defaultHeaders: try BookSourceHeaderResolver().resolve(source)
                )
                var response = try await networkPolicy.execute(
                    prepared,
                    source: source,
                    transport: transport,
                    timeout: 300
                )
                if try evaluateLoginCheckIfNeeded(engine: engine, source: source, response: response) {
                    let rebuilt = try urlBuilder.prepare(
                        engine.url,
                        context: context,
                        defaultHeaders: try BookSourceHeaderResolver().resolve(source)
                    )
                    response = try await networkPolicy.execute(
                        rebuilt,
                        source: source,
                        transport: transport,
                        timeout: 300
                    )
                }
                let contentType = response.headers.first {
                    $0.key.caseInsensitiveCompare("Content-Type") == .orderedSame
                }?.value.components(separatedBy: ";").first?.trimmingCharacters(in: .whitespacesAndNewlines)
                try validateContentType(engine: engine, response: response, contentType: contentType)
                await cache.store(response.data, for: cacheKey)
                return .init(data: response.data, contentType: contentType, finalURL: response.finalURL)
            } catch is CancellationError {
                throw CancellationError()
            } catch HTTPClientError.statusResponse(let response) {
                if try evaluateLoginCheckIfNeeded(engine: engine, source: source, response: response) {
                    let rebuilt = try urlBuilder.prepare(
                        engine.url,
                        context: context,
                        defaultHeaders: try BookSourceHeaderResolver().resolve(source)
                    )
                    let recovered = try await networkPolicy.execute(
                        rebuilt,
                        source: source,
                        transport: transport,
                        timeout: 300
                    )
                    let contentType = Self.contentType(from: recovered.headers)
                    try validateContentType(engine: engine, response: recovered, contentType: contentType)
                    await cache.store(recovered.data, for: cacheKey)
                    return .init(data: recovered.data, contentType: contentType, finalURL: recovered.finalURL)
                }
                lastError = HTTPClientError.statusResponse(response)
                if attempt == 2 || ![408, 425, 429, 500, 502, 503, 504].contains(response.statusCode) { throw lastError }
            } catch let error as RuleEngineError {
                throw error
            } catch {
                lastError = error
                let code = (error as? URLError)?.code
                if attempt == 2 || ![URLError.timedOut, .networkConnectionLost, .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed, .notConnectedToInternet].contains(where: { $0 == code }) { throw error }
            }
            try await Task.sleep(nanoseconds: UInt64(500_000_000 * (attempt + 1)))
        }
        throw lastError
    }

    public func audioStream(engine: HttpTTS, text: String, speechRate: Int) async throws -> HttpTTSAudioStream {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw HttpTTSServiceError.emptyText }
        let cacheKey = try Self.cacheKey(engine: engine, text: text, speechRate: speechRate)
        if let data = await cache.data(for: cacheKey) {
            return Self.bufferedStream(
                data: data,
                contentType: engine.contentType,
                finalURL: cacheURL(engine: engine)
            )
        }
        let requiresBufferedValidation = engine.loginCheckJs?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        guard !requiresBufferedValidation,
              let streamingTransport = transport as? any StreamingHTTPTransport else {
            let value = try await audio(engine: engine, text: text, speechRate: speechRate)
            return Self.bufferedStream(data: value.data, contentType: value.contentType, finalURL: value.finalURL)
        }
        let source = engine.bookSourceAdapter
        let context = URLTemplateContext(
            key: text,
            variables: ["speakText": text, "speakSpeed": String(speechRate)],
            source: source
        )
        let prepared = try urlBuilder.prepare(
            engine.url,
            context: context,
            defaultHeaders: try BookSourceHeaderResolver().resolve(source)
        )
        if prepared.bodyJavaScript != nil || prepared.responseType != nil || prepared.proxy != nil || prepared.useWebView {
            let value = try await audio(engine: engine, text: text, speechRate: speechRate)
            return Self.bufferedStream(data: value.data, contentType: value.contentType, finalURL: value.finalURL)
        }
        let response = try await networkPolicy.executeStream(
            prepared,
            source: source,
            transport: streamingTransport,
            timeout: 300
        )
        let maximumBytes = 64 * 1024 * 1024
        if let length = response.expectedContentLength, length > maximumBytes { throw HttpTTSServiceError.audioTooLarge }
        let contentType = Self.contentType(from: response.headers)
        if let contentType, contentType == "application/json" || contentType.hasPrefix("text/") {
            var body = Data()
            for try await chunk in response.chunks {
                body.append(chunk.prefix(4096 - body.count))
                if body.count == 4096 { break }
            }
            throw HttpTTSServiceError.textResponse(contentType: contentType, body: String(decoding: body, as: UTF8.self))
        }
        try validateStreamContentType(engine: engine, contentType: contentType)
        let upstream = response.chunks
        let cache = self.cache
        let cachedChunks = AsyncThrowingStream<Data, Error> { continuation in
            let task = Task {
                var complete = Data()
                if let length = response.expectedContentLength, length > 0, length <= Int64(Int.max) {
                    complete.reserveCapacity(Int(length))
                }
                do {
                    for try await chunk in upstream {
                        try Task.checkCancellation()
                        guard complete.count + chunk.count <= maximumBytes else { throw HttpTTSServiceError.audioTooLarge }
                        complete.append(chunk)
                        continuation.yield(chunk)
                    }
                    guard !complete.isEmpty else { throw HttpTTSServiceError.emptyAudio }
                    await cache.store(complete, for: cacheKey)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
        return .init(
            contentType: contentType,
            finalURL: response.finalURL,
            expectedContentLength: response.expectedContentLength,
            chunks: cachedChunks,
            isIncremental: true
        )
    }

    private static func cacheKey(engine: HttpTTS, text: String, speechRate: Int) throws -> String {
        struct CacheInput: Encodable {
            let engine: HttpTTS
            let text: String
            let speechRate: Int
            let loginInfo: String
        }
        // Voices can share an endpoint and select their speaker through headers
        // or JavaScript. Include service parameters so a changed voice uses new audio.
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let loginInfo = BookSourceRuntimeStore.shared.get(sourceID: engine.sourceKey, key: "loginInfo")
        let data = try encoder.encode(CacheInput(engine: engine, text: text, speechRate: speechRate, loginInfo: loginInfo))
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func bufferedStream(data: Data, contentType: String?, finalURL: URL) -> HttpTTSAudioStream {
        .init(
            contentType: contentType,
            finalURL: finalURL,
            expectedContentLength: Int64(data.count),
            chunks: AsyncThrowingStream { continuation in
                continuation.yield(data)
                continuation.finish()
            },
            isIncremental: false
        )
    }

    private static func contentType(from headers: [String: String]) -> String? {
        headers.first { $0.key.caseInsensitiveCompare("Content-Type") == .orderedSame }?
            .value.components(separatedBy: ";").first?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func cacheURL(engine: HttpTTS) -> URL {
        URL(string: engine.url.components(separatedBy: ",").first ?? "")
            ?? URL(fileURLWithPath: "/httpTTS-cache")
    }

    private func evaluateLoginCheckIfNeeded(engine: HttpTTS, source: BookSource, response: HTTPResponse) throws -> Bool {
        guard let script = engine.loginCheckJs?.trimmingCharacters(in: .whitespacesAndNewlines),
              !script.isEmpty else { return false }
        let headers = response.headers.mapValues(JSONValue.string)
        let input = JSONValue.object([
            "code": .number(Double(response.statusCode)),
            "body": .string(response.decodedText),
            "headers": .object(headers),
            "url": .string(response.finalURL.absoluteString)
        ])
        let wrapped = """
            (function () {
              var raw = result;
              var rebuildRequest = false;
              function header(name) {
                var wanted = String(name).toLowerCase();
                for (var key in raw.headers) if (key.toLowerCase() === wanted) return raw.headers[key];
                return null;
              }
              result = {
                code: function () { return raw.code; },
                statusCode: function () { return raw.code; },
                body: function () { return { string: function () { return raw.body; } }; },
                header: header,
                headers: function () { return { get: header }; },
                url: function () { return { toString: function () { return raw.url; } }; }
              };
              java.getHeaderMap = function () {
                return { putAll: function () {}, put: function () {} };
              };
              java.getResponse = function () { rebuildRequest = true; return result; };
              java.initUrl = function () { rebuildRequest = true; return result; };
              java.ruleUrl = raw.url;
              (function () {
                \(script)
              })();
              return { rebuildRequest: rebuildRequest };
            })()
            """
        let result = try JavaScriptRuleEvaluator().evaluate(
            script: wrapped,
            result: input,
            executionContext: .init(
                variables: ["speakSpeed": "", "speakText": ""],
                baseURL: response.finalURL.absoluteString,
                source: source
            )
        )
        if case .object(let object) = result.value,
           case .bool(let requested)? = object["rebuildRequest"] {
            return requested
        }
        return false
    }

    private func validateContentType(engine: HttpTTS, response: HTTPResponse, contentType: String?) throws {
        guard !response.data.isEmpty else { throw HttpTTSServiceError.emptyAudio }
        guard response.data.count <= 64 * 1024 * 1024 else { throw HttpTTSServiceError.audioTooLarge }
        guard let contentType, !contentType.isEmpty else { return }
        if contentType == "application/json" || contentType.hasPrefix("text/") {
            throw HttpTTSServiceError.textResponse(contentType: contentType, body: response.decodedText)
        }
        guard let expected = engine.contentType?.trimmingCharacters(in: .whitespacesAndNewlines),
              !expected.isEmpty else { return }
        let expression = try NSRegularExpression(pattern: expected)
        let range = NSRange(contentType.startIndex..., in: contentType)
        guard expression.firstMatch(in: contentType, range: range) != nil else {
            throw HttpTTSServiceError.invalidContentType(
                expected: expected,
                actual: contentType,
                body: response.decodedText
            )
        }
    }

    private func validateStreamContentType(engine: HttpTTS, contentType: String?) throws {
        guard let contentType, !contentType.isEmpty else { return }
        guard let expected = engine.contentType?.trimmingCharacters(in: .whitespacesAndNewlines),
              !expected.isEmpty else { return }
        let expression = try NSRegularExpression(pattern: expected)
        let range = NSRange(contentType.startIndex..., in: contentType)
        guard expression.firstMatch(in: contentType, range: range) != nil else {
            throw HttpTTSServiceError.invalidContentType(expected: expected, actual: contentType, body: "")
        }
    }
}

public struct HttpTTSImportResult: Sendable {
    public let engines: [HttpTTS]
    public let notes: [HttpTTS]
}

public extension HttpTTS {
    static func decodeImport(_ data: Data) throws -> [HttpTTS] { try inspectImport(data).engines }

    static func inspectImport(_ data: Data) throws -> HttpTTSImportResult {
        let decoder = JSONDecoder()
        let values: [HttpTTS]
        if let array = try? decoder.decode([HttpTTS].self, from: data) { values = array }
        else if let engine = try? decoder.decode(HttpTTS.self, from: data) { values = [engine] }
        else { throw BookSourceImportError.invalidDocument("无法识别朗读引擎 JSON，请检查内容或文件类型") }
        guard !values.isEmpty else { throw BookSourceImportError.invalidDocument("文件中没有朗读引擎") }
        let notes = values.filter { $0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || $0.url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let playable = values.filter { !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !$0.url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !playable.isEmpty else {
            throw BookSourceImportError.invalidDocument("没有可导入的朗读引擎，请确认内容包含名称和请求地址，且不是书源文件")
        }
        var seen = Set<Int64>()
        return .init(engines: playable.reversed().filter { seen.insert($0.id).inserted }.reversed(), notes: notes)
    }

    static func openAICompatible(id: Int64, name: String, address: String) throws -> HttpTTS {
        let input = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty,
              var url = URLComponents(string: input.contains("://") ? input : "https://" + input),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host?.isEmpty == false,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else {
            throw BookSourceImportError.invalidDocument("请输入 HTTP(S) 服务地址，不要在地址中填写密钥")
        }
        url.path = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        url.path = url.path.isEmpty ? "/v1/audio/speech" : "/" + url.path
        if !url.path.hasSuffix("/audio/speech") {
            url.path += url.path.hasSuffix("/v1") ? "/audio/speech" : "/v1/audio/speech"
        }
        guard let endpoint = url.string else { throw URLError(.badURL) }
        let literal = String(decoding: try JSONEncoder().encode(endpoint + ","), as: UTF8.self)
        var engine = HttpTTS(id: id, name: name.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !engine.name.isEmpty else { throw BookSourceImportError.invalidDocument("请填写引擎名称") }
        // Home's Edge TTS backend supports at most 2×; higher rates silently fall back to 1×.
        engine.url = """
        @js:var info = source.getLoginInfoMap();
        \(literal) + JSON.stringify({method:"POST",body:{model:"tts-1",input:speakText,
        voice:info.get("voice") || "zh-CN-YunxiNeural",response_format:"mp3",
        speed:Math.min(2,Math.max(0.5,Number(speakSpeed)/10))}});
        """
        engine.contentType = "audio/mpeg"
        engine.header = #"@js:var key = source.getLoginInfoMap().get("apiKey"); JSON.stringify(key ? {Authorization:"Bearer " + key} : {});"#
        engine.loginUi = #"[{"name":"apiKey","type":"password","viewName":"'API Key（无鉴权可留空）'"},{"name":"voice","type":"text","default":"zh-CN-YunxiNeural","viewName":"'音色 ID'"}]"#
        return engine
    }

    var sourceKey: String { "httpTts:\(id)" }

    var openAIServiceAddress: String? {
        guard let range = serviceAddressRange,
              let literal = String(url[range]).data(using: .utf8),
              let address = try? JSONDecoder().decode(String.self, from: literal), address.hasSuffix(","),
              let endpoint = URLComponents(string: String(address.dropLast())),
              ["https", "http"].contains(endpoint.scheme ?? ""), endpoint.host?.isEmpty == false,
              endpoint.user == nil, endpoint.password == nil, endpoint.query == nil, endpoint.fragment == nil,
              endpoint.path.hasSuffix("/audio/speech") else { return nil }
        return String(address.dropLast())
    }

    func updatingOpenAIServiceAddress(_ address: String) throws -> HttpTTS {
        let generated = try Self.openAICompatible(id: id, name: name, address: address)
        guard openAIServiceAddress != nil, let range = serviceAddressRange,
              let endpoint = generated.openAIServiceAddress else {
            throw BookSourceImportError.invalidDocument("此引擎请使用高级规则编辑")
        }
        var updated = self
        updated.url.replaceSubrange(range, with: String(decoding: try JSONEncoder().encode(endpoint + ","), as: UTF8.self))
        return updated
    }

    private var serviceAddressRange: Range<String.Index>? {
        guard url.contains("source.getLoginInfoMap()"), url.contains("get(\"voice\")"),
              header?.contains("get(\"apiKey\")") == true, jsLib?.isEmpty != false,
              loginUrl?.isEmpty != false, loginCheckJs?.isEmpty != false,
              let expression = try? NSRegularExpression(pattern: #"("(?:\\.|[^"\\])*")\s*\+\s*JSON\.stringify"#),
              let match = expression.firstMatch(in: url, range: NSRange(url.startIndex..., in: url)) else { return nil }
        return Range(match.range(at: 1), in: url)
    }

    var bookSourceAdapter: BookSource {
        var source = BookSource(bookSourceUrl: sourceKey, bookSourceName: name)
        source.concurrentRate = concurrentRate
        source.loginUrl = loginUrl
        source.loginUi = loginUi
        source.header = header
        source.jsLib = jsLib
        source.enabledCookieJar = enabledCookieJar
        source.loginCheckJs = loginCheckJs
        source.lastUpdateTime = lastUpdateTime
        return source
    }
}
