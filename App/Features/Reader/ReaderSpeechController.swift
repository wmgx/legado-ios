@preconcurrency import AVFoundation
@preconcurrency import MediaPlayer
import SwiftUI
import UniformTypeIdentifiers

struct ReaderSpeechSegment: Sendable {
    let text: String
    let range: NSRange

    static func split(_ text: String, maximumUTF16Length: Int = 1000, byParagraph: Bool = true) -> [Self] {
        let source = text as NSString
        let limit = max(maximumUTF16Length, 16)
        let boundaries = CharacterSet(charactersIn: "。！？；.!?;，, \t")
        var result: [Self] = []
        var location = 0
        while location < source.length {
            let paragraph = byParagraph ? source.paragraphRange(for: NSRange(location: location, length: 0))
                : NSRange(location: location, length: source.length - location)
            let first = source.rangeOfCharacter(from: .whitespacesAndNewlines.inverted, range: paragraph)
            if first.location != NSNotFound {
                let last = source.rangeOfCharacter(from: .whitespacesAndNewlines.inverted, options: .backwards, range: paragraph)
                let end = NSMaxRange(last)
                var start = first.location
                while start < end {
                    var next = min(start + limit, end)
                    if next < end {
                        next = source.rangeOfComposedCharacterSequence(at: next).location
                        if next <= start { next = NSMaxRange(source.rangeOfComposedCharacterSequence(at: start)) }
                        let boundary = source.rangeOfCharacter(from: boundaries, options: .backwards, range: NSRange(location: start, length: next - start))
                        if boundary.location != NSNotFound, boundary.location >= start + limit / 2 { next = NSMaxRange(boundary) }
                    }
                    let range = NSRange(location: start, length: next - start)
                    result.append(.init(text: source.substring(with: range), range: range))
                    start = next
                }
            }
            location = NSMaxRange(paragraph)
        }
        return result
    }
}

private final class IncrementalAudioResourceLoader: NSObject, AVAssetResourceLoaderDelegate, @unchecked Sendable {
    private let queue = DispatchQueue(label: "io.legado.tts.stream-loader")
    private let contentType: String?
    private let expectedLength: Int64
    private var data = Data()
    private var pending: [AVAssetResourceLoadingRequest] = []
    private var finished = false
    private var failure: Error?
    private var consumeTask: Task<Void, Never>?

    init(stream: HttpTTSAudioStream) {
        contentType = stream.contentType
        expectedLength = stream.expectedContentLength ?? 0
        super.init()
        consumeTask = Task { [weak self] in
            do {
                for try await chunk in stream.chunks {
                    guard let self else { return }
                    self.queue.async { [weak self] in
                        self?.data.append(chunk)
                        self?.processPendingRequests()
                    }
                }
                self?.queue.async { [weak self] in
                    self?.finished = true
                    self?.processPendingRequests()
                }
            } catch {
                self?.queue.async { [weak self] in
                    self?.failure = error
                    self?.finished = true
                    self?.processPendingRequests()
                }
            }
        }
    }

    deinit { consumeTask?.cancel() }

    func cancel() {
        consumeTask?.cancel()
        queue.async { [weak self] in
            guard let self, !finished else { return }
            failure = CancellationError()
            finished = true
            processPendingRequests()
        }
    }

    func install(on asset: AVURLAsset) {
        asset.resourceLoader.setDelegate(self, queue: queue)
    }

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest
    ) -> Bool {
        pending.append(loadingRequest)
        processPendingRequests()
        return true
    }

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        didCancel loadingRequest: AVAssetResourceLoadingRequest
    ) {
        pending.removeAll { $0 === loadingRequest }
    }

    private func processPendingRequests() {
        pending.removeAll { request in
            if let info = request.contentInformationRequest {
                info.contentType = contentType.flatMap { UTType(mimeType: $0)?.identifier }
                info.contentLength = expectedLength
                info.isByteRangeAccessSupported = false
            }
            if let failure {
                request.finishLoading(with: failure)
                return true
            }
            guard let dataRequest = request.dataRequest else {
                if finished { request.finishLoading(); return true }
                return false
            }
            let offset = max(Int(dataRequest.currentOffset), Int(dataRequest.requestedOffset))
            if offset < data.count {
                let requestedEnd = Int(dataRequest.requestedOffset) + dataRequest.requestedLength
                let end = min(data.count, requestedEnd)
                if end > offset { dataRequest.respond(with: data.subdata(in: offset..<end)) }
            }
            let deliveredEnd = max(Int(dataRequest.currentOffset), Int(dataRequest.requestedOffset))
            let requestedEnd = Int(dataRequest.requestedOffset) + dataRequest.requestedLength
            if deliveredEnd >= requestedEnd || finished {
                request.finishLoading()
                return true
            }
            return false
        }
    }
}

