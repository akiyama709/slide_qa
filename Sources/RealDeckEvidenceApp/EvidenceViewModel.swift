import AppKit
import Combine
import NativeLocalIO
import RealDeckEvidenceCore
import SlideQACore
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
    init(arguments:[String]=CommandLine.arguments) {
        if Deck.hasExternalSelection(arguments:arguments) {
            let args=arguments
            if let position=args.firstIndex(of:"--deck"),position+1<args.count,
               args.filter({$0=="--deck"}).count==1,!args[position+1].hasPrefix("--"),!args[position+1].contains("://") {
#if SLIDEQA_DESKTOP_VALIDATION
                if LocalLaunchConfiguration(arguments:args).automaticModelCheck {
                    guard let resources=Bundle.main.resourceURL,
                          URL(fileURLWithPath:args[position+1]).standardizedFileURL==resources.appendingPathComponent("synthetic-deck.json").standardizedFileURL else {
                        message="Explicit desktop verification requires its bundled synthetic deck.";return
                    }
                }
#endif
                load(URL(fileURLWithPath:(args[position+1] as NSString).expandingTildeInPath))
            } else {message="--deck の後にローカルPDF・PPTX・JSONを一つ指定してください．"}
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
                try ImportResources.withMonitoring {
                    let imported=try PresentationImporter.load(url)
                    let index=try EvidenceIndex(deck:imported.deck,checkpoint:ImportResources.check)
                    return (imported,index)
                }
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
    func returnToStart() {
        loadGate.invalidate();loadTask?.cancel();loadTask=nil
        liveSession?.stop()
        index=nil;liveSession=nil;results=[];question="";titleFilter="";selectedPage=nil
        importWarnings=[];originalFileSHA256=nil;message="";importing=false;documentLabel="";formatLabel=""
    }
    private func install(_ imported:ImportedPresentation,index loaded:EvidenceIndex) {
        index=loaded;importWarnings=imported.warnings;originalFileSHA256=imported.originalFileSHA256;importing=false
        formatLabel=imported.format.rawValue.uppercased()
        liveSession=LiveQASession(index:loaded,generator:OnDeviceDraftGenerator(displayPolicy:.unverifiedPrototype,
            diagnostics:{value in
#if SLIDEQA_DESKTOP_VALIDATION
                if LocalLaunchConfiguration(arguments:CommandLine.arguments).automaticModelCheck {
                    DesktopVerification.modelDiagnostic(value);return
                }
#endif
                LocalModelJournal.record(value)
            }),
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
