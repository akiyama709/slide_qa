import Foundation
import Testing
import SlideQACore
@testable import RealDeckEvidenceCore

private func liveFixture(choice:Bool=false) throws -> EvidenceIndex {
    let first=choice ? "給水は自動で行います．手動の扱いも記録します．":"温度はセンサーで測定します．"
    let firstTitle=choice ? "給水の方式":"温度の測定"
    let firstNotes=choice ? "自動と手動の扱いを確認します．":"温度の測定は計画段階です．精度は未検証です．"
    let object:[String:Any] = ["sourceFile":"unit-only.pdf","sourceSHA256":"unit","pageCount":2,
        "printedNumbersVerified":true,"slides":[
            ["page":1,"title":firstTitle,"text":first,"notes":firstNotes],
            ["page":2,"title":"振動の測定","text":"振動を専用のセンサーで測定します．","notes":""]],
        "routes":[["page":1,"cues":[["pattern":choice ? "給水|自動|手動":"温度","weight":8]]],
                  ["page":2,"cues":[["pattern":"振動","weight":8]]]]]
    return EvidenceIndex(deck:try JSONDecoder().decode(Deck.self,from:JSONSerialization.data(withJSONObject:object)))
}

@MainActor private final class HeldLocalGenerator:LocalDraftGenerating {
    private struct Held {let draft:GuardedLocalDraft;let continuation:CheckedContinuation<GuardedLocalDraft,Never>}
    private var held:[Held]=[]
    private let unverified:Bool
    init(unverified:Bool=false) {self.unverified=unverified}
    private(set) var requests:[LocalDraftRequest]=[]
    func generate(_ request:LocalDraftRequest) async throws -> GuardedLocalDraft {
        requests.append(request)
        let proposal=LocalDraftProposal(answer:"資料に記載された計画と条件に沿って説明する案です．未検証の点は確認が必要です．",
            citationIDs:request.sources.map(\.id),cannotAnswer:false)
        let surface=try DraftSurfaceValidator.validate(proposal,request:request)
        let review=LocalDraftGroundingReview(answersQuestion:false,claims:DraftClaimIndex.claims(in:surface.text).map {
            DraftClaimReview(claimID:$0.id,supported:false,citationsRelevant:true,qualificationsPreserved:true,contradictsSource:false,introducesOutsideMaterial:false)
        })
        let draft=unverified ? try DraftPrototypeReviewGate.markUnverified(surface,review:review,note:"UNVERIFIED：模擬照合の試験用です．"):surface
        // Deliberately ignores cancellation, exercising the revision/epoch gate.
        return await withCheckedContinuation {held.append(Held(draft:draft,continuation:$0))}
    }
    func finishFirst() {if !held.isEmpty {let first=held.removeFirst();first.continuation.resume(returning:first.draft)}}
    func finishAll() {while !held.isEmpty {finishFirst()}}
}

@MainActor private func eventually(_ condition:()->Bool) async -> Bool {
    for _ in 0..<300 {
        if condition() {return true}
        try? await Task.sleep(for:.milliseconds(10))
    }
    return condition()
}
private func update(_ id:String,_ order:Int,_ text:String,final:Bool=true,revision:Int?=nil,sourceEnd:Double?=nil)->LiveRecognitionUpdate {
    LiveRecognitionUpdate(id:id,order:order,text:text,final:final,audioStart:Double(order)*4,
        audioEnd:sourceEnd ?? Double(order)*4+3,sourceRevision:revision)
}

