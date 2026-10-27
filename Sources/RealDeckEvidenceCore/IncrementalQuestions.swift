// Adapted from Phase2 IncrementalQuestions; real-deck matcher replaces the fictional-deck adapter.
import Foundation
import SlideQACore

/// Identity belongs to the audio turn and question position, never to response arrival order.
/// A new revision/epoch invalidates every callback belonging to the previous lease.
public struct QuestionLease: Codable, Hashable, Sendable {
    public let epoch: Int
    public let id: String
    public let revision: Int
}
public struct QuestionTicket: Codable, Sendable {
    public let lease: QuestionLease
    public let turnID: String
    public let turnOrder: Int
    public let position: Int
    public let text: String
    public let page: Int
    public let title: String
    public var confirmed: Bool
    /// nil in legacy tickets. A VAD turn ending is not proof the question ended.
    public var awaitingContinuation: Bool? = nil
    public var isAwaitingContinuation: Bool { awaitingContinuation == true }
}
public enum QuestionChange: Sendable {
    case upsert(QuestionTicket)
    /// Display-only clarification of the same explicit binary choice. No new
    /// generation, lease, or first-response timing is created.
    case refined(QuestionTicket)
    case retract(QuestionLease)
    case confirmed(QuestionLease)
    case phase(LiveSpeakingPhase)
}
public enum QuestionPipelineFailure: Error { case conflictingTurnOrder, invalidOrder, invalidRevision, inputLimit }

