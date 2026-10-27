import Foundation

/// A conservative rejection rule for administrative-status answers. A note
/// disclaiming proof of approval does not itself prove non-approval.
public enum DraftCertaintyConsistency {
    public static func requireCompatible(answer:String,citedSources:[EvidencePassage]) throws {
        func plain(_ text:String)->String {
            text.precomposedStringWithCompatibilityMapping.replacingOccurrences(of:#"\s+"#,with:"",options:.regularExpression)
        }
        let source=plain(citedSources.map(\.text).joined(separator:"\n")),reply=plain(answer)
        guard ["合意","承認","受理"].contains(where:source.contains),
              ["という意味ではありません","という意味ではない","確認できません","確認できない","未確認"].contains(where:source.contains) else {return}
        let assertions=["合意は得られていない","合意が得られていない","合意は得られていません","合意が得られていません",
            "合意はない","合意がない","合意はありません","合意がありません","承認されていない","承認されていません",
            "承認は得られていない","承認は得られていません","受理されていない","受理されていません",
            "合意は得られています","合意が得られています","合意はあります","合意があります",
            "承認されています","承認済みです","受理されています","受理済みです"]
        func ranges(_ text:String,_ assertion:String)->[Range<String.Index>] {
            let regex=try! NSRegularExpression(pattern:NSRegularExpression.escapedPattern(for:assertion))
            return regex.matches(in:text,range:NSRange(text.startIndex...,in:text)).compactMap{Range($0.range,in:text)}
        }
        func isEpistemic(_ suffix:String)->Bool {
            let pattern=#"^[」』”\"]*(?:と(?:は)?)?(?:(?:断定|判断|確認)(?:は)?(?:できません|できない)|言えません|言えない|言い切れません|言い切れない)"#
            return suffix.range(of:pattern,options:.regularExpression) != nil
        }
        func sourceAffirms(_ assertion:String)->Bool {
            ranges(source,assertion).contains {range in
                let before=source[..<range.lowerBound]
                let opens:[Character:Character]=["「":"」","『":"』","“":"”"]
                var closing:[Character]=[]
                for char in before {
                    if let close=opens[char] {closing.append(close)}
                    else if closing.last == char {closing.removeLast()}
                    else if char == "\"" {if closing.last == char {closing.removeLast()} else {closing.append(char)}}
                }
                if !closing.isEmpty {return false}
                let suffix=String(source[range.upperBound...])
                let denial=#"^[」』”\"]*(?:という|との)?(?:意味|こと|説明|記述)(?:で)?は(?:ありません|ない|誤り|間違い)"#
                return !isEpistemic(suffix) && suffix.range(of:denial,options:.regularExpression) == nil
            }
        }
        for assertion in assertions where reply.contains(assertion) && !sourceAffirms(assertion) {
            for range in ranges(reply,assertion) {
                guard isEpistemic(String(reply[range.upperBound...])) else {throw LocalDraftFailure.qualificationMissing}
            }
        }
    }
}
