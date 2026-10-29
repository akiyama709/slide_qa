import Combine
import Foundation
import NativeLocalIO
import RealDeckEvidenceCore

@MainActor protocol LiveAudioDriving:AnyObject {
    var recognizerName:String {get}
    func startMicrophone(authorizedLaunch:Bool,ownerConsent:Bool,allowPermissionPrompt:Bool,
        onUpdate:@escaping @MainActor @Sendable (LiveRecognitionUpdate)->Void,
        onEndpoint:@escaping @MainActor @Sendable (Double)->Void,
        onFailure:@escaping @MainActor @Sendable (String)->Void) async throws
    func stop() async
}
extension NativeAudioPipeline:LiveAudioDriving {}

enum CaptureStopOrigin:String {
    case ownerButton,returnToStart,windowClosed,appTermination,permissionOrHardware
}
@MainActor final class LiveAudioController:ObservableObject {
    @Published private(set) var ownerConsent=false
    @Published private(set) var running=false
    @Published private(set) var starting=false
    @Published private(set) var stopping=false
    @Published private(set) var continuousIntent=false
    @Published private(set) var message="音声入力は開始していません．"
    @Published private(set) var lastFailure=""
    let enabledForThisLaunch:Bool
    private let audio:any LiveAudioDriving
    private let retryUnit:Duration
    private var startTask:Task<Void,Never>?
    private var journalTask:Task<Void,Never>?
    private var operation=UUID()
    private var stream=UUID()
    private var attempt=0
    private var highestOrder = -1
    private var orderBase=0
    private var journalURL:URL?
    private var stopOrigin:String?
    private var activeRecognizerName="not-started"
    private var beforeStopDiagnostics:[String:Int]?
    private var recognitionUpdates=0
    private var finalRecognitionUpdates=0
    private var nativeFinalRecognitionUpdates=0
    private var provisionalRecognitionUpdates=0
    private var audioEndpoints=0