@MainActor @Suite struct LiveFlowTests {
    @Test func explicitPrototypePolicyDisplaysUnverifiedAndStrictPolicyStillRejectsIt() async throws {
        for allow in [false,true] {
            let fake=HeldLocalGenerator(unverified:true)
            let session=LiveQASession(index:try liveFixture(),generator:fake,reviewPolicy:allow ? .allowUnverifiedPrototype:.requireModelReview)
            session.beginContinuousQuestions();session.receive(update("prototype-policy",0,"温度はどう測定しますか．"))
            #expect(await eventually{fake.requests.count == 1});fake.finishAll()
            #expect(await eventually{allow ? session.cards.first?.draft != nil:session.cards.first?.status == LocalDraftFailure.groundingReviewFailed.message})
            if allow {
                let draft=try #require(session.cards.first?.draft)
                #expect(draft.reviewState == .unverifiedAfterModelReview)
                #expect(!draft.localModelReviewPassed && !draft.semanticGroundingVerified)
                #expect(session.cards.first?.status.contains("未検証") == true)
            } else {#expect(session.cards.first?.draft == nil)}
            session.stop();fake.finishAll()
        }
    }
    @Test func prototypeCandidateCannotReturnAfterVerbalCancelAndFollowingQuestionNeedsNoModeSwitch() async throws {
        let fake=HeldLocalGenerator(unverified:true)
        let session=LiveQASession(index:try liveFixture(),generator:fake,reviewPolicy:.allowUnverifiedPrototype)
        session.beginContinuousQuestions();session.receive(update("prototype-old",0,"温度はどう測定しますか．"))
        #expect(await eventually{fake.requests.count == 1})
        let old=try #require(session.cards.first)
        session.receive(update("prototype-cancel",1,"今の質問を取り消します．"));fake.finishFirst()
        #expect(await eventually{session.discardedLateReplies>0})
        #expect(old.draft == nil && session.cards.first?.cancelled == true)
        session.receive(update("prototype-next",2,"振動はどう測定しますか．"))
        #expect(await eventually{fake.requests.count == 2});fake.finishAll()
        #expect(await eventually{session.cards.last?.draft?.reviewState == .unverifiedAfterModelReview})
        #expect(session.phase == .qna && session.acceptingInput)
        session.stop();#expect(session.cards.allSatisfy{$0.draft == nil && $0.reference == nil})
    }
    @Test func oneStartAcceptsFollowingQuestionsAndVerbalCancelWithoutModeChanges() async throws {
        let fake=HeldLocalGenerator()
        let session=LiveQASession(index:try liveFixture(),generator:fake,reviewPolicy:.mockOnly)
        session.beginContinuousQuestions()
        #expect(session.acceptingInput && session.generationEnabled && session.phase == .qna)
        session.receive(update("first",0,"温度はどう測定しますか．"))
        #expect(await eventually{fake.requests.count == 1})
        session.receive(update("cancel",1,"今の質問を取り消します．"))
        #expect(session.cards.first?.cancelled == true)
        fake.finishAll()
        session.receive(update("next",2,"振動はどう測定しますか．"))
        #expect(await eventually{fake.requests.count == 2})
        #expect(session.phase == .qna && session.acceptingInput)
        #expect(session.cards.last?.ticket.page == 2)
        session.stop();fake.finishAll()
        #expect(session.cards.allSatisfy{$0.draft == nil})
    }
    @Test func quotedCancellationDoesNotRetractAndSameTurnCancellationDoes() throws {
        let deck=LiveQuestionDeck(index:try liveFixture())
        var pipeline=IncrementalQuestions(phase:.qna)
        _=try pipeline.consume(turnID:"first",order:0,text:"温度はどう測定しますか．",final:true,deck:deck)
        let first=try #require(pipeline.tickets.first)
        _=try pipeline.consume(turnID:"quote",order:1,text:"「今の質問を取り消します」という表現を引用しました．",final:true,deck:deck)
        #expect(pipeline.isCurrent(first.lease))
        _=try pipeline.consume(turnID:"same-turn",order:2,text:"振動はどう測定しますか．今の質問を取り消します．",final:true,deck:deck)
        #expect(pipeline.tickets.map(\.lease) == [first.lease])
    }
    @Test func continuousHistoryRollsPastSixtyFourTurnsAndRejectsRetiredCallbacks() throws {
        let deck=LiveQuestionDeck(index:try liveFixture())
        var pipeline=IncrementalQuestions(phase:.qna)
        for order in 0..<80 {
            _=try pipeline.consume(turnID:"turn-\(order)",order:order,text:"温度はどう測定しますか．",final:true,deck:deck)
        }
        #expect(pipeline.tickets.count == 64)
        #expect(pipeline.tickets.first?.turnOrder == 16)
        let current=pipeline.tickets.map(\.lease)
        let changes=try pipeline.consume(turnID:"turn-0",order:0,text:"振動はどう測定しますか．",final:true,deck:deck)
        #expect(changes.isEmpty)
        #expect(pipeline.tickets.map(\.lease) == current)
        #expect(pipeline.phase == .qna)
    }
    @Test func cancelledCorrectionKeepsItsIdentityWhenOriginalTurnLeavesHistory() throws {
        let deck=LiveQuestionDeck(index:try liveFixture())
        var pipeline=IncrementalQuestions(phase:.qna)
        _=try pipeline.consume(turnID:"original",order:0,text:"温度はどう測定しますか．",final:true,deck:deck)
        _=try pipeline.consume(turnID:"corrected",order:1,text:"訂正します．振動はどう測定しますか．",final:true,deck:deck)
        let corrected=try #require(pipeline.tickets.first)
        for order in 2..<65 {
            _=try pipeline.consume(turnID:"lecture-\(order)",order:order,text:"説明を続けます．",final:true,deck:deck)
        }
        #expect(pipeline.tickets.count == 1)
        #expect(pipeline.tickets.first?.lease == corrected.lease)
        #expect(pipeline.tickets.first?.page == 2)
    }
    @Test func uiCancelledCorrectionCannotReturnAfterTemporaryAsrDisappearance() async throws {
        let fake=HeldLocalGenerator()
        let session=LiveQASession(index:try liveFixture(),generator:fake,reviewPolicy:.mockOnly)
        session.beginContinuousQuestions()
        session.receive(update("original",0,"温度はどう測定しますか．"))
        session.receive(update("correction",1,"訂正します．振動はどう測定しますか．",revision:1,sourceEnd:7))
        #expect(await eventually{fake.requests.count == 1})
        let corrected=try #require(session.cards.last)
        session.cancel(id:corrected.id)
        session.receive(update("correction",1,"訂正します．振動は",final:false,revision:2,sourceEnd:8))
        session.receive(update("correction",1,"訂正します．振動はどう測定しますか．",revision:3,sourceEnd:9))
        try? await Task.sleep(for:.milliseconds(550))
        #expect(fake.requests.count == 1)
        #expect(session.cards.last?.id == corrected.id)
        #expect(session.cards.last?.cancelled == true)
        #expect(session.cards.last?.draft == nil)
        session.stop();fake.finishAll()
    }
    @Test func correctionCannotMoveToAnotherQuestionWhenItsOriginalDisappears() throws {
        let deck=LiveQuestionDeck(index:try liveFixture())
        var pipeline=IncrementalQuestions(phase:.qna)
        _=try pipeline.consume(turnID:"original",order:0,text:"温度はどう測定しますか．振動はどう測定しますか．",final:true,deck:deck,sourceRevision:1,sourceEnd:3)
        let first=try #require(pipeline.tickets.first)
        _=try pipeline.consume(turnID:"corrected",order:1,text:"訂正します．振動はどのように測定しますか．",final:true,deck:deck)
        let corrected=try #require(pipeline.tickets.last)
        _=try pipeline.consume(turnID:"original",order:0,text:"温度はどう測定しますか．",final:true,deck:deck,sourceRevision:2,sourceEnd:4)
        #expect(pipeline.tickets.count == 2)
        #expect(pipeline.tickets.first?.lease == first.lease)
        #expect(pipeline.tickets.last?.lease == corrected.lease)
        #expect(pipeline.tickets.last?.page == 2)
    }
    @Test func spokenCancellationCannotMoveToAnotherQuestionAfterAsrDeletion() throws {
        let deck=LiveQuestionDeck(index:try liveFixture())
        var pipeline=IncrementalQuestions(phase:.qna)
        _=try pipeline.consume(turnID:"original",order:0,text:"温度はどう測定しますか．振動はどう測定しますか．",final:true,deck:deck,sourceRevision:1,sourceEnd:3)
        let first=try #require(pipeline.tickets.first)
        _=try pipeline.consume(turnID:"cancel",order:1,text:"今の質問を取り消します．",final:true,deck:deck)
        _=try pipeline.consume(turnID:"original",order:0,text:"温度はどう測定しますか．",final:true,deck:deck,sourceRevision:2,sourceEnd:4)
        #expect(pipeline.tickets.count == 1)
        #expect(pipeline.tickets.first?.lease == first.lease)
    }
    @Test func safeModeCannotEnableGenerationEvenWhenControlsTryToEnableIt() async throws {
        let fake=HeldLocalGenerator()
        let session=LiveQASession(index:try liveFixture(),generator:fake,reviewPolicy:.mockOnly,generationAllowed:false)
        session.setGenerationEnabled(true)
        #expect(!session.generationEnabled)
        session.submitTyped("温度はどう測定しますか．")
        #expect(session.cards.count == 1)
        #expect(session.cards.first?.reference != nil)
        session.setGenerationEnabled(true)
        try await Task.sleep(for:.milliseconds(500))
        #expect(!session.generationEnabled)
        #expect(session.generationRequests == 0)
        #expect(fake.requests.isEmpty)
        session.stop()
    }
    @Test func constructionAndUnstartedCallbacksNeverInvokeGeneration() async throws {
        let fake=HeldLocalGenerator();let session=LiveQASession(index:try liveFixture(),generator:fake,reviewPolicy:.mockOnly)
        session.setGenerationEnabled(true)
        session.receive(update("q",0,"温度はどう測定しますか"))
        #expect(session.cards.isEmpty)
        #expect(fake.requests.isEmpty)
        #expect(session.generationRequests == 0)
    }
    @Test func presentationSuppressesQuestionsAndClosingCueEnablesFollowingQnA() async throws {
        let fake=HeldLocalGenerator();let session=LiveQASession(index:try liveFixture(),generator:fake,reviewPolicy:.mockOnly)
        session.beginInput(phase:.presentation);session.setGenerationEnabled(true)
        session.receive(update("p",0,"温度はどう測定しますか"))
        #expect(session.cards.isEmpty)
        session.receive(update("end",1,"これで発表を終わります．"))
        session.receive(update("q",2,"温度はどう測定しますか"))
        #expect(session.phase == .qna)
        #expect(await eventually{fake.requests.count == 1})
        fake.finishAll()
        #expect(await eventually{session.cards.first?.draft != nil})
        session.setPhase(.answering)
        #expect(session.cards.first?.draft != nil)
        session.receive(update("blocked",3,"振動はどう測定しますか"))
        #expect(fake.requests.count == 1)
        session.stop()
    }
    @Test func finalizationDoesNotDuplicateAndARepeatedNewTurnIsIndependent() async throws {
        let fake=HeldLocalGenerator();let session=LiveQASession(index:try liveFixture(),generator:fake,reviewPolicy:.mockOnly)
        session.beginInput(phase:.qna);session.setGenerationEnabled(true)
        session.receive(update("one",0,"温度はどう測定しますか",final:false))
        #expect(session.cards.count == 1)
        #expect(fake.requests.isEmpty)
        session.receive(update("one",0,"温度はどう測定しますか"))
        session.receive(update("two",1,"温度はどう測定しますか"))
        #expect(session.cards.count == 2)
        #expect(await eventually{fake.requests.count == 1});fake.finishFirst()
        #expect(await eventually{fake.requests.count == 2});fake.finishFirst()
        #expect(await eventually{session.cards.allSatisfy{$0.draft != nil}})
        #expect(session.cards[0].ticket.lease != session.cards[1].ticket.lease)
        session.stop()
    }
    @Test func correctedQuestionRejectsGeneratorReplyEvenWhenCancellationIsIgnored() async throws {
        let fake=HeldLocalGenerator();let session=LiveQASession(index:try liveFixture(),generator:fake,reviewPolicy:.mockOnly)
        session.beginInput(phase:.qna);session.setGenerationEnabled(true)
        session.receive(update("same",0,"温度はどう測定しますか"))
        #expect(await eventually{fake.requests.count == 1})
        let old=try #require(session.cards.first)
        session.receive(update("same",0,"振動はどう測定しますか"))
        #expect(old.reference == nil)
        fake.finishFirst()
        #expect(await eventually{fake.requests.count == 2})
        #expect(session.cards.first?.ticket.page == 2)
        #expect(session.cards.first?.draft == nil)
        fake.finishFirst()
        #expect(await eventually{session.cards.first?.draft != nil})
        #expect(session.discardedLateReplies == 1)
        session.stop()
    }
    @Test func copiedCompletedCardCannotRedisplayAfterRevision() async throws {
        let fake=HeldLocalGenerator();let session=LiveQASession(index:try liveFixture(),generator:fake,reviewPolicy:.mockOnly)
        session.beginInput(phase:.qna);session.setGenerationEnabled(true)
        session.receive(update("same",0,"温度はどう測定しますか"))
        #expect(await eventually{fake.requests.count == 1});fake.finishFirst()
        #expect(await eventually{session.cards.first?.draft != nil})
        let retained=try #require(session.cards.first)
        session.receive(update("same",0,"振動はどう測定しますか"))
        #expect(retained.draft == nil)
        #expect(retained.reference == nil)
        session.stop();fake.finishAll()
    }
    @Test func cancellationAndStopRejectLateCallbacksAndLaterASRUpdates() async throws {
        let fake=HeldLocalGenerator();let session=LiveQASession(index:try liveFixture(),generator:fake,reviewPolicy:.mockOnly)
        session.beginInput(phase:.qna);session.setGenerationEnabled(true)
        session.receive(update("one",0,"温度はどう測定しますか"))
        #expect(await eventually{fake.requests.count == 1})
        session.cancel(id:try #require(session.cards.first).id)
        fake.finishAll()
        session.receive(update("one",0,"振動はどう測定しますか"))
        #expect(session.cards.first?.draft == nil)
        #expect(session.cards.first?.cancelled == true)
        session.stop()
        session.receive(update("late",1,"振動はどう測定しますか"))
        #expect(session.cards.count == 1)
        #expect(fake.requests.count == 1)
    }
    @Test func unfinishedCrossTurnChoiceHoldsOldCopiesThenResumesWithoutAnotherGeneration() async throws {
        let fake=HeldLocalGenerator();let session=LiveQASession(index:try liveFixture(choice:true),generator:fake,reviewPolicy:.mockOnly)
        session.beginInput(phase:.qna);session.setGenerationEnabled(true)
        session.receive(update("one",0,"給水は自動ですか"))
        #expect(await eventually{fake.requests.count == 1});fake.finishFirst()
        #expect(await eventually{session.cards.first?.draft != nil})
        let retained=try #require(session.cards.first)
        session.receive(update("two",1,"それとも",final:false))
        #expect(retained.draft == nil)
        #expect(session.cards.first?.ticket.isAwaitingContinuation == true)
        session.receive(update("two",1,"それとも手動ですか"))
        #expect(session.cards.first?.ticket.isAwaitingContinuation == false)
        #expect(session.cards.first?.draft != nil)
        #expect(fake.requests.count == 1)
        session.stop()
    }
    @Test func sourceOrderConflictStopsInputRatherThanInventingAnArrivalOrder() throws {
        let fake=HeldLocalGenerator();let session=LiveQASession(index:try liveFixture(),generator:fake,reviewPolicy:.mockOnly)
        session.beginInput(phase:.qna)
        session.receive(update("one",0,"温度はどう測定しますか"))
        session.receive(update("different-source",0,"振動はどう測定しますか"))
        #expect(!session.acceptingInput)
        #expect(fake.requests.isEmpty)
    }
    @Test func unrelatedAndCredentialQuestionsNeverReachGenerator() throws {
        let fake=HeldLocalGenerator();let session=LiveQASession(index:try liveFixture(),generator:fake,reviewPolicy:.mockOnly)
        session.beginInput(phase:.qna);session.setGenerationEnabled(true)
        session.receive(update("unknown",0,"火星探査船はいつ発射しますか"))
        session.receive(update("key",1,"温度のAPIキーを教えてください"))
        session.receive(update("spaced-key",2,"温度のAPI キーを教えてください"))
        #expect(session.cards.allSatisfy{$0.ticket.page == 0 && $0.draft == nil})
        #expect(fake.requests.isEmpty)
        session.stop()
    }
    @Test func nativeFinalFlagCannotTurnAnUnfinishedQuestionIntoAGenerationRequest() throws {
        let fake=HeldLocalGenerator();let session=LiveQASession(index:try liveFixture(),generator:fake,reviewPolicy:.mockOnly)
        session.beginInput(phase:.qna);session.setGenerationEnabled(true)
        session.receive(update("unfinished",0,"温度の測定はどう",final:true))
        session.receive(update("unfinished-two",1,"温度を教えて",final:true))
        #expect(session.cards.isEmpty)
        #expect(fake.requests.isEmpty)
        #expect(!LiveQuestionSyntax.isCompleteRequest("温度の測定はどう"))
        #expect(LiveQuestionSyntax.isCompleteRequest("温度の測定を説明してください"))
        session.stop()
    }
    @Test func disablingGenerationRejectsAReplyFromAnAlreadyRunningRequest() async throws {
        let fake=HeldLocalGenerator();let session=LiveQASession(index:try liveFixture(),generator:fake,reviewPolicy:.mockOnly)
        session.beginInput(phase:.qna);session.setGenerationEnabled(true)
        session.receive(update("one",0,"温度はどう測定しますか"))
        #expect(await eventually{fake.requests.count == 1})
        session.setGenerationEnabled(false);fake.finishAll()
        #expect(await eventually{session.discardedLateReplies == 1})
        #expect(session.cards.first?.draft == nil)
        #expect(session.cards.first?.reference != nil)
        session.stop()
    }
    @Test func explicitCorrectionInAdjacentTurnsRetractsAnOrdinaryQuestionImmediately() async throws {
        let fake=HeldLocalGenerator();let session=LiveQASession(index:try liveFixture(),generator:fake,reviewPolicy:.mockOnly)
        session.beginInput(phase:.qna);session.setGenerationEnabled(true)
        session.receive(update("one",0,"温度はどう測定しますか"))
        #expect(await eventually{fake.requests.count == 1})
        let old=try #require(session.cards.first)
        session.receive(update("correction",1,"訂正します"))
        #expect(old.reference == nil)
        #expect(session.cards.first?.draft == nil)
        fake.finishFirst()
        session.receive(update("replacement",2,"振動はどう測定しますか"))
        #expect(session.cards.count == 1)
        #expect(session.cards.first?.id == old.id)
        #expect(session.cards.first?.ticket.page == 2)
        #expect(session.cards.first?.ticket.lease != old.ticket.lease)
        #expect(await eventually{fake.requests.count == 2});fake.finishFirst()
        #expect(await eventually{session.cards.first?.draft != nil})
        session.stop()
    }
    @Test func quotedCorrectionOrMissingSourceOrderDoesNotRetractAnotherQuestion() throws {
        var pipeline=IncrementalQuestions(phase:.qna)
        let deck=LiveQuestionDeck(index:try liveFixture())
        _=try pipeline.consume(turnID:"one",order:0,text:"温度はどう測定しますか",final:true,deck:deck)
        let first=try #require(pipeline.tickets.first).lease
        _=try pipeline.consume(turnID:"quoted",order:1,text:"「訂正します」という言葉を引用しました",final:true,deck:deck)
        #expect(pipeline.isCurrent(first))
        _=try pipeline.consume(turnID:"gap",order:3,text:"訂正します",final:true,deck:deck)
        #expect(pipeline.isCurrent(first))
    }
    @Test func successiveExplicitCorrectionsUseSourceOriginsRatherThanTheOriginalDisplayPosition() throws {
        var pipeline=IncrementalQuestions(phase:.qna)
        let deck=LiveQuestionDeck(index:try liveFixture())
        _=try pipeline.consume(turnID:"one",order:0,text:"温度はどう測定しますか",final:true,deck:deck)
        let original=try #require(pipeline.tickets.first).lease
        _=try pipeline.consume(turnID:"two",order:1,text:"訂正します，振動はどう測定しますか",final:true,deck:deck)
        _=try pipeline.consume(turnID:"three",order:2,text:"訂正します，温度はどう測定しますか",final:true,deck:deck)
        #expect(pipeline.tickets.count == 1)
        #expect(pipeline.tickets.first?.lease.id == original.id)
        #expect(pipeline.tickets.first?.lease.revision == original.revision+2)
        #expect(pipeline.tickets.first?.page == 1)
    }
    @Test func oldCancelledDebounceCannotClearANewerJobWithTheSameLease() async throws {
        let fake=HeldLocalGenerator();let session=LiveQASession(index:try liveFixture(choice:true),generator:fake,reviewPolicy:.mockOnly)
        session.beginInput(phase:.qna);session.setGenerationEnabled(true)
        session.receive(update("one",0,"給水は自動ですか"))
        await Task.yield()
        session.receive(update("two",1,"それとも",final:false))
        session.receive(update("two",1,"それとも手動ですか"))
        session.receive(update("three",2,"続いて振動はどう測定しますか"))
        #expect(await eventually{fake.requests.count >= 1})
        try await Task.sleep(for:.milliseconds(150))
        #expect(fake.requests.count == 1)
        fake.finishFirst()
        #expect(await eventually{fake.requests.count == 2});fake.finishFirst()
        #expect(await eventually{session.cards.count == 2 && session.cards.allSatisfy{$0.draft != nil}})
        session.stop()
    }
    @Test func newerNativePartialWithAdvancingAudioEndCanCorrectAnEarlierFragmentFinal() async throws {
        let fake=HeldLocalGenerator();let session=LiveQASession(index:try liveFixture(),generator:fake,reviewPolicy:.mockOnly)
        session.beginInput(phase:.qna);session.setGenerationEnabled(true)
        session.receive(update("native",0,"温度はどう測定しますか",revision:1,sourceEnd:3))
        #expect(await eventually{fake.requests.count == 1})
        let old=try #require(session.cards.first)
        let corrected="温度はどう測定しますか．訂正します，振動はどう測定しますか"
        session.receive(update("native",0,corrected,final:false,revision:2,sourceEnd:4))
        #expect(old.reference == nil)
        #expect(session.cards.first?.ticket.page == 2)
        #expect(session.cards.first?.ticket.confirmed == false)
        fake.finishFirst()
        session.receive(update("native",0,corrected,revision:3,sourceEnd:4.5))
        #expect(await eventually{fake.requests.count == 2});fake.finishFirst()
        #expect(await eventually{session.cards.first?.draft != nil})
        let current=try #require(session.cards.first).ticket.lease
        session.receive(update("native",0,"温度はどう測定しますか",final:false,revision:2,sourceEnd:3))
        #expect(session.cards.first?.ticket.lease == current)
        #expect(session.cards.first?.ticket.page == 2)
        session.stop()
    }
    @Test func newerUnconfirmedSnapshotHoldsExistingDraftCopiesWithoutHidingTheCandidate() async throws {
        let fake=HeldLocalGenerator();let session=LiveQASession(index:try liveFixture(),generator:fake,reviewPolicy:.mockOnly)
        session.beginInput(phase:.qna);session.setGenerationEnabled(true)
        session.receive(update("native",0,"温度はどう測定しますか",revision:1,sourceEnd:3))
        #expect(await eventually{fake.requests.count == 1});fake.finishFirst()
        #expect(await eventually{session.cards.first?.draft != nil})
        let retained=try #require(session.cards.first)
        session.receive(update("native",0,"温度はどう測定しますか．それと",final:false,revision:2,sourceEnd:4))
        #expect(retained.draft == nil)
        #expect(session.cards.first?.reference != nil)
        session.receive(update("native",0,"温度はどう測定しますか",revision:3,sourceEnd:4.5))
        #expect(session.cards.first?.draft != nil)
        #expect(fake.requests.count == 1)
        session.stop()
    }
    @Test func nativePartialWithoutAudioGrowthCannotOverwriteFragmentFinal() throws {
        var pipeline=IncrementalQuestions(phase:.qna);let deck=LiveQuestionDeck(index:try liveFixture())
        _=try pipeline.consume(turnID:"native",order:0,text:"温度はどう測定しますか",final:true,deck:deck,sourceRevision:1,sourceEnd:3)
        let first=try #require(pipeline.tickets.first).lease
        _=try pipeline.consume(turnID:"native",order:0,text:"振動はどう測定しますか",final:false,deck:deck,sourceRevision:2,sourceEnd:3)
        #expect(pipeline.isCurrent(first))
        #expect(pipeline.tickets.first?.page == 1)
    }
    @Test func duplicateFinalCannotLowerTheAudioHighWatermark() throws {
        var pipeline=IncrementalQuestions(phase:.qna);let deck=LiveQuestionDeck(index:try liveFixture())
        _=try pipeline.consume(turnID:"native",order:0,text:"温度はどう測定しますか",final:true,deck:deck,sourceRevision:1,sourceEnd:10)
        let first=try #require(pipeline.tickets.first).lease
        _=try pipeline.consume(turnID:"native",order:0,text:"温度はどう測定しますか",final:true,deck:deck,sourceRevision:2,sourceEnd:5)
        _=try pipeline.consume(turnID:"native",order:0,text:"振動はどう測定しますか",final:false,deck:deck,sourceRevision:3,sourceEnd:7)
        #expect(pipeline.isCurrent(first))
        #expect(pipeline.tickets.first?.page == 1)
    }
    @Test func productionPolicyDoesNotAcceptASurfaceOnlyAdapterReply() async throws {
        let fake=HeldLocalGenerator();let session=LiveQASession(index:try liveFixture(),generator:fake)
        session.beginInput(phase:.qna);session.setGenerationEnabled(true)
        session.receive(update("strict",0,"温度はどう測定しますか"))
        #expect(await eventually{fake.requests.count == 1});fake.finishFirst()
        #expect(await eventually{session.cards.first?.status == LocalDraftFailure.groundingReviewFailed.message})
        #expect(session.cards.first?.draft == nil)
        #expect(session.cards.first?.reference != nil)
        session.stop()
    }
}

@Suite struct LocalDraftGuardTests {
    private func request() throws -> LocalDraftRequest {
        let index=try liveFixture()
        var pipeline=IncrementalQuestions(phase:.qna)
        _=try pipeline.consume(turnID:"unit",order:0,text:"温度はどう測定しますか",final:true,deck:LiveQuestionDeck(index:index))
        let ticket=try #require(pipeline.tickets.first)
        return try LocalDraftRequest(ticket:ticket,reference:index.search(ticket.text))
    }
    @Test func supportedProposalStillRequiresHumanSemanticReview() throws {
        let request=try request()
        let draft=try DraftSurfaceValidator.validate(LocalDraftProposal(
            answer:"温度はセンサーで測定する計画です．精度は未検証のため，確認が必要です．",
            citationIDs:request.sources.map(\.id),cannotAnswer:false),request:request)
        #expect(!draft.semanticGroundingVerified)
        #expect(draft.humanReviewRequired)
        #expect(!draft.abstained)
    }
    @Test func unknownOrMissingSourceIDsAndMissingQualificationAreRejected() throws {
        let request=try request()
        #expect(throws:LocalDraftFailure.invalidCitations) {
            try DraftSurfaceValidator.validate(LocalDraftProposal(answer:"温度をセンサーで測定する計画です．確認が必要です．",citationIDs:["unknown"],cannotAnswer:false),request:request)
        }
        #expect(throws:LocalDraftFailure.qualificationMissing) {
            try DraftSurfaceValidator.validate(LocalDraftProposal(answer:"温度はセンサーで測定しており，精度の高い測定ができます．",citationIDs:request.sources.map(\.id),cannotAnswer:false),request:request)
        }
    }
    @Test func unsupportedNumberCannotPassByBeingASubstringOfAnotherNumber() throws {
        #expect(!DraftSurfaceValidator.numbers(in:"200円です").isSubset(of:DraftSurfaceValidator.numbers(in:"1200円です")))
        #expect(DraftSurfaceValidator.numbers(in:"１，２００円と四件") == ["1200","四件"])
        let request=try request()
        #expect(throws:LocalDraftFailure.unsupportedNumbers) {
            try DraftSurfaceValidator.validate(LocalDraftProposal(answer:"温度を200回測定する計画です．精度は未検証です．",citationIDs:request.sources.map(\.id),cannotAnswer:false),request:request)
        }
    }
    @Test func abstentionNeverEchoesAnUnsupportedModelClaim() throws {
        let request=try request()
        let result=try DraftSurfaceValidator.validate(LocalDraftProposal(answer:"UNSUPPORTED_TEXT",citationIDs:[],cannotAnswer:true),request:request)
        #expect(result.abstained)
        #expect(!result.text.contains("UNSUPPORTED_TEXT"))
        #expect(result.citations.isEmpty)
    }
    @Test func copiedSourceTextIsNotRelabeledAsANewGeneratedAnswer() throws {
        let request=try request()
        let note=try #require(request.sources.first(where:{$0.source == .speakerNotes}))
        let draft=try DraftSurfaceValidator.validate(LocalDraftProposal(answer:note.text,
            citationIDs:[note.id],cannotAnswer:false),request:request)
        #expect(draft.composition == .quotedSources)
        #expect(!draft.localModelReviewPassed)
        #expect(draft.segments.allSatisfy{$0.quotation.map{note.text.contains($0.text)} == true})
        #expect(!draft.composition.label.contains("新しい"))
    }
    @Test func multipleCopiedSourceSentencesAreNotRelabeledAsNewGeneration() {
        let a="アルファ装置は温度を測定する装置として計画されています．"
        let b="ベータ装置は振動を測定する装置として計画されています．"
        #expect(DraftSurfaceValidator.isExtractiveOnly(a+b,sources:[a,b]))
        #expect(DraftSurfaceValidator.isExtractiveOnly(b+a,sources:[a,b]))
        #expect(!DraftSurfaceValidator.isExtractiveOnly("両装置では，観測したい対象に応じて温度と振動を分担する案です．",sources:[a,b]))
    }
    @Test func quantityCannotChangeItsUnitWhileKeepingTheSameDigits() {
        #expect(!DraftSurfaceValidator.numericClaims(in:"200件です").isSubset(of:DraftSurfaceValidator.numericClaims(in:"200年です")))
        #expect(DraftSurfaceValidator.numericClaims(in:"２００年と四件") == ["200年","四件"])
        #expect(!DraftSurfaceValidator.numericClaims(in:"200ドルです").isSubset(of:DraftSurfaceValidator.numericClaims(in:"200年です")))
        #expect(!DraftSurfaceValidator.numericClaims(in:"200ms").isSubset(of:DraftSurfaceValidator.numericClaims(in:"200m")))
        #expect(!DraftSurfaceValidator.numericClaims(in:"$200").isSubset(of:DraftSurfaceValidator.numericClaims(in:"200年")))
    }
    @Test func deadlineBoundaryCanBeCheckedWithoutWaitingOrInvokingAModel() throws {
        let start=ContinuousClock.now
        try LocalDraftDeadline.requireValid(createdAt:start,now:start.advanced(by:.seconds(12)))
        #expect(throws:LocalDraftFailure.deadlineExceeded) {
            try LocalDraftDeadline.requireValid(createdAt:start,now:start.advanced(by:.seconds(13)))
        }
    }
}

