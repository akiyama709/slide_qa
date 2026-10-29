import Foundation
import Testing
import SlideQACore
@testable import RealDeckEvidenceCore
import NativeLocalIO
@testable import RealDeckEvidenceApp

@MainActor private final class CaptureFake:LiveAudioDriving {
    var recognizerName="mock-only"
    var prompts:[Bool]=[]
    var updates:[@MainActor @Sendable (LiveRecognitionUpdate)->Void]=[]
    var failures:[@MainActor @Sendable (String)->Void]=[]
    var permissionDenied=false
    var transientStartFailures=0
    func startMicrophone(authorizedLaunch:Bool,ownerConsent:Bool,allowPermissionPrompt:Bool,
        onUpdate:@escaping @MainActor @Sendable (LiveRecognitionUpdate)->Void,
        onEndpoint:@escaping @MainActor @Sendable (Double)->Void,
        onFailure:@escaping @MainActor @Sendable (String)->Void) async throws {
        prompts.append(allowPermissionPrompt)
        if permissionDenied {throw AudioFailure.microphoneDenied}
        if transientStartFailures>0 {transientStartFailures-=1;throw AudioFailure.recognitionInterrupted}
        updates.append(onUpdate);failures.append(onFailure)
    }
    func stop() async {}
    func question(_ stream:Int,_ text:String,order:Int=0) {
        updates[stream](.init(id:"native-\(order)",order:order,text:text,final:true,audioStart:0,audioEnd:2,sourceRevision:1))
    }
}
@MainActor private final class CaptureGenerator:LocalDraftGenerating {
    var requests=0
    var generationDelay:Duration = .zero
    func generate(_ request:LocalDraftRequest) async throws ->GuardedLocalDraft {
        requests+=1
        try await Task.sleep(for:generationDelay)
        return try DraftSurfaceValidator.validate(.init(answer:"温度はセンサーで測定します．",
            citationIDs:request.sources.map(\.id),cannotAnswer:false),request:request)
    }
}
@MainActor @Suite struct ContinuousCaptureTests {
    private func session(_ generator:CaptureGenerator,generationDebounce:Duration = .milliseconds(400)) throws ->LiveQASession {
        let object:[String:Any]=["slides":[["page":1,"title":"温度の測定","text":"温度はセンサーで測定します．","notes":""]]]
        let deck=try Deck.validated(data:JSONSerialization.data(withJSONObject:object))
        return LiveQASession(index:EvidenceIndex(deck:deck),generator:generator,reviewPolicy:.mockOnly,
            generationDebounce:generationDebounce)
    }
    private func until(_ condition:()->Bool) async ->Bool {
        for _ in 0..<300 {if condition(){return true};try? await Task.sleep(for:.milliseconds(10))}
        return condition()
    }
    @Test func eightyAnsweredQuestionsCrossHistoryRetentionAndReconnectWithoutAnotherStart() async throws {
        let d=CaptureFake(),g=CaptureGenerator(),s=try session(g,generationDebounce:.zero)
        let c=LiveAudioController(audio:d,enabledForThisLaunch:true,retryUnit:.milliseconds(1))
        c.startByOwner(session:s)
        #expect(await until{d.updates.count==1 && c.running})
        var capture=0,order=0
        for number in 1...80 {
            d.question(capture,"温度はどう測定しますか．",order:order);order+=1
            #expect(await until{g.requests==number && s.cards.last?.draft != nil})
            #expect(s.cards.last?.ticket.turnOrder==number-1)
            #expect(s.cards.count<=64 && s.acceptingInput && c.continuousIntent)
            if number==20 {
                s.cancel(id:try #require(s.cards.last?.id))
                #expect(s.cards.last?.cancelled==true && s.cards.last?.draft==nil)
            }
            if number==40 {
                d.failures[0]("synthetic interruption after forty answers")
                #expect(await until{d.updates.count==2 && c.running})
                capture=1;order=0
                let before=s.transcript
                d.question(0,"古い認識結果ですか．",order:999)
                #expect(s.transcript==before)
            }
        }
        #expect(s.cards.count==64 && g.requests==80 && d.prompts==[true,false])
        #expect(s.cards.last?.reference?.candidates.first?.page==1)
        #expect(s.cards.last?.draft?.citations.allSatisfy{$0.page==1}==true)
        c.stop(session:s);#expect(await until{!c.stopping})
        let count=g.requests
        d.question(1,"温度はどう測定しますか．",order:40)
        #expect(g.requests==count && !s.acceptingInput && !c.continuousIntent)
    }
    @Test func oneStartRecoversWithoutPromptsAndPreservesAnswersAndSourceOrder() async throws {
        let driver=CaptureFake(),generator=CaptureGenerator(),s=try session(generator)
        let c=LiveAudioController(audio:driver,enabledForThisLaunch:true,retryUnit:.milliseconds(10))
        c.startByOwner(session:s)
        #expect(await until{driver.updates.count==1})
        driver.question(0,"温度はどう測定しますか．")
        #expect(await until{s.cards.first?.draft != nil})
        driver.failures[0]("simulated transient failure")
        #expect(c.continuousIntent && c.starting && !c.running)
        #expect(s.acceptingInput && s.cards.first?.draft != nil)
        #expect(await until{driver.updates.count==2 && c.running})
        #expect(driver.prompts==[true,false])
        let before=s.transcript
        driver.question(0,"古い認識結果ですか．",order:7)
        #expect(s.transcript==before)
        driver.question(1,"温度はどう測定しますか．")
        #expect(await until{generator.requests==2 && s.cards.filter{$0.draft != nil}.count==2})
        c.stop(session:s)
        #expect(await until{!c.stopping})
    }
    @Test func explicitStopCancelsPendingRecoveryAndLateCallbacks() async throws {
        let d=CaptureFake(),g=CaptureGenerator(),s=try session(g)
        let c=LiveAudioController(audio:d,enabledForThisLaunch:true,retryUnit:.milliseconds(80))
        c.startByOwner(session:s);#expect(await until{d.updates.count==1})
        d.failures[0]("transient");c.stop(session:s)
        try await Task.sleep(for:.milliseconds(150))
        #expect(d.prompts.count==1 && !c.continuousIntent && !s.acceptingInput)
        d.question(0,"温度はどう測定しますか．")
        #expect(s.transcript.isEmpty)
    }
    @Test func permissionDenialIsTerminalAndDoesNotReprompt() async throws {
        let d=CaptureFake();d.permissionDenied=true
        let g=CaptureGenerator(),s=try session(g)
        let c=LiveAudioController(audio:d,enabledForThisLaunch:true,retryUnit:.milliseconds(10))
        c.startByOwner(session:s)
        #expect(await until{!c.continuousIntent && !c.stopping})
        #expect(d.prompts==[true])
    }
    @Test func malformedRecognitionUpdateDoesNotStopFollowingQuestions() async throws {
        let g=CaptureGenerator(),s=try session(g);s.beginContinuousQuestions()
        s.receive(.init(id:"bad",order:-1,text:"bad",final:true,audioStart:0,audioEnd:0))
        #expect(s.acceptingInput)
        s.receive(.init(id:"good",order:0,text:"温度はどう測定しますか．",final:true,audioStart:1,audioEnd:2))
        #expect(await until{s.cards.first?.draft != nil})
        s.stop()
    }
    @Test func initialTemporaryFailuresRecoverWithoutAnotherOwnerStart() async throws {
        let d=CaptureFake();d.transientStartFailures=2
        let g=CaptureGenerator(),s=try session(g)
        let c=LiveAudioController(audio:d,enabledForThisLaunch:true,retryUnit:.milliseconds(10))
        c.startByOwner(session:s)
        #expect(await until{d.updates.count==1 && c.running})
        #expect(d.prompts==[true,false,false] && c.continuousIntent && s.acceptingInput)
        d.question(0,"温度はどう測定しますか．")
        #expect(await until{s.cards.first?.draft != nil})
        c.stop(session:s);#expect(await until{!c.stopping})
    }
    @Test func recognitionFailureDuringGenerationDoesNotCancelItsAnswer() async throws {
        let d=CaptureFake(),g=CaptureGenerator();g.generationDelay = .milliseconds(200)
        let s=try session(g)
        let c=LiveAudioController(audio:d,enabledForThisLaunch:true,retryUnit:.milliseconds(10))
        c.startByOwner(session:s);#expect(await until{d.updates.count==1})
        d.question(0,"温度はどう測定しますか．")
        #expect(await until{g.requests==1})
        d.failures[0]("synthetic-service / 99")
        #expect(await until{d.updates.count==2 && s.cards.first?.draft != nil})
        #expect(g.requests==1 && s.acceptingInput)
        c.stop(session:s);#expect(await until{!c.stopping})
    }
    @Test func technicalJournalDoesNotStoreRecognizedOrGeneratedText() async throws {
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent("slideqa-state-"+UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:directory)}
        let file=directory.appendingPathComponent("state.json")
        let d=CaptureFake(),g=CaptureGenerator(),s=try session(g)
        let c=LiveAudioController(audio:d,enabledForThisLaunch:true,retryUnit:.milliseconds(10),journalURL:file)
        c.startByOwner(session:s);#expect(await until{d.updates.count==1})
        d.question(0,"温度はどう測定しますか．")
        #expect(await until{s.cards.first?.draft != nil})
        d.failures[0]("synthetic-service / 99")
        #expect(await until{d.updates.count==2 && c.running})
        let data=try Data(contentsOf:file)
        let record=try #require(JSONSerialization.jsonObject(with:data) as? [String:Any])
        #expect(record["transcriptStored"] as? Bool == false)
        #expect(record["audioStored"] as? Bool == false)
        #expect(record["generationRequests"] as? Int == 1)
        #expect(record["answerCount"] as? Int == 1)
        let text=String(decoding:data,as:UTF8.self)
        #expect(!text.contains("温度") && !text.contains("センサー"))
        c.stop(session:s);#expect(await until{!c.stopping})
    }
    @Test func twelveQuestionsAndRepeatedReconnectsContinueUntilOwnerStop() async throws {
        let d=CaptureFake(),g=CaptureGenerator(),s=try session(g)
        let c=LiveAudioController(audio:d,enabledForThisLaunch:true,retryUnit:.milliseconds(1))
        c.startByOwner(session:s);#expect(await until{d.updates.count==1})
        var capture=0,order=0
        for number in 1...12 {
            d.question(capture,"温度はどう測定しますか．",order:order);order+=1
            #expect(await until{g.requests==number && s.cards.filter{$0.draft != nil}.count==number})
            if number%3==0 {
                d.failures[capture]("synthetic interruption")
                capture+=1;order=0
                #expect(await until{d.updates.count==capture+1 && c.running})
            }
            #expect(c.continuousIntent && s.acceptingInput)
        }
        #expect(d.prompts.filter{$0}.count==1 && g.requests==12)
        c.stop(session:s);#expect(await until{!c.stopping})
        #expect(!c.continuousIntent)
    }
    @Test func twelveConsecutiveTransientFailuresHaveNoRetryCountStop() async throws {
        let d=CaptureFake(),g=CaptureGenerator(),s=try session(g)
        let c=LiveAudioController(audio:d,enabledForThisLaunch:true,retryUnit:.milliseconds(1))
        c.startByOwner(session:s);#expect(await until{d.updates.count==1})
        for capture in 0..<12 {
            d.failures[capture]("synthetic service interruption")
            #expect(await until{d.updates.count==capture+2 && c.running})
            #expect(c.continuousIntent && s.acceptingInput)
        }
        d.question(12,"温度はどう測定しますか．")
        #expect(await until{s.cards.first?.draft != nil})
        #expect(d.prompts.count==13 && d.prompts.dropFirst().allSatisfy{!$0})
        c.stop(session:s);#expect(await until{!c.stopping})
    }
    @Test func oneHundredUnfinishedRecognitionTurnsDoNotBlockANewQuestion() async throws {
        let g=CaptureGenerator(),s=try session(g)
        s.beginInput(phase:.qna)
        for order in 0..<100 {
            s.receive(.init(id:"partial-\(order)",order:order,text:"温度について",
                final:false,audioStart:Double(order),audioEnd:Double(order)+0.5))
            #expect(s.acceptingInput)
        }
        s.setGenerationEnabled(true)
        s.receive(.init(id:"complete",order:100,text:"温度はどう測定しますか．",
            final:true,audioStart:101,audioEnd:102))
        #expect(await until{s.cards.last?.draft != nil})
        #expect(s.acceptingInput && s.cards.count<=64)
        s.stop()
    }
    @Test func completeInterruptedQuestionMayProceedButIsClearlyProvisional() async throws {
        let d=CaptureFake(),g=CaptureGenerator(),s=try session(g)
        let c=LiveAudioController(audio:d,enabledForThisLaunch:true,retryUnit:.milliseconds(1))
        c.startByOwner(session:s);#expect(await until{d.updates.count==1})
        let partial=LiveRecognitionUpdate(id:"partial",order:0,text:"温度はどう測定しますか．",
            final:false,audioStart:0,audioEnd:2,sourceRevision:1)
        d.updates[0](partial)
        #expect(s.cards.first?.draft==nil)
        let provisional=try #require(InterruptedQuestionCompletion.provisional(partial))
        d.updates[0](provisional);d.failures[0]("synthetic interruption")
        #expect(await until{s.cards.first?.draft != nil})
        #expect(s.cards.first?.provisionalSpeech==true && s.acceptingInput)
        #expect(InterruptedQuestionCompletion.provisional(.init(id:"fragment",order:1,text:"温度について",
            final:false,audioStart:3,audioEnd:4,sourceRevision:1))==nil)
        c.stop(session:s);#expect(await until{!c.stopping})
    }
    @Test func journalDistinguishesOwnerStopAndPreservesPreStopReasons() async throws {
        let folder=FileManager.default.temporaryDirectory.appendingPathComponent("slideqa-stop-"+UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:folder)}
        let file=folder.appendingPathComponent("state.json")
        let d=CaptureFake(),g=CaptureGenerator(),s=try session(g)
        let c=LiveAudioController(audio:d,enabledForThisLaunch:true,retryUnit:.milliseconds(1),journalURL:file)
        c.startByOwner(session:s);#expect(await until{d.updates.count==1})
        d.question(0,"火星の基地はいつできますか．")
        c.stop(session:s,origin:.ownerButton)
        #expect(await until{!c.stopping})
        let value=try #require(JSONSerialization.jsonObject(with:Data(contentsOf:file)) as? [String:Any])
        #expect(value["stopOrigin"] as? String=="ownerButton")
        let diagnostic=try #require(value["questionDiagnostics"] as? [String:Int])
        #expect(diagnostic["insufficientSources"]==1)
        #expect(!String(decoding:try Data(contentsOf:file),as:UTF8.self).contains("火星"))
    }
    @Test func ambiguousSourcesAreOptInAndNeverBypassReviewOrSensitiveQuestionGuards() async throws {
        let object:[String:Any]=["slides":[
            ["page":1,"title":"温度の測定 A","text":"温度はセンサーで測定します．","notes":""],
            ["page":2,"title":"温度の測定 B","text":"温度はセンサーで測定します．","notes":""],
            ["page":3,"title":"図書","text":"図書は書架に保管します．","notes":""],
            ["page":4,"title":"照明","text":"照明はランプを使います．","notes":""],
            ["page":5,"title":"運搬","text":"運搬には台車を使います．","notes":""],
            ["page":6,"title":"植栽","text":"植栽には用土を使います．","notes":""]]]
        let index=EvidenceIndex(deck:try Deck.validated(data:JSONSerialization.data(withJSONObject:object)))
        let question="温度はどう測定しますか．",reference=index.search("温度はどう測定しますか．")
        #expect(reference.disposition == .ambiguous)
        let ticket=QuestionTicket(lease:.init(epoch:0,id:"ambiguous",revision:1),turnID:"native",turnOrder:0,
            position:0,text:question,page:0,title:"該当なし",confirmed:true)
        #expect(throws:LocalDraftFailure.insufficientSources){try LocalDraftRequest(ticket:ticket,reference:reference)}
        let request=try LocalDraftRequest(ticket:ticket,reference:reference,allowAmbiguousSources:true)
        #expect(Set(request.sources.map(\.page))==Set([1,2]))
        #expect(request.sources.allSatisfy{source in index.passages.contains{$0.id==source.id && $0.text==source.text}})
        var sensitive=ticket
        sensitive=QuestionTicket(lease:sensitive.lease,turnID:"native",turnOrder:0,position:0,
            text:"温度のAPIキーを教えてください．",page:0,title:"該当なし",confirmed:true)
        #expect(throws:LocalDraftFailure.insufficientSources){try LocalDraftRequest(ticket:sensitive,reference:reference,allowAmbiguousSources:true)}
        let generator=CaptureGenerator()
        let s=LiveQASession(index:index,generator:generator,reviewPolicy:.allowUnverifiedPrototype)
        s.beginContinuousQuestions()
        s.receive(.init(id:"question",order:0,text:question,final:true,audioStart:0,audioEnd:2))
        #expect(await until{generator.requests==1})
        #expect(await until{s.cards.first?.status==LocalDraftFailure.groundingReviewFailed.message})
        #expect(s.cards.first?.draft==nil && s.cards.first?.sourceSelectionAmbiguous==true)
        s.stop()
    }

    @Test func journalRefreshesAfterGenerationWithoutAnyFollowingSpeechEvent() async throws {
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent("slideqa-periodic-"+UUID().uuidString)
        defer {try? FileManager.default.removeItem(at:directory)}
        let file=directory.appendingPathComponent("state.json")
        let d=CaptureFake(),g=CaptureGenerator(),s=try session(g)
        let c=LiveAudioController(audio:d,enabledForThisLaunch:true,journalURL:file)
        c.startByOwner(session:s);#expect(await until{d.updates.count==1})
        d.question(0,"温度はどう測定しますか．")
        #expect(await until{s.cards.first?.draft != nil})
        #expect(await until{
            guard let data=try? Data(contentsOf:file),
                  let value=(try? JSONSerialization.jsonObject(with:data)) as? [String:Any] else {return false}
            return value["answerCount"] as? Int==1
        })
        let value=try #require(JSONSerialization.jsonObject(with:Data(contentsOf:file)) as? [String:Any])
        #expect(value["recognitionUpdates"] as? Int==1 && value["finalRecognitionUpdates"] as? Int==1)
        #expect(value["nativeFinalRecognitionUpdates"] as? Int==1 && value["provisionalRecognitionUpdates"] as? Int==0)
        #expect(value["questionPhase"] as? String=="qna" && value["lastGenerationFailure"] as? String=="none")
        #expect(value["acceptingInput"] as? Bool==true && value["generationEnabled"] as? Bool==true)
        c.stop(session:s);#expect(await until{!c.stopping})
    }

}