    init(audio:any LiveAudioDriving=NativeAudioPipeline(),
         enabledForThisLaunch:Bool=LocalLaunchConfiguration(arguments:CommandLine.arguments).microphoneStartAllowed,
         retryUnit:Duration = .milliseconds(500),journalURL:URL?=nil) {
        self.audio=audio;self.enabledForThisLaunch=enabledForThisLaunch;self.retryUnit=retryUnit
        self.journalURL=journalURL
    }
    // Only the owner's Start action establishes continuous intent.
    func startByOwner(session:LiveQASession) {
        guard enabledForThisLaunch,!continuousIntent,!stopping else {return}
        ownerConsent=true;continuousIntent=true;operation=UUID()
        attempt=0;highestOrder = -1;orderBase=0;stopOrigin=nil;beforeStopDiagnostics=nil
        recognitionUpdates=0;finalRecognitionUpdates=0
        nativeFinalRecognitionUpdates=0;provisionalRecognitionUpdates=0;audioEndpoints=0
        session.beginContinuousQuestions()
        record(session)
        launch(session:session,epoch:operation,permissionPrompt:true)
        scheduleRecord(session,epoch:operation)
    }
    private func launch(session:LiveQASession,epoch:UUID,permissionPrompt:Bool) {
        guard continuousIntent,operation==epoch else {return}
        starting=true;running=false
        let token=UUID();stream=token;orderBase=highestOrder+1
        let base=orderBase
        if attempt==0 {message="端末内の音声認識を準備しています．"}
        startTask=Task {[weak self,weak session] in
            guard let self,let session else {return}
            do {
                try await self.audio.startMicrophone(authorizedLaunch:self.enabledForThisLaunch,
                    ownerConsent:self.ownerConsent,allowPermissionPrompt:permissionPrompt,
                    onUpdate:{[weak self,weak session] update in
                        guard let self,let session,self.continuousIntent,self.operation==epoch,self.stream==token else {return}
                        let (order,overflow)=base.addingReportingOverflow(update.order)
                        guard !overflow,update.order>=0 else {return}
                        self.recognitionUpdates+=1
                        if update.final {self.finalRecognitionUpdates+=1}
                        if update.provisionalCompletion {self.provisionalRecognitionUpdates+=1}
                        else if update.final {self.nativeFinalRecognitionUpdates+=1}
                        self.highestOrder=max(self.highestOrder,order);self.attempt=0
                        session.receive(.init(id:token.uuidString+":"+update.id,order:order,text:update.text,final:update.final,
                            audioStart:update.audioStart,audioEnd:update.audioEnd,alternatives:update.alternatives,
                            sourceRevision:update.sourceRevision,provisionalCompletion:update.provisionalCompletion,
                            stableCompletion:update.stableCompletion))
                        self.scheduleRecord(session,epoch:epoch)
                    },onEndpoint:{[weak self,weak session] _ in
                        guard let self,let session,self.operation==epoch,self.stream==token,self.continuousIntent else {return}
                        self.audioEndpoints+=1;self.scheduleRecord(session,epoch:epoch)
                    },onFailure:{[weak self,weak session] reason in
                        guard let self,let session,self.operation==epoch,self.stream==token,self.continuousIntent else {return}
                        self.recover(session:session,epoch:epoch,reason:reason)
                    })
                guard !Task.isCancelled,self.continuousIntent,self.operation==epoch,self.stream==token else {return}
                self.starting=false;self.running=true
                self.activeRecognizerName=self.audio.recognizerName
                self.message="質問を待っています．\(self.audio.recognizerName)で端末内認識中です．"
                self.record(session)
            } catch is CancellationError {}
            catch let failure as AudioFailure {
                guard self.operation==epoch,self.stream==token,self.continuousIntent else {return}
                switch failure {
                case .microphoneLocked,.microphoneDenied,.speechDenied,.japaneseNotInstalled,.unavailable:
                    self.stop(session:session,reason:failure.errorDescription,origin:.permissionOrHardware)
                default:self.recover(session:session,epoch:epoch,reason:failure.errorDescription ?? "音声入力を処理できませんでした．")
                }
            } catch {
                guard self.operation==epoch,self.stream==token,self.continuousIntent else {return}
                self.recover(session:session,epoch:epoch,reason:"音声認識を一時的に継続できませんでした．")
            }
        }
    }
    private func recover(session:LiveQASession,epoch:UUID,reason:String) {
        // Retire only the capture callbacks. Confirmed question/model leases
        // remain valid; no new permission prompt or user mode switch is needed.
        stream=UUID();startTask?.cancel();running=false;starting=true
        if attempt<Int.max {attempt+=1}
        lastFailure=reason
        message="音声認識を復帰中です．開始の押し直しは不要です．"
        record(session)
        let wait=retryUnit*min(1 << min(attempt-1,5),30)
        startTask=Task {[weak self,weak session] in
            guard let self,let session else {return}
            await self.audio.stop()
            do {try await Task.sleep(for:wait)} catch {return}
            guard self.continuousIntent,self.operation==epoch,!Task.isCancelled else {return}
            self.launch(session:session,epoch:epoch,permissionPrompt:false)
        }
    }
    func stop(session:LiveQASession,reason:String?=nil,origin:CaptureStopOrigin = .ownerButton) {
        beforeStopDiagnostics=session.diagnosticCounts
        stopOrigin=origin.rawValue
        continuousIntent=false;operation=UUID();stream=UUID()
        let epoch=operation
        startTask?.cancel();startTask=nil;starting=false;running=false;stopping=true
        message=reason ?? "収音の停止を確認しています．"
        if let reason {lastFailure=reason}
        journalTask?.cancel();journalTask=nil
        session.stop()
        record(session)
        Task {[weak self] in
            guard let self else {return}
            await self.audio.stop()
            if self.operation==epoch {self.stopping=false;self.message=reason ?? "収音は停止しています．"}
        }
    }
    private func record(_ session:LiveQASession) {
        guard let journalURL else {return}
        let values:[String:Any]=["atUTC":ISO8601DateFormatter().string(from:Date()),
            "continuousIntent":continuousIntent,"captureRunning":running,"reconnecting":starting,
            "retryAttempt":attempt,"lastFailure":lastFailure,"recognizer":activeRecognizerName,
            "stopOrigin":stopOrigin ?? "none","appVersion":Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "test",
            "questionDiagnostics":beforeStopDiagnostics ?? session.diagnosticCounts,
            "lastGenerationFailure":session.lastGenerationFailure,
            "lastInputDisposition":session.lastInputDisposition,
            "recognitionUpdates":recognitionUpdates,"finalRecognitionUpdates":finalRecognitionUpdates,
            "nativeFinalRecognitionUpdates":nativeFinalRecognitionUpdates,
            "provisionalRecognitionUpdates":provisionalRecognitionUpdates,"audioEndpoints":audioEndpoints,
            "questionPhase":session.phase.rawValue,"acceptingInput":session.acceptingInput,
            "generationEnabled":session.generationEnabled,
            "questionCount":session.cards.count,"generationRequests":session.generationRequests,
            "answerCount":session.cards.filter{$0.draft != nil}.count,
            "transcriptStored":false,"audioStored":false]
        do {
            try FileManager.default.createDirectory(at:journalURL.deletingLastPathComponent(),withIntermediateDirectories:true)
            try JSONSerialization.data(withJSONObject:values,options:.sortedKeys).write(to:journalURL,options:.atomic)
        } catch { /* A diagnostic write must not interrupt capture or generation. */ }
    }
    private func scheduleRecord(_ session:LiveQASession,epoch:UUID) {
        guard journalURL != nil,journalTask==nil else {return}
        journalTask=Task {[weak self,weak session] in
            while !Task.isCancelled {
                do {try await Task.sleep(for:.seconds(2))} catch {return}
                guard let self,let session,self.operation==epoch,self.continuousIntent else {return}
                self.record(session)
            }
        }
    }
    static var localJournalURL:URL? {
        guard LocalLaunchConfiguration(arguments:CommandLine.arguments).writesOwnerDiagnostics else {return nil}
        return FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask).first?
            .appendingPathComponent("SlideQA/Diagnostics/last-capture-state.json")
    }
}
