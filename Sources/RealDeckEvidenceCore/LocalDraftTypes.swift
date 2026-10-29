import Foundation

public struct LocalDraftRequest: Sendable {
    public let lease: QuestionLease
    public let question: String
    public let page: Int
    public let title: String
    public let sources: [EvidencePassage]
    public let contextLabels:[String]
    public let createdAt:ContinuousClock.Instant
    public init(ticket: QuestionTicket, reference: EvidenceSearchResult,allowAmbiguousSources:Bool=false) throws {
        guard ticket.confirmed,!ticket.isAwaitingContinuation,LiveQuestionMatcher.permitsQuestion(ticket.text) else {throw LocalDraftFailure.insufficientSources}
        let candidate:EvidenceCandidate
        let selected:[EvidencePassage]
        if ticket.page>0,let exact=reference.candidates.first(where:{$0.page==ticket.page && $0.title==ticket.title}),!exact.passages.isEmpty {
            candidate=exact;selected=exact.passages
        } else if allowAmbiguousSources,reference.disposition == .ambiguous,
                  let first=reference.candidates.first,!first.passages.isEmpty {
            candidate=first
            // Keep whole source passages, preferring qualified speaker notes.
            // Only query-related candidates selected by the index are eligible.
            selected=Array(reference.candidates.compactMap {
                $0.passages.first(where:{$0.source == .speakerNotes}) ?? $0.passages.first
            }.prefix(3))
        } else {throw LocalDraftFailure.insufficientSources}
        guard !selected.isEmpty else {throw LocalDraftFailure.insufficientSources}
        let size=selected.reduce(0){$0+$1.text.utf8.count}
        guard size <= 20_000, ticket.text.count <= 4_000 else { throw LocalDraftFailure.inputLimit }
        lease=ticket.lease;question=ticket.text;page=candidate.page;title=candidate.title;sources=selected
        contextLabels=reference.candidates.filter{c in selected.contains{$0.page==c.page}}.flatMap(\.contextLabels)
        createdAt = .now
    }
    /// Queuing behind an earlier question is not model execution time.
    /// Preserve the exact lease and sources; only start the execution clock.
    func startingExecution(now:ContinuousClock.Instant = .now)->Self {
        Self(lease:lease,question:question,page:page,title:title,sources:sources,contextLabels:contextLabels,createdAt:now)
    }
    private init(lease:QuestionLease,question:String,page:Int,title:String,sources:[EvidencePassage],
                 contextLabels:[String],createdAt:ContinuousClock.Instant) {
        self.lease=lease;self.question=question;self.page=page;self.title=title
        self.sources=sources;self.contextLabels=contextLabels;self.createdAt=createdAt
    }
}

