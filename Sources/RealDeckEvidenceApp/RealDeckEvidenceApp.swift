import AppKit
import NativeLocalIO
import Combine
import RealDeckEvidenceCore
import SlideQACore
import SwiftUI
import UniformTypeIdentifiers

@MainActor final class EvidenceViewModel:ObservableObject {
    @Published var question=""
    @Published var titleFilter=""
    @Published var selectedPage:Int?
    @Published var results:[EvidenceSearchResult]=[]
    @Published var message=""
    @Published private(set) var index:EvidenceIndex?
    @Published private(set) var liveSession:LiveQASession?
    @Published private(set) var importing=false
    @Published private(set) var documentLabel=""
    @Published private(set) var formatLabel=""
    @Published private(set) var importWarnings:[String]=[]
    @Published private(set) var originalFileSHA256:String?
    private var loadGate=PresentationLoadGate()
    private var loadTask:Task<Void,Never>?
    init() {
        if Deck.hasExternalSelection() {
            let args=CommandLine.arguments
            if let position=args.firstIndex(of:"--deck"),position+1<args.count,
               args.filter({$0=="--deck"}).count==1,!args[position+1].hasPrefix("--"),!args[position+1].contains("://") {
                load(URL(fileURLWithPath:(args[position+1] as NSString).expandingTildeInPath))
            } else {message="--deck の後にローカルPDF・PPTX・JSONを一つ指定してください．"}
        } else if CommandLine.arguments.contains("--safe-ui-smoke") || CommandLine.arguments.contains("--verify-local-answers-no-audio") {
            useDemo()
        }
    }
    func choosePresentation(language:InterfaceLanguageStore) {
        let panel=NSOpenPanel()
        panel.title=language.text("発表資料を開く")
        panel.message=language.text("PDF・PPTX・資料JSONをこのMac内で読み込みます．資料は外部へ送信しません．")
        panel.prompt=language.text("開く")
        panel.allowsMultipleSelection=false;panel.canChooseDirectories=false
        panel.allowedContentTypes=[.pdf,.json]+(UTType(filenameExtension:"pptx").map{[$0]} ?? [])
        if panel.runModal() == .OK,let url=panel.url {load(url)}
    }
    private func resetForSelection()->UUID {
        loadTask?.cancel();liveSession?.stop()
        index=nil;liveSession=nil;results=[];question="";titleFilter="";selectedPage=nil
        importWarnings=[];originalFileSHA256=nil;message="";importing=true;documentLabel="";formatLabel=""
        return loadGate.begin()
    }
    func load(_ url:URL) {
        let ticket=resetForSelection();documentLabel=url.lastPathComponent
        loadTask=Task { [weak self] in
            let worker=Task.detached(priority:.userInitiated) {
                let imported=try PresentationImporter.load(url)
                try Task.checkCancellation()
                return (imported,EvidenceIndex(deck:imported.deck))
            }
            do {
                let (imported,index)=try await withTaskCancellationHandler(operation:{try await worker.value},onCancel:{worker.cancel()})
                guard let self,self.loadGate.isCurrent(ticket),!Task.isCancelled else {return}
                self.install(imported,index:index)
            } catch {
                guard let self,self.loadGate.isCurrent(ticket),!Task.isCancelled else {return}
                self.importing=false;self.message=(error as? LocalizedError)?.errorDescription ?? "資料を読み込めませんでした．"
            }
        }
    }
    func useDemo() {
        _=resetForSelection()
        do {install(try PresentationImporter.demo())}
        catch {importing=false;message="合成デモを読み込めませんでした．"}
    }
    private func install(_ imported:ImportedPresentation,index prepared:EvidenceIndex?=nil) {
        let loaded=prepared ?? EvidenceIndex(deck:imported.deck)
        index=loaded;importWarnings=imported.warnings;originalFileSHA256=imported.originalFileSHA256;importing=false
        formatLabel=imported.format.rawValue.uppercased()
        liveSession=LiveQASession(index:loaded,generator:OnDeviceDraftGenerator(displayPolicy:.unverifiedPrototype),
            reviewPolicy:.allowUnverifiedPrototype,generationAllowed:!CommandLine.arguments.contains("--safe-ui-smoke"))
    }
    func cancelImport() {
        loadGate.invalidate();loadTask?.cancel();loadTask=nil;importing=false
        if index==nil {documentLabel=""}
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
    @StateObject private var ui=InterfaceLanguageStore()
    @StateObject private var model=EvidenceViewModel()
    @StateObject private var audio=LiveAudioController()
    @StateObject private var verification=NativeVerificationModel()
    @State private var selectedTab=1
    @State private var checkStarted=false
    @MainActor private var documentHeading:String {
        if let index=model.index {
            return ui.format("{0} · {1}枚 · {2}",arguments:[index.deck.sourceFile,String(index.deck.pageCount),model.formatLabel])
        }
        return model.documentLabel.isEmpty ? ui.text("資料を選択してください"):model.documentLabel
    }
    var body:some Scene {
        WindowGroup("SlideQA 0.25.0") {
          VStack(spacing:0) {
            HStack {
                Button(ui.text("ui.4b56425eecbf2940")) {model.choosePresentation(language:ui)}
                    .keyboardShortcut("o",modifiers:.command)
                    .accessibilityLabel(ui.text("ui.e4a5bb47a808ec43"))
                    .accessibilityHint(ui.text("ui.c7d36a22917d2565"))
                    .accessibilityIdentifier("presentation.open")
                    .disabled(audio.running || audio.starting || audio.stopping || verification.running)
                Text(documentHeading).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                    .accessibilityLabel(ui.text("ui.0f547e007f14d84d")).accessibilityValue(Text(documentHeading))
                Spacer()
                Menu {
                    Picker(ui.text("表示言語"),selection:Binding(get:{ui.language},set:{ui.select($0)})) {
                        Text(ui.text("英語")).tag(InterfaceLanguage.english)
                        Text(ui.text("日本語")).tag(InterfaceLanguage.japanese)
                    }.accessibilityIdentifier("interface.language")
                } label:{Label(ui.text("設定"),systemImage:"gearshape")}
                    .accessibilityLabel(ui.text("表示言語を選択"))
                if model.importing {
                    ProgressView().controlSize(.small).accessibilityLabel(ui.text("ui.42508c0915c419d9"))
                    Button(ui.text("ui.caef505ae9b26648")) {model.cancelImport()}.accessibilityIdentifier("presentation.cancelImport")
                }
            }.padding(12)
            if !model.importWarnings.isEmpty {
                DisclosureGroup(ui.text("ui.aa2942e1de3e0ecd")) {
                    ForEach(model.importWarnings,id:\.self){Text(ui.text($0)).font(.caption).frame(maxWidth:.infinity,alignment:.leading)}
                }.padding(.horizontal,12).padding(.bottom,8)
            }
            if let session=model.liveSession {
            TabView(selection:$selectedTab) {
                EvidenceMainView(model:model).tabItem{Text(ui.text("ui.9e4a11f727de4c34"))}.tag(0)
                    LiveSessionPanel(session:session,audio:audio,verification:verification,onOpenSource:{page in model.selectedPage=page;selectedTab=0})
                        .tabItem{Text(ui.text("ui.ace9f8d7189b9284"))}.tag(1)
                    LiveDiagnosticPanel(session:session,audio:audio,verification:verification,originalFileSHA256:model.originalFileSHA256)
                        .tabItem{Text(ui.text("ui.5f867e41fe27e63b"))}.tag(2)
            }.frame(minWidth:1040,minHeight:800)
            } else {
                VStack(spacing:18) {
                    Text(model.importing ? ui.text("ui.3588d9223d82f6f6"):ui.text("ui.1a781986911ce71a")).font(.title)
                    Text(ui.text("ui.5ac01915738bd9a9"))
                    Text(ui.text("ui.457d52b1c85f3867")).foregroundStyle(.secondary)
                    if !model.message.isEmpty {
                        Text(ui.text(model.message)).foregroundStyle(.red).textSelection(.enabled)
                            .accessibilityLabel(ui.text("ui.3f4013e2bb1e3161")).accessibilityValue(Text(ui.text(model.message)))
                    }
                    Button(ui.text("ui.c77bd836e79807c7")) {model.useDemo()}.disabled(model.importing)
                }.padding(30).frame(minWidth:1040,minHeight:800,maxHeight:.infinity)
            }
          }
                .environmentObject(ui)
                .environment(\.locale,Locale(identifier:ui.language.rawValue))
                .disabled(CommandLine.arguments.contains("--safe-ui-smoke"))
                .task {
                    let launch=LocalLaunchConfiguration(arguments:CommandLine.arguments)
                    guard !checkStarted,launch.safeSmoke || launch.automaticModelCheck else {return}
                    checkStarted=true
                    while model.importing {do {try await Task.sleep(for:.milliseconds(100))} catch {return}}
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
    @EnvironmentObject private var ui:InterfaceLanguageStore
    @ObservedObject var model: EvidenceViewModel
    var body: some View {
        HSplitView {
            VStack(alignment: .leading, spacing: 10) {
                Text(ui.format("ui.083c97382139ecea",arguments:[String(describing:model.index?.deck.pageCount ?? 0)])).font(.title3)
                TextField(ui.text("ui.3adf722abdf4f02a"), text: $model.titleFilter)
                    .textFieldStyle(.roundedBorder)
                List(selection: $model.selectedPage) {
                    ForEach(model.slides) { slide in
                        Text("\(slide.page): \(slide.title)")
                            .font(.system(size: 14)).fixedSize(horizontal: false, vertical: true)
                            .padding(.vertical, 5).tag(slide.page)
                    }
                }
                Text(ui.text("ui.ab40f7cc03ade54f"))
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(14).frame(minWidth: 270, idealWidth: 310, maxWidth: 390)

            VStack(alignment: .leading, spacing: 12) {
                Text(ui.text("ui.4ff8cfa371155d5e")).font(.title2)
                Text(ui.text("ui.df5b0aef3eea6a73"))
                    .foregroundStyle(.secondary)
                TextEditor(text: $model.question).font(.system(size: 17))
                    .padding(6).frame(height: 90)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
                    .accessibilityLabel(ui.text("ui.ef50f5116d059c98"))
                    .onChange(of: model.question) { _, _ in model.invalidateResults() }
                HStack {
                    Button(ui.text("ui.03a261beb47f1fb8")) { model.search() }
                        .keyboardShortcut(.return, modifiers: .command)
                        .disabled(model.index == nil || model.question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Button(ui.text("ui.03846efd296f188e")) { model.clear() }
                    Text(ui.text("ui.d580c44fd0c01c41")).font(.caption).foregroundStyle(.secondary)
                }
                if !model.message.isEmpty { Text(ui.text(model.message)).font(.callout).foregroundStyle(.secondary) }
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        if let page = model.selectedPage, let slide = model.index?.slide(page: page) {
                            SourceSlideView(slide: slide, sourceName: sourceName)
                        } else if model.results.isEmpty {
                            Text(ui.text("ui.98fb4339524299e6"))
                                .foregroundStyle(.secondary).padding(.top, 20)
                        } else {
                            ForEach(model.results) { result in
                                SearchResultView(result: result, onOpen: { model.selectedPage = $0 })
                            }
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(.trailing, 10)
                }
                Divider()
                Text(ui.format("ui.29aa2f0394bf2b6d",arguments:[String(describing:sourceName)]))
                    .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                Text(ui.text("ui.803a77df6338d88f"))
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(20).frame(minWidth: 650)
        }
    }
    private var sourceName: String {
        model.index.map { URL(fileURLWithPath: $0.deck.sourceFile).lastPathComponent } ?? ui.text("ui.1e495985d03938b0")
    }
}

struct SearchResultView: View {
    @EnvironmentObject private var ui:InterfaceLanguageStore
    let result: EvidenceSearchResult
    let onOpen: (Int) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(result.question).font(.headline).textSelection(.enabled)
            Text(ui.text(result.disposition.label)).font(.callout)
                .foregroundStyle(result.candidates.isEmpty ? .secondary : .primary)
            ForEach(result.candidates) { candidate in
                VStack(alignment: .leading, spacing: 10) {
                    Text("\(candidate.page): \(candidate.title)")
                        .font(.system(size: 22)).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                    Text(ui.text(candidate.basis)).font(.caption).foregroundStyle(.secondary)
                    if candidate.passages.isEmpty {
                        Text(ui.text("ui.aaf7969813dff657"))
                            .font(.callout)
                    }
                    ForEach(candidate.passages) { passage in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(ui.format("ui.ce60f9011413c50e",arguments:[String(describing:ui.citation(passage))])).font(.caption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                            Text(passage.text).font(.system(size: 17)).lineSpacing(5)
                                .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(12)
                            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 7))
                    }
                    Button(ui.text("ui.9cca36006f6285b9")) { onOpen(candidate.page) }
                }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
                    .overlay(RoundedRectangle(cornerRadius: 9).stroke(.quaternary))
            }
        }.padding(.bottom, 14)
    }
}

struct SourceSlideView: View {
    @EnvironmentObject private var ui:InterfaceLanguageStore
    let slide: Slide
    let sourceName: String
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("\(slide.page): \(slide.title)").font(.system(size: 24))
                .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            Text(ui.format("ui.b135bbb38c72ed34",arguments:[String(describing:sourceName),String(describing:slide.page)])).font(.caption)
                .foregroundStyle(.secondary).textSelection(.enabled)
            Text(ui.text("ui.fdd290d9270a26f1")).font(.headline)
            Text(slide.text.isEmpty ? ui.text("ui.cac871bc182e8c43") : slide.text)
                .font(.system(size: 17)).lineSpacing(5).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            Divider()
            Text(ui.text("ui.323174b992c4dc46")).font(.headline)
            Text(slide.notes.isEmpty ? ui.text("ui.1c6cc7b85b6852ac") : slide.notes)
                .font(.system(size: 17)).lineSpacing(5).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            Text(ui.text("ui.793abc4c8a093006"))
                .font(.caption).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
