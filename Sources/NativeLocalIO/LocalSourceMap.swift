import Foundation
import RealDeckEvidenceCore

/// The writer chooses a closed enum of short tokens. Only local code maps
/// those choices to canonical source IDs; the reviewer sees the canonical IDs.
struct LocalSourceMap {
    static let tokens=["sourceA","sourceB","sourceC"]
    let sources:[EvidencePassage]
    init(sources:[EvidencePassage]) throws {
        guard (1...3).contains(sources.count) else {throw LocalDraftFailure.inputLimit}
        guard Set(sources.map(\.id)).count == sources.count else {throw LocalDraftFailure.invalidCitations}
        self.sources=sources
    }
    var writerContext:String {
        sources.enumerated().map{offset,item in
            "[出典記号：\(Self.tokens[offset])]\n\(item.citation)\n\(item.text)"
        }.joined(separator:"\n\n")
    }
    var reviewerContext:String {
        sources.map{"[根拠ID：\($0.id)]\n\($0.citation)\n\($0.text)"}.joined(separator:"\n\n")
    }
    func reviewerContext(citationIDs:[String])->String {
        sources.filter{citationIDs.contains($0.id)}.map{"[根拠ID：\($0.id)]\n\($0.citation)\n\($0.text)"}.joined(separator:"\n\n")
    }
    func requireVerbatimExcerpt(_ excerpt:String,citationIDs:[String]) throws {
        func plain(_ value:String)->String {
            value.precomposedStringWithCompatibilityMapping.replacingOccurrences(of:#"\s+"#,with:"",options:.regularExpression)
        }
        let value=plain(excerpt)
        guard (6...600).contains(value.count),sources.contains(where:{citationIDs.contains($0.id) && plain($0.text).contains(value)}) else {
            throw LocalDraftFailure.invalidCitations
        }
    }
    func canonicalIDs(for positions:[Int],cannotAnswer:Bool=false) throws -> [String] {
        if cannotAnswer {return []}
        guard (1...3).contains(positions.count),Set(positions).count == positions.count,
              positions.allSatisfy({sources.indices.contains($0)}) else {throw LocalDraftFailure.invalidCitations}
        return positions.map{sources[$0].id}
    }
}