@MainActor
final class ReaderSpeechController: NSObject, ObservableObject, @preconcurrency AVSpeechSynthesizerDelegate, @preconcurrency AVAudioPlayerDelegate {
    @Published private(set) var isSpeaking = false
    @Published private(set) var isPaused = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var completionCount = 0
    @Published private(set) var currentCharacterPosition = 0
    @Published private(set) var isBuffering = false
    private static weak var audioSessionOwner: ReaderSpeechController?
    private let synthesizer = AVSpeechSynthesizer()
    private let httpService = HttpTTSService()
    private var audioPlayer: AVAudioPlayer?
    private var streamPlayer: AVPlayer?
    private var streamLoader: IncrementalAudioResourceLoader?
    private var streamCompletionToken: NSObjectProtocol?
    private var streamFailureToken: NSObjectProtocol?
    private var streamStatus: NSKeyValueObservation?
    private var streamPlaybackStatus: NSKeyValueObservation?
    private var httpTask: Task<Void, Never>?
    private var httpPrefetchTask: Task<Void, Never>?
    private var nextChapterPrefetchTask: Task<Void, Never>?
    private var prefetchedThrough = 0
    private var sessionID = UUID()
    private var httpSegments: [ReaderSpeechSegment] = []
    private var httpSegmentIndex = 0
    private var httpEngine: HttpTTS?
    private var systemSegments: [ReaderSpeechSegment] = []
    private var currentUtterance: AVSpeechUtterance?
    private var systemSegmentIndex = 0
    private var characterOffset = 0
    private var followsSystemRate = true
    private var speechRate = 5
    private var readByPage = false
    private var streamsHTTPAudio = true
    private var voiceIdentifier = ""
    private var continuesAcrossChapters = false
    private var notificationTokens: [NSObjectProtocol] = []
    nonisolated(unsafe) private var remoteCommandTargets: [(MPRemoteCommand, Any)] = []
    private var resumesAfterInterruption = false
    private var ignoresAudioFocus = false
    private var pausesForPhoneCalls = false
    private var mediaButtonPerNext = false
    private var bookName = ""
    private var chapterTitle = ""
    private var author = ""
    var onNextChapter: (() -> Void)?
    var onPreviousChapter: (() -> Void)?
    var onRemoteStop: (() -> Void)?

    override init() {
        super.init()
        synthesizer.delegate = self
        observeAudioSession()
        installRemoteCommands()
    }

    deinit {
        notificationTokens.forEach(NotificationCenter.default.removeObserver)
        remoteCommandTargets.forEach { command, target in command.removeTarget(target) }
    }

    func toggle(text: String, continuesAcrossChapters: Bool = false) {
        if isSpeaking || isPaused {
            stop()
            return
        }
        speak(text, continuesAcrossChapters: continuesAcrossChapters)
    }

    func toggleHTTP(engine: HttpTTS, text: String, continuesAcrossChapters: Bool = false) {
        if isSpeaking || isPaused {
            stop()
            return
        }
        speakHTTP(engine: engine, text: text, continuesAcrossChapters: continuesAcrossChapters)
    }

