import Foundation

/// A rejection-only check for explicit Japanese subject/object relations.
/// Unparsed language is left to the other gates; an empty conflict list is
/// never evidence that a generated statement is true.
public enum DraftRelationConsistency {
    public struct Relation:Equatable,Sendable,Codable {
        public let subject:String
        public let predicate:String
        public let object:String
    }
    public struct Conflict:Equatable,Sendable,Codable {
        public let asserted:Relation
        public let objectsForSubject:[String]
        public let otherSubjects:[String]
    }
    private static let relationPattern = #"(?<![\p{Han}\p{Hiragana}\p{Katakana}A-Za-z0-9])([\p{Han}\p{Katakana}A-Za-z0-9ー・]{1,36})(?:は|が|も)\s*([\p{Han}\p{Katakana}A-Za-z0-9ー・]{1,36})\s*を\s*([\p{Han}\p{Katakana}]{1,12})(?:しています|している|します|する|し)(?!ません|ない|なかった|なけれ)"#
    private static func withoutQuotedSpans(_ text:String)->String {
        var stack:[Character]=[];var result=""
        let pairs:[Character:Character] = ["「":"」","『":"』","“":"”","‘":"’"]
        for c in text {
            if let close=pairs[c] {stack.append(close);result.append(" ");continue}
            if c == "\"" {
                if stack.last == c {stack.removeLast()} else if stack.isEmpty {stack.append(c)}
                result.append(" ");continue
            }
            if stack.last == c {stack.removeLast();result.append(" ");continue}
            result.append(stack.isEmpty ? c:" ")
        }
        return result
    }
    static func relations(in text:String)->[Relation] {
        let normalized=withoutQuotedSpans(text.precomposedStringWithCompatibilityMapping.lowercased())
        let sentences=normalized.components(separatedBy:CharacterSet(charactersIn:"。．.!?？！\n"))
        let uncertain=["例えば","たとえば","仮に","予定","計画","可能性","かもしれ","場合","とき","なら",
                       "ません","ない","なかった","なけれ","とは限ら","という意味","とされ","とする"]
        let expression=try! NSRegularExpression(pattern:relationPattern)
        return sentences.flatMap {sentence -> [Relation] in
            guard !uncertain.contains(where:sentence.contains) else {return []}
            return expression.matches(in:sentence,range:NSRange(sentence.startIndex...,in:sentence)).compactMap {match in
                let values=(1...3).compactMap{Range(match.range(at:$0),in:sentence).map{String(sentence[$0])}}
                guard values.count == 3 else {return nil}
                return Relation(subject:values[0],predicate:values[2],object:values[1])
            }
        }
    }
    public static func conflicts(answer:String,citedSources:[EvidencePassage])->[Conflict] {
        let originals=citedSources.flatMap {source -> [Relation] in
            let text=source.source == .speakerNotes ? source.text.replacingOccurrences(of:#"(?<!\n)\n(?!\n)"#,with:"",options:.regularExpression):source.text
            return relations(in:text)
        }
        return relations(in:answer).compactMap {claim in
            let predicateFacts=originals.filter{$0.predicate == claim.predicate}
            let subjects=Set(predicateFacts.map(\.subject))
            guard subjects.count>=2,subjects.contains(claim.subject) else {return nil}
            let objects=Set(predicateFacts.filter{$0.subject == claim.subject}.map(\.object))
            guard !objects.contains(claim.object),
                  !objects.contains(where:{$0.contains(claim.object) || claim.object.contains($0)}) else {return nil}
            let others=Set(predicateFacts.filter{$0.subject != claim.subject && $0.object == claim.object}.map(\.subject))
            guard !others.isEmpty else {return nil}
            return Conflict(asserted:claim,objectsForSubject:objects.sorted(),otherSubjects:others.sorted())
        }
    }
    public static func requireCompatible(answer:String,citedSources:[EvidencePassage]) throws {
        guard conflicts(answer:answer,citedSources:citedSources).isEmpty else {throw LocalDraftFailure.sourceRelationMismatch}
    }
}