public struct IncrementalQuestions: Sendable {
    private struct Turn: Sendable {
        var id:String;var order:Int;var text:String;var final:Bool
        var sourceRevision:Int?;var sourceEnd:Double?
    }
    private struct ChoiceBoundary:Sendable {
        var order:Int;var id:String;var fragment:String;var allFinal:Bool;var baseFinal:Bool
    }
    private struct QuestionOrigin:Hashable,Sendable {var turnOrder:Int;var position:Int}
    private var initialPhase: LiveSpeakingPhase
    public private(set) var phase: LiveSpeakingPhase
    public private(set) var epoch = 0
    private var turns: [String: Turn] = [:]
    private var current: [String: QuestionTicket] = [:]
    private var currentOrigins:[String:QuestionOrigin]=[:]
    private var revisions: [String: Int] = [:]
    private var revisionOrigins:[String:Int]=[:]
    private var retiredThroughOrder = -1
    private var identitiesByOrigin:[QuestionOrigin:String]=[:]
    private var correctionTargets:[Int:QuestionTicket]=[:]
    private var cancellationTargets:[Int:String]=[:]
    public init(phase: LiveSpeakingPhase) { initialPhase = phase; self.phase = phase }
    public var tickets: [QuestionTicket] { current.values.sorted(by: Self.ordered) }
    /// Includes temporarily absent ASR questions until their source turn is
    /// permanently retired. UI cancellation must outlive an unstable snapshot.
    public var retainedSourceQuestionIDs:Set<String> {Set(identitiesByOrigin.values)}
    public func isCurrent(_ lease: QuestionLease) -> Bool { current[lease.id]?.lease == lease }
    private static func ordered(_ a: QuestionTicket, _ b: QuestionTicket) -> Bool {
        (a.turnOrder, a.position) < (b.turnOrder, b.position)
    }
    /// The adapter must supply source turn order; first response arrival is not a source clock.
    public mutating func consume(turnID: String, order: Int, text: String, final: Bool,
                                 deck: LiveQuestionDeck,sourceRevision:Int?=nil,sourceEnd:Double?=nil) throws -> [QuestionChange] {
        guard (0..<1_000_000).contains(order) else { throw QuestionPipelineFailure.invalidOrder }
        if order<=retiredThroughOrder {return []}
        guard text.utf8.count <= 16_384 else { throw QuestionPipelineFailure.inputLimit }
        guard !turns.values.contains(where: { $0.order == order && $0.id != turnID }),
              turns[turnID].map({ $0.order == order }) ?? true else { throw QuestionPipelineFailure.conflictingTurnOrder }
        if let sourceRevision {
            guard (0..<1_000_000).contains(sourceRevision),let sourceEnd,sourceEnd.isFinite,sourceEnd>=0 else {throw QuestionPipelineFailure.invalidRevision}
        }
        if turns[turnID] == nil,turns.count>=64 {
            guard let oldest=turns.values.min(by:{$0.order<$1.order}),oldest.final,
                  order>oldest.order else {throw QuestionPipelineFailure.inputLimit}
            turns.removeValue(forKey:oldest.id)
            retiredThroughOrder=max(retiredThroughOrder,oldest.order)
            identitiesByOrigin=identitiesByOrigin.filter{$0.key.turnOrder>retiredThroughOrder}
            correctionTargets=correctionTargets.filter{$0.key>retiredThroughOrder}
            cancellationTargets=cancellationTargets.filter{$0.key>retiredThroughOrder}
            initialPhase=phase
        }
        let highWaterEnd:Double?
        if let sourceEnd {highWaterEnd=max(sourceEnd,turns[turnID]?.sourceEnd ?? sourceEnd)}
        else {highWaterEnd=turns[turnID]?.sourceEnd}
        if let old = turns[turnID] {
            if let sourceRevision {
                if let previous=old.sourceRevision,sourceRevision<=previous {
                    if sourceRevision == previous && (old.text != text || old.final != final) {throw QuestionPipelineFailure.invalidRevision}
                    return []
                }
                // Native fragment-final is not a sealed audio turn. Accept a
                // subsequent partial only when its source audio end advanced.
                if old.final && !final {
                    guard let previousEnd=old.sourceEnd,let sourceEnd,sourceEnd>previousEnd+0.00001 else {return []}
                }
            } else {
                if old.sourceRevision != nil || (old.final && !final) {return []}
            }
            if old.text == text && old.final == final {
                turns[turnID]=Turn(id:turnID,order:order,text:text,final:final,sourceRevision:sourceRevision,sourceEnd:highWaterEnd)
                return []
            }
        }
        turns[turnID] = Turn(id:turnID,order:order,text:text,final:final,sourceRevision:sourceRevision,sourceEnd:highWaterEnd)
        var nextPhase = initialPhase
        var desired: [String: QuestionTicket] = [:]
        var desiredOrigins:[String:QuestionOrigin]=[:]
        var previousBoundary:ChoiceBoundary?
        var previousCorrection:(order:Int,anchor:QuestionTicket)?
        for turn in turns.values.sorted(by: { $0.order < $1.order }) {
            var body=turn.text
            if nextPhase == .presentation {
                guard turn.final,let after=QuestionBoundaries.afterClosingCue(body) else {continue}
                nextPhase = .qna;body=after
            }
            if nextPhase == .answering { continue }
            if turn.final,QuestionBoundaries.hasExplicitCancellationLeading(body),
               let target=cancellationTargets[turn.order] ?? desired.values.max(by:Self.ordered)?.lease.id {
                cancellationTargets[turn.order]=target
                desired.removeValue(forKey:target)
                desiredOrigins.removeValue(forKey:target)
                previousBoundary=nil;previousCorrection=nil
            }
            let candidates=QuestionBoundaries.completeQuestions(body,final:turn.final,deck:deck)
            guard candidates.count<=16 else {throw QuestionPipelineFailure.inputLimit}
            var consumedFirst:String?,nextBoundary:ChoiceBoundary?,correctedAnchor:QuestionTicket?
            if let waiting=previousCorrection,waiting.order+1==turn.order,
               !QuestionBoundaries.hasIndependentIntroduction(body),!body.contains("「"),!body.contains("『") {
                correctedAnchor=waiting.anchor
            }
            // An explicit adjacent correction declaration also applies to
            // ordinary real-deck questions, not only automatic/manual choices.
            // Bare "no" or a quoted correction is not authority to retract.
            if correctedAnchor == nil,QuestionBoundaries.hasExplicitCorrectionLeading(body) {
                let anchor=correctionTargets[turn.order] ??
                    desired.values.filter({desiredOrigins[$0.lease.id]?.turnOrder == turn.order-1}).max(by:Self.ordered)
                if let anchor {
                    correctionTargets[turn.order]=anchor
                    desired.removeValue(forKey:anchor.lease.id)
                    desiredOrigins.removeValue(forKey:anchor.lease.id)
                    correctedAnchor=anchor
                }
            }
            if let boundary=previousBoundary,boundary.order+1==turn.order,
               var anchor=desired[boundary.id],anchor.page != 0,
               let first=QuestionBoundaries.leadingFragment(body) {
                switch QuestionBoundaries.crossTurnRelation(anchor:anchor.text,accumulated:boundary.fragment,first:first) {
                case .pending(let fragment):
                    anchor.awaitingContinuation=true;anchor.confirmed=false;desired[boundary.id]=anchor
                    consumedFirst=first
                    if QuestionBoundaries.fingerprint(body)==QuestionBoundaries.fingerprint(first) {
                        nextBoundary=ChoiceBoundary(order:turn.order,id:boundary.id,fragment:fragment,
                            allFinal:boundary.allFinal && turn.final,baseFinal:boundary.baseFinal)
                    }
                case .complete(let combined):
                    if let slide=LiveQuestionMatcher.match(combined,deck:deck),slide.number==anchor.page,slide.title==anchor.title {
                        anchor=QuestionTicket(lease:anchor.lease,turnID:anchor.turnID,turnOrder:anchor.turnOrder,
                            position:anchor.position,text:combined,page:anchor.page,title:anchor.title,
                            confirmed:boundary.allFinal && turn.final)
                        desired[boundary.id]=anchor
                        consumedFirst=first
                    }
                case .independent(let release):
                    if release {anchor.awaitingContinuation=nil;anchor.confirmed=boundary.baseFinal;desired[boundary.id]=anchor}
                case .changed:
                    desired.removeValue(forKey:boundary.id);desiredOrigins.removeValue(forKey:boundary.id);correctedAnchor=anchor
                }
            }
            var lastID:String?
            for (position,candidate) in candidates.enumerated() {
                if position==0,let consumedFirst,
                   QuestionBoundaries.fingerprint(consumedFirst)==QuestionBoundaries.fingerprint(candidate.text) {continue}
                let replacement=position==0 ? correctedAnchor:nil
                let origin=QuestionOrigin(turnOrder:turn.order,position:position)
                // A correction may retain an older turn's ID. Keep the ID
                // already bound to its source origin when that older turn
                // leaves the history window; otherwise a UI cancellation
                // could be defeated by inventing a new ID for the same input.
                let establishedID=identitiesByOrigin[origin]
                let id=establishedID ?? replacement?.lease.id ?? String(format:"e%d-t%06d-q%03d",epoch,turn.order,position+1)
                identitiesByOrigin[origin]=id
                // A correction is a new source intent even when its words are
                // unchanged. The stable source origin prevents replaying that
                // same correction snapshot from consuming another revision.
                let old=current[id]
                let same=currentOrigins[id]==origin && (old.map {QuestionBoundaries.sameQuestion($0.text,candidate.text)
                    && $0.page==(candidate.slide?.number ?? 0) && $0.title==(candidate.slide?.title ?? "該当なし")} ?? false
                )
                let revision=same ? old!.lease.revision:(revisions[id] ?? 0)+1
                var ticket=QuestionTicket(lease:QuestionLease(epoch:epoch,id:id,revision:revision),
                    turnID:replacement?.turnID ?? turn.id,turnOrder:replacement?.turnOrder ?? turn.order,
                    position:replacement?.position ?? position,text:candidate.text,
                    page:candidate.slide?.number ?? 0,title:candidate.slide?.title ?? "該当なし",confirmed:turn.final)
                // A disappearing/unknown prefix is not authority to redisplay a
                // withheld answer. Only the closed bridge or clear new intent releases it.
                if same,replacement==nil,old?.isAwaitingContinuation==true {
                    ticket.awaitingContinuation=true;ticket.confirmed=false
                }
                desired[id]=ticket;desiredOrigins[id]=origin;lastID=id
            }
            if let anchor=correctedAnchor,QuestionBoundaries.isCorrectionOnly(body) {
                previousCorrection=(turn.order,anchor)
            } else {previousCorrection=nil}
            if let nextBoundary {previousBoundary=nextBoundary}
            else if let lastID,let last=desired[lastID],QuestionBoundaries.mayAnchorChoice(last.text),
                    QuestionBoundaries.isPureQuestionSequence(body,candidates:candidates,consumedFirst:consumedFirst) {
                previousBoundary=ChoiceBoundary(order:turn.order,id:lastID,fragment:"",allFinal:turn.final,baseFinal:turn.final)
            } else {previousBoundary=nil}
        }
        // Publish revision history only for tickets surviving the whole source
        // snapshot, not temporary anchors removed by a later correction.
        for next in desired.values {
            revisions[next.lease.id]=max(revisions[next.lease.id] ?? 0,next.lease.revision)
            revisionOrigins[next.lease.id]=max(revisionOrigins[next.lease.id] ?? -1,desiredOrigins[next.lease.id]?.turnOrder ?? next.turnOrder)
        }
        let retiredIDs=revisionOrigins.filter{$0.value<=retiredThroughOrder && desired[$0.key] == nil}.map(\.key)
        for id in retiredIDs {revisionOrigins.removeValue(forKey:id);revisions.removeValue(forKey:id)}
        var changes: [QuestionChange] = []
        // Retractions precede replacements, so an obsolete stream cannot write into its replacement.
        for old in tickets where desired[old.lease.id]?.lease != old.lease { changes.append(.retract(old.lease)) }
        for next in desired.values.sorted(by: Self.ordered) {
            if current[next.lease.id]?.lease != next.lease { changes.append(.upsert(next)) }
            else if current[next.lease.id]?.text != next.text
                || current[next.lease.id]?.isAwaitingContinuation != next.isAwaitingContinuation
                || (current[next.lease.id]?.confirmed==true && !next.confirmed) { changes.append(.refined(next)) }
            else if next.confirmed && current[next.lease.id]?.confirmed == false { changes.append(.confirmed(next.lease)) }
        }
        current = desired;currentOrigins=desiredOrigins
        if nextPhase != phase { phase = nextPhase; changes.append(.phase(phase)) }
        return changes
    }
    @discardableResult public mutating func restart() -> [QuestionChange] {
        let changes = tickets.map { QuestionChange.retract($0.lease) }
        epoch += 1; turns = [:]; current = [:]; currentOrigins=[:];revisions = [:];revisionOrigins=[:];identitiesByOrigin=[:];correctionTargets=[:];cancellationTargets=[:];retiredThroughOrder = -1; phase = initialPhase
        return changes + [.phase(phase)]
    }
    @discardableResult public mutating func changePhase(to value:LiveSpeakingPhase) -> [QuestionChange] {
        initialPhase=value
        return restart()
    }
}

