// Adapted from the existing local SpeechAnalyzer pipeline; no startup capture or asset installation.
import Foundation
@preconcurrency import AVFoundation
import Speech
import CoreMedia
import SlideQACore
import RealDeckEvidenceCore

typealias RecognitionUpdate = LiveRecognitionUpdate

public enum AudioFailure: LocalizedError {
    case unavailable, japaneseNotInstalled, format, conversion, microphoneLocked, microphoneDenied, speechDenied, overflow
    public var errorDescription: String? {
        switch self {
        case .unavailable: "このMacではSpeechTranscriberを利用できません．"
        case .japaneseNotInstalled: "日本語の音声モデルがありません．自動ダウンロードは行いません．"
        case .format: "音声形式を処理できません．"
        case .conversion: "音声変換に失敗しました．"
        case .microphoneLocked: "マイク試験は未承認のため無効です．"
        case .microphoneDenied: "このアプリのマイク権限がありません．"
        case .speechDenied: "このアプリの音声認識の許可がありません．本人の開始操作で確認してください．"
        case .overflow: "音声処理が追いつかず，入力バッファが満杯になりました．"
        }
    }
}

/// A single producer owns the converter. Audio buffers go only to Apple's
/// on-device SpeechTranscriber; no playback, file recording or network client.
final class AudioIngress: @unchecked Sendable {
    private let lock = NSLock()
    private let converter: AVAudioConverter?
    let format: AVAudioFormat
    private var samplePosition: Int64 = 0
    private var lastVoiced: Double = 0
    private var speechOpen = false
    private var endpointSent = false
    let continuation: AsyncStream<AnalyzerInput>.Continuation
    let endpoint: @Sendable (Double, Double) -> Void
    let failure: @Sendable (String) -> Void

    init(input: AVAudioFormat, output: AVAudioFormat,
         continuation: AsyncStream<AnalyzerInput>.Continuation,
         endpoint: @escaping @Sendable (Double, Double) -> Void,
         failure: @escaping @Sendable (String) -> Void) throws {
        format = output
        converter = input == output ? nil : AVAudioConverter(from: input, to: output)
        if input != output && converter == nil { throw AudioFailure.format }
        self.continuation = continuation
        self.endpoint = endpoint
        self.failure = failure
    }

    func push(_ input: AVAudioPCMBuffer) throws {
        lock.lock(); defer { lock.unlock() }
        let buffer: AVAudioPCMBuffer
        if let converter {
            let capacity = AVAudioFrameCount(ceil(Double(input.frameLength) * format.sampleRate / input.format.sampleRate) + 64)
            guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { throw AudioFailure.format }
            var supplied = false
            var error: NSError?
            let status = converter.convert(to: output, error: &error) { _, flag in
                if supplied { flag.pointee = .noDataNow; return nil }
                supplied = true
                flag.pointee = .haveData
                return input
            }
            if status == .error { throw (error as Error?) ?? AudioFailure.conversion }
            buffer = output
        } else { buffer = input }
        guard buffer.frameLength > 0 else { return }
        let startSample = samplePosition
        samplePosition += Int64(buffer.frameLength)
        let position = Double(samplePosition) / format.sampleRate
        // Preserve exact sample boundaries. Rounding cumulative Double seconds
        // to another timescale can overlap adjacent buffers by one time unit.
        let item = AnalyzerInput(buffer: buffer, bufferStartTime: CMTime(value: startSample, timescale: Int32(format.sampleRate)))
        if case .dropped = continuation.yield(item) { failure(AudioFailure.overflow.localizedDescription) }
        if let samples = buffer.floatChannelData?[0] {
            var sum: Float = 0
            for i in 0..<Int(buffer.frameLength) { sum += samples[i] * samples[i] }
            let rms = sqrt(sum / Float(buffer.frameLength))
            if rms > 0.006 {
                lastVoiced = position; speechOpen = true; endpointSent = false
            } else if speechOpen && !endpointSent && position - lastVoiced >= 0.60 {
                endpointSent = true
                endpoint(lastVoiced, position)
            }
        }
    }
}

