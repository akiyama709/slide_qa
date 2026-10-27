import Foundation
import RealDeckEvidenceCore

/// Query-shape guidance only. It adds no answer facts or source assertions.
enum LocalQuestionIntent {
    static func requireSurfaceResponse(question:String,answer:String) throws {
        // Reject a missing answer form; this is not a factual validator.
        let targets=comparisonTargets(question)
        if targets.count == 2,!(["誰","だれ","どなた"].contains(where:question.contains)),
           ["違","異な","相違"].contains(where:question.contains) {
            let markers=["違","異な","区別","一方","対し","特に","重視","大切","特徴","焦点","今回は","ここでは","同じでは","同じでない"]
            let explicitClauses=targets.count == 2 && targets.allSatisfy {target in
                answer.contains(target+"は") || answer.contains(target+"では") || answer.contains(target+"が")
            }
            guard explicitClauses || markers.contains(where:answer.contains) else {throw LocalDraftFailure.questionNotAnswered}
        }
        // Pronouns may resolve against the recognized question. The model's
        // separate language/reference check decides that using both texts.
    }
    static func comparisonTargets(_ question:String)->[String] {
        guard ["違","異な","同じ","共通","区別"].contains(where:question.contains) else {return[]}
        let pattern=#"^([^。．！？?]{1,50}?)と([^。．！？?]{1,50}?)(?:は|の)(?:[^。．！？?]{0,16})(?:違|異な|同じ|共通|区別)"#
        let regex=try! NSRegularExpression(pattern:pattern)
        guard let match=regex.firstMatch(in:question,range:NSRange(question.startIndex...,in:question)) else {return[]}
        return (1...2).compactMap{Range(match.range(at:$0),in:question).map{String(question[$0])}}
    }
    static func responseRequirement(_ question:String)->String {
        if ["誰","だれ","どなた"].contains(where:question.contains) {return "資料にある担当者や役割を直接答え，別の主体に入れ替えない．"}
        if ["違","異な","同じ","共通","区別"].contains(where:question.contains) {return "質問の比較対象と，原文に明記された関係を保って答える．共通点を相違点に変えない．"}
        if ["いつ","何日","何回","いくら"].contains(where:question.contains) {return "資料にある時点・数量・単位・条件を保って答える．"}
        if ["なぜ","理由","根拠"].contains(where:question.contains) {return "原文にある理由だけを答える．理由を創作しない．"}
        return "質問の対象と条件へ直接答える．資料から答えられない範囲は未確認とし，外部知識で補わない．"
    }
}
