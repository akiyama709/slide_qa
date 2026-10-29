import Foundation
import SlideQACore

public enum LiveSpeakingPhase: String, Codable, CaseIterable, Hashable, Sendable {
    case presentation, qna, answering
    public var label: String {
        switch self { case .presentation: "発表中"; case .qna: "質疑待ち"; case .answering: "回答中" }
    }
}

public struct LiveRecognitionUpdate: Sendable {
    public let id: String
    public let order: Int
    public let text: String
    public let final: Bool
    public let audioStart: Double
    public let audioEnd: Double
    public let alternatives: [String]
    public let sourceRevision:Int?
    public let provisionalCompletion:Bool
    public let stableCompletion:Bool
    public init(id: String, order: Int, text: String, final: Bool, audioStart: Double,
                audioEnd: Double, alternatives: [String] = [], sourceRevision:Int?=nil,provisionalCompletion:Bool=false,
                stableCompletion:Bool=false) {
        self.id=id; self.order=order; self.text=text; self.final=final
        self.audioStart=audioStart; self.audioEnd=audioEnd; self.alternatives=alternatives
        self.sourceRevision=sourceRevision
        self.provisionalCompletion=provisionalCompletion
        self.stableCompletion=stableCompletion
    }
}

public struct LiveMatchedSlide: Sendable {
    public let number: Int
    public let title: String
}
public struct LiveQuestionCandidate: Sendable {
    public var text: String
    public let slide: LiveMatchedSlide?
    public var sourcePosition:Int?=nil
    public var sourceSegment:Int=0
}
public struct LiveQuestionDeck: Sendable {
    public let index: EvidenceIndex
    public init(index: EvidenceIndex) { self.index=index }
}
public enum LiveQuestionMatcher {
    public static func permitsQuestion(_ question:String)->Bool {
        let q=question.precomposedStringWithCompatibilityMapping.lowercased()
            .replacingOccurrences(of:#"\s+"#,with:"",options:.regularExpression)
        return !["暗証番号","apiキー","秘密鍵","パスワード","個人の住所","個人の電話番号"].contains(where:q.contains)
    }
    public static func match(_ question: String, deck: LiveQuestionDeck) -> LiveMatchedSlide? {
        guard permitsQuestion(question) else {return nil}
        let result=deck.index.search(question)
        guard result.disposition == .references, result.candidates.count == 1,
              let candidate=result.candidates.first, !candidate.passages.isEmpty else { return nil }
        return LiveMatchedSlide(number:candidate.page,title:candidate.title)
    }
}

public enum LiveQuestionSyntax {
    public static func isCancellation(_ text:String)->Bool {
        QuestionBoundaries.hasExplicitCancellationLeading(text)
    }
    public static func endsWithCancellation(_ text:String)->Bool {
        QuestionBoundaries.endsWithCancellation(text)
    }
    public static func isCompleteRequest(_ text:String,finalUtterance:Bool=false)->Bool {
        let normalized=text.precomposedStringWithCompatibilityMapping
            .replacingOccurrences(of:"下さい",with:"ください")
            .trimmingCharacters(in:.whitespacesAndNewlines)
        let trimmed=normalized.trimmingCharacters(in:CharacterSet(charactersIn:"。．.?!？！"))
            .trimmingCharacters(in:.whitespacesAndNewlines)
        guard trimmed.count>=4 else {return false}
        if trimmed.range(of:#"(?:ですか|ますか|でしょうか|ましたか|でしたか)(?:ね|な)?$|(?:教えてください|説明してください|伺いたいです|聞きたいです|お聞かせください|お願いします|教えていただきたいです|説明していただきたいです)$"#,options:.regularExpression) != nil {return true}
        // A final ASR utterance can be a natural question without a polite
        // suffix. Preserve '?' through sentence splitting so it remains evidence.
        guard finalUtterance else {return false}
        if QuestionGate.isQuestion(normalized) {return true}
        return trimmed.range(of:#"(?:教えて|説明して|教えてほしい|説明してほしい|聞きたい|伺いたい|なんですかね|なの|なんでしょう|何でしょう|とは|って何|ってなに|どういう意味|どういうこと|どう違う|どこが違う|何が違う)$"#,options:.regularExpression) != nil
    }
    /// An ordinary completed statement must not become the prefix of the next
    /// question. This seals the audio turn; it does not admit a model request.
    public static func isFinishedStatement(_ text:String)->Bool {
        let value=text.trimmingCharacters(in:.whitespacesAndNewlines.union(CharacterSet(charactersIn:"。．.!！")))
        return value.range(of:#"(?:です|ます|でした|ました|ません|である|だった|しています|している|しました|ということ)$"#,options:.regularExpression) != nil
    }
}
