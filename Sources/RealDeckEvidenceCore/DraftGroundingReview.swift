import Foundation

public struct DraftClaim:Identifiable,Sendable,Equatable {
    public let id:Int
    public let text:String
}
public enum DraftClaimIndex {
    public static func claims(in text:String)->[DraftClaim] {
        let chars=Array(text);var buffer="";var values:[DraftClaim]=[];var quotes:[Character]=[]
        let pairs:[Character:Character] = ["「":"」","『":"』","“":"”","‘":"’"]
        func append() {
            let value=buffer.trimmingCharacters(in:.whitespacesAndNewlines);buffer=""
            if !value.isEmpty {values.append(DraftClaim(id:values.count+1,text:value))}
        }
        for (offset,c) in chars.enumerated() {
            buffer.append(c)
            if let close=pairs[c] {quotes.append(close)}
            else if c == "\"" {
                if quotes.last == c {quotes.removeLast()} else if quotes.isEmpty {quotes.append(c)}
            } else if quotes.last == c {quotes.removeLast()}
            let decimal=(c == "." || c == "．") && offset>0 && offset+1<chars.count && chars[offset-1].isNumber && chars[offset+1].isNumber
            if "。．.!?？！\n".contains(c),!decimal,quotes.isEmpty {append()}
        }
        append()
        return values
    }
}
public struct DraftClaimReview:Sendable {
    public let claimID:Int
    public let supported:Bool
    public let citationsRelevant:Bool
    public let qualificationsPreserved:Bool
    public let contradictsSource:Bool
    public let introducesOutsideMaterial:Bool
    public init(claimID:Int,supported:Bool,citationsRelevant:Bool,qualificationsPreserved:Bool,
                contradictsSource:Bool,introducesOutsideMaterial:Bool) {
        self.claimID=claimID;self.supported=supported;self.citationsRelevant=citationsRelevant
        self.qualificationsPreserved=qualificationsPreserved;self.contradictsSource=contradictsSource
        self.introducesOutsideMaterial=introducesOutsideMaterial
    }
}
public struct LocalDraftGroundingReview:Sendable {
    public let answersQuestion:Bool
    public let claims:[DraftClaimReview]
    public init(answersQuestion:Bool,claims:[DraftClaimReview]) {self.answersQuestion=answersQuestion;self.claims=claims}
}
/// Additional rejection gate, not a proof. No sentence may be omitted and
/// the review has no fields that can replace the answer or its source IDs.
public enum DraftGroundingReviewGate {
    public static func accept(_ draft:GuardedLocalDraft,review:LocalDraftGroundingReview) throws -> GuardedLocalDraft {
        if draft.abstained {return draft}
        let expected=DraftClaimIndex.claims(in:draft.text)
        guard (1...8).contains(expected.count),review.answersQuestion,
              review.claims.count == expected.count,
              Set(review.claims.map(\.claimID)) == Set(expected.map(\.id)),
              review.claims.allSatisfy({$0.supported && $0.citationsRelevant && $0.qualificationsPreserved &&
                  !$0.contradictsSource && !$0.introducesOutsideMaterial}) else {throw LocalDraftFailure.groundingReviewFailed}
        return GuardedLocalDraft.withModelReview(draft)
    }
}
