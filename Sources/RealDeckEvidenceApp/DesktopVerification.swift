#if SLIDEQA_DESKTOP_VALIDATION
import AppKit
import Foundation
import FoundationModels
import NativeLocalIO
import RealDeckEvidenceCore

/// Explicit developer build only. Normal builds have no automatic model hook.
/// Receives a hash-bound synthetic manifest; never invokes an audio API.
@MainActor enum DesktopVerification {
    private struct Spec:Decodable {
        let nonce:String
        let syntheticOnly:Bool
        let expectedDeckSHA256:String
        let mode:String
        let questions:[String]
        let seconds:Int
    }
    private static var nonce="not-loaded"
    private static var ended=false
    private static var visibleAnswers:[String:String]=[:]
    private static var hiddenCards:Set<String>=[]
    /// Called by this app's own SwiftUI card lifecycle. Observes no screen,
    /// accessibility tree, other window, microphone, or private document.
    static func cardViewUpdated(_ card:LiveQACard) {
        guard nonce != "not-loaded",!ended else {return}
        Task {@MainActor in
            await Task.yield()
            guard !ended,NSApplication.shared.windows.contains(where:{
                $0.isVisible && $0.title=="SlideQA 0.32.0" && $0.frame.width>=900 && $0.frame.height>=600
            }) else {return}
            if !card.allowsDisplay {
                hiddenCards.insert(card.id);visibleAnswers.removeValue(forKey:card.id)
                emit("card-view-hidden",["cardID":card.id]);return
            }
            if let draft=card.draft,visibleAnswers[card.id] != draft.text {
                visibleAnswers[card.id]=draft.text
                emit("card-view-updated",["cardID":card.id,"answerMatchesBoundView":true,
                    "windowVisible":true,"pixelCapturePerformed":false])
            }
        }
    }
    static func modelDiagnostic(_ value:LocalModelDiagnostic) {
        if let data=try? JSONEncoder().encode(value),
           let object=try? JSONSerialization.jsonObject(with:data) {
            emit("model-diagnostic",["diagnostic":object])
        }
    }
    private static func emit(_ event:String,_ values:[String:Any]=[:]) {
        var row=values
        row["event"]=event;row["nonce"]=nonce
        row["microphoneStarted"]=false;row["permissionsRequested"]=false
        if let data=try? JSONSerialization.data(withJSONObject:row,options:[.sortedKeys]) {
            FileHandle.standardOutput.write(data);FileHandle.standardOutput.write(Data([10]))
        }
    }
    private static func finish(_ success:Bool,_ reason:String) {
        guard !ended else {return};ended=true
        emit("terminal",["success":success,"reason":reason])
        NSApplication.shared.terminate(nil)
    }
    static func run(model:EvidenceViewModel) async {
        let args=CommandLine.arguments,launch=LocalLaunchConfiguration(arguments:args)
        guard launch.automaticModelCheck,!launch.microphoneStartAllowed,
              let position=args.firstIndex(of:"--verification-spec"),position+1<args.count,
              let resources=Bundle.main.resourceURL,
              URL(fileURLWithPath:args[position+1]).standardizedFileURL==resources.appendingPathComponent("desktop-verification.json").standardizedFileURL,
              let data=try? Data(contentsOf:URL(fileURLWithPath:args[position+1])),
              let spec=try? JSONDecoder().decode(Spec.self,from:data),spec.syntheticOnly,
              !spec.nonce.isEmpty,!spec.questions.isEmpty,["raw","session","all"].contains(spec.mode) else {finish(false,"invalid-explicit-synthetic-manifest");return}
        nonce=spec.nonce
        emit("started",["bundleID":Bundle.main.bundleIdentifier ?? "none",
            "bundleName":Bundle.main.bundleURL.lastPathComponent,
            "executableName":Bundle.main.executableURL?.lastPathComponent ?? "none",
            "osVersion":ProcessInfo.processInfo.operatingSystemVersionString,
            "mode":spec.mode,"pid":ProcessInfo.processInfo.processIdentifier])
        let budget=min(max(spec.seconds,5),180)
        let watchdog=Task {@MainActor in
            do {try await Task.sleep(for:.seconds(budget))} catch {return}
            finish(false,"overall-verification-timeout")
        }
        defer {watchdog.cancel()}
        for _ in 0..<400 {
            if model.liveSession != nil {break}
            do {try await Task.sleep(for:.milliseconds(25))} catch {finish(false,"cancelled");return}
        }
        guard let session=model.liveSession,model.originalFileSHA256==spec.expectedDeckSHA256,
              session.index.deck.sourceFile=="synthetic-deck.json" else {finish(false,"synthetic-deck-not-loaded-or-hash-mismatch");return}
        let native=SystemLanguageModel.default
        emit("ready",["modelAvailable":native.isAvailable,"japaneseSupported":native.supportsLocale(Locale(identifier:"ja-JP")),
                      "pages":session.index.deck.pageCount,"deckHashMatched":true])
        guard native.isAvailable,native.supportsLocale(Locale(identifier:"ja-JP")) else {finish(false,"model-or-japanese-unavailable");return}
        if spec.mode=="raw" || spec.mode=="all" {
            var result:Result<String,Error>?
            let started=ContinuousClock.now
            let worker=Task {@MainActor in
                do {
                    let nativeSession=LanguageModelSession(model:native,tools:[],instructions:"合成資料だけを使い，日本語一文で答えてください．")
                    let original=session.index.passages.map(\.text).joined(separator:"\n")
                    let response=try await nativeSession.respond(to:"合成資料：\(original)\n質問：\(spec.questions[0])",
                        options:GenerationOptions(temperature:0,maximumResponseTokens:100))
                    result = .success(response.content)
                } catch {result = .failure(error)}
            }
            for _ in 0..<600 {
                if result != nil || ended {break}
                do {try await Task.sleep(for:.milliseconds(25))} catch {break}
            }
            let elapsed=started.duration(to:.now).components
            let seconds=Double(elapsed.seconds)+Double(elapsed.attoseconds)/1e18
            guard let result else {worker.cancel();finish(false,"raw-generation-timeout");return}
            switch result {
            case .success(let answer):
                emit("raw-answer",["answer":answer,"elapsedSeconds":seconds])
                guard !answer.isEmpty else {finish(false,"raw-empty");return}
                if spec.mode=="raw" {finish(true,"raw-finished");return}
            case .failure(let error):
                // Only this hash-bound synthetic run observes raw error details.
                let e=error as NSError
                emit("raw-error",["domain":e.domain,"code":e.code,"detail":String(reflecting:error),"elapsedSeconds":seconds])
                finish(false,"raw-generation-failed");return
            }
        }
        session.beginContinuousQuestions()
        var sourceOrder=0
        var cancelledCards:[LiveQACard]=[]
        for (order,question) in spec.questions.enumerated() {
            if spec.mode=="all",order==2 {
                let before=session.generationRequests
                session.receive(.init(id:"cancel-probe",order:sourceOrder,text:spec.questions[0],final:true,
                    audioStart:Double(sourceOrder)*4,audioEnd:Double(sourceOrder)*4+2,sourceRevision:1))
                sourceOrder+=1
                for _ in 0..<100 {
                    if session.generationRequests>before {break}
                    try? await Task.sleep(for:.milliseconds(25))
                }
                guard session.generationRequests>before,let old=session.cards.last else {finish(false,"cancel-target-never-generated");return}
                let inFlight=old.draft==nil && session.diagnosticCounts["generating"] != 0
                session.receive(.init(id:"cancel-control",order:sourceOrder,text:"今の質問を取り消します．",final:true,
                    audioStart:Double(sourceOrder)*4,audioEnd:Double(sourceOrder)*4+2,sourceRevision:1))
                sourceOrder+=1;cancelledCards.append(old)
                emit("cancelled",["whileGenerating":inFlight,"oldDraftHidden":old.draft==nil && !old.allowsDisplay])
                guard old.draft==nil,!old.allowsDisplay else {finish(false,"cancelled-draft-still-visible");return}
                for _ in 0..<80 {
                    if hiddenCards.contains(old.id) {break}
                    try? await Task.sleep(for:.milliseconds(25))
                }
                guard hiddenCards.contains(old.id) else {finish(false,"cancelled-card-view-not-updated");return}
            }
            let started=ContinuousClock.now
            let synthetic=LiveRecognitionUpdate(id:"desktop-\(order)",order:sourceOrder,text:question,
                final:order != spec.questions.count-1,audioStart:Double(sourceOrder)*4,audioEnd:Double(sourceOrder)*4+2,sourceRevision:1)
            sourceOrder+=1
            var completion:SpeechQuestionCompletion?
            if !synthetic.final {
                completion=SpeechQuestionCompletion {value in
                    session.receive(.init(id:value.id,order:value.order,text:value.text,final:true,
                        audioStart:value.audioStart,audioEnd:value.audioEnd,sourceRevision:2,
                        provisionalCompletion:true,stableCompletion:true))
                }
                completion?.receive(synthetic)
            }
            session.receive(synthetic)
            for _ in 0..<600 {
                if session.cards.contains(where:{$0.ticket.turnID==synthetic.id && $0.draft != nil}) ||
                    (completion==nil && session.diagnosticCounts["generating"]==0 && session.diagnosticCounts["queued"]==0) || session.generationFailures>0 {break}
                do {try await Task.sleep(for:.milliseconds(25))} catch {break}
            }
            completion?.stop()
            let elapsed=started.duration(to:.now).components
            let card=session.cards.last(where:{$0.ticket.turnID==synthetic.id}),draft=card?.draft
            if let card,let draft {
                for _ in 0..<80 {
                    if visibleAnswers[card.id]==draft.text {break}
                    try? await Task.sleep(for:.milliseconds(25))
                }
            }
            let viewUpdated=card.map{visibleAnswers[$0.id]==draft?.text && draft != nil} ?? false
            emit("session-answer",["order":order,"question":question,"answer":draft?.text ?? "",
                "draftShown":draft != nil,"abstained":draft?.abstained ?? false,
                "reviewState":draft?.reviewState.rawValue ?? "none","status":card?.status ?? "none",
                "stableCompletion":card?.stableCompletion ?? false,"visibleCardViewUpdated":viewUpdated,
                "sources":draft?.citations.map{$0.id} ?? [],"generationRequests":session.generationRequests,
                "lastFailure":session.lastGenerationFailure,
                "elapsedSeconds":Double(elapsed.seconds)+Double(elapsed.attoseconds)/1e18])
            guard draft != nil,draft?.abstained==false else {session.stop();finish(false,"session-no-answer");return}
            guard viewUpdated else {session.stop();finish(false,"answer-view-not-updated");return}
        }
        let hidden=cancelledCards.allSatisfy{$0.draft==nil && !$0.allowsDisplay}
        emit("sequence-summary",["questions":spec.questions.count,"cancelledResultsRemainHidden":hidden,
            "discardedLateReplies":session.discardedLateReplies,"generationRequests":session.generationRequests])
        session.stop()
        let requestsAtStop=session.generationRequests
        session.receive(.init(id:"post-stop",order:sourceOrder,text:spec.questions[0],final:true,
            audioStart:Double(sourceOrder)*4,audioEnd:Double(sourceOrder)*4+2,sourceRevision:1))
        try? await Task.sleep(for:.milliseconds(500))
        let stopped = !session.acceptingInput && session.generationRequests==requestsAtStop
        emit("stopped",["rejectsFurtherQuestions":stopped,"generationRequests":session.generationRequests])
        finish(hidden && stopped,"session-sequence-finished")
    }
}
#endif
