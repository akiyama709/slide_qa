import Foundation
import Darwin
@preconcurrency import AVFoundation
@preconcurrency import Speech
import RealDeckEvidenceCore

public enum InterruptedQuestionCompletion {
    public static func provisional(_ update:LiveRecognitionUpdate)->LiveRecognitionUpdate? {
        guard !update.final,LiveQuestionSyntax.isCompleteRequest(update.text),
              update.sourceRevision != Int.max else {return nil}
        return .init(id:update.id,order:update.order,text:update.text,final:true,
            audioStart:update.audioStart,audioEnd:update.audioEnd,alternatives:update.alternatives,
            sourceRevision:update.sourceRevision.map{$0+1},provisionalCompletion:true)
    }
}

/// A complete request can be provisionally released after an acoustic endpoint
/// or stable recognized wording. The latter is not represented as measured silence.
@MainActor public final class SpeechQuestionCompletion {
    private let grace:Duration
    private let textGrace:Duration
    private let onStable:@MainActor @Sendable (LiveRecognitionUpdate)->Void
    private var latest:LiveRecognitionUpdate?
    private var boundary:Double?
    private var releasedText:String?
    private var task:Task<Void,Never>?
    private var operation=UUID()
    public init(grace:Duration = .milliseconds(750),textGrace:Duration = .milliseconds(1200),
                onStable:@escaping @MainActor @Sendable (LiveRecognitionUpdate)->Void) {
        self.grace=grace;self.textGrace=textGrace;self.onStable=onStable
    }
    public func receive(_ update:LiveRecognitionUpdate) {
        if let latest,update.order<latest.order {return}
        let same=latest.map{$0.id==update.id && $0.text==update.text && abs($0.audioEnd-update.audioEnd)<0.05} ?? false
        latest=update
        if update.final {boundary=nil;releasedText=nil;task?.cancel();task=nil;operation=UUID();return}
        if let boundary,update.audioEnd>boundary+0.35 {self.boundary=nil}
        if same,(task != nil || releasedText==update.text) {return}
        releasedText=nil;schedule()
    }
    public func endpoint(_ audioEnd:Double) {boundary=audioEnd;schedule()}
    public func stop() {task?.cancel();task=nil;latest=nil;boundary=nil;releasedText=nil;operation=UUID()}
    private func schedule() {
        task?.cancel();task=nil;operation=UUID()
        guard let latest,!latest.final,releasedText != latest.text,
              LiveQuestionSyntax.isCompleteRequest(latest.text) || LiveQuestionSyntax.endsWithCancellation(latest.text) else {return}
        let token=operation,wait=boundary == nil ? textGrace:grace
        task=Task {[weak self] in
            guard let self else {return}
            do {try await Task.sleep(for:wait)} catch {return}
            guard self.operation==token,let current=self.latest,!current.final,
                  current.id==latest.id,current.text==latest.text else {return}
            self.task=nil;self.releasedText=current.text
            self.onStable(current)
        }
    }
}
private struct LegacyTextPacket:Sendable {
    let text:String
    let final:Bool
    let relativeEnd:Double
    let alternatives:[String]
    let errorDomain:String?
    let errorCode:Int?
}

/// The same reducer is used by native callbacks and audio-free regression tests.
/// A cancellation is a completed control turn, never a prefix of the next question.
public struct LegacyRecognitionTurns:Sendable {
    private var order=0
    private var start:Double?
    private var completed=""
    private var revision=0
    public init() {}
    public mutating func confirmStableQuestion(_ update:LiveRecognitionUpdate)->LiveRecognitionUpdate? {
        guard !update.final,update.order==order,update.sourceRevision==revision,revision<Int.max,
              LiveQuestionSyntax.isCompleteRequest(update.text) || LiveQuestionSyntax.endsWithCancellation(update.text) else {return nil}
        revision+=1
        return .init(id:update.id,order:update.order,text:update.text,final:true,audioStart:update.audioStart,
            audioEnd:update.audioEnd,alternatives:update.alternatives,sourceRevision:revision,
            provisionalCompletion:true,stableCompletion:true)
    }
    public mutating func accept(id:String,text:String,final:Bool,start audioStart:Double,end:Double,
                                alternatives:[String]=[])->LiveRecognitionUpdate? {
        guard !text.isEmpty else {return nil}
        if start == nil {start=audioStart;revision=0}
        revision+=1
        // A standalone control utterance supersedes an unfinished speech
        // fragment; it must still reach the cancellation parser at the start.
        let prefix=final && LiveQuestionSyntax.isCancellation(text) ? "":completed
        let accumulated=prefix.isEmpty ? text:prefix+" "+text
        let value=LiveRecognitionUpdate(id:id+":legacy\(order)",order:order,text:accumulated,final:final,
            audioStart:start ?? audioStart,audioEnd:end,
            alternatives:alternatives.map{prefix.isEmpty ? $0:prefix+" "+$0},sourceRevision:revision)
        if final {
            if LiveQuestionSyntax.isCompleteRequest(accumulated,finalUtterance:true)
                || LiveQuestionSyntax.isCancellation(accumulated) || LiveQuestionSyntax.isFinishedStatement(accumulated)
                || accumulated.utf8.count>=8_000 {
                order+=1;start=nil;completed="";revision=0
            } else {completed=accumulated}
        }
        return value
    }
}