    func stop() {
        sessionID = UUID()
        currentUtterance = nil
        synthesizer.stopSpeaking(at: .word)
        stopCurrentHTTPPlayback()
        httpPrefetchTask?.cancel(); httpPrefetchTask = nil
        nextChapterPrefetchTask?.cancel(); nextChapterPrefetchTask = nil
        prefetchedThrough = 0
        httpSegments = []
        httpSegmentIndex = 0
        httpEngine = nil
        systemSegments = []
        systemSegmentIndex = 0
        characterOffset = 0
        continuesAcrossChapters = false
        isSpeaking = false
        isPaused = false
        isBuffering = false
        updateNowPlaying()
        if Self.audioSessionOwner === self {
            Self.audioSessionOwner = nil
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }

    func configure(
        followsSystemRate: Bool,
        speechRate: Int,
        readByPage: Bool,
        streamsHTTPAudio: Bool = true,
        voiceIdentifier: String = "",
        ignoresAudioFocus: Bool = false,
        pausesForPhoneCalls: Bool = false,
        mediaButtonPerNext: Bool = false,
        bookName: String = "",
        chapterTitle: String = "",
        author: String = ""
    ) {
        self.followsSystemRate = followsSystemRate
        self.speechRate = min(max(speechRate, 0), 45)
        self.readByPage = readByPage
        self.streamsHTTPAudio = streamsHTTPAudio
        self.voiceIdentifier = voiceIdentifier
        self.ignoresAudioFocus = ignoresAudioFocus
        self.pausesForPhoneCalls = pausesForPhoneCalls
        self.mediaButtonPerNext = mediaButtonPerNext
        self.bookName = bookName
        self.chapterTitle = chapterTitle
        self.author = author
    }

    func speak(_ text: String, continuesAcrossChapters: Bool = false, characterOffset: Int = 0, startsPaused: Bool = false) {
        stop()
        errorMessage = nil
        guard activateAudioSession() else { return }
        self.continuesAcrossChapters = continuesAcrossChapters
        if synthesizer.isSpeaking || synthesizer.isPaused {
            synthesizer.stopSpeaking(at: .immediate)
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        systemSegments = segments(for: text)
        guard !systemSegments.isEmpty else { return }
        systemSegmentIndex = 0
        self.characterOffset = max(characterOffset, 0)
        currentCharacterPosition = self.characterOffset + systemSegments[0].range.location
        if startsPaused { isPaused = true; updateNowPlaying() }
        else { playCurrentSystemSegment() }
    }

    func speakHTTP(
        engine: HttpTTS,
        text: String,
        continuesAcrossChapters: Bool = false,
        characterOffset: Int = 0,
        startsPaused: Bool = false
    ) {
        stop()
        errorMessage = nil
        guard activateAudioSession() else { return }
        self.continuesAcrossChapters = continuesAcrossChapters
        httpEngine = engine
        httpSegments = segments(for: text)
        guard !httpSegments.isEmpty else { return }
        httpSegmentIndex = 0
        self.characterOffset = max(characterOffset, 0)
        currentCharacterPosition = self.characterOffset + httpSegments[0].range.location
        if startsPaused { isPaused = true; updateNowPlaying() }
        else { isSpeaking = true; playCurrentHTTPSegment() }
    }

    func prefetchHTTP(engine: HttpTTS, text: String, limit: Int = 10) {
        guard httpEngine?.id == engine.id, isSpeaking || isPaused else { return }
        nextChapterPrefetchTask?.cancel()
        let values = Array(segments(for: text).prefix(min(max(limit, 0), 3)))
        let session = sessionID
        let rate = followsSystemRate ? 10 : speechRate + 5
        nextChapterPrefetchTask = Task { [weak self] in
            guard let self else { return }
            for segment in values {
                guard !Task.isCancelled, sessionID == session else { return }
                _ = try? await httpService.audio(engine: engine, text: segment.text, speechRate: rate)
            }
        }
    }

    func pauseOrResume(text: String, continuesAcrossChapters: Bool = false) {
        if isPaused {
            resumePlayback()
        } else if isSpeaking {
            pausePlayback()
        } else {
            speak(text, continuesAcrossChapters: continuesAcrossChapters)
        }
    }

    func pauseOrResumeHTTP(engine: HttpTTS, text: String, continuesAcrossChapters: Bool = false) {
        if isPaused { resumePlayback() }
        else if isSpeaking { pausePlayback() }
        else {
            speakHTTP(engine: engine, text: text, continuesAcrossChapters: continuesAcrossChapters)
        }
    }

    private func segments(for text: String) -> [ReaderSpeechSegment] {
        ReaderSpeechSegment.split(text, byParagraph: !readByPage)
    }

    private func activateAudioSession() -> Bool {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .spokenAudio, options: ignoresAudioFocus ? [.mixWithOthers] : [])
            try session.setActive(true)
            Self.audioSessionOwner = self
            return true
        } catch { errorMessage = error.localizedDescription; return false }
    }

    private func pausePlayback() {
        if let audioPlayer, audioPlayer.isPlaying {
            audioPlayer.pause()
        } else if let streamPlayer {
            streamPlayer.pause()
        } else if !systemSegments.isEmpty {
            synthesizer.pauseSpeaking(at: .word)
        } else if httpTask != nil {
            httpTask?.cancel()
            httpTask = nil
        } else {
            return
        }
        isPaused = true
        isSpeaking = false
        isBuffering = false
        updateNowPlaying()
    }