@Suite struct DraftGroundingReviewTests {
    private func draft() throws -> GuardedLocalDraft {
        let index=try liveFixture();var pipeline=IncrementalQuestions(phase:.qna)
        _=try pipeline.consume(turnID:"review",order:0,text:"温度はどう測定しますか",final:true,deck:LiveQuestionDeck(index:index))
        let ticket=try #require(pipeline.tickets.first)
        let request=try LocalDraftRequest(ticket:ticket,reference:index.search(ticket.text))
        return try DraftSurfaceValidator.validate(LocalDraftProposal(
            answer:"温度はセンサーで測定する計画です．精度は未検証のため，確認が必要です．",
            citationIDs:request.sources.map(\.id),cannotAnswer:false),request:request)
    }
    private func accepted(_ id:Int,supported:Bool=true,contradiction:Bool=false,outside:Bool=false)->DraftClaimReview {
        DraftClaimReview(claimID:id,supported:supported,citationsRelevant:true,qualificationsPreserved:true,
            contradictsSource:contradiction,introducesOutsideMaterial:outside)
    }
    @Test func everyFixedClaimMustBeReviewedExactlyOnceWithoutChangingTheDraft() throws {
        let draft=try draft();let claims=DraftClaimIndex.claims(in:draft.text)
        let result=try DraftGroundingReviewGate.accept(draft,review:LocalDraftGroundingReview(answersQuestion:true,claims:claims.map{accepted($0.id)}))
        #expect(result.localModelReviewPassed)
        #expect(!result.semanticGroundingVerified)
        #expect(result.text == draft.text)
        #expect(result.citations.map(\.id) == draft.citations.map(\.id))
        #expect(throws:LocalDraftFailure.groundingReviewFailed) {
            try DraftGroundingReviewGate.accept(draft,review:LocalDraftGroundingReview(answersQuestion:true,claims:[accepted(1)]))
        }
        #expect(throws:LocalDraftFailure.groundingReviewFailed) {
            try DraftGroundingReviewGate.accept(draft,review:LocalDraftGroundingReview(answersQuestion:true,claims:[accepted(1),accepted(1)]))
        }
    }
    @Test func unsupportedContradictoryOutsideOrOffQuestionVerdictsWithholdTheAnswer() throws {
        let draft=try draft()
        for reviews in [[accepted(1,supported:false),accepted(2)],[accepted(1,contradiction:true),accepted(2)],
                        [accepted(1,outside:true),accepted(2)]] {
            #expect(throws:LocalDraftFailure.groundingReviewFailed) {
                try DraftGroundingReviewGate.accept(draft,review:LocalDraftGroundingReview(answersQuestion:true,claims:reviews))
            }
        }
        #expect(throws:LocalDraftFailure.groundingReviewFailed) {
            try DraftGroundingReviewGate.accept(draft,review:LocalDraftGroundingReview(answersQuestion:false,claims:[accepted(1),accepted(2)]))
        }
    }
    @Test func claimIndexKeepsDecimalsAndCoversAllAnswerText() {
        let claims=DraftClaimIndex.claims(in:"予定は3.5年です．未確定の点を確認します．")
        #expect(claims.map(\.id) == [1,2])
        #expect(claims[0].text.contains("3.5"))
        #expect(claims.map(\.text).joined() == "予定は3.5年です．未確定の点を確認します．")
    }
}
