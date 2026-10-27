import Foundation
import Testing
import SlideQACore
import RealDeckEvidenceCore

@Suite struct DemoDeckValidationTests {
    private func data(pages:[Int]=[1,2],title:String="架空の点検",declaredCount:Int?=nil) throws -> Data {
        let slides=pages.map{["page":$0,"title":title,"text":"装置の状態を確認します．","notes":"架空の動作確認資料です．","preparedScript":"未使用の固定文"] as [String:Any]}
        let object:[String:Any]=["sourceFile":"untrusted-metadata.pdf","sourceSHA256":"untrusted-claim",
            "pageCount":declaredCount ?? pages.count,"printedNumbersVerified":true,"slides":slides,
            "routes":[["page":1,"cues":[["pattern":"[","weight":8]]]]]
        return try JSONSerialization.data(withJSONObject:object)
    }
    @Test func fictionalBundleHasNoClaimOfOriginalPDFVerification() throws {
        let deck=try Deck.bundled()
        #expect(deck.pageCount == 6)
        #expect(deck.slides.map(\.page) == Array(1...6))
        #expect(deck.sourceFile == "synthetic-demo.json")
        #expect(!deck.printedNumbersVerified)
    }
    @Test func localJSONAssertionsDoNotBecomeVerificationOrCannedAnswers() throws {
        let deck=try Deck.validated(data:data(),sourceName:"selected-local.json")
        #expect(!deck.printedNumbersVerified)
        #expect(deck.sourceSHA256 != "untrusted-claim")
        #expect(deck.sourceFile == "selected-local.json")
        #expect(deck.slides.allSatisfy{$0.preparedScript == nil && $0.scriptSourcePages == nil})
        #expect(deck.routes.isEmpty)
    }
    @Test func duplicateSkippedOutOfOrderEmptyAndMismatchedPagesAreRejected() throws {
        for pages in [[1,1],[1,3],[2,1],[0,1],[]] {
            #expect(throws:(any Error).self){try Deck.validated(data:data(pages:pages))}
        }
        #expect(throws:(any Error).self){try Deck.validated(data:data(title:" "))}
        #expect(throws:(any Error).self){try Deck.validated(data:data(declaredCount:3))}
        #expect(throws:(any Error).self){try Deck.validated(data:data(pages:Array(1...501)))}
    }
    @Test func inputSizeAndAmbiguousOrNetworkArgumentsAreRejected() throws {
        #expect(throws:(any Error).self){try Deck.validated(data:Data(repeating:0,count:5*1024*1024+1))}
        for args in [["check","--deck"],["check","--deck=https://example.invalid/deck.json"],
            ["check","--deck","https://example.invalid/deck.json"],
            ["check","--deck","--disable-microphone"],["check","--deck","a","--deck","b"]] {
            #expect(throws:(any Error).self){try Deck.configured(arguments:args)}
        }
        #expect(Deck.hasExternalSelection(arguments:["check","--deck","local.json"]))
    }
}