public struct LocalDraftProposal: Sendable {
    public let answer: String
    public let citationIDs: [String]
    public let cannotAnswer: Bool
    public let supportingExcerpt:String?
    public init(answer:String,citationIDs:[String],cannotAnswer:Bool,supportingExcerpt:String?=nil) {
        self.answer=answer;self.citationIDs=citationIDs;self.cannotAnswer=cannotAnswer;self.supportingExcerpt=supportingExcerpt
    }
}
public enum DraftReviewState:String,Sendable,Codable {case surfaceOnly,modelReviewed,unverifiedAfterModelReview}
public struct GuardedLocalDraft: Sendable {
    public let text: String
    public let citations: [EvidencePassage]
    public let abstained: Bool
    public let localModelReviewPassed:Bool
    public let reviewState:DraftReviewState
    public let reviewNote:String
    public let composition:DraftResponseComposition
    public let segments:[DraftResponseSegment]
    public let semanticGroundingVerified = false
    public let humanReviewRequired = true
    fileprivate init(text:String,citations:[EvidencePassage],abstained:Bool,localModelReviewPassed:Bool=false,
                     reviewState:DraftReviewState = .surfaceOnly,reviewNote:String="") {
        self.text=text;self.citations=citations;self.abstained=abstained;self.localModelReviewPassed=localModelReviewPassed
        self.reviewState=reviewState;self.reviewNote=reviewNote
        segments=abstained ? []:DraftSourceAlignment.segments(text,sources:citations)
        let quoted=segments.filter{$0.quotation != nil}.count
        composition=abstained ? .abstention:quoted == segments.count ? .quotedSources:quoted == 0 ? .modelText:.mixed
    }
    static func withModelReview(_ draft:GuardedLocalDraft)->GuardedLocalDraft {
        GuardedLocalDraft(text:draft.text,citations:draft.citations,abstained:draft.abstained,localModelReviewPassed:true,reviewState:.modelReviewed)
    }
    static func withUnverifiedModelReview(_ draft:GuardedLocalDraft,note:String)->GuardedLocalDraft {
        GuardedLocalDraft(text:draft.text,citations:draft.citations,abstained:draft.abstained,
            reviewState:.unverifiedAfterModelReview,reviewNote:note)
    }
}
public enum LocalDraftFailure: Error, Equatable, Sendable {
    case modelUnavailable, modelStillRunning, modelServiceFailed, japaneseUnavailable, insufficientSources, inputLimit,
         invalidCitations, invalidText, verbatimOnly, unsupportedNumbers, qualificationMissing,
         groundingReviewFailed, subjectMismatch, unsupportedTerms, deadlineExceeded, generationFailed,
         questionNotAnswered,unclearResponse,sourceRelationMismatch
    public var message: String {
        switch self {
        case .modelUnavailable: "端末内モデルを利用できません．モデルの取得や外部送信には切り替えません．"
        case .modelStillRunning: "前のモデル処理の終了を確認できないため，新規生成を保留しています．質問の受付と原文表示は続けます．"
        case .modelServiceFailed: "端末内AIのモデルサービスで生成に失敗しました．認識と原文の参照は続けます．"
        case .japaneseUnavailable: "端末内モデルの日本語対応を確認できません．"
        case .insufficientSources: "質問に対応する資料根拠を確定できないため，生成を保留しました．"
        case .inputLimit: "生成へ渡す質問・根拠の上限を超えました．原文の留保を削って続行しません．"
        case .invalidCitations: "生成案の出典を確認できないため，表示を保留しました．"
        case .unsupportedNumbers: "生成案に資料と一致しない数値・単位があるため，表示を保留しました．"
        case .qualificationMissing: "資料の重要な留保を生成案で確認できないため，表示を保留しました．"
        case .invalidText: "生成案の形式を確認できないため，表示を保留しました．"
        case .verbatimOnly: "返された文が原文の写しだけのため，新しい応答案としては表示しません．原文欄で確認できます．"
        case .groundingReviewFailed: "生成案の主張と出典の対応を確認できないため，表示を保留しました．"
        case .subjectMismatch: "生成案の判断主体を出典に対応づけられないため，表示を保留しました．"
        case .sourceRelationMismatch: "生成案で主語と対象の対応が原文の別の主語の対応へ入れ替わっているため，表示を保留しました．"
        case .unsupportedTerms: "生成案の内容語を引用した原文に対応づけられないため，表示を保留しました．有効な言い換えも保留される場合があります．"
        case .deadlineExceeded: "生成と根拠照合の時間上限を超えた案は表示しません．モデル実行の終了確認とは区別します．"
        case .generationFailed: "端末内の新規生成を完了できませんでした．原文引用とは別の失敗です．"
        case .questionNotAnswered:"関連する説明はありますが，質問へ直接答えていることを確認できないため保留しました．"
        case .unclearResponse:"応答案の文のつながりや指示語を確認できないため保留しました．"
        }
    }
}

public enum LocalDraftDeadline {
    public static func requireValid(createdAt:ContinuousClock.Instant,now:ContinuousClock.Instant = .now) throws {
        guard createdAt.duration(to:now) <= .seconds(12) else {throw LocalDraftFailure.deadlineExceeded}
    }
}

@MainActor public protocol LocalDraftGenerating: AnyObject {
    func prepare() async
    func generate(_ request: LocalDraftRequest) async throws -> GuardedLocalDraft
}
public extension LocalDraftGenerating {
    func prepare() async {}
}

