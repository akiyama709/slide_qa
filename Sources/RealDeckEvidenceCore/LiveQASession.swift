import Combine
import Foundation

fileprivate final class LiveDisplayGate: @unchecked Sendable {
    private let lock=NSLock()
    private var held=false
    private var retired=false
    func hold(_ value:Bool) {lock.lock();defer{lock.unlock()};if !retired {held=value}}
    func retire() {lock.lock();retired=true;held=true;lock.unlock()}
    var visible:Bool {lock.lock();defer{lock.unlock()};return !held && !retired}
}

public struct LiveQACard: Identifiable, Sendable {
    public let id:String
    public fileprivate(set) var ticket:QuestionTicket
    fileprivate var storedReference:EvidenceSearchResult?
    fileprivate var storedDraft:GuardedLocalDraft?
    fileprivate let gate=LiveDisplayGate()
    fileprivate let draftGate=LiveDisplayGate()
    public fileprivate(set) var status:String
    public fileprivate(set) var cancelled=false
    public var reference:EvidenceSearchResult? {gate.visible ? storedReference:nil}
    public var draft:GuardedLocalDraft? {gate.visible && draftGate.visible ? storedDraft:nil}
    public var allowsDisplay:Bool {gate.visible}
}

/// Shared by native speech callbacks, typed input and fake-only headless tests.
/// Generation is serialized; epoch, source order and revision own every reply.
public enum LocalDraftReviewPolicy:Equatable,Sendable {case requireModelReview,allowUnverifiedPrototype,mockOnly}

@MainActor public final class LiveQASession:ObservableObject {
    @Published public private(set) var cards:[LiveQACard]=[]
    @Published public private(set) var phase:LiveSpeakingPhase = .presentation
    @Published public private(set) var transcript=""
    @Published public private(set) var status="待機中です．収音・生成は開始していません．"
    @Published public private(set) var acceptingInput=false
    @Published public private(set) var generationEnabled=false
    public let index:EvidenceIndex
    public let generationAllowed:Bool
    private let generator:any LocalDraftGenerating
    private let reviewPolicy:LocalDraftReviewPolicy
    private var pipeline=IncrementalQuestions(phase:.presentation)
    private var suppressed:Set<String>=[]
    private var pending:[LocalDraftRequest]=[]
    private var active:QuestionLease?
    private var activeOperation:UUID?
    private var generationTask:Task<Void,Never>?
    private var generationEpoch=UUID()
    private var typedOrder=0
    public private(set) var discardedLateReplies=0
    public private(set) var generationRequests=0

    public init(index:EvidenceIndex,generator:any LocalDraftGenerating,reviewPolicy:LocalDraftReviewPolicy = .requireModelReview,
                generationAllowed:Bool=true) {
        self.index=index;self.generator=generator;self.reviewPolicy=reviewPolicy;self.generationAllowed=generationAllowed
    }

