import AppKit
import NativeLocalIO
import Combine
import RealDeckEvidenceCore
import SlideQACore
import SwiftUI

@MainActor final class EvidenceViewModel:ObservableObject {
    @Published var question=""
    @Published var titleFilter=""
    @Published var selectedPage:Int?
    @Published var results:[EvidenceSearchResult]=[]
    @Published var message=""
    let index:EvidenceIndex?
    let liveSession:LiveQASession?
    init() {
        let loaded=try? EvidenceIndex.configured()
        index=loaded
        if let loaded {
            liveSession=LiveQASession(index:loaded,generator:OnDeviceDraftGenerator(displayPolicy:.unverifiedPrototype),
                reviewPolicy:.allowUnverifiedPrototype,generationAllowed:!CommandLine.arguments.contains("--safe-ui-smoke"))
        } else {
            liveSession=nil;message="ローカルJSONを読み込めません．連番・表題・サイズと --deck の指定を確認してください．"
        }
    }
    var slides:[Slide] {
        guard let index else {return []}
        let q=normalize(titleFilter)
        return index.deck.slides.filter{q.isEmpty || normalize($0.title).contains(q) || String($0.page) == q}
    }
    func search() {
        guard let index else {return}
        selectedPage=nil
        do {
            let chunks=try TypedQuestionBatch.parse(question)
            results=(chunks.isEmpty ? [question]:chunks).map{index.search($0)}
            message="参考箇所です．否定・条件を含めて原文を確認してください．"
        } catch {results=[];message="質問を短い文に分けて確認してください．"}
    }
    func invalidateResults() {
        if !results.isEmpty {results=[];message="質問を変更しました．再検索で更新します．"}
    }
    func clear() {question="";results=[];selectedPage=nil;message=""}
}

@main struct RealDeckEvidenceApplication:App {
    @StateObject private var model=EvidenceViewModel()
    @StateObject private var audio=LiveAudioController()
    @StateObject private var verification=NativeVerificationModel()
    @State private var selectedTab=1
    @State private var checkStarted=false
    var body:some Scene {
        WindowGroup("SlideQA Prototype 0.23.0 · UNVERIFIED") {
            TabView(selection:$selectedTab) {
                EvidenceMainView(model:model).tabItem{Text("資料の参照")}.tag(0)
                if let session=model.liveSession {
                    LiveSessionPanel(session:session,audio:audio,verification:verification,onOpenSource:{page in model.selectedPage=page;selectedTab=0})
                        .tabItem{Text("質問と応答案")}.tag(1)
                    LiveDiagnosticPanel(session:session,audio:audio,verification:verification)
                        .tabItem{Text("動作確認")}.tag(2)
                }
            }.frame(minWidth:1040,minHeight:800)
                .disabled(CommandLine.arguments.contains("--safe-ui-smoke"))
                .task {
                    let launch=LocalLaunchConfiguration(arguments:CommandLine.arguments)
                    guard !checkStarted,launch.safeSmoke || launch.automaticModelCheck else {return}
                    checkStarted=true
                    if launch.safeSmoke {runSafeUISmoke()} else {await runNoAudioAcceptance()}
                }
                .onDisappear{if let session=model.liveSession {audio.stop(session:session)}}
                .onReceive(NotificationCenter.default.publisher(for:NSApplication.willTerminateNotification)){_ in
                    if let session=model.liveSession {audio.stop(session:session)}
                }
        }.defaultSize(width:1260,height:940)
    }
    @MainActor private func runNoAudioAcceptance() async {
        guard !audio.enabledForThisLaunch,!audio.running,!audio.starting,!audio.ownerConsent else {return}
        let start=ContinuousClock.now
        selectedTab=2;verification.verifyAnswers()
        while verification.running,start.duration(to:.now) < .seconds(240) {
            do {try await Task.sleep(for:.milliseconds(100))} catch {break}
        }
        let wasRunning=verification.running
        let timedOut=wasRunning && !Task.isCancelled
        if wasRunning {verification.cancelVerification(timedOut:timedOut)}
        let elapsed=start.duration(to:.now)
        _=verification.saveLaunchOutcome(["kind":"explicit-no-audio-demo-launch","nativeReport":verification.savedReport,
            "demoCheckRefused":Deck.hasExternalSelection(),"timedOut":timedOut,"cancelled":Task.isCancelled,
            "underlyingModelFinishedConfirmed":!wasRunning,"recordingStarted":false,"permissionRequested":false,
            "externalAPIUsed":false,"pixelsCaptured":false,"ComputerUseRequested":false,
            "elapsedSeconds":Double(elapsed.components.seconds)+Double(elapsed.components.attoseconds)/1e18])
        NSApplication.shared.terminate(nil)
    }
    @MainActor private func runSafeUISmoke() {
        let noAudio = !audio.enabledForThisLaunch && !audio.running && !audio.ownerConsent
        _=verification.saveLaunchOutcome(["kind":"source-and-launch-state-check","recordingStarted":false,
            "modelGenerationInvoked":false,"permissionRequested":false,"pixelsCaptured":false,
            "loadedPages":model.index?.deck.pageCount ?? 0,"noAudioDefaults":noAudio,
            "PDFOrPixelComparisonPerformed":false,"externalAPIUsed":false])
        NSApplication.shared.terminate(nil)
    }
}