public enum QuestionBoundaries {
    static func hasExplicitCancellationLeading(_ text:String)->Bool {
        let value=withoutQuotes(text).trimmingCharacters(in:.whitespacesAndNewlines)
        return value.range(of:#"^(?:(?:すみません|失礼しました)[、，,\s]*)?(?:今の|直前の|先ほどの|この)質問(?:を|は)(?:取り消します|取消します|取り下げます|キャンセルします)(?:[。．、，,!！\s]|$)"#,options:.regularExpression) != nil
    }
    static func fingerprint(_ text: String) -> String {
        text.precomposedStringWithCompatibilityMapping.replacingOccurrences(of: "[\\s、，,。．?!？！]", with: "", options: .regularExpression)
    }
    private static func trimEnd(_ text:String)->String {
        text.trimmingCharacters(in:.whitespacesAndNewlines.union(CharacterSet(charactersIn:"。．？！?!")))
    }
    /// Deliberately limited to the observed automatic/manual contrast. A new
    /// subject, action, correction or independent-question marker cannot match.
    static func joinChoice(_ anchor:String,_ fragment:String)->String? {
        let base=trimEnd(anchor),tail=trimChoiceTail(fragment)
        guard !["「","『","“","言い直","訂正","いえ","何","どれ","どう","なぜ","いつ","どこ","誰","いくら","いくつ","どの"].contains(where:base.contains),
              let subject=base.firstIndex(where:{"はが".contains($0)}),subject>base.startIndex else { return nil }
        for (first,second) in [("自動","手動"),("手動","自動")] {
            guard base.contains(first),!base.contains(second),
                  base.hasSuffix(first+"ですか") || base.hasSuffix(first+"でしょうか") else { continue }
            if tail.range(of:"^(?:それとも\\s*)?"+second+"(?:ですか|でしょうか)$",options:.regularExpression) != nil {
                return base+"，"+tail
            }
        }
        return nil
    }
    private static func trimChoiceTail(_ text:String)->String {
        trimEnd(text).trimmingCharacters(in:.whitespacesAndNewlines.union(CharacterSet(charactersIn:"、，,")))
    }
    /// Keep a completed scoped anchor while only the closed opposite-choice
    /// grammar is arriving. This is lexical evidence, never same-page semantic
    /// equivalence, and it does not retain a question after arbitrary deletion.
    // The alternative connective 「それとも」 is not the independent marker 「それと」.
    private static let independentIntroductions=["それともう一点","もう一点","次に","続いて","それと"]
    private static func beginsIndependentQuestion(_ text:String,allowIncomplete:Bool=false)->Bool {
        if independentIntroductions.contains(where:{text.hasPrefix($0) && !($0=="それと" && text.hasPrefix("それとも"))}) {return true}
        // Only a known compound marker may bridge the ambiguous partial
        // 「それともう…」. Final unfinished text does not receive this bridge.
        return allowIncomplete && !text.isEmpty && "それともう一点".hasPrefix(text)
    }
    private static func hasClosedChoiceContinuation(_ anchor:String,_ rest:String,allowIncomplete:Bool)->Bool {
        let tail=rest.trimmingCharacters(in:.whitespacesAndNewlines.union(CharacterSet(charactersIn:"、，,"))).replacingOccurrences(of:"^それとも\\s*",with:"それとも",options:.regularExpression)
        guard !tail.isEmpty else {return false}
        for opposite in ["自動","手動"] {
            for intro in ["","それとも"] {
                for ending in ["ですか","でしょうか"] {
                    let phrase=intro+opposite+ending
                    guard joinChoice(anchor,phrase) != nil else {continue}
                    if phrase==tail || (allowIncomplete && phrase.hasPrefix(tail)) {return true}
                    if tail.hasPrefix(phrase) {
                        let after=String(tail.dropFirst(phrase.count))
                        if let first=after.first,"。．？！?!\n".contains(first) {return true}
                        if beginsIndependentQuestion(after,allowIncomplete:allowIncomplete) {return true}
                    }
                }
            }
        }
        return false
    }
    /// Only an adjacent final raw fragment inside this same turn. A complete
    /// second question, new subject or arbitrary unknown text is never folded.
    private static func isUnfinishedClosedChoice(_ anchor:String,_ fragment:String)->Bool {
        let tail=trimChoiceTail(fragment).replacingOccurrences(of:"^それとも\\s*",with:"それとも",options:.regularExpression)
        guard !tail.isEmpty else {return false}
        for opposite in ["自動","手動"] {
            for intro in ["","それとも"] {
                for ending in ["ですか","でしょうか"] {
                    let phrase=intro+opposite+ending
                    if phrase != tail,phrase.hasPrefix(tail),joinChoice(anchor,phrase) != nil {return true}
                }
            }
        }
        return false
    }
    private static func choiceBase(_ text:String)->String {
        let value=trimEnd(text)
        // Incremental ASR can remove a comma before an elliptical second
        // choice. Only this closed automatic/manual grammar is equivalent;
        // same-page matches, repeated subjects and changed premises are not.
        guard let suffix=value.range(of:"[、，,\\s]*(?:それとも\\s*)?(?:自動|手動)(?:ですか|でしょうか)$",options:.regularExpression) else { return value }
        let base=String(value[..<suffix.lowerBound]),tail=trimChoiceTail(String(value[suffix.lowerBound...]))
        guard let combined=joinChoice(base,tail),fingerprint(combined)==fingerprint(value) else { return value }
        return base
    }
    static func sameQuestion(_ a:String,_ b:String)->Bool {
        fingerprint(a)==fingerprint(b) || fingerprint(choiceBase(a))==fingerprint(choiceBase(b))
    }
    static func firstChoiceFragment(_ text:String)->String? {
        guard let first=split(text,final:true).first else { return nil }
        let value=trimEnd(first)
        return value.range(of:"^(?:それとも\\s*)?(?:自動|手動)(?:ですか|でしょうか)$",options:.regularExpression) == nil ? nil:value
    }
    enum CrossTurnRelation {case pending(String),complete(String),independent(Bool),changed}
    static func hasIndependentIntroduction(_ text:String)->Bool {
        beginsIndependentQuestion(text.trimmingCharacters(in:.whitespacesAndNewlines))
    }
    static func hasExplicitCorrectionLeading(_ text:String)->Bool {
        guard !["「","『","“","\""].contains(where:text.contains) else {return false}
        let compact=text.trimmingCharacters(in:.whitespacesAndNewlines)
            .replacingOccurrences(of:"[、，,。．？！?!\\s]",with:"",options:.regularExpression)
        return ["言い直します","訂正します","いえ言い直します","いいえ言い直します","いえ訂正します","いいえ訂正します"].contains(where:compact.hasPrefix)
    }
    static func isCorrectionOnly(_ text:String)->Bool {
        let compact=text.replacingOccurrences(of:"[、，,。．？！?!\\s]",with:"",options:.regularExpression)
        return ["言い直します","訂正します","いえ言い直します","いいえ言い直します","いえ訂正します","いいえ訂正します"].contains(compact)
    }
    static func leadingFragment(_ text:String)->String? {
        split(text,final:true).first(where:{!$0.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty}).map(trimChoiceTail)
    }
    private static func choiceForms(_ anchor:String)->[String] {
        ["自動","手動"].flatMap { word in ["","それとも"].flatMap { intro in ["ですか","でしょうか"].map{intro+word+$0} } }
            .filter{joinChoice(anchor,$0) != nil}
    }
    static func mayAnchorChoice(_ text:String)->Bool { !choiceForms(text).isEmpty }
    private static func normalizeBridge(_ text:String)->String {
        trimChoiceTail(text).precomposedStringWithCompatibilityMapping
            .replacingOccurrences(of:"^それとも\\s*",with:"それとも",options:.regularExpression)
    }
    private static func ownsAlternative(_ text:String)->Bool {
        text.hasPrefix("それとも") || ["自動","手動"].contains(where:text.hasPrefix)
    }
    static func crossTurnRelation(anchor:String,accumulated:String,first:String)->CrossTurnRelation {
        let raw=normalizeBridge(first),previous=normalizeBridge(accumulated),joined=normalizeBridge(previous+raw)
        guard !["「","『","“","」","』","”"].contains(where:first.contains) else {return .independent(previous.isEmpty)}
        if ["いえ、","いえ，","いえ,","いいえ、","いいえ，","言い直します","訂正します"].contains(where:raw.hasPrefix) {return .changed}
        let forms=choiceForms(anchor)
        if forms.contains(joined),let combined=joinChoice(anchor,joined) {return .complete(combined)}
        if !joined.isEmpty,forms.contains(where:{$0.hasPrefix(joined)}) {return .pending(joined)}
        if joined.hasPrefix("それともう一点") {return .independent(true)}
        if !joined.isEmpty,"それともう一点".hasPrefix(joined) {return .pending(joined)}
        let premise=joined.range(of:"^(?:それとも)?(?:自動|手動)(?:では|でも|なら|で[0-9一二三四五六七八九十]|ですかでは)",options:.regularExpression) != nil
        if premise {return .changed}
        let scoped=(!ownsAlternative(raw) ? raw.firstIndex(where:{"はが".contains($0)}).map{$0>raw.startIndex}:nil) ?? false
        let action=["自動の","手動の"].contains(where:raw.hasPrefix)
        if beginsIndependentQuestion(raw,allowIncomplete:true) || scoped || action {
            return .independent(previous.isEmpty)
        }
        if joined.hasPrefix("それとも") || premise || (!previous.isEmpty && ownsAlternative(previous)) {return .changed}
        return .independent(false)
    }
    /// Only a pure sequence of matched questions can supply a trailing anchor;
    /// narration, quotations and missing source orders do not confer context.
    static func isPureQuestionSequence(_ text:String,candidates:[LiveQuestionCandidate],consumedFirst:String?)->Bool {
        guard !["「","『","“"].contains(where:text.contains) else {return false}
        var raw=split(text,final:true).filter{!$0.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty}
        var wanted=candidates
        if let consumedFirst,raw.first.map({fingerprint($0)==fingerprint(consumedFirst)})==true {
            raw.removeFirst()
            if wanted.first.map({fingerprint($0.text)==fingerprint(consumedFirst)})==true {wanted.removeFirst()}
        }
        guard raw.count==wanted.count,!raw.isEmpty else {return false}
        return zip(raw,wanted).allSatisfy { piece,candidate in
            guard candidate.slide != nil else {return false}
            var normalized=piece.trimmingCharacters(in:.whitespacesAndNewlines)
            for intro in independentIntroductions where normalized.hasPrefix(intro) && !(intro=="それと" && normalized.hasPrefix("それとも")) {
                normalized=String(normalized.dropFirst(intro.count)).trimmingCharacters(in:.whitespacesAndNewlines)
            }
            return fingerprint(normalized)==fingerprint(candidate.text)
        }
    }
    static func afterClosingCue(_ text: String) -> String? {
        guard !["という言葉", "という表現", "と引用", "と書いて", "と言います"].contains(where: text.contains),
              !text.contains("「"), !text.contains("『") else { return nil }
        let compact = text.replacingOccurrences(of: "[、，,\\s]", with: "", options: .regularExpression)
        let cues = ["ご清聴ありがとうございました", "ご静聴ありがとうございました", "これで発表を終わります"]
        guard let range = cues.compactMap({ compact.range(of: $0) }).max(by: { $0.upperBound < $1.upperBound }) else { return nil }
        return String(compact[range.upperBound...])
    }
    public static func completeQuestions(_ text: String, final: Bool, deck: LiveQuestionDeck) -> [LiveQuestionCandidate] {
        let raw = split(text, final: final).filter{!$0.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty}
        var chunks:[String]=[]
        for (index,chunk) in raw.enumerated() {
            if let previous=chunks.last,let combined=joinChoice(previous,chunk) {
                chunks[chunks.count-1]=combined
            } else {
                if final,index==raw.count-1,let previous=chunks.last,isUnfinishedClosedChoice(previous,chunk) {
                    chunks.removeLast() // final unfinished alternative cannot confirm its old answer
                }
                chunks.append(chunk)
            }
        }
        var output: [LiveQuestionCandidate] = []
        for raw in chunks {
            var piece = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !piece.isEmpty else { continue }
            if let marker = piece.range(of: "言い直します", options: .backwards)
                ?? piece.range(of: "訂正します", options: .backwards)
                ?? piece.range(of: "いえ、", options: .backwards)
                ?? piece.range(of: "いえ，", options: .backwards) {
                let prefix = String(piece[..<marker.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
                // A standalone correction retracts the last question. A correction inside an
                // unfinished second clause must not erase the already completed first question.
                if ["", "いえ、", "いえ，", "いいえ、", "いいえ，"].contains(prefix), !output.isEmpty { output.removeLast() }
                piece = String(piece[marker.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            for intro in independentIntroductions where piece.hasPrefix(intro) && !(intro=="それと" && piece.hasPrefix("それとも")) { piece = String(piece.dropFirst(intro.count)).trimmingCharacters(in: .whitespacesAndNewlines) }
            let intent = withoutQuotes(piece)
            if final,hasExplicitCancellationLeading(intent) {
                if !output.isEmpty {output.removeLast()}
                continue
            }
            guard LiveQuestionSyntax.isCompleteRequest(intent) else {continue}
            guard !["質問はあります", "質問がありますか", "ご質問をどうぞ", "質問をお願いします", "という言葉", "という表現", "と引用"].contains(where: intent.contains) else { continue }
            output.append(LiveQuestionCandidate(text: piece, slide: LiveQuestionMatcher.match(intent, deck: deck)))
        }
        return output
    }
    private static let terminals = ["でしょうか", "でしたか", "ましたか", "ですか", "ますか", "教えてください", "説明してください", "伺いたいです", "聞きたいです", "お聞かせください", "お願いします"]
    private static func split(_ text: String, final: Bool) -> [String] {
        let chars = Array(text); var quote = 0; var buffer = ""; var result: [String] = []
        for (i, c) in chars.enumerated() {
            if "「『“".contains(c) { quote += 1 }
            if "」』”".contains(c) { quote = max(0, quote - 1) }
            let decimalPoint=c == "．" && i>0 && i+1<chars.count && chars[i-1].isNumber && chars[i+1].isNumber
            if quote == 0 && "。．？！?!\n".contains(c) && !decimalPoint {
                result.append(buffer); buffer = ""; continue
            }
            buffer.append(c)
            if quote == 0, terminals.contains(where: buffer.hasSuffix), i + 1 < chars.count {
                let rest = String(chars[(i + 1)...])
                if beginsIndependentQuestion(rest,allowIncomplete:!final)
                    || hasClosedChoiceContinuation(buffer,rest,allowIncomplete:!final) { result.append(buffer); buffer = "" }
            }
        }
        let tail = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        // A growing keyword such as 教えて is not a completed request.
        if !tail.isEmpty, final || terminals.contains(where: tail.hasSuffix) { result.append(tail) }
        // Process an incomplete correction immediately to revoke an old response.
        else if tail.contains("言い直します") || tail.contains("訂正します") || tail.hasSuffix("いえ、") || tail.hasSuffix("いえ，") { result.append(tail) }
        return result
    }
    private static func withoutQuotes(_ text: String) -> String {
        var depth = 0; var result = ""
        for c in text {
            if "「『“".contains(c) { depth += 1; continue }
            if "」』”".contains(c) { depth = max(0, depth - 1); continue }
            if depth == 0 { result.append(c) }
        }
        return result
    }
}

