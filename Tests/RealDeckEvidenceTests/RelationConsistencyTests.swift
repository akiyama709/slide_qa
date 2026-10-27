import Testing
import Foundation
import SlideQACore
@testable import RealDeckEvidenceCore

@Suite struct RelationConsistencyTests {
    private func source(_ text:String)->[EvidencePassage] {
        [.init(page:1,title:"対応",source:.speakerNotes,paragraph:1,text:text)]
    }
    @Test func differentSubjectsCannotExchangeKnownObjectsForTheSamePredicate() throws {
        let sources=source("アルファ装置は温度を測定し，ベータ装置は振動を測定します．")
        #expect(DraftRelationConsistency.conflicts(answer:"アルファ装置は温度を測定します．ベータ装置も温度を測定します．",citedSources:sources).count == 1)
        #expect(throws:LocalDraftFailure.sourceRelationMismatch) {
            try DraftRelationConsistency.requireCompatible(answer:"ベータ装置は温度を測定します．",citedSources:sources)
        }
        try DraftRelationConsistency.requireCompatible(answer:"アルファ装置は温度を測定します．ベータ装置は振動を測定します．",citedSources:sources)
    }
    @Test func heldOutVocabulariesAndReversedOrdersUseTheSameStructuralRule() {
        for (text,wrong,correct) in [
            ("研究班甲は河川を調査し，研究班乙は森林を調査します．","研究班乙も河川を調査します．","研究班乙は森林を調査します．"),
            ("系統Yは熱を検出し，系統Xは光を検出します．","系統Xが熱を検出します．","系統Xが光を検出します．")
        ] {
            #expect(DraftRelationConsistency.conflicts(answer:wrong,citedSources:source(text)).count == 1)
            #expect(DraftRelationConsistency.conflicts(answer:correct,citedSources:source(text)).isEmpty)
        }
    }
    @Test func additionalExplicitSupportPreventsAClosedWorldRejection() {
        let sources=source("装置Aは温度を測定し，装置Bは振動を測定します．装置Bは温度を測定します．")
        #expect(DraftRelationConsistency.conflicts(answer:"装置Bも温度を測定します．",citedSources:sources).isEmpty)
    }
    @Test func uncertaintyQuotationJointSubjectsAndUnparsedLanguageAreNotPositiveRelations() {
        let wrong="研究班乙は河川を調査します．"
        for text in [
            "「研究班甲は河川を調査し，研究班乙は森林を調査します．」とは書かれていません．",
            "研究班甲は河川を調査し，研究班乙は森林を調査する計画です．",
            "仮に研究班甲は河川を調査し，研究班乙は森林を調査する場合を考えます．",
            "研究班甲は河川を調査しません．研究班乙は森林を調査します．",
            "研究班甲と研究班乙は河川を調査し，研究班丙は森林を調査します．"
        ] {#expect(DraftRelationConsistency.conflicts(answer:wrong,citedSources:source(text)).isEmpty)}
        let sources=source("研究班甲は河川を調査し，研究班乙は森林を調査します．")
        for answer in ["『研究班乙は河川を調査します．』とは言えません．","研究班乙は河川を調査しません．","研究班甲と研究班乙は河川を調査します．","別の説明を確認する必要があります．"] {
            #expect(DraftRelationConsistency.conflicts(answer:answer,citedSources:sources).isEmpty)
        }
    }
    @Test func nestedObjectNamesAreLeftToSemanticReview() {
        let sources=source("装置Aは表面温度を測定し，装置Bは温度を測定します．")
        #expect(DraftRelationConsistency.conflicts(answer:"装置Aは温度を測定します．",citedSources:sources).isEmpty)
    }
    @Test func productionSurfaceGateRejectsTheSwapWithoutCallingAModel() throws {
        let fixture:[String:Any]=["sourceFile":"local-fixture.pdf","sourceSHA256":"fixture","pageCount":1,
            "printedNumbersVerified":true,"routes":[],"slides":[["page":1,"title":"研究班の調査対象",
            "text":"研究班甲は河川を調査し，研究班乙は森林を調査します．","notes":""]]]
        let index=EvidenceIndex(deck:try JSONDecoder().decode(Deck.self,from:JSONSerialization.data(withJSONObject:fixture)))
        let question="スライド1について，研究班甲と研究班乙は何を調査しますか．"
        let reference=index.search(question)
        var pipeline=IncrementalQuestions(phase:.qna)
        _=try pipeline.consume(turnID:"relation-production",order:0,text:question,final:true,deck:LiveQuestionDeck(index:index))
        let request=try LocalDraftRequest(ticket:try #require(pipeline.tickets.first),reference:reference)
        #expect(throws:LocalDraftFailure.sourceRelationMismatch) {
            try DraftSurfaceValidator.validate(.init(answer:"研究班乙も河川を調査します．",citationIDs:request.sources.map(\.id),cannotAnswer:false),request:request)
        }
        let draft=try DraftSurfaceValidator.validate(.init(answer:"研究班乙は森林を調査します．",citationIDs:request.sources.map(\.id),cannotAnswer:false),request:request)
        #expect(!draft.localModelReviewPassed)
        #expect(!draft.semanticGroundingVerified)
    }
}