/// Owns only the current request and a bounded RAM pre-roll/rotation buffer.
/// No audio file, network client or asset-install API is used.
private final class LegacyAudioIngress:@unchecked Sendable {
    private struct Chunk {let buffer:AVAudioPCMBuffer;let start:Double;let voiced:Bool}
    private let lock=NSLock()
    private var active=true
    private var request:SFSpeechAudioBufferRecognitionRequest?
    private var pending:[Chunk]=[]
    private var pendingDuration:Double=0
    private var position:Double=0
    private var turnStart:Double=0
    private var lastVoice:Double=0
    private var voiceOpen=false
    private var closing=false
    private var startRequested=false
    private var queuedVoice=false
    let needRequest:@Sendable ()->Void
    let endpoint:@Sendable (Double)->Void
    let failure:@Sendable ()->Void

    init(needRequest:@escaping @Sendable ()->Void,endpoint:@escaping @Sendable (Double)->Void,
         failure:@escaping @Sendable ()->Void) {
        self.needRequest=needRequest;self.endpoint=endpoint;self.failure=failure
    }
    private func copy(_ input:AVAudioPCMBuffer)->AVAudioPCMBuffer? {
        guard let output=AVAudioPCMBuffer(pcmFormat:input.format,frameCapacity:input.frameLength) else {return nil}
        output.frameLength=input.frameLength
        let from=UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating:input.audioBufferList))
        let to=UnsafeMutableAudioBufferListPointer(output.mutableAudioBufferList)
        guard from.count == to.count else {return nil}
        for offset in from.indices {
            guard let src=from[offset].mData,let dst=to[offset].mData else {return nil}
            memcpy(dst,src,Int(from[offset].mDataByteSize))
        }
        return output
    }
    func push(_ buffer:AVAudioPCMBuffer) {
        lock.lock()
        guard active,buffer.format.sampleRate>0 else {lock.unlock();return}
        let duration=Double(buffer.frameLength)/buffer.format.sampleRate
        let start=position;position+=duration
        var voiced=false
        if let channel=buffer.floatChannelData?[0],buffer.frameLength>0 {
            var sum:Float=0
            for offset in 0..<Int(buffer.frameLength) {sum+=channel[offset]*channel[offset]}
            voiced=sqrt(sum/Float(buffer.frameLength))>0.006
        }
        var notifyStart=false,notifyEnd:Double?,overflow=false
        if let request,!closing {
            request.append(buffer)
            if voiced {lastVoice=position;voiceOpen=true}
            if (voiceOpen && position-lastVoice>=0.60) || position-turnStart>=50 {
                closing=true;voiceOpen=false
                request.endAudio()
                notifyEnd=lastVoice
            }
        } else {
            if let clone=copy(buffer) {
                pending.append(Chunk(buffer:clone,start:start,voiced:voiced));pendingDuration+=duration
                if voiced {queuedVoice=true}
                if request == nil,!startRequested,queuedVoice {startRequested=true;notifyStart=true}
                if request == nil,!startRequested {
                    while pendingDuration>0.25,pending.count>1 {
                        let first=pending.removeFirst()
                        pendingDuration-=Double(first.buffer.frameLength)/first.buffer.format.sampleRate
                    }
                }
                if pendingDuration>12 {active=false;overflow=true}
            } else {active=false;overflow=true}
        }
        lock.unlock()
        if notifyStart {needRequest()}
        if let notifyEnd {endpoint(notifyEnd)}
        if overflow {failure()}
    }
    func attach(_ next:SFSpeechAudioBufferRecognitionRequest)->Double? {
        lock.lock();defer{lock.unlock()}
        guard active,request == nil else {return nil}
        turnStart=pending.first?.start ?? position
        request=next;closing=false;startRequested=false;voiceOpen=queuedVoice
        lastVoice=pending.last(where:{$0.voiced}).map{$0.start+Double($0.buffer.frameLength)/$0.buffer.format.sampleRate} ?? turnStart
        for chunk in pending {next.append(chunk.buffer)}
        pending=[];pendingDuration=0;queuedVoice=false
        return turnStart
    }
    func completeTurn() {
        lock.lock()
        guard active else {lock.unlock();return}
        request=nil;closing=false;voiceOpen=false
        let shouldStart=queuedVoice && !startRequested
        if shouldStart {startRequested=true}
        lock.unlock()
        if shouldStart {needRequest()}
    }
    func stop() {
        lock.lock();defer{lock.unlock()}
        active=false;request?.endAudio();request=nil;pending=[];pendingDuration=0
    }
}

