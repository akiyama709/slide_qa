import Foundation
import Darwin
@preconcurrency import AVFoundation
@preconcurrency import Speech
import RealDeckEvidenceCore

private struct LegacyTextPacket:Sendable {
    let text:String
    let final:Bool
    let relativeEnd:Double
    let alternatives:[String]
    let errorDomain:String?
    let errorCode:Int?
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
                if pendingDuration>3 {active=false;overflow=true}
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
    private var logicalOrder=0
    private var logicalStart:Double?
    private var completedText=""
    private var revision=0
    private var tapInstalled=false
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
              recognizer.supportsOnDeviceRecognition,recognizer.isAvailable else {throw AudioFailure.japaneseNotInstalled}
        self.recognizer=recognizer
        var speechStatus=SFSpeechRecognizer.authorizationStatus()
        if speechStatus == .notDetermined {
            guard allowPermissionPrompt else {throw AudioFailure.speechDenied}
            speechStatus=await withCheckedContinuation {continuation in
                SFSpeechRecognizer.requestAuthorization {continuation.resume(returning:$0)}
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
        let engine=AVAudioEngine();let node=engine.inputNode;let format=node.outputFormat(forBus:0)
        guard format.sampleRate>0,format.channelCount>0,format.commonFormat == .pcmFormatFloat32 else {throw AudioFailure.format}
        let ingress=LegacyAudioIngress(needRequest:{[weak self] in
            Task {@MainActor in guard let self,self.generation == session else {return};self.beginTurn(session)}
        },endpoint:{[weak self] end in Task {@MainActor in
            guard let self,self.generation == session else {return};onEndpoint(end)
        }},failure:{[weak self] in
            Task {@MainActor in
                guard let self,self.generation == session else {return}
                onFailure("音声認識の待機バッファ上限を超えたため停止します．")
            }
        })
        self.ingress=ingress;self.engine=engine
        node.installTap(onBus:0,bufferSize:2048,format:format) {buffer,_ in ingress.push(buffer)}
        tapInstalled=true;engine.prepare()
        do {try engine.start();try check(session)} catch {stop();throw error}
    }
    private func beginTurn(_ session:UUID) {
        guard generation == session,task == nil,let recognizer,recognizer.supportsOnDeviceRecognition,
              recognizer.isAvailable,let ingress else {return}
        let request=SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition=true
        guard request.requiresOnDeviceRecognition else {failure?("端末内認識を強制できないため停止します．");return}
        request.shouldReportPartialResults=true
        request.addsPunctuation=true
        request.contextualStrings=["オリオン装置", "リラ装置", "温度", "振動", "点検", "校正", "警報", "取消", "訂正"]
        guard let start=ingress.attach(request) else {return}
        self.request=request
        let turn=UUID(),order=logicalOrder;turnOrder+=1;activeTurn=turn
        if logicalStart == nil {logicalStart=start;revision=0}
        let groupStart=logicalStart ?? start
        let prefix=completedText
        task=recognizer.recognitionTask(with:request) {[weak self] result,error in
            let best=result?.bestTranscription
            let packet=LegacyTextPacket(text:best?.formattedString ?? "",final:result?.isFinal ?? false,
                relativeEnd:best?.segments.last.map{$0.timestamp+$0.duration} ?? 0,
                alternatives:Array((result?.transcriptions.dropFirst().prefix(2) ?? []).map(\.formattedString)),
                errorDomain:(error as NSError?)?.domain,errorCode:(error as NSError?)?.code)
            Task {@MainActor in
                guard let self,self.generation == session,self.activeTurn == turn else {return}
                if !packet.text.isEmpty {
                    self.revision+=1
                    let accumulated=prefix.isEmpty ? packet.text:prefix+" "+packet.text
                    self.callback?(.init(id:"\(session.uuidString):legacy\(order)",order:order,text:accumulated,final:packet.final,
                        audioStart:groupStart,audioEnd:start+packet.relativeEnd,
                        alternatives:packet.alternatives.map{prefix.isEmpty ? $0:prefix+" "+$0},sourceRevision:self.revision))
                    if packet.final {
                        if LiveQuestionSyntax.isCompleteRequest(accumulated) || accumulated.utf8.count>=8_000 {
                            self.logicalOrder+=1;self.logicalStart=nil;self.completedText="";self.revision=0
                        } else {self.completedText=accumulated}
                    }
                }
                if packet.final {
                    self.activeTurn=nil;self.task?.cancel();self.task=nil;self.request=nil
                    self.ingress?.completeTurn()
                } else if packet.errorDomain != nil {
                    self.failure?("端末内の日本語認識を継続できませんでした．外部認識や資産取得には切り替えません．")
                }
            }
        }
    }
    private func check(_ session:UUID) throws {
        try Task.checkCancellation()
        guard generation == session else {throw CancellationError()}
    }
    func stop() {
        generation=UUID();activeTurn=nil
        ingress?.stop();ingress=nil;request=nil
        task?.cancel();task=nil;recognizer=nil
        if let engine {if tapInstalled {engine.inputNode.removeTap(onBus:0)};engine.stop()}
        engine=nil;tapInstalled=false;callback=nil;failure=nil;turnOrder=0;revision=0
        logicalOrder=0;logicalStart=nil;completedText=""
    }
}
