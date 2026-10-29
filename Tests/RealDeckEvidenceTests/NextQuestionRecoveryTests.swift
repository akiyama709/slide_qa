import Foundation
import Testing
import FoundationModels
import SlideQACore
@testable import RealDeckEvidenceCore
@testable import NativeLocalIO
@testable import RealDeckEvidenceApp

@MainActor private final class RecoveryGenerator:LocalDraftGenerating {
    var requests:[LocalDraftRequest]=[]
    var first:CheckedContinuation<GuardedLocalDraft,Error>?
    var holdFirst=false
    var failFirst=false
    var cancelFirst=false
    var onFirstRequest:(()->Void)?
    func generate(_ request:LocalDraftRequest) async throws ->GuardedLocalDraft {
        requests.append(request)
        if requests.count==1 {onFirstRequest?()}
        if holdFirst && requests.count==1 {return try await withCheckedThrowingContinuation{first=$0}}
        if failFirst && requests.count==1 {throw LocalDraftFailure.generationFailed}
        if cancelFirst && requests.count==1 {throw CancellationError()}
        return try DraftSurfaceValidator.validate(.init(answer:"温度はセンサーで測定します．",
            citationIDs:request.sources.map(\.id),cannotAnswer:false),request:request)
    }
    func finishOld() {
        first?.resume(throwing:LocalDraftFailure.generationFailed);first=nil
    }
}
@MainActor @Suite struct NextQuestionRecoveryTests {
    private func session(_ generator:RecoveryGenerator,timeout:Duration = .seconds(2)) throws ->LiveQASession {
        let deck=try Deck.validated(data:JSONSerialization.data(withJSONObject:["slides":[
            ["page":1,"title":"温度の測定","text":"温度はセンサーで測定します．","notes":""]]]))
        return LiveQASession(index:EvidenceIndex(deck:deck),generator:generator,reviewPolicy:.mockOnly,
            generationTimeout:timeout,generationDebounce:.zero)
    }
    private func until(_ condition:()->Bool) async ->Bool {
        for _ in 0..<300 {if condition(){return true};try? await Task.sleep(for:.milliseconds(10))}
        return condition()
    }
    private func question(_ session:LiveQASession,order:Int) {
        session.receive(.init(id:"turn-\(order)",order:order,text:"温度はどう測定しますか．",
            final:true,audioStart:Double(order)*4,audioEnd:Double(order)*4+2,sourceRevision:1))
    }
    @Test func realLegacyReducerSealsCancellationBeforeNextQuestion() async throws {
        let g=RecoveryGenerator(),s=try session(g)
        s.beginContinuousQuestions()
        var turns=LegacyRecognitionTurns()
        for number in 0..<8 {
            let qValue=turns.accept(id:"native",text:"温度はどう測定しますか．",final:true,
                start:Double(number)*5,end:Double(number)*5+1)
            let q=try #require(qValue)
            #expect(q.order==number*2)
            #expect(!q.text.contains("取消") && !q.text.contains("取り消"))
            s.receive(q)
            #expect(await until{s.cards.last?.draft != nil})
            let cancellationValue=turns.accept(id:"native",text:"今の質問を取り消します．",final:true,
                start:Double(number)*5+2,end:Double(number)*5+3)
            let cancellation=try #require(cancellationValue)
            #expect(cancellation.order==number*2+1)
            s.receive(cancellation)
            #expect(s.cards.last?.cancelled==true && s.acceptingInput && s.generationEnabled)
            #expect(s.lastInputDisposition=="cancellationDetected")
        }
        #expect(g.requests.count==8)
        s.stop()
    }
    @Test func legacyFragmentsAndPartialRevisionsPreserveIdentityButNewQuestionDoesNot() throws {
        var turns=LegacyRecognitionTurns()
        let fragmentValue=turns.accept(id:"native",text:"温度は",final:true,start:0,end:1)
        let fragment=try #require(fragmentValue)
        let partialValue=turns.accept(id:"native",text:"どう測定",final:false,start:2,end:3)
        let partial=try #require(partialValue)
        let completeValue=turns.accept(id:"native",text:"どう測定しますか．",final:true,start:2,end:4)
        let complete=try #require(completeValue)
        #expect(fragment.id==partial.id && partial.id==complete.id)
        #expect(complete.text=="温度は どう測定しますか．" && complete.sourceRevision==3)
        let followingValue=turns.accept(id:"native",text:"温度はどう測定しますか．",final:true,start:5,end:6)
        let following=try #require(followingValue)
        #expect(following.order==1 && following.id != complete.id && following.sourceRevision==1)
    }
    @Test func standaloneCancellationAfterAnUnfinishedFragmentCannotContaminateNextQuestion() throws {
        var turns=LegacyRecognitionTurns()
        _=turns.accept(id:"native",text:"温度について",final:true,start:0,end:1)
        let cancelledValue=turns.accept(id:"native",text:"今の質問を取り消します．",final:true,start:2,end:3)
        let cancelled=try #require(cancelledValue)
        #expect(cancelled.text=="今の質問を取り消します．")
        let nextValue=turns.accept(id:"native",text:"温度はどう測定しますか．",final:true,start:4,end:5)
        let next=try #require(nextValue)
        #expect(next.order==1 && next.text=="温度はどう測定しますか．")
    }
    @Test func hungFirstGenerationCannotBlockSecondAndLateReplyCannotOverwriteIt() async throws {
        let g=RecoveryGenerator();g.holdFirst=true
        let s=try session(g,timeout:.milliseconds(150))
        s.beginContinuousQuestions();question(s,order:0)
        #expect(await until{g.requests.count==1})
        question(s,order:1)
        #expect(await until{s.cards.last?.draft != nil})
        #expect(s.generationTimeouts==1 && s.generationFailures==1)
        #expect(s.cards.first?.status==LocalDraftFailure.deadlineExceeded.message)
        #expect(g.requests.count==2 && s.acceptingInput)
        g.finishOld()
        #expect(await until{s.discardedLateReplies>0})
        #expect(s.cards.first?.draft==nil && s.cards.last?.draft != nil)
        s.stop()
    }
    @Test func cancelWhileSDKIgnoresCancellationThenNextQuestionResponds() async throws {
        let g=RecoveryGenerator();g.holdFirst=true
        let s=try session(g);s.beginContinuousQuestions();question(s,order:0)
        #expect(await until{g.requests.count==1})
        s.cancel(id:try #require(s.cards.first?.id))
        question(s,order:1)
        #expect(await until{s.cards.last?.draft != nil})
        #expect(g.requests.count==2 && s.cards.first?.cancelled==true && s.acceptingInput)
        g.finishOld();#expect(await until{s.discardedLateReplies>0})
        #expect(s.cards.first?.draft==nil && s.cards.last?.draft != nil)
        s.stop()
    }
    @Test func modelFailureDoesNotRequireStartOrCancelBeforeFollowingQuestion() async throws {
        for cancellationError in [false,true] {
            let g=RecoveryGenerator();g.failFirst = !cancellationError;g.cancelFirst=cancellationError
            let s=try session(g);s.beginContinuousQuestions();question(s,order:0)
            #expect(await until{s.generationFailures==1})
            #expect(s.cards.first?.status==LocalDraftFailure.generationFailed.message)
            for order in 1...10 {
                question(s,order:order)
                #expect(await until{s.cards.last?.draft != nil && g.requests.count==order+1})
                #expect(s.acceptingInput && s.generationEnabled)
            }
            #expect(s.lastGenerationFailure=="generationFailed")
            s.stop()
        }
    }
    @Test func executionClockStartsAtDequeueWithoutChangingSourcesOrLease() throws {
        let g=RecoveryGenerator(),s=try session(g)
        s.beginContinuousQuestions();s.setGenerationEnabled(false);question(s,order:0)
        let card=try #require(s.cards.first),reference=try #require(card.reference)
        let queued=try LocalDraftRequest(ticket:card.ticket,reference:reference)
        let started=queued.startingExecution(now:queued.createdAt.advanced(by:.seconds(30)))
        #expect(started.createdAt==queued.createdAt.advanced(by:.seconds(30)))
        #expect(started.lease==queued.lease && started.question==queued.question)
        #expect(started.sources.map(\.id)==queued.sources.map(\.id))
        #expect(throws:LocalDraftFailure.deadlineExceeded){try LocalDraftDeadline.requireValid(createdAt:queued.createdAt,now:started.createdAt)}
        try LocalDraftDeadline.requireValid(createdAt:started.createdAt,now:started.createdAt)
        s.stop()
    }
    @Test func stoppedSessionCancelsWatchdogAndRejectsHungResult() async throws {
        let g=RecoveryGenerator();g.holdFirst=true
        let s=try session(g,timeout:.milliseconds(100))
        // Stop synchronously at request entry, before yielding the actor to the
        // watchdog; parallel import tests must not determine test ordering.
        g.onFirstRequest={s.stop()}
        s.beginContinuousQuestions();question(s,order:0)
        #expect(await until{g.requests.count==1 && !s.acceptingInput})
        try await Task.sleep(for:.milliseconds(150))
        #expect(s.generationTimeouts==0 && !s.acceptingInput)
        g.finishOld();#expect(await until{s.discardedLateReplies>0})
        #expect(s.cards.allSatisfy{$0.draft==nil})
    }
    @Test func modelJournalPersistsMetadataOnlyWithoutStartingAModel() throws {
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent("slideqa-model-meta-"+UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:directory)}
        let file=directory.appendingPathComponent("model.json")
        let diagnostic=LocalModelDiagnostic(stage:"writer-failed",category:"synthetic-failure",
            errorDomain:"synthetic.domain",errorCode:99,permissionFailureMentioned:false,
            connectionFailureMentioned:true,errorChain:[.init(domain:"synthetic.domain",code:99)])
        LocalModelJournal.record(diagnostic,at:file)
        let data=try Data(contentsOf:file)
        let record=try #require(JSONSerialization.jsonObject(with:data) as? [String:Any])
        #expect(Set(record.keys)==Set(["atUTC","appVersion","hostBundleID","executableName","osVersion","sandboxContainerVariablePresent","diagnostic"]))
        let details=try #require(record["diagnostic"] as? [String:Any])
        #expect(details["stage"] as? String=="writer-failed" && details["errorCode"] as? Int==99)
        #expect(Set(details.keys)==Set(["stage","category","errorDomain","errorCode",
            "permissionFailureMentioned","connectionFailureMentioned","errorChain"]))
    }

    @Test func nonCooperativeSDKCallsCannotAccumulateUnboundedModelSessions() throws {
        var slots=ModelInvocationSlots()
        let firstValue=slots.begin();let first=try #require(firstValue)
        let secondValue=slots.begin();let second=try #require(secondValue)
        let unavailable=slots.begin();#expect(unavailable==nil)
        slots.finish(first)
        let nextValue=slots.begin();let next=try #require(nextValue)
        // A late duplicate completion must not release a different invocation.
        slots.finish(first);let unavailableAgain=slots.begin();#expect(unavailableAgain==nil)
        slots.finish(second);slots.finish(next)
        for _ in 0..<100 {
            let valueValue=slots.begin();let value=try #require(valueValue);slots.finish(value)
        }
    }

    @Test func finalizedNaturalQuestionFormsReachGenerationWithoutModeSwitching() async throws {
        let g=RecoveryGenerator(),s=try session(g);s.beginContinuousQuestions()
        var turns=LegacyRecognitionTurns()
        let forms=["温度を教えて下さい．","温度はどう測定するか．","温度の測定方法？",
            "温度を教えて．","温度はどのように測定しますかね．","温度とは．",
            "温度は何でしょう．","温度の測定を説明してほしい．"]
        for (number,text) in forms.enumerated() {
            let value=turns.accept(id:"native",text:text,final:true,start:Double(number)*3,end:Double(number)*3+2)
            let update=try #require(value)
            #expect(update.order==number)
            s.receive(update)
            #expect(await until{s.cards.last?.draft != nil && g.requests.count==number+1})
            #expect(s.lastInputDisposition=="questionDetected")
        }
        #expect(s.acceptingInput && s.generationEnabled && g.requests.count==forms.count)
        s.stop()
    }
    @Test func questionMarkSurvivesNativeSplittingButDoesNotConfirmAVolatileSnapshot() throws {
        let g=RecoveryGenerator(),s=try session(g);s.beginContinuousQuestions()
        s.receive(.init(id:"q",order:0,text:"温度の測定方法？",final:false,audioStart:0,audioEnd:1,sourceRevision:1))
        #expect(s.cards.isEmpty && g.requests.isEmpty)
        s.receive(.init(id:"q",order:0,text:"温度の測定方法？",final:true,audioStart:0,audioEnd:1,sourceRevision:2))
        #expect(s.cards.count==1 && s.cards.first?.ticket.text.contains("？")==true)
        s.stop()
    }
    @Test func completedNarrationIsSeparatedFromFollowingQuestionWithoutBeingGenerated() async throws {
        let g=RecoveryGenerator(),s=try session(g);s.beginContinuousQuestions()
        var turns=LegacyRecognitionTurns()
        let narrationValue=turns.accept(id:"native",text:"温度はセンサーで測定します．",final:true,start:0,end:2)
        let narration=try #require(narrationValue);s.receive(narration)
        #expect(s.cards.isEmpty && g.requests.isEmpty && s.lastInputDisposition=="noQuestionDetected")
        let questionValue=turns.accept(id:"native",text:"温度の測定方法？",final:true,start:3,end:5)
        let question=try #require(questionValue)
        #expect(question.order==1 && !question.text.contains("センサー"))
        s.receive(question);#expect(await until{s.cards.first?.draft != nil})
        #expect(g.requests.count==1)
        s.stop()
    }
    @Test func questionInvitationsQuotesAndUnfinishedFragmentsDoNotStartModels() throws {
        let g=RecoveryGenerator(),s=try session(g);s.beginContinuousQuestions()
        for (number,text) in ["温度について","温度の測定はどのように","温度を教えても",
            "質問はありますか．","ご質問をどうぞ．","「温度の測定方法？」という言葉を引用しました．"].enumerated() {
            s.receive(.init(id:"excluded-\(number)",order:number,text:text,final:true,
                audioStart:Double(number)*3,audioEnd:Double(number)*3+2))
        }
        #expect(s.cards.isEmpty && g.requests.isEmpty)
        #expect(s.acceptingInput)
        s.stop()
    }
    @Test(.enabled(if:ProcessInfo.processInfo.environment["SLIDEQA_LOCAL_MODEL_TEST"] == "1"))
    func optInInstalledModelSyntheticQuestionWithoutMicrophone() async throws {
        let started=ContinuousClock.now
        var stages:[LocalModelDiagnostic]=[]
        let generator=OnDeviceDraftGenerator(displayPolicy:.unverifiedPrototype,diagnostics:{stages.append($0)})
        let deck=try Deck.validated(data:JSONSerialization.data(withJSONObject:["slides":[
            ["page":1,"title":"温度の測定","text":"温度はセンサーで測定します．","notes":""]]]))
        let s=LiveQASession(index:EvidenceIndex(deck:deck),generator:generator,reviewPolicy:.allowUnverifiedPrototype)
        s.beginContinuousQuestions()
        s.receive(.init(id:"synthetic-model-check",order:0,text:"温度の測定方法？",final:true,
            audioStart:0,audioEnd:1,sourceRevision:1))
        for _ in 0..<800 {
            if s.cards.first?.draft != nil || s.generationFailures>0 ||
                (s.generationRequests==0 && s.diagnosticCounts["queued"]==0 && s.diagnosticCounts["generating"]==0) {break}
            try await Task.sleep(for:.milliseconds(25))
        }
        let draft=s.cards.first?.draft
        let passed=draft != nil && draft?.abstained==false
        let duration=started.duration(to:.now).components
        let model=SystemLanguageModel.default
        let stageData=try JSONEncoder().encode(stages)
        let record:[String:Any]=["kind":"real-installed-on-device-model-check","syntheticSourceOnly":true,
            "microphoneStarted":false,"permissionsRequested":false,"modelAvailable":model.isAvailable,
            "japaneseSupported":model.supportsLocale(Locale(identifier:"ja-JP")),
            "generationRequests":s.generationRequests,"questionCount":s.cards.count,
            "generatedDraftShown":draft != nil,"abstained":draft?.abstained ?? false,
            "answerFromModel":draft?.text ?? "","sourceIDs":draft?.citations.map(\.id) ?? [],
            "reviewState":draft?.reviewState.rawValue ?? "none","lastGenerationFailure":s.lastGenerationFailure,
            "cardStatus":s.cards.first?.status ?? "none","lastInputDisposition":s.lastInputDisposition,
            "elapsedSeconds":Double(duration.seconds)+Double(duration.attoseconds)/1e18,
            "stages":try JSONSerialization.jsonObject(with:stageData),"passed":passed]
        s.stop()
        // Test hosts can prohibit arbitrary result-file writes. Report through
        // the ordinary test output; never retry a refused file operation.
        let data=try JSONSerialization.data(withJSONObject:record,options:[.sortedKeys])
        print("SLIDEQA_LOCAL_MODEL_RESULT="+String(decoding:data,as:UTF8.self))
        #expect(passed,"Actual installed model produced no displayable non-abstaining draft; see local metadata result.")
    }

    @Test(.enabled(if:ProcessInfo.processInfo.environment["SLIDEQA_CONTEXT_PROBE"] == "1"))
    func optInPlainInstalledModelContextProbeWithoutMicrophone() async throws {
        let model=SystemLanguageModel.default
        let start=ContinuousClock.now
        var ended=false
        var answer=""
        var diagnostic:[String:Any]=[:]
        let task=Task {@MainActor in
            do {
                guard model.isAvailable,model.supportsLocale(Locale(identifier:"ja-JP")) else {
                    diagnostic=["category":"modelUnavailableBeforeRequest"];ended=true;return
                }
                let session=LanguageModelSession(model:model,tools:[],instructions:"提示された合成資料だけを使い，日本語で一文で答えてください．")
                let response=try await session.respond(to:"合成資料：温度はセンサーで測定します．質問：温度は何で測定しますか．",
                    options:GenerationOptions(temperature:0,maximumResponseTokens:80))
                answer=response.content;ended=true
            } catch {
                let native=error as NSError
                let home=FileManager.default.homeDirectoryForCurrentUser.path
                // This opt-in probe uses a constant synthetic prompt only.
                // No production error observer or private question is attached.
                func redact(_ value:String)->String {value.replacingOccurrences(of:home,with:"<HOME>")}
                diagnostic=["swiftType":String(reflecting:type(of:error)),"domain":native.domain,"code":native.code,
                    "reflected":redact(String(reflecting:error)),"localizedDescription":redact(native.localizedDescription),
                    "userInfoKeys":native.userInfo.keys.sorted(),"userInfoDescription":redact(String(describing:native.userInfo))]
                if let local=error as? LocalizedError {
                    diagnostic["failureReason"]=redact(local.failureReason ?? "")
                    diagnostic["recoverySuggestion"]=redact(local.recoverySuggestion ?? "")
                }
                ended=true
            }
        }
        for _ in 0..<520 {
            if ended {break}
            try await Task.sleep(for:.milliseconds(25))
        }
        if !ended {task.cancel()}
        let elapsed=start.duration(to:.now).components
        let context:[String:Any]=["kind":"raw-string-installed-model-context-probe","syntheticSourceOnly":true,
            "modelAvailable":model.isAvailable,"japaneseSupported":model.supportsLocale(Locale(identifier:"ja-JP")),
            "bundleID":Bundle.main.bundleIdentifier ?? "none","bundleName":Bundle.main.bundleURL.lastPathComponent,
            "executableName":Bundle.main.executableURL?.lastPathComponent ?? "none",
            "processName":ProcessInfo.processInfo.processName,
            "sandboxContainerVariablePresent":ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil,
            "osVersion":ProcessInfo.processInfo.operatingSystemVersionString,
            "timedOut":!ended,"answerFromModel":answer,"error":diagnostic,
            "elapsedSeconds":Double(elapsed.seconds)+Double(elapsed.attoseconds)/1e18,
            "microphoneStarted":false,"permissionsRequested":false,"resultFileWritten":false]
        let data=try JSONSerialization.data(withJSONObject:context,options:[.sortedKeys])
        print("SLIDEQA_CONTEXT_PROBE="+String(decoding:data,as:UTF8.self))
        #expect(ended && !answer.isEmpty,"The raw model probe failed or timed out; see stdout diagnostic.")
    }

    @Test func modelErrorsFollowMultipleUnderlyingErrorsWithoutCopyingPrivateText() {
        let service=NSError(domain:"ModelManagerServices.ModelManagerError",code:1008,
            userInfo:[NSLocalizedDescriptionKey:"private source passage must not be stored"])
        let nested=NSError(domain:"FoundationModels.LanguageModelSession.GenerationError",code:-1,
            userInfo:[NSMultipleUnderlyingErrorsKey:[service]])
        let root=NSError(domain:"FoundationModels.LanguageModelSession.GenerationError",code:-1,
            userInfo:[NSMultipleUnderlyingErrorsKey:[nested]])
        let links=LocalModelErrorMetadata.links(root)
        #expect(links.map(\.code)==[-1,-1,1008])
        #expect(links.last?.domain=="ModelManagerServices.ModelManagerError")
        #expect(LocalModelErrorMetadata.failure(root,fallback:.generationFailed) == .modelServiceFailed)
        #expect(LocalModelErrorMetadata.failure(root,fallback:.groundingReviewFailed) == .modelServiceFailed)
        #expect(!String(describing:links).contains("private source passage"))
    }
    @Test func underlyingErrorTraversalIsBoundedAndUnrelatedErrorsKeepTheirFailureCategory() {
        let other=NSError(domain:"synthetic.other",code:22)
        let child=NSError(domain:"synthetic.child",code:44,userInfo:[NSUnderlyingErrorKey:other])
        let root=NSError(domain:"synthetic.root",code:11,userInfo:[NSMultipleUnderlyingErrorsKey:Array(repeating:child,count:100)])
        let links=LocalModelErrorMetadata.links(root)
        #expect(links.count==3 && links.last?.domain=="synthetic.other")
        #expect(LocalModelErrorMetadata.failure(root,fallback:.groundingReviewFailed) == .groundingReviewFailed)
        #expect(!LocalModelErrorMetadata.hasModelManagerFailure(root))
    }

}
