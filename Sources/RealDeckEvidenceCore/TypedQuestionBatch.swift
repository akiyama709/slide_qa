import Foundation

public enum TypedQuestionBatchError: Error, Equatable, Sendable {
    case inputTooLong, questionTooLong, tooManyQuestions
    public var message: String {
        switch self {
        case .inputTooLong: "入力全体を8,000文字以内にしてください．"
        case .questionTooLong: "1件の質問を4,000文字以内にしてください．"
        case .tooManyQuestions: "質問を8件以内に分けて検索してください．"
        }
    }
}

/// Splits manually entered questions without interpreting quoted text as a
/// new question, or treating the decimal point in 3.5 as a sentence ending.
public enum TypedQuestionBatch {
    public static func parse(_ input: String) throws -> [String] {
        guard input.count <= 8_000 else { throw TypedQuestionBatchError.inputTooLong }
        let characters = Array(input)
        let quotePairs: [Character: Character] = ["「":"」", "『":"』", "“":"”", "\"":"\""]
        var closingQuotes: [Character] = []
        var buffer = ""
        var questions: [String] = []
        func isNumber(_ index: Int) -> Bool {
            characters.indices.contains(index) && characters[index].isNumber
        }
        func appendQuestion() throws {
            let text = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
            buffer = ""
            guard !text.isEmpty else { return }
            guard text.count <= 4_000 else { throw TypedQuestionBatchError.questionTooLong }
            questions.append(text)
            guard questions.count <= 8 else { throw TypedQuestionBatchError.tooManyQuestions }
        }
        for (offset, character) in characters.enumerated() {
            buffer.append(character)
            if closingQuotes.last == character {
                closingQuotes.removeLast()
                continue
            }
            if let closing = quotePairs[character] {
                closingQuotes.append(closing)
                continue
            }
            guard closingQuotes.isEmpty else { continue }
            let decimalPoint = (character == "." || character == "．") && isNumber(offset - 1) && isNumber(offset + 1)
            let internalASCIIStop = character == "." && offset + 1 < characters.count && !characters[offset + 1].isWhitespace
            if "。．.？！?!\n\r".contains(character), !decimalPoint, !internalASCIIStop {
                try appendQuestion()
            }
        }
        try appendQuestion()
        return questions
    }
}
