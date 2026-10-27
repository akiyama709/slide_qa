import Foundation

public enum SessionPhase: String, Codable, CaseIterable, Sendable {
    case presentation, qna, answering
    public var label: String {
        switch self { case .presentation: "発表中"; case .qna: "質疑待ち"; case .answering: "回答中" }
    }
}

public struct GateResult: Sendable, Equatable {
    public var phase: SessionPhase
    public var cue: String?
    public var questions: [String]
    public var ignoredReason: String?
}

public struct QuestionGate: Sendable {
    public var phase: SessionPhase = .presentation
    public var automaticCues = true
    public init() {}

    public static func outsideQuotes(_ text: String) -> String {
        var result = text
        for pattern in [#"「[^」]*」"#, #"『[^』]*』"#, #"“[^”]*”"#] {
            result = result.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        }
        return result
    }

    public mutating func process(_ text: String, final: Bool) -> GateResult {
        let outside = Self.outsideQuotes(text)
        let closing = outside.range(of: #"(?:これで|以上で)(?:私の|本日の)?発表を終わります|ご清聴[、，,\s]*(?:誠に|まことに)?[、，,\s]*(?:ありがとうございました|有難うございました)"#, options: .regularExpression)
        let quotedContext = text.range(of: #"(?:例えば|例として|と言います|という言葉|という表現|という台詞)"#, options: .regularExpression) != nil
        if final, automaticCues, phase == .presentation, closing != nil, !quotedContext {
            phase = .qna
            let expression = try! NSRegularExpression(pattern: #"(?:これで|以上で)(?:私の|本日の)?発表を終わります|ご清聴[、，,\s]*(?:誠に|まことに)?[、，,\s]*(?:ありがとうございました|有難うございました)"#)
            let matches = expression.matches(in: outside, range: NSRange(outside.startIndex..., in: outside))
            let tail = matches.last.flatMap { Range($0.range, in: outside) }.map { String(outside[$0.upperBound...]) } ?? ""
            let following = process(tail, final: true)
            return GateResult(phase: phase, cue: "発表終了の文脈上の合図", questions: following.questions, ignoredReason: nil)
        }
        guard phase == .qna else { return GateResult(phase: phase, questions: [], ignoredReason: phase.rawValue) }
        guard final else { return GateResult(phase: phase, questions: [], ignoredReason: "partial") }
        let excluded = #"ご質問(?:は|を)|質問(?:をどうぞ|はありますか|をお願いします|をお受け)|質疑(?:に移|応答に)|という(?:ご質問|ことですね|問い)|お答えします|自問|問いを立て|質問を読み上げ|質問を言い直"#
        let chunks = Self.sentences(outside)
        let questions = chunks.filter { chunk in
            chunk.range(of: excluded, options: .regularExpression) == nil && Self.isQuestion(chunk)
        }
        return GateResult(phase: phase, questions: questions, ignoredReason: questions.isEmpty ? "not_substantive_question" : nil)
    }

    public static func isQuestion(_ text: String) -> Bool {
        guard normalize(text).count >= 5 else { return false }
        return text.range(of: #"(?:[?？]|(?:か|でしょうか|ですか|ますか)[。．.]?|教えて(?:ください|下さい)[。．.]?|説明してください[。．.]?|お聞かせください[。．.]?|伺いたいです[。．.]?|お願いします[。．.]?)\s*$"#, options: .regularExpression) != nil
    }

    public static func sentences(_ text: String) -> [String] {
        // ASR punctuation is retained. Split explicit consecutive requests even
        // when recognizer omits punctuation between them.
        let separated = text.replacingOccurrences(of: #"(ですか|ますか|でしょうか|教えてください|説明してください)[、，\s]*(?!ら|と|ね)(?=[\p{L}\p{N}])"#, with: "$1。", options: .regularExpression)
        let regex = try! NSRegularExpression(pattern: #"[^。．.!?！？]+[。．.!?！？]*"#)
        let range = NSRange(separated.startIndex..., in: separated)
        return regex.matches(in: separated, range: range).compactMap { match in
            Range(match.range, in: separated).map { String(separated[$0]).trimmingCharacters(in: .whitespacesAndNewlines) }
        }.filter { !$0.isEmpty }
    }
}

public struct RevisionLease: Sendable, Equatable {
    public let id: String
    public let token: UUID
    public let text: String
}

public struct RevisionRegistry: Sendable {
    private var entries: [String: RevisionLease] = [:]
    public init() {}
    public mutating func update(id: String, text: String) -> RevisionLease? {
        if let existing = entries[id], normalize(existing.text) == normalize(text) { return nil }
        let lease = RevisionLease(id: id, token: UUID(), text: text)
        entries[id] = lease
        return lease
    }
    public func isCurrent(_ lease: RevisionLease) -> Bool { entries[lease.id] == lease }
    public mutating func invalidate(id: String) { entries.removeValue(forKey: id) }
    public mutating func reset() { entries.removeAll() }
}

public enum DraftChecks {
    public static func useful(_ text: String) -> Bool {
        let stripped = text.replacingOccurrences(of: #"ご質問ありがとうございます[。．、，\s]*|回答案[：:\s]*"#, with: "", options: .regularExpression)
        return normalize(stripped).count >= 24
    }
    public static func unsupportedNumbers(in draft: String, source: String) -> [String] {
        let regex = try! NSRegularExpression(pattern: #"[0-9]+(?:[.,][0-9]+)*"#)
        let numbers = regex.matches(in: draft, range: NSRange(draft.startIndex..., in: draft)).compactMap { Range($0.range, in: draft).map { String(draft[$0]) } }
        return Array(Set(numbers.filter { !source.contains($0) })).sorted()
    }
}