/// Compatibility path for an already supported on-device Japanese recognizer.
/// Never sets supportsOnDeviceRecognition; false means an immediate stop.
@MainActor final class LegacyOfflineMicrophone {
    private var generation=UUID()
    private var engine:AVAudioEngine?
    private var ingress:LegacyAudioIngress?
    private var recognizer:SFSpeechRecognizer?
    private var task:SFSpeechRecognitionTask?
    private var request:SFSpeechAudioBufferRecognitionRequest?
    private var activeTurn:UUID?
    private var turnOrder=0
    private var turns=LegacyRecognitionTurns()
    private var tapInstalled=false
    private var completionWatchdog:Task<Void,Never>?
    private var lastTurnUpdate:LiveRecognitionUpdate?
    private var endpointCompletion:SpeechQuestionCompletion?
    private var callback:(@MainActor @Sendable (LiveRecognitionUpdate)->Void)?
    private var failure:(@MainActor @Sendable (String)->Void)?

    static var supported:Bool {
        SFSpeechRecognizer(locale:Locale(identifier:"ja-JP"))?.supportsOnDeviceRecognition == true
    }
    func start(authorizedLaunch:Bool,ownerConsent:Bool,allowPermissionPrompt:Bool,
               onUpdate:@escaping @MainActor @Sendable (LiveRecognitionUpdate)->Void,
               onEndpoint:@escaping @MainActor @Sendable (Double)->Void,
               onFailure:@escaping @MainActor @Sendable (String)->Void) async throws {
        guard authorizedLaunch,ownerConsent else {throw AudioFailure.microphoneLocked}
        stop();let session=UUID();generation=session
        guard let recognizer=SFSpeechRecognizer(locale:Locale(identifier:"ja-JP")),
              recognizer.supportsOnDeviceRecognition else {throw AudioFailure.japaneseNotInstalled}
        guard recognizer.isAvailable else {throw AudioFailure.recognitionInterrupted}
        self.recognizer=recognizer
        var speechStatus=SFSpeechRecognizer.authorizationStatus()
        if speechStatus == .notDetermined {
            guard allowPermissionPrompt else {throw AudioFailure.speechDenied}
            speechStatus=await CallbackBridge.value { @Sendable completion in
                SFSpeechRecognizer.requestAuthorization { @Sendable status in completion(status) }
            }
        }
        try check(session)
        guard speechStatus == .authorized else {throw AudioFailure.speechDenied}
        let microphone=AVCaptureDevice.authorizationStatus(for:.audio)
        if microphone == .notDetermined {
            guard allowPermissionPrompt else {throw AudioFailure.microphoneDenied}
            guard await AVCaptureDevice.requestAccess(for:.audio) else {throw AudioFailure.microphoneDenied}
        } else if microphone != .authorized {throw AudioFailure.microphoneDenied}
        try check(session)
        callback=onUpdate;failure=onFailure
        endpointCompletion=SpeechQuestionCompletion {[weak self] update in
            guard let self,self.generation==session,
                  let value=self.turns.confirmStableQuestion(update) else {return}
            self.lastTurnUpdate=value;self.callback?(value)
        }
        let engine=AVAudioEngine();let node=engine.inputNode;let format=node.outputFormat(forBus:0)
        guard format.sampleRate>0,format.channelCount>0,format.commonFormat == .pcmFormatFloat32 else {throw AudioFailure.format}
        let ingress=LegacyAudioIngress(needRequest:{[weak self] in
            Task {@MainActor in guard let self,self.generation == session else {return};self.beginTurn(session)}
        },endpoint:{[weak self] end in Task {@MainActor in
            guard let self,self.generation == session else {return}
            onEndpoint(end);self.endpointCompletion?.endpoint(end);self.watchCompletion(session)
        }},failure:{[weak self] in
            Task {@MainActor in
                guard let self,self.generation == session else {return}
                self.completeInterruptedQuestion()
                onFailure("音声認識の待機バッファ上限を超えたため停止します．")
            }
        })
        self.ingress=ingress;self.engine=engine
        node.installTap(onBus:0,bufferSize:2048,format:format) { @Sendable buffer,_ in ingress.push(buffer)}
        tapInstalled=true;engine.prepare()
        do {try engine.start();try check(session)} catch {stop();throw error}
    }
    private func beginTurn(_ session:UUID) {
        guard generation == session,task == nil,let recognizer,recognizer.supportsOnDeviceRecognition,
              let ingress else {return}
        guard recognizer.isAvailable else {
            // Ingress has already requested a task and will not request again.
            // A silent return here wedges capture until another owner Start.
            failure?(AudioFailure.recognitionInterrupted.errorDescription ?? "");return
        }
        let request=SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition=true
        guard request.requiresOnDeviceRecognition else {failure?("端末内認識を強制できないため停止します．");return}
        request.shouldReportPartialResults=true
        request.addsPunctuation=true
        request.contextualStrings=["訂正します", "今の質問を取り消します"]
        guard let start=ingress.attach(request) else {return}
        self.request=request;lastTurnUpdate=nil;endpointCompletion?.stop()
        let turn=UUID();turnOrder+=1;activeTurn=turn
        task=recognizer.recognitionTask(with:request) { @Sendable [weak self] result,error in
            let best=result?.bestTranscription
            let packet=LegacyTextPacket(text:best?.formattedString ?? "",final:result?.isFinal ?? false,
                relativeEnd:best?.segments.last.map{$0.timestamp+$0.duration} ?? 0,
                alternatives:Array((result?.transcriptions.dropFirst().prefix(2) ?? []).map(\.formattedString)),
                errorDomain:(error as NSError?)?.domain,errorCode:(error as NSError?)?.code)
            Task {@MainActor in
                guard let self,self.generation == session,self.activeTurn == turn else {return}
                if let update=self.turns.accept(id:session.uuidString,text:packet.text,final:packet.final,
                    start:start,end:start+packet.relativeEnd,alternatives:packet.alternatives) {
                    self.lastTurnUpdate=update;self.endpointCompletion?.receive(update);self.callback?(update)
                }
                if packet.final {
                    self.completionWatchdog?.cancel();self.completionWatchdog=nil
                    self.activeTurn=nil;self.task?.cancel();self.task=nil;self.request=nil
                    self.ingress?.completeTurn()
                } else if packet.errorDomain != nil {
                    self.completeInterruptedQuestion()
                    let domain=String((packet.errorDomain ?? "Speech").prefix(120))
                    self.failure?("音声認識サービスが中断しました． "+domain+" / "+String(packet.errorCode ?? 0))
                }
            }
        }
    }
    private func check(_ session:UUID) throws {
        try Task.checkCancellation()
        guard generation == session else {throw CancellationError()}
    }
    private func watchCompletion(_ session:UUID) {
        completionWatchdog?.cancel()
        let turn=activeTurn
        completionWatchdog=Task {[weak self] in
            do {try await Task.sleep(for:.seconds(8))} catch {return}
            guard let self,self.generation==session,self.activeTurn==turn,turn != nil else {return}
            self.completeInterruptedQuestion()
            self.failure?("音声の確定待ちが続いています．未確定の音声は回答に使わず，認識を復帰します．")
        }
    }
    private func completeInterruptedQuestion() {
        guard let lastTurnUpdate,let next=InterruptedQuestionCompletion.provisional(lastTurnUpdate) else {return}
        self.lastTurnUpdate=next;callback?(next)
    }
    func stop() {
        completionWatchdog?.cancel();completionWatchdog=nil
        endpointCompletion?.stop();endpointCompletion=nil
        generation=UUID();activeTurn=nil;lastTurnUpdate=nil
        ingress?.stop();ingress=nil;request=nil
        task?.cancel();task=nil;recognizer=nil
        if let engine {if tapInstalled {engine.inputNode.removeTap(onBus:0)};engine.stop()}
        engine=nil;tapInstalled=false;callback=nil;failure=nil;turnOrder=0;turns=LegacyRecognitionTurns()
    }
}
