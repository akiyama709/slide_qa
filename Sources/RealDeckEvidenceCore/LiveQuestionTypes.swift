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
    public init(id: String, order: Int, text: String, final: Bool, audioStart: Double,
                audioEnd: Double, alternatives: [String] = [], sourceRevision:Int?=nil) {
        self.id=id; self.order=order; self.text=text; self.final=final
        self.audioStart=audioStart; self.audioEnd=audioEnd; self.alternatives=alternatives
        self.sourceRevision=sourceRevision
    }
}

public struct LiveMatchedSlide: Sendable {
    public let number: Int
    public let title: String
}
public struct LiveQuestionCandidate: Sendable {
    public var text: String
    public let slide: LiveMatchedSlide?
}
public struct LiveQuestionDeck: Sendable {
    public let index: EvidenceIndex
    public init(index: EvidenceIndex) { self.index=index }
}
public enum LiveQuestionMatcher {
    public static func match(_ question: String, deck: LiveQuestionDeck) -> LiveMatchedSlide? {
        let q=question.precomposedStringWithCompatibilityMapping.lowercased()
            .replacingOccurrences(of:#"\s+"#,with:"",options:.regularExpression)
        guard !["暗証番号","apiキー","秘密鍵","パスワード","個人の住所","個人の電話番号"].contains(where:q.contains) else { return nil }
        let result=deck.index.search(question)
        guard result.disposition == .references, result.candidates.count == 1,
              let candidate=result.candidates.first, !candidate.passages.isEmpty else { return nil }
        return LiveMatchedSlide(number:candidate.page,title:candidate.title)
    }
}

public enum LiveQuestionSyntax {
    public static func isCompleteRequest(_ text:String)->Bool {
        let trimmed=text.trimmingCharacters(in:.whitespacesAndNewlines.union(CharacterSet(charactersIn:"。．.?!？！")))
        return trimmed.range(of:#"(?:ですか|ますか|でしょうか|ましたか|でしたか|教えてください|説明してください|伺いたいです|聞きたいです|お聞かせください|お願いします)$"#,options:.regularExpression) != nil
    }
}
