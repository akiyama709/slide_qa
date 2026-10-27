import Foundation

/// A narrow, source-based rejection check for Japanese questions about who
/// makes a judgment. It adds no answer facts and does not prove entailment.
public enum DraftSubjectConsistency {
    private static func heads(_ text:String,patterns:[String])->Set<String> {
        let normalized=text.precomposedStringWithCompatibilityMapping
        return Set(patterns.flatMap {pattern in
            let expression=try! NSRegularExpression(pattern:pattern)
            return expression.matches(in:normalized,range:NSRange(normalized.startIndex...,in:normalized)).compactMap {match in
                Range(match.range(at:1),in:normalized).map {range in
                    let role=String(normalized[range]);return role == "人間" ? "人":role
                }
            }
        })
    }
    public static func sourceRoles(in sources:[EvidencePassage])->Set<String> {
        let role=#"([\p{Han}\p{Katakana}A-Za-z]{1,24})"#
        let sourcePatterns=[role + #"\s*の\s*(?:検証\s*と\s*)?(?:判断|決定)"#,
                            role + #"\s*が\s*(?:最終的な|最終の|最終)?\s*(?:判断|決定)"#]
        return heads(sources.map(\.text).joined(separator:"\n"),patterns:sourcePatterns)
    }
    public static func requireCompatible(question:String,answer:String,citedSources:[EvidencePassage]) throws {
        guard ["誰","だれ","どなた"].contains(where:question.contains),
              ["判断","決定"].contains(where:question.contains) else {return}
        let role=#"([\p{Han}\p{Katakana}A-Za-z]{1,24})"#
        let sourceRoles=sourceRoles(in:citedSources)
        guard !sourceRoles.isEmpty else {throw LocalDraftFailure.subjectMismatch}
        let answerPatterns=[role + #"\s*(?:が|は)\s*(?:最終的な|最終の|最終)?\s*(?:判断|決定)"#,
                            #"(?:判断|決定)(?:を行う)?(?:の)?(?:主体)?は\s*"# + role + #"\s*(?:が|です|である)"#]
        let answerRoles=heads(answer,patterns:answerPatterns)
        guard !answerRoles.isEmpty,sourceRoles.contains(where:answer.contains),answerRoles.isSubset(of:sourceRoles) else {
            throw LocalDraftFailure.subjectMismatch
        }
    }
}
