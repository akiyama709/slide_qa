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
        var result:[String:Any]=["kind":"local-file-and-index-check","pages":deck.pageCount,
            "sourceSelection":external ? "owner-local-presentation":"fictional-demo",
            "PDFVerified":false,"modelInvoked":false,"microphoneStarted":false,"semanticTruthProved":false]
        if let p=CommandLine.arguments.firstIndex(of:"--query"),p+1<CommandLine.arguments.count {
            let search=index.search(CommandLine.arguments[p+1])
            guard index.quotesAreVerbatim(search) else {throw DeckError.invalid}
            result["disposition"]=search.disposition.rawValue
            result["candidatePages"]=search.candidates.map(\.page)
            result["quotedPassages"]=search.candidates.reduce(0){$0+$1.passages.count}
            result["quotesAreVerbatim"]=true
        }
        let data=try JSONSerialization.data(withJSONObject:result,options:[.sortedKeys])
        print(String(decoding:data,as:UTF8.self))
    }
}