    private func resumePlayback() {
        guard activateAudioSession() else { return }
        if let audioPlayer {
            isSpeaking = audioPlayer.play()
        } else if let streamPlayer {
            streamPlayer.play()
            isSpeaking = true
        } else if synthesizer.isPaused {
            synthesizer.continueSpeaking()
            isSpeaking = true
        } else if currentUtterance != nil {
            isSpeaking = true
        } else if systemSegments.indices.contains(systemSegmentIndex) {
            playCurrentSystemSegment()
        } else if httpEngine != nil, httpSegments.indices.contains(httpSegmentIndex) {
            isSpeaking = true
            playCurrentHTTPSegment()
        } else {
            return
        }
        isPaused = false
        updateNowPlaying()
    }

    private func observeAudioSession() {
        let center = NotificationCenter.default
        notificationTokens.append(center.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] note in
            let type = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            let options = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            Task { @MainActor in self?.handleAudioInterruption(type: type, options: options) }
        })
        notificationTokens.append(center.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] note in
            let reason = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            Task { @MainActor in self?.handleRouteChange(reason: reason) }
        })
    }

    private func handleAudioInterruption(type raw: UInt?, options rawOptions: UInt) {
        guard let raw,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        switch type {
        case .began:
            if ignoresAudioFocus && !pausesForPhoneCalls { return }
            resumesAfterInterruption = isSpeaking
            if isSpeaking { pausePlayback() }
        case .ended:
            if ignoresAudioFocus && !pausesForPhoneCalls { return }
            let options = AVAudioSession.InterruptionOptions(rawValue: rawOptions)
            if resumesAfterInterruption, options.contains(.shouldResume) { resumePlayback() }
            resumesAfterInterruption = false
        @unknown default:
            break
        }
    }

    private func handleRouteChange(reason raw: UInt?) {
        guard let raw,
              AVAudioSession.RouteChangeReason(rawValue: raw) == .oldDeviceUnavailable else { return }
        if isSpeaking { pausePlayback() }
    }

    private func installRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.isEnabled = true
        center.pauseCommand.isEnabled = true
        center.togglePlayPauseCommand.isEnabled = true
        center.stopCommand.isEnabled = true
        center.nextTrackCommand.isEnabled = true
        center.previousTrackCommand.isEnabled = true
        addRemoteTarget(center.playCommand) { $0.resumePlayback() }
        addRemoteTarget(center.pauseCommand) { $0.pausePlayback() }
        addRemoteTarget(center.togglePlayPauseCommand) { controller in
            controller.isPaused ? controller.resumePlayback() : controller.pausePlayback()
        }
        addRemoteTarget(center.stopCommand) { controller in
            controller.stop()
            controller.onRemoteStop?()
        }
        addRemoteTarget(center.nextTrackCommand) { $0.skipForward(usesChapterPreference: true) }
        addRemoteTarget(center.previousTrackCommand) { $0.skipBackward(usesChapterPreference: true) }
    }

    private func addRemoteTarget(_ command: MPRemoteCommand, action: @escaping @MainActor (ReaderSpeechController) -> Void) {
        let target = command.addTarget { [weak self] _ in
            guard self != nil else { return .noSuchContent }
            Task { @MainActor [weak self] in
                guard let self else { return }
                action(self)
            }
            return .success
        }
        remoteCommandTargets.append((command, target))
    }

    func nextSegment() {
        guard isSpeaking || isPaused else { return }
        skipForward(usesChapterPreference: false)
    }

    func previousSegment() {
        guard isSpeaking || isPaused else { return }
        skipBackward(usesChapterPreference: false)
    }

    private func playCurrentSystemSegment() {
        guard systemSegments.indices.contains(systemSegmentIndex) else {
            finishNaturally()
            return
        }
        let segment = systemSegments[systemSegmentIndex]
        let utterance = AVSpeechUtterance(string: segment.text)
        utterance.voice = AVSpeechSynthesisVoice(identifier: voiceIdentifier)
            ?? AVSpeechSynthesisVoice(language: "zh-CN")
        let multiplier = followsSystemRate ? 1 : Float(speechRate + 5) / 10
        utterance.rate = min(
            max(AVSpeechUtteranceDefaultSpeechRate * multiplier, AVSpeechUtteranceMinimumSpeechRate),
            AVSpeechUtteranceMaximumSpeechRate
        )
        utterance.pitchMultiplier = 1
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-uiMuteSpeech") { utterance.volume = 0 }
        #endif
        currentUtterance = utterance
        synthesizer.speak(utterance)
        currentCharacterPosition = characterOffset + segment.range.location
        isSpeaking = true
        isPaused = false
        updateNowPlaying()
    }

    private func skipForward(usesChapterPreference: Bool) {
        if usesChapterPreference && mediaButtonPerNext {
            onNextChapter?()
        } else if httpEngine != nil, httpSegmentIndex + 1 < httpSegments.count {
            stopCurrentHTTPPlayback()
            httpSegmentIndex += 1
            playCurrentHTTPSegment()
        } else if !systemSegments.isEmpty, systemSegmentIndex + 1 < systemSegments.count {
            changeSystemSegment(to: systemSegmentIndex + 1)
        } else {
            onNextChapter?()
        }
    }

    private func skipBackward(usesChapterPreference: Bool) {
        if usesChapterPreference && mediaButtonPerNext {
            onPreviousChapter?()
        } else if httpEngine != nil, httpSegmentIndex > 0 {
            stopCurrentHTTPPlayback()
            httpSegmentIndex -= 1
            playCurrentHTTPSegment()
        } else if !systemSegments.isEmpty, systemSegmentIndex > 0 {
            changeSystemSegment(to: systemSegmentIndex - 1)
        } else {
            onPreviousChapter?()
        }
    }

    private func stopCurrentHTTPPlayback() {
        audioPlayer?.stop()
        audioPlayer = nil
        streamPlayer?.pause()
        streamLoader?.cancel()
        streamPlayer = nil
        streamLoader = nil
        streamStatus = nil
        streamPlaybackStatus = nil
        if let streamCompletionToken {
            NotificationCenter.default.removeObserver(streamCompletionToken)
            self.streamCompletionToken = nil
        }
        if let streamFailureToken { NotificationCenter.default.removeObserver(streamFailureToken); self.streamFailureToken = nil }
        httpTask?.cancel()
        httpTask = nil
    }

    private func changeSystemSegment(to index: Int) {
        currentUtterance = nil
        synthesizer.stopSpeaking(at: .immediate)
        systemSegmentIndex = index
        playCurrentSystemSegment()
    }

    private func updateNowPlaying() {
        guard isSpeaking || isPaused else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [
            MPMediaItemPropertyTitle: chapterTitle,
            MPMediaItemPropertyAlbumTitle: bookName,
            MPMediaItemPropertyArtist: author,
            MPNowPlayingInfoPropertyPlaybackRate: isSpeaking ? 1 : 0
        ]
    }

    private func playCurrentHTTPSegment() {
        guard let engine = httpEngine, httpSegments.indices.contains(httpSegmentIndex) else {
            stop()
            return
        }
        let segment = httpSegments[httpSegmentIndex]
        let text = segment.text
        stopCurrentHTTPPlayback()
        currentCharacterPosition = characterOffset + segment.range.location
        let rate = followsSystemRate ? 10 : speechRate + 5
        let session = sessionID
        isSpeaking = true; isPaused = false; isBuffering = true
        httpTask = Task { [weak self] in
            guard let self else { return }
            do {
                if streamsHTTPAudio {
                    let stream = try await httpService.audioStream(engine: engine, text: text, speechRate: rate)
                    try Task.checkCancellation()
                    guard sessionID == session else { return }
                    if stream.isIncremental, stream.expectedContentLength ?? 0 > 0 {
                        playIncrementalHTTPStream(stream)
                    } else {
                        var data = Data()
                        for try await chunk in stream.chunks { data.append(chunk) }
                        try Task.checkCancellation()
                        try playBufferedHTTPAudio(data)
                    }
                } else {
                    let audio = try await httpService.audio(engine: engine, text: text, speechRate: rate)
                    try Task.checkCancellation()
                    try playBufferedHTTPAudio(audio.data)
                }
                isPaused = false
                isBuffering = false
                updateNowPlaying()
                if !isSpeaking { throw CocoaError(.fileReadCorruptFile) }
            } catch is CancellationError {
                return
            } catch {
                guard sessionID == session, !Task.isCancelled else { return }
                errorMessage = error.localizedDescription
                stop()
            }
        }
        scheduleHTTPPrefetch()
    }

    private func playBufferedHTTPAudio(_ data: Data) throws {
        let player = try AVAudioPlayer(data: data)
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-uiMuteSpeech") { player.volume = 0 }
        #endif
        player.delegate = self
        player.prepareToPlay()
        audioPlayer = player
        isSpeaking = player.play()
    }

    private func playIncrementalHTTPStream(_ stream: HttpTTSAudioStream) {
        let url = URL(string: "legado-tts-stream://audio/\(UUID().uuidString)")!
        let asset = AVURLAsset(url: url)
        let loader = IncrementalAudioResourceLoader(stream: stream)
        loader.install(on: asset)
        let item = AVPlayerItem(asset: asset)
        let player = AVPlayer(playerItem: item)
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-uiMuteSpeech") { player.isMuted = true }
        #endif
        streamLoader = loader
        streamPlayer = player
        let identity = ObjectIdentifier(item)
        streamCompletionToken = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, let current = self.streamPlayer?.currentItem, ObjectIdentifier(current) == identity else { return }
                self.incrementalPlayerDidFinish()
            }
        }
        streamFailureToken = NotificationCenter.default.addObserver(forName: .AVPlayerItemFailedToPlayToEndTime, object: item, queue: .main) { [weak self] note in
            let message = (note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error)?.localizedDescription ?? "在线朗读播放失败"
            Task { @MainActor in self?.streamFailed(identity: identity, message: message) }
        }
        streamStatus = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
            guard item.status == .failed else { return }
            let message = item.error?.localizedDescription ?? "在线音频无法播放"
            Task { @MainActor in self?.streamFailed(identity: identity, message: message) }
        }
        streamPlaybackStatus = player.observe(\.timeControlStatus, options: [.initial, .new]) { [weak self] player, _ in
            let waiting = player.timeControlStatus == .waitingToPlayAtSpecifiedRate
            Task { @MainActor in
                guard let self, let current = self.streamPlayer?.currentItem, ObjectIdentifier(current) == identity else { return }
                self.isBuffering = waiting && !self.isPaused
            }
        }
        player.play()
        isSpeaking = true
    }

    private func incrementalPlayerDidFinish() {
        stopCurrentHTTPPlayback()
        httpSegmentIndex += 1
        if httpSegmentIndex < httpSegments.count { playCurrentHTTPSegment() }
        else { finishNaturally() }
    }

    private func streamFailed(identity: ObjectIdentifier, message: String) {
        guard let current = streamPlayer?.currentItem, ObjectIdentifier(current) == identity else { return }
        errorMessage = message
        stop()
    }

    private func scheduleHTTPPrefetch() {
        guard httpPrefetchTask == nil, let engine = httpEngine else { return }
        let start = max(httpSegmentIndex + 1, prefetchedThrough + 1)
        guard start < httpSegments.count else { return }
        let rate = followsSystemRate ? 10 : speechRate + 5
        let session = sessionID
        httpPrefetchTask = Task { [weak self] in
            guard let self else { return }
            defer { if sessionID == session { httpPrefetchTask = nil } }
            var index = start
            while index < httpSegments.count, index <= httpSegmentIndex + 3 {
                guard !Task.isCancelled, sessionID == session else { return }
                let text = httpSegments[index].text
                _ = try? await httpService.audio(engine: engine, text: text, speechRate: rate)
                guard !Task.isCancelled, sessionID == session else { return }
                prefetchedThrough = max(prefetchedThrough, index)
                index += 1
            }
        }
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        guard player === audioPlayer else { return }
        audioPlayer = nil
        guard flag else {
            errorMessage = "HTTP TTS 音频播放失败"
            stop()
            return
        }
        httpSegmentIndex += 1
        if httpSegmentIndex < httpSegments.count {
            playCurrentHTTPSegment()
        } else {
            finishNaturally()
        }
    }

    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        guard player === audioPlayer else { return }
        errorMessage = error?.localizedDescription ?? "在线朗读音频无法解码"
        stop()
    }

    private func finishNaturally() {
        let shouldContinue = continuesAcrossChapters
        stop()
        if shouldContinue { completionCount += 1 }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        guard utterance === currentUtterance else { return }
        systemSegmentIndex += 1
        if systemSegmentIndex < systemSegments.count { playCurrentSystemSegment() }
        else { finishNaturally() }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        guard utterance === currentUtterance else { return }
        if isPaused { synthesizer.pauseSpeaking(at: .immediate) }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        guard utterance === currentUtterance else { return }
        guard !synthesizer.isSpeaking else { return }
        isSpeaking = false
        isPaused = false
        updateNowPlaying()
    }
}
