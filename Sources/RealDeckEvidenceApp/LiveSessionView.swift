import AppKit
import Combine
import NativeLocalIO
import RealDeckEvidenceCore
import SwiftUI
import SlideQACore

struct LiveSessionPanel:View {
    @EnvironmentObject private var ui:InterfaceLanguageStore
    @ObservedObject var session:LiveQASession
    @ObservedObject var audio:LiveAudioController
    let onOpenSource:(Int)->Void

    var body:some View {
        VStack(alignment:.leading,spacing:12) {
            Text("SlideQA").font(.title)
            HStack {
                Button(audio.starting ? ui.text("ui.9e305eab23ddf8d3"):ui.text("ui.cc147e162c82bbc7")) {audio.startByOwner(session:session)}
                    .buttonStyle(.borderedProminent)
                    .disabled(!audio.enabledForThisLaunch || audio.running || audio.starting || audio.stopping)
                Button(audio.stopping ? ui.text("ui.72eea71385de7be6"):ui.text("ui.ca4d973c0b006b75")) {audio.stop(session:session)}
                    .disabled(audio.stopping || (!audio.running && !audio.starting && !session.acceptingInput))
                Text(audio.running ? ui.text("ui.3aa713a1fa1a8eb2"):ui.text("ui.51ef5206fba40810")).foregroundStyle(.secondary)
            }
            if !audio.running && !audio.starting {
                Text(ui.text("ui.e7ea99bcc7a3d68f")).font(.caption).foregroundStyle(.secondary)
            }
            Text(ui.text("ui.5a0885e126c08c6a")).font(.caption).foregroundStyle(.secondary)
            if !audio.enabledForThisLaunch {Text(ui.text("ui.c73dda359d7aedb2")).font(.caption)}
            Text(ui.text(audio.message)).font(.caption).foregroundStyle(.secondary)
            if !audio.lastFailure.isEmpty {
                Text(ui.format("直近の認識中断：{0}",arguments:[ui.text(audio.lastFailure)]))
                    .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
            Text(ui.text(session.status)).font(.callout)
            if !session.transcript.isEmpty {
                Text(ui.text("ui.1e8b0bf7b73cd645")+session.transcript).font(.callout).lineLimit(3).textSelection(.enabled)
            }
            Divider()
            ScrollView {
                LazyVStack(alignment:.leading,spacing:18) {
                    ForEach(Array(session.cards.reversed())) {card in LiveQuestionCardView(card:card,onCancel:{session.cancel(id:card.id)},onOpenSource:onOpenSource)}
                }.frame(maxWidth:.infinity,alignment:.leading).padding(.trailing,10)
            }
            Text(ui.text("ui.1df12ad4697d34d0"))
                .font(.caption).foregroundStyle(.secondary)
        }.padding(20)
    }
}

struct ManualQuestionPanel:View {
    @EnvironmentObject private var ui:InterfaceLanguageStore
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var session:LiveQASession
    @State private var question=""
    var body:some View {
        VStack(alignment:.leading,spacing:14) {
            Text(ui.text("手入力")).font(.title2)
            Text(ui.text("マイクを使わず質問を送ります．")).font(.caption)
            TextEditor(text:$question).font(.system(size:17)).frame(minHeight:100)
                .accessibilityLabel(ui.text("手入力"))
            HStack {
                Button(ui.text("閉じる")) {dismiss()}.keyboardShortcut(.cancelAction)
                Spacer()
                Button(ui.text("送信")) {
                    if !session.acceptingInput {session.beginContinuousQuestions()}
                    session.setGenerationEnabled(true);session.submitTyped(question);dismiss()
                }.disabled(question.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty)
                    .keyboardShortcut(.return,modifiers:.command)
            }
        }.padding(20).frame(width:560,height:240)
    }
}

struct LiveQuestionCardView:View {
    @EnvironmentObject private var ui:InterfaceLanguageStore
    let card:LiveQACard
    let onCancel:()->Void
    let onOpenSource:(Int)->Void
    var body:some View {
        VStack(alignment:.leading,spacing:12) {
            Text(card.ticket.text).font(.headline).textSelection(.enabled)
            if card.stableCompletion {
                Text(ui.text("認識文から仮確定した質問です．続く発話や訂正で更新します．"))
                    .font(.caption).foregroundStyle(.orange)
            } else if card.provisionalSpeech {
                Text(ui.text("認識が中断したため仮確定した質問です．認識文を確認してください．"))
                    .font(.caption).foregroundStyle(.orange)
            }
            if card.sourceSelectionAmbiguous {
                Text(ui.text("複数の資料候補があります．質問との対応は未確定なので，引用元を確認してください．"))
                    .font(.caption).foregroundStyle(.orange)
            }
            Text(ui.text(card.status)).font(.caption).foregroundStyle(.secondary)
            if card.allowsDisplay {
                if let reference=card.reference {
                    ForEach(reference.candidates) {candidate in
                        Text("\(candidate.page): \(candidate.title)").font(.system(size:17)).textSelection(.enabled)
                    }
                }
                if let draft=card.draft {
                    VStack(alignment:.leading,spacing:10) {
                        Text(draft.composition == .quotedSources ? ui.text("ui.3dee612c9d3b03a1"):ui.text("ui.f3f6fb15b1ead24e")).font(.headline)
                        if !draft.reviewNote.isEmpty {Text(ui.text(draft.reviewNote)).font(.callout).foregroundStyle(.orange)}
                        if draft.abstained {
                            Text(ui.text(draft.text)).font(.system(size:19)).lineSpacing(5)
                        } else {
                            ForEach(draft.segments) {segment in
                                VStack(alignment:.leading,spacing:5) {
                                    if let quotation=segment.quotation {
                                        Text(ui.text("ui.44e67fb8f61baae0")).font(.caption).foregroundStyle(.secondary)
                                        Text(quotation.text).font(.system(size:19)).lineSpacing(5)
                                            .fixedSize(horizontal:false,vertical:true).textSelection(.enabled)
                                        Text(ui.citation(quotation)).font(.caption).textSelection(.enabled)
                                    } else {
                                        Text(segment.modelText).font(.system(size:19)).lineSpacing(5)
                                            .fixedSize(horizontal:false,vertical:true).textSelection(.enabled)
                                    }
                                }
                            }
                        }
                        if !draft.citations.isEmpty {
                            Text(draft.citations.map({ui.citation($0)}).joined(separator:"\n")).font(.caption).textSelection(.enabled)
                        }
                        if !draft.abstained {
                            Text(ui.text("ui.952fb2d01a483f3d"))
                                .font(.caption).foregroundStyle(.secondary)
                            if draft.localModelReviewPassed {
                                Text(ui.text("ui.fb1bcf38f719c723"))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            DisclosureGroup(ui.text("ui.a67eaa3a7b744cf4")) {
                                ForEach(draft.citations) {quote in
                                    VStack(alignment:.leading,spacing:6) {
                                        Text(ui.format("ui.ce60f9011413c50e",arguments:[String(describing:ui.citation(quote))])).font(.caption)
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
                            Text(card.draft?.citations.isEmpty == false ? ui.text("ui.5aea848358c1f383"):ui.text("ui.486c5ef8925b8d9d")).font(.headline)
                            Text(ui.citation(original)).font(.caption)
                            Text(original.text).font(.system(size:17)).lineSpacing(4).textSelection(.enabled)
                        }.padding(12).frame(maxWidth:.infinity,alignment:.leading)
                            .background(.quaternary.opacity(0.35),in:RoundedRectangle(cornerRadius:8))
                    }
                    DisclosureGroup(ui.text("ui.444936b275ddb963")) {
                        SearchResultView(result:reference,onOpen:onOpenSource)
                    }
                }
                Button(ui.text("ui.78137c28cd53ffd0"),action:onCancel).disabled(card.cancelled)
            }
        }.padding(15).frame(maxWidth:.infinity,alignment:.leading)
            .overlay(RoundedRectangle(cornerRadius:9).stroke(.quaternary))
#if SLIDEQA_DESKTOP_VALIDATION
            .onAppear {DesktopVerification.cardViewUpdated(card)}
            .onChange(of:card.draft?.text) {_,_ in DesktopVerification.cardViewUpdated(card)}
            .onChange(of:card.allowsDisplay) {_,_ in DesktopVerification.cardViewUpdated(card)}
#endif
    }
}
