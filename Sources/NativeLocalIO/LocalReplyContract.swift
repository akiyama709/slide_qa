import Foundation
import RealDeckEvidenceCore

/// Prefer a short answer; retain up to three complete sentences when needed.
/// Does not truncate text or remove qualifications to make an answer fit.
enum LocalReplyContract {
    static func claims(_ text:String,question:String?=nil) throws -> [DraftClaim] {
        let value=text.trimmingCharacters(in:.whitespacesAndNewlines)
        let claims=DraftClaimIndex.claims(in:value)
        guard (8...450).contains(value.count),(1...3).contains(claims.count),
              claims.allSatisfy({claim in claim.text.last.map{"。．.!?？！".contains($0)} == true}) else {
            throw LocalDraftFailure.invalidText
        }
        let keys=claims.map{$0.text.precomposedStringWithCompatibilityMapping.replacingOccurrences(of:#"\s+"#,with:"",options:.regularExpression)}
        guard Set(keys).count == keys.count else {throw LocalDraftFailure.invalidText}
        for claim in claims {
            let sentence=claim.text.trimmingCharacters(in:CharacterSet(charactersIn:"。．.!?？！ \n"))
            if LiveQuestionSyntax.isCompleteRequest(sentence) || claim.text.last.map{"?？".contains($0)} == true {
                throw LocalDraftFailure.questionNotAnswered
            }
        }
        if let question {try LocalQuestionIntent.requireSurfaceResponse(question:question,answer:value)}
        return claims
    }
    static func validateReviewCount(claimCount:Int,verdictCount:Int) throws {
        guard (1...3).contains(claimCount),verdictCount == claimCount else {
            throw LocalDraftFailure.groundingReviewFailed
        }
    }
}

/// Pure diagnostic preflight. This returns a count, never a displayable draft.
public enum LocalReplyPreflight {
    public static func inspectFormat(_ text:String,question:String) throws -> Int {
        try LocalReplyContract.claims(text,question:question).count
    }
}