/// Surface checks do not prove semantic entailment. The generated text remains
/// visibly separate from its exact sources and always requires human review.
public enum DraftSurfaceValidator {
    public static func validate(_ proposal:LocalDraftProposal, request:LocalDraftRequest) throws -> GuardedLocalDraft {
        if proposal.cannotAnswer {
            return GuardedLocalDraft(text:"この質問に答えるには資料の根拠が足りません．確認が必要です．",citations:[],abstained:true)
        }
        let text=proposal.answer.trimmingCharacters(in:.whitespacesAndNewlines)
        guard (8...900).contains(text.count), text.last.map({"。．.!！?？".contains($0)}) == true,
              !["```","<script","javascript:","sk-","Bearer "].contains(where:text.contains) else {throw LocalDraftFailure.invalidText}
        let ids=Set(proposal.citationIDs)
        guard (1...3).contains(ids.count),ids.count == proposal.citationIDs.count,
              ids.isSubset(of:Set(request.sources.map(\.id))) else {throw LocalDraftFailure.invalidCitations}
        let cited=request.sources.filter{ids.contains($0.id)}
        let sourceText=cited.map(\.text).joined(separator:"\n")
        guard numbers(in:text).isSubset(of:numbers(in:sourceText)) else {throw LocalDraftFailure.unsupportedNumbers}
        guard numericClaims(in:text).isSubset(of:numericClaims(in:sourceText)) else {throw LocalDraftFailure.unsupportedNumbers}
        try DraftSubjectConsistency.requireCompatible(question:request.question,answer:text,citedSources:cited)
        try DraftRelationConsistency.requireCompatible(answer:text,citedSources:cited)
        try DraftCertaintyConsistency.requireCompatible(answer:text,citedSources:cited)
        let qualifierMarkers=["という意味ではありません","未承認","未確定","未検証","計画段階"]
        let criticalNotes=request.sources.filter {source in
            source.source == .speakerNotes && qualifierMarkers.contains(where:source.text.contains)
        }
        guard criticalNotes.allSatisfy({ids.contains($0.id)}) else {throw LocalDraftFailure.invalidCitations}
        let qualified=qualifierMarkers.contains(where:request.sources.map(\.text).joined(separator:"\n").contains)
        if qualified && !["未","まだ","ではありません","ではない","確認が必要","計画","予定","留保","断定できません","断定できない","確認できません","確認できない","判断できません","判断できない","確定できません","確定できない","言えません","言えない","言い切れません","言い切れない","分かりません","わかりません"].contains(where:text.contains) {
            throw LocalDraftFailure.qualificationMissing
        }
        return GuardedLocalDraft(text:text,citations:cited,abstained:false)
    }

    public static func numbers(in text:String) -> Set<String> {
        let normalized=text.precomposedStringWithCompatibilityMapping.replacingOccurrences(of:"−",with:"-")
        let patterns=[#"[+-]?[0-9]+(?:[.,][0-9]+)*"#,
                      #"[〇零一二三四五六七八九十百千万億兆]+(?:円|年|月|日|名|人|組織|期|件|秒|回|枚|倍|割)"#]
        return Set(patterns.flatMap { pattern in
            let regex=try! NSRegularExpression(pattern:pattern)
            return regex.matches(in:normalized,range:NSRange(normalized.startIndex...,in:normalized)).compactMap {
                Range($0.range,in:normalized).map{String(normalized[$0]).replacingOccurrences(of:",",with:"")}
            }
        })
    }

    public static func numericClaims(in text:String)->Set<String> {
        let value=text.precomposedStringWithCompatibilityMapping.lowercased().replacingOccurrences(of:"−",with:"-")
        let patterns = [#"[$€£¥]\s*[+-]?[0-9]+(?:[.,][0-9]+)*"#,
            #"(?:[+-]?[0-9]+(?:[.,][0-9]+)*|[〇零一二三四五六七八九十百千万億兆]+)\s*(?:兆円|億円|万円|千円|組織|機関|人月|人年|年代|年度|時間|円|年|月|日|名|人|期|件|秒|分|回|枚|倍|割|%|(?:kg|km|mm|cm|ml|hz|°c|g|m|l)(?![a-z])|[\p{Han}\p{Katakana}a-z%°]+)"#]
        return Set(patterns.flatMap {pattern in
            let regex=try! NSRegularExpression(pattern:pattern)
            return regex.matches(in:value,range:NSRange(value.startIndex...,in:value)).compactMap {
                Range($0.range,in:value).map{String(value[$0]).replacingOccurrences(of:#"[\s,]+"#,with:"",options:.regularExpression)}
            }
        })
    }

    public static func isExtractiveOnly(_ answer:String,sources:[String])->Bool {
        func plain(_ value:String)->String {
            value.precomposedStringWithCompatibilityMapping.lowercased().replacingOccurrences(of:#"[\p{P}\s]+"#,with:"",options:.regularExpression)
        }
        let original=sources.map(plain),value=plain(answer)
        guard !value.isEmpty else {return true}
        if original.contains(where:{$0.contains(value)}) {return true}
        let statements=DraftClaimIndex.claims(in:answer).map{plain($0.text)}.filter{!$0.isEmpty}
        if !statements.isEmpty,statements.allSatisfy({sentence in original.contains{$0.contains(sentence)}}) {return true}
        for a in original.indices {
            for b in original.indices where b != a {
                if (original[a]+original[b]).contains(value) {return true}
                for c in original.indices where c != a && c != b {
                    if (original[a]+original[b]+original[c]).contains(value) {return true}
                }
            }
        }
        return false
    }
}
