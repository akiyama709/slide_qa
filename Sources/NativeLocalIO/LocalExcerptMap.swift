import Foundation
import RealDeckEvidenceCore

/// Closed selections into exact local text. No model-generated quotation is
/// trusted, and every original sentence remains in the writer's context.
struct LocalExcerptMap {
    struct Entry {
        let sourceID:String
        let text:String
    }
    static let tokens=(1...24).map{String(format:"e%02d",$0)}
    let entries:[Entry]
    let sourceMap:LocalSourceMap
    private init(entries:[Entry],sourceMap:LocalSourceMap) {self.entries=entries;self.sourceMap=sourceMap}
    init(sources:[EvidencePassage]) throws {
        sourceMap=try LocalSourceMap(sources:sources)
        var items:[Entry]=[]
        var seen:Set<String>=[]
        let completeNotes=sources.filter{$0.source == .speakerNotes}.map(\.text).joined(separator:"\n")
            .replacingOccurrences(of:#"\s+"#,with:"",options:.regularExpression)
        for source in sources.sorted(by:{$0.source == .speakerNotes && $1.source != .speakerNotes}) {
            // Join narrative note wrapping. Preserve PDF layout rows rather
            // than inventing relationships by concatenating adjacent columns.
            let value=source.source == .speakerNotes ?
                source.text.replacingOccurrences(of:#"(?<!\n)\n(?!\n)"#,with:"",options:.regularExpression):source.text
            for claim in DraftClaimIndex.claims(in:value) {
                let key=claim.text.replacingOccurrences(of:#"\s+"#,with:"",options:.regularExpression)
                if source.source == .slideText,key.count>=12,completeNotes.contains(key) {continue}
                if !key.isEmpty,seen.insert(key).inserted {items.append(Entry(sourceID:source.id,text:claim.text))}
            }
        }
        // Group adjacent pieces rather than dropping tail qualifications.
        while items.count>24 {
            guard let offset=items.indices.dropLast().first(where:{items[$0].sourceID == items[$0+1].sourceID}) else {
                throw LocalDraftFailure.inputLimit
            }
            items[offset]=Entry(sourceID:items[offset].sourceID,text:items[offset].text+"\n"+items[offset+1].text)
            items.remove(at:offset+1)
        }
        guard !items.isEmpty else {throw LocalDraftFailure.insufficientSources}
        entries=items
    }
    var writerContext:String {
        entries.enumerated().map{offset,item in
            let label=sourceMap.sources.first(where:{$0.id == item.sourceID})?.source.label ?? "原文"
            return "[\(Self.tokens[offset])] [\(item.sourceID)] [\(label)]\n\(item.text)"
        }.joined(separator:"\n\n")
    }
    private func ranking(question:String,contextLabels:[String]=[])->[(Int,Double)] {
        let terms=EvidenceIndex.queryWords(question)
        let topicTerms=Set(contextLabels.flatMap{EvidenceIndex.words($0)})
        let comparisons=["違","異な","特色","特徴"].contains(where:question.contains)
        let asksQuantity=question.range(of:#"いくら|金額|何(?:年|名|人|円)|何万円|割合|何割|いつ|年度"#,options:.regularExpression) != nil
        let yesNo=question.contains("か") && !["どの","どんな","どう","誰","なぜ","何"].contains(where:question.contains)
        var ranked:[(Int,Double)]=[]
        for (offset,item) in entries.enumerated() {
            let matches=terms.intersection(EvidenceIndex.words(item.text))
            var score=matches.reduce(0.0){$0+(topicTerms.contains($1) ? 0.2:1.0)}
            if score>0,item.sourceID.contains("speakerNotes") {score+=0.4}
            if comparisons,["特に","重視","大切に","一体として"].contains(where:item.text.contains) {score+=3}
            if ["誰","だれ","どなた"].contains(where:question.contains),item.text.contains("判断"),item.text.contains("が判断") {score+=4}
            if yesNo,score>0,["ではない","ではありません","しません","しない","区別","未確認"].contains(where:item.text.contains) {score+=1.5}
            if !asksQuantity,!DraftSurfaceValidator.numbers(in:item.text).isEmpty {score-=0.75}
            ranked.append((offset,score))
        }
        ranked.sort{$0.1 == $1.1 ? $0.0<$1.0:$0.1>$1.1}
        return ranked
    }
    func focus(question:String,contextLabels:[String]=[])->String {
        let ranked=ranking(question:question,contextLabels:contextLabels)
        return ranked.prefix(4).filter{$0.1>0}.map{Self.tokens[$0.0]}.joined(separator:", ")
    }
    /// The writer sees a small set of exact, query-related facts. All original
    /// notes remain in sourceMap and in the final grounding review.
    func focused(question:String,contextLabels:[String]=[])->LocalExcerptMap {
        let ranked=ranking(question:question,contextLabels:contextLabels)
        var selected=ranked.filter{$0.1>0}.prefix(2).map{$0.0}
        if selected.isEmpty {selected=Array(entries.indices.prefix(2))}
        let primary=selected
        let terms=EvidenceIndex.queryWords(question)
        // Reserve space for explicit uncertainty before adding neighbours.
        let critical=entries.indices.filter {index in
            guard entries[index].sourceID.contains("speakerNotes") else {return false}
            let text=entries[index].text
            if ["意味ではありません","という意味ではない","未確認","未検証","計画段階","受入れ"].contains(where:text.contains) {return true}
            return text.contains("区別") && !terms.intersection(EvidenceIndex.words(text)).isEmpty
        }
        for index in critical where !selected.contains(index) {selected.append(index)}
        // A long qualified source gets the full context rather than losing a
        // qualification to the compact writer's capacity.
        if selected.count>6 {return self}
        for index in entries.indices where selected.count<4 && entries[index].sourceID.contains("speakerNotes") {
            let text=entries[index].text
            if ["計画","提案","予定"].contains(where:text.contains),!terms.intersection(EvidenceIndex.words(text)).isEmpty,!selected.contains(index) {
                selected.append(index)
            }
        }
        for index in primary where entries[index].sourceID.contains("speakerNotes") {
            for next in [index-1,index+1] where selected.count<6 && entries.indices.contains(next) && entries[next].sourceID == entries[index].sourceID {
                if !selected.contains(next) {selected.append(next)}
            }
        }
        for index in entries.indices where selected.count<6 && entries[index].sourceID.contains("speakerNotes") {
            if ["意味ではありません","未確認","未検証","区別","計画","提案","予定"].contains(where:entries[index].text.contains),!selected.contains(index) {
                selected.append(index)
            }
        }
        return LocalExcerptMap(entries:selected.prefix(6).map{entries[$0]},sourceMap:sourceMap)
    }
    func selected(positions:[Int],cannotAnswer:Bool) throws ->(ids:[String],excerpt:String) {
        if cannotAnswer {return([],"")}
        guard (1...4).contains(positions.count),Set(positions).count == positions.count,
              positions.allSatisfy({entries.indices.contains($0)}) else {throw LocalDraftFailure.invalidCitations}
        var ids=positions.map{entries[$0].sourceID}
        // The complete speaker note stays available to the review even if the
        // writer chooses a PDF fragment without its qualifications.
        ids+=sourceMap.sources.filter{$0.source == .speakerNotes}.map(\.id)
        var seen:Set<String>=[]
        ids=ids.filter{seen.insert($0).inserted}
        return(ids,positions.map{entries[$0].text}.joined(separator:"\n"))
    }
}