    public func beginInput(phase initial:LiveSpeakingPhase) {
        stop()
        cards=[];suppressed=[];typedOrder=0;transcript=""
        pipeline=IncrementalQuestions(phase:initial);phase=initial
        acceptingInput=true;status="入力待ちです．端末内で処理します．"
    }
    /// Called only by an explicit Start action. No microphone is touched here.
    /// Questions, revisions and cancellations then use the same continuous path.
    public func beginContinuousQuestions() {
        beginInput(phase:.qna)
        setGenerationEnabled(true)
        status="質問を待っています．質問ごとの操作は不要です．"
    }
    public func setPhase(_ value:LiveSpeakingPhase) {
        cancelJobs()
        let changes=pipeline.changePhase(to:value)
        for change in changes {
            if case .retract(let lease)=change,value == .answering,
               let offset=cards.firstIndex(where:{$0.ticket.lease == lease && $0.storedDraft != nil && !$0.cancelled}) {
                cards[offset].status="確定済みの前の応答案です．回答中は新しい案を生成しません．"
            } else {apply([change])}
        }
        phase=value
        status=value == .qna ? "質疑待ちです．":"この状態では新しい応答案を生成しません．"
    }
    public func setGenerationEnabled(_ value:Bool) {
        guard !value || generationAllowed else {
            generationEnabled=false;cancelJobs()
            status="この安全確認モードでは新規生成を有効にできません．"
            return
        }
        generationEnabled=value
        if !value {
            cancelJobs()
            for offset in cards.indices where cards[offset].storedDraft == nil && !cards[offset].cancelled {
                cards[offset].status="新規生成を無効にしました．原文の参考箇所は確認できます．"
            }
            return
        }
        Task { [weak self] in
            guard let self,self.generationEnabled else {return}
            await self.generator.prepare()
        }
        for card in cards where !card.cancelled && card.ticket.confirmed && !card.ticket.isAwaitingContinuation && card.draft == nil {
            enqueue(card.ticket)
        }
        launchNext()
    }
    public func submitTyped(_ text:String) {
        // Typed input is an explicit question mode, not simulated speech timing.
        if !acceptingInput {beginInput(phase:.qna)}
        guard phase == .qna else {status="質疑待ちへ切り替えてから質問を入力してください．";return}
        do {
            for question in try TypedQuestionBatch.parse(text) {
                let update=LiveRecognitionUpdate(id:"typed-\(typedOrder)",order:typedOrder,text:question,
                    final:true,audioStart:0,audioEnd:0)
                typedOrder += 1
                receive(update)
            }
        } catch let error as TypedQuestionBatchError {status=error.message}
        catch {status="質問入力を処理できませんでした．"}
    }
    public func receive(_ update:LiveRecognitionUpdate) {
        guard acceptingInput else {return}
        transcript=update.text
        do {
            let changes=try pipeline.consume(turnID:update.id,order:update.order,text:update.text,
                final:update.final,deck:LiveQuestionDeck(index:index),sourceRevision:update.sourceRevision,
                sourceEnd:update.sourceRevision == nil ? nil:update.audioEnd)
            apply(changes)
            launchNext()
        } catch {
            stop();status="質問の順序または入力上限を確認できないため停止しました．"
        }
    }
    public func cancel(id:String) {
        suppressed.insert(id)
        if let card=cards.first(where:{$0.id == id}) {retire(card.ticket.lease,reason:"取り消しました．遅い結果も表示しません．")}
        launchNext()
    }
    public func stop() {
        acceptingInput=false;cancelJobs()
        for card in cards {card.gate.retire()}
        for offset in cards.indices {cards[offset].status="停止しました．";cards[offset].cancelled=true}
        _=pipeline.restart()
        status="質問入力の受付と生成案の表示更新を止めました．遅い結果は表示しません．"
    }

