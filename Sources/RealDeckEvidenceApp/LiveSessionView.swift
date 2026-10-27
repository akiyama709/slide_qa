import AppKit
import Combine
import NativeLocalIO
import RealDeckEvidenceCore
import SwiftUI

@MainActor final class LiveAudioController:ObservableObject {
    @Published private(set) var ownerConsent=false
    @Published private(set) var running=false
    @Published private(set) var starting=false
    @Published private(set) var stopping=false
    @Published private(set) var message="音声入力は開始していません．"
    let enabledForThisLaunch = LocalLaunchConfiguration(arguments:CommandLine.arguments).microphoneStartAllowed
    private let audio=NativeAudioPipeline()
    private var startTask:Task<Void,Never>?
    private var operation=UUID()

    // The only call site is the owner's visible Start button. No automatic
    // task, launch hook or diagnostic calls this method.
    func startByOwner(session:LiveQASession) {
        guard enabledForThisLaunch,!running,!starting,!stopping else {return}
        ownerConsent=true
        operation=UUID();let epoch=operation
        starting=true;message="端末内の音声認識を準備しています．"
        session.beginContinuousQuestions()
        startTask=Task { [weak self,session] in
            guard let self else {return}
            do {
                try await self.audio.startMicrophone(authorizedLaunch:self.enabledForThisLaunch,
                    ownerConsent:self.ownerConsent,allowPermissionPrompt:self.ownerConsent,
                    onUpdate:{[weak self,weak session] update in
                        guard let self,let session,self.operation == epoch else {return}
                        session.receive(update)
                        if !session.acceptingInput {self.stop(session:session,reason:"質問入力の順序または上限を確認できないため，収音も停止しました．")}
                    },onEndpoint:{_ in /* acoustic endpoint is not semantic question completion */},
                    onFailure:{[weak self,weak session] reason in
                        guard let self,let session,self.operation == epoch else {return}
                        self.stop(session:session,reason:reason)
                    })
                guard !Task.isCancelled,self.operation == epoch else {return}
                self.starting=false;self.running=true
                self.message="質問を待っています．\(self.audio.recognizerName)で端末内認識中です．"
            } catch {
                guard self.operation == epoch else {return}
                let reason=(error as? AudioFailure)?.errorDescription ?? "音声認識を開始できませんでした．新規取得や外部認識には切り替えません．"
                self.stop(session:session,reason:reason)
            }
        }
    }
    func stop(session:LiveQASession,reason:String?=nil) {
        operation=UUID();let epoch=operation
        startTask?.cancel();startTask=nil
        starting=false;running=false;stopping=true
        message=reason ?? "収音の停止を確認しています．"
        session.stop()
        Task { [weak self] in
            guard let self else {return}
            await self.audio.stop()
            if self.operation == epoch {self.stopping=false;self.message=reason ?? "収音は停止しています．"}
        }
    }
}

struct LiveSessionPanel:View {
    @ObservedObject var session:LiveQASession
    @ObservedObject var audio:LiveAudioController
    @ObservedObject var verification:NativeVerificationModel
    let onOpenSource:(Int)->Void

    var body:some View {
        VStack(alignment:.leading,spacing:12) {
            Text("SlideQA").font(.title)
            HStack {
                Button(audio.starting ? "準備中":"開始") {audio.startByOwner(session:session)}
                    .buttonStyle(.borderedProminent)
                    .disabled(!audio.enabledForThisLaunch || audio.running || audio.starting || audio.stopping || verification.running)
                Button(audio.stopping ? "停止中":"停止") {audio.stop(session:session)}
                    .disabled(audio.stopping || (!audio.running && !audio.starting && !session.acceptingInput))
                Text(audio.running ? "質問を継続して受け付けています":"発表前に一度開始してください．").foregroundStyle(.secondary)
            }
            if !audio.running && !audio.starting {
                Text("開始すると，このMacのマイクを使って日本語を端末内で認識します．音声・資料は外部へ送信せず，音声ファイルを保存しません．").font(.caption).foregroundStyle(.secondary)
            }
            if !audio.enabledForThisLaunch {Text("この起動では音声入力は無効です．有効化と実機試験は確認後に行います．").font(.caption)}
            Text(audio.message).font(.caption).foregroundStyle(.secondary)
            if verification.running {Text("動作確認中です．終了後に開始できます．").font(.caption)}
            Text(session.status).font(.callout)
            if !session.transcript.isEmpty {
                Text("認識中："+session.transcript).font(.callout).lineLimit(3).textSelection(.enabled)
            }
            Divider()
            ScrollView {
                LazyVStack(alignment:.leading,spacing:18) {
                    ForEach(Array(session.cards.reversed())) {card in LiveQuestionCardView(card:card,onCancel:{session.cancel(id:card.id)},onOpenSource:onOpenSource)}
                }.frame(maxWidth:.infinity,alignment:.leading).padding(.trailing,10)
            }
            Text("「訂正します…」「今の質問を取り消します」も受け付けます．発表者と聴衆の声は識別しないため，講演中の疑問文を拾う場合があります．応答案は出典と合わせてご確認ください．")
                .font(.caption).foregroundStyle(.secondary)
        }.padding(20)
    }
}

