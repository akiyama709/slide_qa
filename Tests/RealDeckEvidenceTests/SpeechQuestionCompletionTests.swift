import Foundation
import Testing
import SlideQACore
@testable import RealDeckEvidenceCore
@testable import NativeLocalIO

@MainActor private final class DefinitionGenerator:LocalDraftGenerating {
    var requests=0
    func generate(_ request:LocalDraftRequest) async throws ->GuardedLocalDraft {
        requests+=1
        let draft=try DraftSurfaceValidator.validate(.init(answer:request.sources[0].text,
            citationIDs:[request.sources[0].id],cannotAnswer:false),request:request)
        return draft
    }
}
@MainActor private final class DefinitionFlow {
    let generator=DefinitionGenerator()
    let session:LiveQASession
    var turns=LegacyRecognitionTurns()
    var completion:SpeechQuestionCompletion!
    var provisional:[LiveRecognitionUpdate]=[]
    init(topic:String="温度計",textGrace:Duration = .milliseconds(40)) throws {
        let deck=try Deck.validated(data:JSONSerialization.data(withJSONObject:["slides":[
            ["page":1,"title":topic+"の定義","text":topic+"とは合成試験用の用語です．","notes":""]]]))
        session=LiveQASession(index:EvidenceIndex(deck:deck),generator:generator,reviewPolicy:.mockOnly,generationDebounce:.zero)
        session.beginContinuousQuestions()
        completion=SpeechQuestionCompletion(grace:.milliseconds(20),textGrace:textGrace) {[weak self] update in
            guard let self,let value=self.turns.confirmStableQuestion(update) else {return}
            self.provisional.append(value);self.session.receive(value)
        }
    }
    @discardableResult func receive(_ text:String,final:Bool=false,end:Double=2)->LiveRecognitionUpdate {
        let update=turns.accept(id:"native",text:text,final:final,start:0,end:end)!
        completion.receive(update);session.receive(update);return update
    }
    func stop() {completion.stop();session.stop()}
}
@MainActor @Suite struct SpeechQuestionCompletionTests {
    private func until(_ condition:()->Bool) async ->Bool {
        for _ in 0..<800 {if condition(){return true};try? await Task.sleep(for:.milliseconds(10))}
        return condition()
    }
    @Test func wordDefinitionRequestsAreNotBlanketExcludedAsQuotation() async throws {
        for text in ["ありがとうございましたの質問ですけども、温度計という言葉の定義をもう一度お願いします",
                     "温度計という表現の意味を説明してください","「温度計」という言葉の定義を教えてください"] {
            let f=try DefinitionFlow();f.receive(text,final:true)
            #expect(await until{f.session.cards.last?.draft != nil})
            #expect(f.generator.requests==1 && f.session.cards.last?.ticket.page==1)
            f.stop()
        }
    }
    @Test func stableCompletePartialReleasesWithoutSDKFinalOrAcousticEndpoint() async throws {
        let f=try DefinitionFlow()
        f.receive("温度計という言葉の定義をもう一度お願いします")
        #expect(f.session.cards.first?.ticket.confirmed==false)
        #expect(await until{f.session.cards.first?.draft != nil})
        #expect(f.provisional.count==1 && f.session.cards.first?.stableCompletion==true)
        let revision=try #require(f.provisional.last?.sourceRevision)
        let sdkFinal=f.receive("温度計という言葉の定義をもう一度お願いします",final:true)
        #expect(try #require(sdkFinal.sourceRevision)>revision)
        try await Task.sleep(for:.milliseconds(80))
        #expect(f.generator.requests==1 && f.session.cards.first?.stableCompletion==false)
        f.stop()
    }
    @Test func identicalPartialPacketsDoNotStarveStableCompletionOrDuplicateIt() async throws {
        let f=try DefinitionFlow(textGrace:.milliseconds(60))
        for tick in 0..<20 {
            f.receive("温度計の定義を説明してください",end:2+Double(tick)*0.04)
            try await Task.sleep(for:.milliseconds(10))
        }
        #expect(await until{f.session.cards.first?.draft != nil})
        #expect(f.generator.requests==1 && f.provisional.count==1)
        f.stop()
    }
    @Test func endpointDoesNotFinalizeAnIncompleteFragmentAndStopCancelsPendingCompletion() async throws {
        let f=try DefinitionFlow()
        f.receive("温度計の定義について")
        f.completion.endpoint(2)
        try await Task.sleep(for:.milliseconds(100))
        #expect(f.provisional.isEmpty && f.generator.requests==0)
        f.receive("温度計の定義を説明してください")
        f.stop()
        try await Task.sleep(for:.milliseconds(100))
        #expect(f.provisional.isEmpty && f.generator.requests==0)
    }
    @Test func revisionAfterProvisionalAtSameAudioEndRetractsOldDraftAndRegenerates() async throws {
        let f=try DefinitionFlow()
        f.receive("温度計の定義を説明してください")
        #expect(await until{f.session.cards.first?.draft != nil})
        let old=try #require(f.session.cards.first),lease=old.ticket.lease
        f.receive("温度計という言葉の意味を教えてください")
        #expect(old.draft==nil)
        #expect(await until{f.session.cards.last?.draft != nil && f.generator.requests==2})
        #expect(f.session.cards.last?.ticket.lease != lease && f.session.lastInputDisposition != "invalidRecognitionUpdate")
        f.stop()
    }
    @Test func cumulativeCancellationThenFollowingQuestionHasNewIdentityEvenIfPrefixDisappears() async throws {
        let f=try DefinitionFlow()
        let first="温度計の定義を説明してください．"
        f.receive(first)
        #expect(await until{f.session.cards.first?.draft != nil})
        let originalID=try #require(f.session.cards.first?.id)
        f.session.cancel(id:originalID)
        f.receive(first+"今の質問を取り消します．温度計という言葉の意味を教えてください")
        #expect(await until{f.session.cards.last?.draft != nil && f.generator.requests==2})
        let followingID=try #require(f.session.cards.last?.id)
        #expect(followingID != originalID)
        f.receive("今の質問を取り消します．温度計という言葉の意味を教えてください")
        #expect(await until{f.session.cards.last?.draft != nil})
        #expect(f.session.cards.last?.id==followingID && f.generator.requests==2)
        f.stop()
    }
    @Test func quotedQuestionReportStillDoesNotCreateAQuestionOrGeneration() async throws {
        let f=try DefinitionFlow()
        f.receive("「温度計の定義を説明してください」という言葉を引用しました．",final:true)
        try await Task.sleep(for:.milliseconds(100))
        #expect(f.session.cards.isEmpty && f.generator.requests==0)
        f.stop()
    }
    @Test func twentyCumulativeStableQuestionsNeedNoSDKFinalOrPerQuestionOwnerAction() async throws {
        let f=try DefinitionFlow()
        var text=""
        for number in 1...20 {
            text+="温度計という言葉の定義をお願いします．"
            f.receive(text,end:Double(number)*2)
            #expect(await until{f.generator.requests==number && f.session.cards.last?.draft != nil})
        }
        #expect(f.session.acceptingInput && f.generator.requests==20)
        f.receive(text,final:true,end:40)
        #expect(f.generator.requests==20)
        f.stop()
    }
    @Test(.enabled(if:ProcessInfo.processInfo.environment["SLIDEQA_OWNER_REPLAY"] == "1"))
    func optInOwnerWordingReplayUsesOnlySyntheticDefinitionAndMockGenerator() async throws {
        let text=try #require(ProcessInfo.processInfo.environment["SLIDEQA_REPLAY_QUESTION"])
        let topic=try #require(ProcessInfo.processInfo.environment["SLIDEQA_REPLAY_TOPIC"])
        let f=try DefinitionFlow(topic:topic)
        f.receive(text)
        #expect(await until{f.session.cards.last?.draft != nil})
        #expect(f.generator.requests==1 && f.session.cards.last?.stableCompletion==true)
        print("SLIDEQA_OWNER_REPLAY: question admitted, stable provisional completion, one mock request, one mock draft; real model and microphone not used")
        f.stop()
    }
}
