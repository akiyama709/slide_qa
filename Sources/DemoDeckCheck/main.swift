import Foundation
import RealDeckEvidenceCore
import SlideQACore

/// Pure source/index check. Does not open an app, microphone or model session.
@main struct DemoDeckCheck {
    static func main() throws {
        let external=Deck.hasExternalSelection()
        let deck=try Deck.configured()
        let index=EvidenceIndex(deck:deck)
        guard !deck.printedNumbersVerified else {throw DeckError.invalid}
        if !external {
            guard deck.pageCount == 6 else {throw DeckError.invalid}
            for (question,page) in [("スライド2の測定対象を教えてください．",2),
                ("スライド3の警報について教えてください．",3),("スライド4の校正について教えてください．",4)] {
                let result=index.search(question)
                guard result.candidates.first?.page == page,index.quotesAreVerbatim(result) else {throw DeckError.invalid}
            }
        }
        let result:[String:Any]=["kind":"local-json-and-index-check","pages":deck.pageCount,
            "sourceSelection":external ? "owner-local-json":"fictional-demo",
            "PDFVerified":false,"modelInvoked":false,"microphoneStarted":false,"semanticTruthProved":false]
        let data=try JSONSerialization.data(withJSONObject:result,options:[.sortedKeys])
        print(String(decoding:data,as:UTF8.self))
    }
}
