import Foundation

/// Exact reference ranges for a generated sentence. Retrieval is not entailment.
public struct DraftEvidenceAnchor:Codable,Equatable,Sendable {
    public let claimID:Int
    public let sourceID:String
    public let utf16Offset:Int
    public let utf16Length:Int
    public let text:String
    public let previousSentence:String?
    public let nextSentence:String?
    public let exactSentenceMatch:Bool
}
public enum DraftClaimEvidenceMap {
    public static func anchors(for claim:DraftClaim,sources:[EvidencePassage],limit:Int=3)->[DraftEvidenceAnchor] {
        let terms=EvidenceIndex.words(claim.text)
        var candidates:[(DraftEvidenceAnchor,Double)]=[]
        for source in sources {
            let sentences=DraftSourceAlignment.sentences(source.text)
            var cursor=source.text.startIndex
            for (position,text) in sentences.enumerated() {
                guard let range=source.text.range(of:text,range:cursor..<source.text.endIndex) else {continue}
                cursor=range.upperBound
                let ns=NSRange(range,in:source.text)
                let exact=DraftSourceAlignment.normalized(text) == DraftSourceAlignment.normalized(claim.text)
                let words=EvidenceIndex.words(text)
                let overlap=terms.intersection(words)
                guard exact || !overlap.isEmpty else {continue}
                let score = (exact ? 1_000.0:0) + Double(overlap.count)*2 + Double(overlap.count)/Double(max(1,words.count)) + (source.source == .speakerNotes ? 0.1:0)
                let anchor=DraftEvidenceAnchor(claimID:claim.id,sourceID:source.id,utf16Offset:ns.location,utf16Length:ns.length,
                    text:text,previousSentence:position>0 ? sentences[position-1]:nil,
                    nextSentence:position+1<sentences.count ? sentences[position+1]:nil,exactSentenceMatch:exact)
                candidates.append((anchor,score))
            }
        }
        return candidates.sorted {a,b in
            if a.1 != b.1 {return a.1>b.1}
            return (a.0.sourceID,a.0.utf16Offset)<(b.0.sourceID,b.0.utf16Offset)
        }.prefix(max(0,min(limit,6))).map(\.0)
    }
    public static func areVerbatim(_ anchors:[DraftEvidenceAnchor],sources:[EvidencePassage])->Bool {
        anchors.allSatisfy {anchor in
            guard let source=sources.first(where:{$0.id == anchor.sourceID}) else {return false}
            let original=source.text as NSString
            guard anchor.utf16Offset>=0,anchor.utf16Length>0,
                  anchor.utf16Offset<=original.length-anchor.utf16Length else {return false}
            return original.substring(with:NSRange(location:anchor.utf16Offset,length:anchor.utf16Length)) == anchor.text
        }
    }
}