struct EvidenceMainView: View {
    @ObservedObject var model: EvidenceViewModel
    var body: some View {
        HSplitView {
            VStack(alignment: .leading, spacing: 10) {
                Text("ローカル資料・\(model.index?.deck.pageCount ?? 0)枚").font(.title3)
                TextField("番号・表題を絞り込み", text: $model.titleFilter)
                    .textFieldStyle(.roundedBorder)
                List(selection: $model.selectedPage) {
                    ForEach(model.slides) { slide in
                        Text("\(slide.page)：\(slide.title)")
                            .font(.system(size: 14)).fixedSize(horizontal: false, vertical: true)
                            .padding(.vertical, 5).tag(slide.page)
                    }
                }
                Text("項目を選ぶと，抽出本文と発表ノートの全文を確認できます．")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(14).frame(minWidth: 270, idealWidth: 310, maxWidth: 390)

            VStack(alignment: .leading, spacing: 12) {
                Text("SlideQA · ローカルJSONの原文を探す").font(.title2)
                Text("資料の原文を確認する画面です．通常の使用は「質問と応答案」だけで行えます．")
                    .foregroundStyle(.secondary)
                TextEditor(text: $model.question).font(.system(size: 17))
                    .padding(6).frame(height: 90)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
                    .accessibilityLabel("質問入力")
                    .onChange(of: model.question) { _, _ in model.invalidateResults() }
                HStack {
                    Button("資料から探す") { model.search() }
                        .keyboardShortcut(.return, modifiers: .command)
                        .disabled(model.index == nil || model.question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Button("表示を消去") { model.clear() }
                    Text("⌘ Return で検索").font(.caption).foregroundStyle(.secondary)
                }
                if !model.message.isEmpty { Text(model.message).font(.callout).foregroundStyle(.secondary) }
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        if let page = model.selectedPage, let slide = model.index?.slide(page: page) {
                            SourceSlideView(slide: slide, sourceName: sourceName)
                        } else if model.results.isEmpty {
                            Text("質問を検索するか，左の資料を選択してください．")
                                .foregroundStyle(.secondary).padding(.top, 20)
                        } else {
                            ForEach(model.results) { result in
                                SearchResultView(result: result, onOpen: { model.selectedPage = $0 })
                            }
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(.trailing, 10)
                }
                Divider()
                Text("出典：\(sourceName) ／ ローカルJSONの連番と表題を使用")
                    .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                Text("このタブは原文参照です．語の一致は回答の正しさを保証しません．新しい応答案は「質問と応答案」で生成します．図表の意味理解には対応していません．")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(20).frame(minWidth: 650)
        }
    }
    private var sourceName: String {
        model.index.map { URL(fileURLWithPath: $0.deck.sourceFile).lastPathComponent } ?? "読込エラー"
    }
}

struct SearchResultView: View {
    let result: EvidenceSearchResult
    let onOpen: (Int) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(result.question).font(.headline).textSelection(.enabled)
            Text(result.disposition.label).font(.callout)
                .foregroundStyle(result.candidates.isEmpty ? .secondary : .primary)
            ForEach(result.candidates) { candidate in
                VStack(alignment: .leading, spacing: 10) {
                    Text("\(candidate.page)：\(candidate.title)")
                        .font(.system(size: 22)).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                    Text(candidate.basis).font(.caption).foregroundStyle(.secondary)
                    if candidate.passages.isEmpty {
                        Text("質問に対応する原文の箇所を特定できません．資料全体を確認してください．")
                            .font(.callout)
                    }
                    ForEach(candidate.passages) { passage in
                        VStack(alignment: .leading, spacing: 8) {
                            Text("出典：\(passage.citation)").font(.caption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                            Text(passage.text).font(.system(size: 17)).lineSpacing(5)
                                .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(12)
                            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 7))
                    }
                    Button("このスライドの本文・ノート全文を開く") { onOpen(candidate.page) }
                }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
                    .overlay(RoundedRectangle(cornerRadius: 9).stroke(.quaternary))
            }
        }.padding(.bottom, 14)
    }
}

struct SourceSlideView: View {
    let slide: Slide
    let sourceName: String
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("\(slide.page)：\(slide.title)").font(.system(size: 24))
                .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            Text("出典：\(sourceName)・\(slide.page)ページ").font(.caption)
                .foregroundStyle(.secondary).textSelection(.enabled)
            Text("スライドの抽出本文（全文）").font(.headline)
            Text(slide.text.isEmpty ? "抽出本文がありません．" : slide.text)
                .font(.system(size: 17)).lineSpacing(5).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            Divider()
            Text("発表ノート（全文）").font(.headline)
            Text(slide.notes.isEmpty ? "このページの発表ノートはありません．" : slide.notes)
                .font(.system(size: 17)).lineSpacing(5).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            Text("PDFの配置・図表を再現した表示ではありません．読み込んだJSONの本文とノートです．PDFの原本照合はしていません．")
                .font(.caption).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