struct LiveDiagnosticPanel:View {
    @ObservedObject var session:LiveQASession
    @ObservedObject var audio:LiveAudioController
    @ObservedObject var verification:NativeVerificationModel
    @State private var typedQuestion=""
    var body:some View {
        ScrollView {
            VStack(alignment:.leading,spacing:16) {
                Text("動作確認 · v0.23.0").font(.title2)
                Text("通常の使用ではこの画面の操作は不要です．音声入力・応答品質・表示速度の確認は未完です．").foregroundStyle(.secondary)
                NativeVerificationPanel(model:verification).disabled(audio.running || audio.starting || audio.stopping)
                DisclosureGroup("手入力で同じ質問処理を確認する") {
                    VStack(alignment:.leading,spacing:8) {
                        TextEditor(text:$typedQuestion).font(.system(size:17)).frame(height:90)
                            .overlay(RoundedRectangle(cornerRadius:5).stroke(.quaternary))
                            .accessibilityLabel("確認用の質問")
                        Button("質問として処理する") {
                            if !session.acceptingInput {session.beginContinuousQuestions()}
                            session.setGenerationEnabled(true)
                            session.submitTyped(typedQuestion)
                        }.disabled(typedQuestion.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty || audio.running || audio.starting || audio.stopping || verification.running)
                        Text("手入力は音声認識や発話からの速度の試験ではありません．結果は「質問と応答案」に表示します．").font(.caption)
                    }
                }
            }.padding(20).frame(maxWidth:.infinity,alignment:.leading)
        }
    }
}

struct LiveQuestionCardView:View {
    let card:LiveQACard
    let onCancel:()->Void
    let onOpenSource:(Int)->Void
    var body:some View {
        VStack(alignment:.leading,spacing:12) {
            Text(card.ticket.text).font(.headline).textSelection(.enabled)
            Text(card.status).font(.caption).foregroundStyle(.secondary)
            if card.allowsDisplay {
                if let reference=card.reference {
                    ForEach(reference.candidates) {candidate in
                        Text("\(candidate.page)：\(candidate.title)").font(.system(size:17)).textSelection(.enabled)
                    }
                }
                if let draft=card.draft {
                    VStack(alignment:.leading,spacing:10) {
                        Text(draft.composition == .quotedSources ? "原文引用（新規生成ではありません）":"AI草案・未検証（UNVERIFIED）").font(.headline)
                        if !draft.reviewNote.isEmpty {Text(draft.reviewNote).font(.callout).foregroundStyle(.orange)}
                        if draft.abstained {
                            Text(draft.text).font(.system(size:19)).lineSpacing(5)
                        } else {
                            ForEach(draft.segments) {segment in
                                VStack(alignment:.leading,spacing:5) {
                                    if let quotation=segment.quotation {
                                        Text("原文の該当箇所（引用）").font(.caption).foregroundStyle(.secondary)
                                        Text(quotation.text).font(.system(size:19)).lineSpacing(5)
                                            .fixedSize(horizontal:false,vertical:true).textSelection(.enabled)
                                        Text(quotation.citation).font(.caption).textSelection(.enabled)
                                    } else {
                                        Text(segment.modelText).font(.system(size:19)).lineSpacing(5)
                                            .fixedSize(horizontal:false,vertical:true).textSelection(.enabled)
                                    }
                                }
                            }
                        }
                        if !draft.citations.isEmpty {
                            Text(draft.citations.map(\.citation).joined(separator:"\n")).font(.caption).textSelection(.enabled)
                        }
                        if !draft.abstained {
                            Text("出典ID・数値などの形式検査を通過した案です．意味の正しさを証明した結果ではありません．")
                                .font(.caption).foregroundStyle(.secondary)
                            if draft.localModelReviewPassed {
                                Text("端末内モデルによる各文の照合も通過しています．同じモデルによる判断であり，人の確認が必要です．")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            DisclosureGroup("応答候補が参照した原文を確認する") {
                                ForEach(draft.citations) {quote in
                                    VStack(alignment:.leading,spacing:6) {
                                        Text("出典：\(quote.citation)").font(.caption)
                                        Text(quote.text).font(.system(size:17)).lineSpacing(4)
                                    }.textSelection(.enabled).frame(maxWidth:.infinity,alignment:.leading).padding(.vertical,8)
                                }
                            }
                        }
                    }.padding(14).frame(maxWidth:.infinity,alignment:.leading)
                        .background(.quaternary.opacity(0.5),in:RoundedRectangle(cornerRadius:8))
                }
                if let reference=card.reference {
                    let draftCitations=card.draft?.citations ?? []
                    let originals=draftCitations.isEmpty ? Array(reference.candidates.first?.passages.prefix(1) ?? []):draftCitations
                    ForEach(originals) {original in
                        VStack(alignment:.leading,spacing:6) {
                            Text(card.draft?.citations.isEmpty == false ? "草案が引用した原文（全文）":"参考原文（引用）").font(.headline)
                            Text(original.citation).font(.caption)
                            Text(original.text).font(.system(size:17)).lineSpacing(4).textSelection(.enabled)
                        }.padding(12).frame(maxWidth:.infinity,alignment:.leading)
                            .background(.quaternary.opacity(0.35),in:RoundedRectangle(cornerRadius:8))
                    }
                    DisclosureGroup("候補スライドと原文・留保の全文を確認する") {
                        SearchResultView(result:reference,onOpen:onOpenSource)
                    }
                }
                Button("この質問を取り消す",action:onCancel).disabled(card.cancelled)
            }
        }.padding(15).frame(maxWidth:.infinity,alignment:.leading)
            .overlay(RoundedRectangle(cornerRadius:9).stroke(.quaternary))
    }
}
