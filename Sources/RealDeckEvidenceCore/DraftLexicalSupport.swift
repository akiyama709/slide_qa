import Foundation

/// A conservative novelty filter, not entailment. It can withhold a valid
/// paraphrase; matching vocabulary does not establish a statement's truth.
public enum DraftLexicalSupport {
    private static let connectiveTerms:Set<String>=[
        "最終", "最終的", "行い", "行う", "行います", "明記", "記述", "述べ", "示し", "示す", "指し", "指す",
        "原文", "本文", "出典", "資料", "結論", "回答", "必要", "不明", "有無", "範囲", "述べる", "いえ", "言え",
        "といえ", "と言え", "言い切れ", "言い切る", "とれる", "なる", "なり", "られる", "され", "なっ", "とおり", "一方", "つまり", "断定", "断言"
    ]
    public static func unknownTerms(answer:String,citedSources:[EvidencePassage],contextLabels:[String]=[])->Set<String> {
        let source=citedSources.map(\.text).joined(separator:"\n")
        var allowed=EvidenceIndex.words(source).union(connectiveTerms)
        // Exact page/navigation labels establish terminology, never facts.
        for label in contextLabels {allowed.formUnion(EvidenceIndex.words(label))}
        let compact=source.replacingOccurrences(of:#"\s+"#,with:"",options:.regularExpression)
        if source.contains("自ら") || source.contains("自分") {allowed.formUnion(["自身","自分","自ら"])}
        // Narrow source-conditioned paraphrases, not an unconditional list of
        // new factual terms. Scope, negation and certainty still need review.
        if compact.contains("確かめ") {allowed.formUnion(["確かめる","検証","確認"])}
        if compact.contains("捉え") {allowed.insert("捉える")}
        if compact.contains("大切") {allowed.insert("重視")}
        if compact.contains("使い") || compact.contains("用い") || compact.contains("活用") {allowed.insert("使う")}
        if compact.contains("ほかの存在") {allowed.insert("他者")}
        return EvidenceIndex.words(answer).subtracting(allowed)
    }
    public static func requireCompatible(answer:String,citedSources:[EvidencePassage],contextLabels:[String]=[]) throws {
        guard unknownTerms(answer:answer,citedSources:citedSources,contextLabels:contextLabels).isEmpty else {throw LocalDraftFailure.unsupportedTerms}
    }
}
