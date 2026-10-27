import Foundation

public enum DraftResponseComposition:String,Sendable,Codable {
    case quotedSources,mixed,modelText,abstention
    public var label:String {
        switch self {
        case .quotedSources:"原文引用による応答候補（新規文章ではありません）"
        case .mixed:"端末内モデルの応答案（原文引用を含む）"
        case .modelText:"端末内モデルの応答案（要確認）"
        case .abstention:"根拠不足による保留"
        }
    }
}
public struct DraftSourceQuotation:Sendable {
    public let text:String
    public let sourceID:String
    public let page:Int
    public let title:String
    public let source:EvidenceSource
    public let paragraph:Int
    public var citation:String {
        "\(page)：\(title) ／ "+(source == .speakerNotes ? "発表ノートからの引用":"スライド本文・第\(paragraph)段落からの引用")
    }
}
public struct DraftResponseSegment:Identifiable,Sendable {
    public let id:Int
    public let modelText:String
    public let quotation:DraftSourceQuotation?
    public var displayText:String {quotation?.text ?? modelText}
}

/// Align a complete model sentence to original characters for honest quotation
/// display. Punctuation/space normalization is for matching only; it is never
/// applied to the displayed original or used as a semantic proof.
enum DraftSourceAlignment {
    static func normalized(_ text:String)->String {
        let original=Array(text.precomposedStringWithCompatibilityMapping)
        var chars:[Character]=[]
        for (offset,char) in original.enumerated() {
            if char.isWhitespace {
                let next=original.dropFirst(offset+1).first{!$0.isWhitespace}
                if let previous=chars.last,let next,previous.isASCII,next.isASCII,previous != " " {chars.append(" ")}
            } else {chars.append(char)}
        }
        var result=""
        for char in chars {
            // Fold equivalent Japanese sentence punctuation in place. Never
            // delete delimiters: A,B and AB must remain different strings.
            if char == "、" {result.append(",")}
            else if char == "。" {result.append(".")}
            else {result.append(char)}
        }
        return result
    }
    static func sentences(_ text:String)->[String] {
        let opens:[Character:Character]=["「":"」","『":"』","（":"）","(":")","[":"]","【":"】"]
        var closing:[Character]=[],buffer="",result:[String]=[]
        let chars=Array(text)
        func append() {
            let value=buffer.trimmingCharacters(in:.whitespacesAndNewlines);buffer=""
            if !value.isEmpty {result.append(value)}
        }
        for (offset,char) in chars.enumerated() {
            buffer.append(char)
            if let close=opens[char] {closing.append(close)}
            else if closing.last == char {closing.removeLast()}
            else if char == "\"" {if closing.last == char {closing.removeLast()} else {closing.append(char)}}
            let decimal=(char == "." || char == "．") && offset>0 && offset+1<chars.count && chars[offset-1].isNumber && chars[offset+1].isNumber
            if closing.isEmpty,"。．.!?？！".contains(char),!decimal {append()}
        }
        append()
        return result
    }
    static func segments(_ text:String,sources:[EvidencePassage])->[DraftResponseSegment] {
        let originals=sources.flatMap{source in sentences(source.text).map{(source,$0,normalized($0))}}
        return DraftClaimIndex.claims(in:text).map {claim in
            let needle=normalized(claim.text)
            let match=originals.first{!needle.isEmpty && $0.2 == needle}
            let quote=match.map{source,original,_ in
                DraftSourceQuotation(text:original,sourceID:source.id,page:source.page,title:source.title,
                    source:source.source,paragraph:source.paragraph)
            }
            return DraftResponseSegment(id:claim.id,modelText:claim.text,quotation:quote)
        }
    }
}