@MainActor
public final class NativeAudioPipeline {
    public init() {}
    private var analyzer: SpeechAnalyzer?
    private var resultTask: Task<Void, Never>?
    private var continuation: AsyncStream<AnalyzerInput>.Continuation?
    private var engine: AVAudioEngine?
    private var ingress: AudioIngress?
    private var generation = UUID()
    private var assembler = TranscriptAssembler()
    private var sourceRevisions:[Int:Int]=[:]
    private var legacy:LegacyOfflineMicrophone?
    public var recognizerName: String { legacy == nil ? "SpeechTranscriber":"SFSpeechRecognizer（端末内のみ）" }
    var replayStartUptime: Double = 0
    var preparationSeconds: Double = 0

    private func prepare(inputFormat: AVAudioFormat, expectedSession: UUID,
                         onUpdate: @escaping @MainActor @Sendable (RecognitionUpdate) -> Void,
                         onEndpoint: @escaping @MainActor @Sendable (Double) -> Void,
                         onFailure: @escaping @MainActor @Sendable (String) -> Void) async throws -> AudioIngress {
        guard SpeechTranscriber.isAvailable else { throw AudioFailure.unavailable }
        try checkSession(expectedSession)
        let installed = await SpeechTranscriber.installedLocales
        try checkSession(expectedSession)
        guard let locale = installed.first(where: { $0.language.languageCode?.identifier == "ja" }) else { throw AudioFailure.japaneseNotInstalled }
        let before = ProcessInfo.processInfo.systemUptime
        let session = expectedSession
        let module: any SpeechModule
        let startResults: @MainActor () -> Task<Void, Never>
        let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [],
            reportingOptions: [.volatileResults,.alternativeTranscriptions,.fastResults], attributeOptions: [.audioTimeRange])
        module = transcriber
        startResults = { Task {
            do {
                for try await result in transcriber.results {
                    try Task.checkCancellation()
                    guard self.generation == session else { return }
                    self.deliver(session: session, text: String(result.text.characters), final: result.isFinal,
                        start: result.range.start.seconds, end: CMTimeRangeGetEnd(result.range).seconds,
                        alternatives: result.alternatives.map { String($0.characters) }, callback: onUpdate)
                }
                if self.generation == session,!Task.isCancelled {onFailure("音声認識ストリームが予期せず終了したため停止します．")}
            } catch is CancellationError { }
            catch {
                if self.generation == session,!Task.isCancelled {onFailure("音声認識ストリームが失敗したため停止します．")}
            }
        } }
        // Read existing asset state. Do not prepare a module whose assets
        // would need to be installed, and never invoke an install request.
        guard await AssetInventory.status(forModules: [module]) == .installed else { throw AudioFailure.japaneseNotInstalled }
        try checkSession(session)
        let analyzer = SpeechAnalyzer(modules: [module], options: .init(priority: .userInitiated, modelRetention: .processLifetime))
        self.analyzer = analyzer
        let context = AnalysisContext()
        context.contextualStrings[.general] = ["オリオン装置", "リラ装置", "温度", "振動", "点検", "校正", "警報", "取消", "訂正"]
        try await analyzer.setContext(context)
        try checkSession(session)
        guard let output = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module], considering: inputFormat) else { throw AudioFailure.format }
        try checkSession(session)
        try await analyzer.prepareToAnalyze(in: output)
        try checkSession(session)
        let stream = AsyncStream<AnalyzerInput>.makeStream(bufferingPolicy: .bufferingOldest(250))
        self.continuation = stream.continuation
        let resultTask = startResults()
        self.resultTask = resultTask
        let ingress = try AudioIngress(input: inputFormat, output: output, continuation: stream.continuation,
            endpoint: { [weak self] voicedEnd, through in
                Task { @MainActor in
                    guard let self, self.generation == session else { return }
                    self.assembler.endpoint(voicedEnd)
                    onEndpoint(voicedEnd)
                    do { try await analyzer.finalize(through: CMTime(seconds: through, preferredTimescale: 48_000)) }
                    catch {if self.generation == session {onFailure("音声区切りを確定できませんでした．")}}
                }
            }, failure: { [weak self] message in Task { @MainActor in
                guard let self,self.generation == session else {return}
                onFailure(message)
            } })
        self.ingress = ingress
        try await analyzer.start(inputSequence: stream.stream)
        try checkSession(session)
        preparationSeconds = ProcessInfo.processInfo.systemUptime - before
        return ingress
    }

    private func deliver(session: UUID, text: String, final: Bool, start: Double, end: Double,
                         alternatives: [String], callback: @MainActor (RecognitionUpdate) -> Void) {
        guard generation == session, !Task.isCancelled else { return }
        for value in assembler.accept(.init(start: start,end: end,text: text,final: final,alternatives: alternatives)) {
            sourceRevisions[value.group,default:0] += 1
            callback(.init(id: "\(session.uuidString):u\(value.group)", order: value.group, text: value.text, final: value.final,
                audioStart: value.start, audioEnd: value.end, alternatives: value.alternatives,sourceRevision:sourceRevisions[value.group]))
        }
    }

    public func startMicrophone(authorizedLaunch: Bool, ownerConsent: Bool, allowPermissionPrompt: Bool,
                         onUpdate: @escaping @MainActor @Sendable (LiveRecognitionUpdate) -> Void,
                         onEndpoint: @escaping @MainActor @Sendable (Double) -> Void,
                         onFailure: @escaping @MainActor @Sendable (String) -> Void) async throws {
        guard authorizedLaunch, ownerConsent else { throw AudioFailure.microphoneLocked }
        await stop()
        try Task.checkCancellation()
        let session=UUID()
        generation=session
        let standardReady=await Self.installedStandardRecognizer()
        try checkSession(session)
        if !standardReady {
            guard LegacyOfflineMicrophone.supported else {throw AudioFailure.japaneseNotInstalled}
            let compatibility=LegacyOfflineMicrophone();legacy=compatibility
            do {
                try await compatibility.start(authorizedLaunch:authorizedLaunch,ownerConsent:ownerConsent,
                    allowPermissionPrompt:allowPermissionPrompt,onUpdate:onUpdate,onEndpoint:onEndpoint,onFailure:onFailure)
                try checkSession(session)
            } catch {if generation == session {await stop()};throw error}
            return
        }
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        if status == .notDetermined {
            guard allowPermissionPrompt else { throw AudioFailure.microphoneDenied }
            guard await AVCaptureDevice.requestAccess(for: .audio) else { throw AudioFailure.microphoneDenied }
        } else if status != .authorized { throw AudioFailure.microphoneDenied }
        try checkSession(session)
        let engine = AVAudioEngine()
        let node = engine.inputNode
        let format = node.outputFormat(forBus: 0)
        var tapInstalled=false
        do {
            let ingress = try await prepare(inputFormat: format, expectedSession: session,
                onUpdate: onUpdate, onEndpoint: onEndpoint, onFailure: onFailure)
            try checkSession(session)
            node.installTap(onBus: 0, bufferSize: 2048, format: format) { buffer, _ in
                do { try ingress.push(buffer) }
                catch { Task { @MainActor in onFailure("音声入力を処理できませんでした．") } }
            }
            tapInstalled=true
            engine.prepare()
            try checkSession(session)
            try engine.start()
            self.engine = engine
        } catch {
            if tapInstalled {engine.inputNode.removeTap(onBus:0)}
            engine.stop()
            if generation == session { await stop() }
            throw error
        }
    }

    private func checkSession(_ session: UUID) throws {
        try Task.checkCancellation()
        guard generation == session else {throw CancellationError()}
    }
    private static func installedStandardRecognizer() async -> Bool {
        guard SpeechTranscriber.isAvailable else {return false}
        guard let locale=await SpeechTranscriber.installedLocales.first(where:{$0.language.languageCode?.identifier == "ja"}) else {return false}
        let module=SpeechTranscriber(locale:locale,transcriptionOptions:[],
            reportingOptions:[.volatileResults,.alternativeTranscriptions,.fastResults],attributeOptions:[.audioTimeRange])
        return await AssetInventory.status(forModules:[module]) == .installed
    }

    public func stop() async {
        generation = UUID()
        assembler = TranscriptAssembler()
        sourceRevisions=[:]
        let previousEngine=engine
        let previousAnalyzer=analyzer
        let previousTask=resultTask
        let previousContinuation=continuation
        let previousLegacy=legacy
        // Detach owned resources before awaiting framework teardown, so an
        // older Stop cannot clear the resources of a newer start operation.
        engine=nil; analyzer=nil; resultTask=nil; continuation=nil; ingress=nil;legacy=nil
        previousLegacy?.stop()
        if let previousEngine { previousEngine.inputNode.removeTap(onBus:0); previousEngine.stop() }
        previousContinuation?.finish()
        previousTask?.cancel()
        await previousAnalyzer?.cancelAndFinishNow()
    }
}
