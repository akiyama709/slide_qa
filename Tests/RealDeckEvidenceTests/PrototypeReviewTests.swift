import Foundation
import Testing
import SlideQACore
@testable import RealDeckEvidenceCore

@Suite struct PrototypeReviewTests {
    private func draft() throws -> GuardedLocalDraft {
        let object:[String:Any]=["sourceFile":"synthetic.json","sourceSHA256":"synthetic","pageCount":1,
            "printedNumbersVerified":true,"routes":[],"slides":[["page":1,"title":"温度の確認",
                "text":"温度をセンサーで確認します．","notes":"温度はセンサーで測定します．"]]]
        let index=EvidenceIndex(deck:try JSONDecoder().decode(Deck.self,from:JSONSerialization.data(withJSONObject:object)))
        let question="スライド1の温度はどう確認しますか．";let reference=index.search(question)
        var pipeline=IncrementalQuestions(phase:.qna)
        _=try pipeline.consume(turnID:"prototype",order:0,text:question,final:true,deck:LiveQuestionDeck(index:index))
        let request=try LocalDraftRequest(ticket:try #require(pipeline.tickets.first),reference:reference)
        return try DraftSurfaceValidator.validate(.init(answer:"温度はセンサーで確認します．",citationIDs:request.sources.map(\.id),cannotAnswer:false),request:request)
    }
    private func review(relevant:Bool=true,qualified:Bool=true,contradiction:Bool=false,outside:Bool=false)->LocalDraftGroundingReview {
        .init(answersQuestion:false,claims:[.init(claimID:1,supported:false,citationsRelevant:relevant,
            qualificationsPreserved:qualified,contradictsSource:contradiction,introducesOutsideMaterial:outside)])
    }
    @Test func inconclusiveReviewIsVisibleOnlyAsExplicitlyUnverified() throws {
        let result=try DraftPrototypeReviewGate.markUnverified(draft(),review:review(),note:"UNVERIFIED：原文との意味の対応は未確認です．")
        #expect(result.reviewState == .unverifiedAfterModelReview)
        #expect(!result.localModelReviewPassed && !result.semanticGroundingVerified && result.humanReviewRequired)
        #expect(result.reviewNote.contains("UNVERIFIED"))
        #expect(!result.citations.isEmpty)
    }
    @Test func knownConflictMissingQualificationOrIrrelevantEvidenceIsStillBlocked() throws {
        for report in [review(relevant:false),review(qualified:false),review(contradiction:true),review(outside:true)] {
            #expect(throws:LocalDraftFailure.groundingReviewFailed) {try DraftPrototypeReviewGate.markUnverified(draft(),review:report,note:"UNVERIFIED")}
        }
    }
    @Test func incompleteOrDuplicateClaimReviewCannotBecomeAPrototypeCandidate() throws {
        #expect(throws:LocalDraftFailure.groundingReviewFailed) {
            try DraftPrototypeReviewGate.markUnverified(draft(),review:.init(answersQuestion:false,claims:[]),note:"UNVERIFIED")
        }
        let claim=review().claims[0]
        #expect(throws:LocalDraftFailure.groundingReviewFailed) {
            try DraftPrototypeReviewGate.markUnverified(draft(),review:.init(answersQuestion:false,claims:[claim,claim]),note:"UNVERIFIED")
        }
        #expect(throws:LocalDraftFailure.groundingReviewFailed) {try DraftPrototypeReviewGate.markUnverified(draft(),review:review(),note:"")}
    }
}
