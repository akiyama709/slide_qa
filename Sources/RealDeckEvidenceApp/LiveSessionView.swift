import AppKit
import Combine
import NativeLocalIO
import RealDeckEvidenceCore
import SwiftUI
import SlideQACore

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
    @EnvironmentObject private var ui:InterfaceLanguageStore
    @ObservedObject var session:LiveQASession
    @ObservedObject var audio:LiveAudioController
    @ObservedObject var verification:NativeVerificationModel
    let onOpenSource:(Int)->Void

    var body:some View {
        VStack(alignment:.leading,spacing:12) {
            Text("SlideQA").font(.title)
            HStack {
                Button(audio.starting ? ui.text("ui.9e305eab23ddf8d3"):ui.text("ui.cc147e162c82bbc7")) {audio.startByOwner(session:session)}
                    .buttonStyle(.borderedProminent)
                    .disabled(!audio.enabledForThisLaunch || audio.running || audio.starting || audio.stopping || verification.running)
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
            if verification.running {Text(ui.text("ui.8f38cd54631e166c")).font(.caption)}
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

struct LiveDiagnosticPanel:View {
    @EnvironmentObject private var ui:InterfaceLanguageStore
    @ObservedObject var session:LiveQASession
    @ObservedObject var audio:LiveAudioController
    @ObservedObject var verification:NativeVerificationModel
    var originalFileSHA256:String?=nil
    @State private var typedQuestion=""
    var body:some View {
        ScrollView {
            VStack(alignment:.leading,spacing:16) {
                Text(ui.text("ui.5f867e41fe27e63b")).font(.title2)
                Text(ui.text("ui.2b749e3f7c9f5263")).foregroundStyle(.secondary)
                NativeVerificationPanel(model:verification).disabled(audio.running || audio.starting || audio.stopping)
                DisclosureGroup(ui.text("ui.de3a9665aa01129c")) {
                    if let digest=originalFileSHA256 {Text(ui.text("ui.d815335fbc9dafe2")+digest).textSelection(.enabled)}
                    Text(ui.text("ui.0f338ffa2106f1d0")+session.index.deck.sourceSHA256).textSelection(.enabled)
                    Text(ui.text("ui.52cfb3205210e7d5")).font(.caption)
                }
                DisclosureGroup(ui.text("ui.a9a7d51c3f004ed3")) {
                    VStack(alignment:.leading,spacing:8) {
                        TextEditor(text:$typedQuestion).font(.system(size:17)).frame(height:90)
                            .overlay(RoundedRectangle(cornerRadius:5).stroke(.quaternary))
                            .accessibilityLabel(ui.text("ui.8be9a9f8e739f2f4"))
                        Button(ui.text("ui.8a3bf2b4784f56e2")) {
                            if !session.acceptingInput {session.beginContinuousQuestions()}
                            session.setGenerationEnabled(true)
                            session.submitTyped(typedQuestion)
                        }.disabled(typedQuestion.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty || audio.running || audio.starting || audio.stopping || verification.running)
                        Text(ui.text("ui.9dc25c722013eef9")).font(.caption)
                    }
                }
            }.padding(20).frame(maxWidth:.infinity,alignment:.leading)
        }
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
    }
}