    private func apply(_ changes:[QuestionChange]) {
        for change in changes {
            switch change {
            case .retract(let lease):retire(lease,reason:"質問を訂正したため旧案を撤回しました．")
            case .phase(let value):phase=value
            case .upsert(let ticket):
                guard !suppressed.contains(ticket.lease.id) else {continue}
                let reference=index.search(ticket.text)
                let card=LiveQACard(id:ticket.lease.id,ticket:ticket,storedReference:reference,
                    status:ticket.confirmed ? "質問が確定しました．":"認識中の暫定候補です．")
                card.gate.hold(ticket.isAwaitingContinuation)
                card.draftGate.hold(!ticket.confirmed || ticket.isAwaitingContinuation)
                if let offset=cards.firstIndex(where:{$0.id == card.id}) {cards[offset]=card}
                else {cards.append(card)}
                if ticket.confirmed {enqueue(ticket)}
            case .refined(let ticket):
                guard let offset=cards.firstIndex(where:{$0.id == ticket.lease.id && $0.ticket.lease == ticket.lease && !$0.cancelled}) else {continue}
                cards[offset].ticket=ticket;cards[offset].gate.hold(ticket.isAwaitingContinuation)
                cards[offset].draftGate.hold(!ticket.confirmed || ticket.isAwaitingContinuation)
                cards[offset].storedReference=index.search(ticket.text)
                if ticket.isAwaitingContinuation || !ticket.confirmed {
                    removeJob(ticket.lease)
                    cards[offset].status=ticket.isAwaitingContinuation ? "質問の続きが未完のため，引用・応答案を保留しています．":"認識を更新中のため，新しい応答案の反映を保留しています．"
                } else if ticket.confirmed && cards[offset].storedDraft == nil {enqueue(ticket)}
            case .confirmed(let lease):
                guard let offset=cards.firstIndex(where:{$0.ticket.lease == lease && !$0.cancelled}) else {continue}
                cards[offset].ticket.confirmed=true
                cards[offset].draftGate.hold(cards[offset].ticket.isAwaitingContinuation)
                enqueue(cards[offset].ticket)
            }
        }
        cards.sort {($0.ticket.lease.epoch,$0.ticket.turnOrder,$0.ticket.position) < ($1.ticket.lease.epoch,$1.ticket.turnOrder,$1.ticket.position)}
        // Keep a bounded recent display while receiving throughout a talk.
        if cards.count>64 {
            let old=Array(cards.prefix(cards.count-64))
            for card in old {suppressed.insert(card.id);retire(card.ticket.lease,reason:"古い質問を表示履歴から外しました．")}
            cards.removeFirst(old.count)
        }
        suppressed.formIntersection(pipeline.retainedSourceQuestionIDs)
    }
    private func enqueue(_ ticket:QuestionTicket) {
        guard acceptingInput,generationEnabled,phase == .qna,ticket.confirmed,!ticket.isAwaitingContinuation,
              !suppressed.contains(ticket.lease.id),pipeline.isCurrent(ticket.lease),active != ticket.lease,
              !pending.contains(where:{$0.lease == ticket.lease}),
              let offset=cards.firstIndex(where:{$0.ticket.lease == ticket.lease && !$0.cancelled}),
              cards[offset].storedDraft == nil,let reference=cards[offset].storedReference else {return}
        do {pending.append(try LocalDraftRequest(ticket:ticket,reference:reference));cards[offset].status="端末内モデルの応答を待っています．"}
        catch let error as LocalDraftFailure {cards[offset].status=error.message}
        catch {cards[offset].status=LocalDraftFailure.insufficientSources.message}
    }
    private func launchNext() {
        guard active == nil,acceptingInput,generationEnabled,phase == .qna else {return}
        while !pending.isEmpty {
            let request=pending.removeFirst()
            guard isCurrent(request.lease) else {continue}
            active=request.lease;let epoch=generationEpoch
            let operation=UUID();activeOperation=operation
            generationTask=Task { [weak self] in
                guard let self else {return}
                do {
                    try await Task.sleep(for:.milliseconds(400))
                    guard self.generationEpoch == epoch,self.activeOperation == operation,self.isCurrent(request.lease) else {throw CancellationError()}
                    self.update(request.lease){$0.status="端末内モデルで応答案を生成し，原文との対応を検査しています．"}
                    self.generationRequests += 1
                    let draft=try await self.generator.generate(request)
                    guard !Task.isCancelled,self.generationEpoch == epoch,self.activeOperation == operation,self.isCurrent(request.lease) else {
                        self.discardedLateReplies += 1;return
                    }
                    try LocalDraftDeadline.requireValid(createdAt:request.createdAt)
                    let unverifiedAllowed=self.reviewPolicy == .allowUnverifiedPrototype && draft.reviewState == .unverifiedAfterModelReview
                    guard draft.abstained || draft.localModelReviewPassed || unverifiedAllowed || self.reviewPolicy == .mockOnly else {throw LocalDraftFailure.groundingReviewFailed}
                    self.update(request.lease){card in
                        card.storedDraft=draft
                        card.status=draft.abstained ? "根拠不足のため生成を保留しました．":unverifiedAllowed ? "未検証のAI草案です．原文と照合してからお使いください．":draft.composition.label+"．根拠と内容を確認してください．"
                    }
                } catch is CancellationError { }
                catch let error as LocalDraftFailure {if self.generationEpoch == epoch,self.activeOperation == operation {self.update(request.lease){$0.status=error.message}}}
                catch {if self.generationEpoch == epoch,self.activeOperation == operation {self.update(request.lease){$0.status=LocalDraftFailure.generationFailed.message}}}
                if self.activeOperation == operation,self.generationEpoch == epoch {
                    self.active=nil;self.activeOperation=nil;self.generationTask=nil;self.launchNext()
                }
            }
            break
        }
    }
    private func isCurrent(_ lease:QuestionLease)->Bool {
        acceptingInput && generationEnabled && phase == .qna && pipeline.isCurrent(lease) &&
        !suppressed.contains(lease.id) && cards.contains{$0.ticket.lease == lease && !$0.cancelled && $0.ticket.confirmed && !$0.ticket.isAwaitingContinuation}
    }
    private func update(_ lease:QuestionLease,_ body:(inout LiveQACard)->Void) {
        guard isCurrent(lease),let offset=cards.firstIndex(where:{$0.ticket.lease == lease}) else {return}
        body(&cards[offset])
    }
    private func retire(_ lease:QuestionLease,reason:String) {
        removeJob(lease)
        guard let offset=cards.firstIndex(where:{$0.ticket.lease == lease}) else {return}
        cards[offset].gate.retire();cards[offset].cancelled=true;cards[offset].status=reason
    }
    private func removeJob(_ lease:QuestionLease) {
        pending.removeAll{$0.lease == lease}
        if active == lease {generationTask?.cancel();generationTask=nil;active=nil;activeOperation=nil}
    }
    private func cancelJobs() {
        generationEpoch=UUID();generationTask?.cancel();generationTask=nil;active=nil;activeOperation=nil;pending=[]
    }
}
