import Foundation

/// Explicit prototype policy, separate from strict review acceptance.
/// The source/number/subject/relationship/qualification gates must already
/// have produced the immutable draft. A complete but inconclusive model
/// review can expose a clearly UNVERIFIED candidate, never a verified answer.
public enum DraftPrototypeReviewGate {
    public static func markUnverified(_ draft:GuardedLocalDraft,review:LocalDraftGroundingReview,note:String) throws -> GuardedLocalDraft {
        let claims=DraftClaimIndex.claims(in:draft.text)
        guard !draft.abstained,!draft.citations.isEmpty,!note.isEmpty,
              (1...3).contains(claims.count),review.claims.count == claims.count,
              Set(review.claims.map(\.claimID)) == Set(claims.map(\.id)),
              review.claims.allSatisfy({$0.citationsRelevant && $0.qualificationsPreserved &&
                  !$0.contradictsSource && !$0.introducesOutsideMaterial}) else {throw LocalDraftFailure.groundingReviewFailed}
        return GuardedLocalDraft.withUnverifiedModelReview(draft,note:note)
    }
}
