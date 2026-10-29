import AppKit
import Combine
import NativeLocalIO
import RealDeckEvidenceCore
import SlideQACore
import SwiftUI

@main struct RealDeckEvidenceApplication:App {
    @StateObject private var ui=InterfaceLanguageStore()
    @StateObject private var model=EvidenceViewModel()
    @StateObject private var audio=LiveAudioController(journalURL:LiveAudioController.localJournalURL)
    @State private var selectedTab=1
    @State private var manualInputShown=false
#if SLIDEQA_DESKTOP_VALIDATION
    @State private var verificationStarted=false
#endif

    @MainActor private var documentHeading:String {
        if let index=model.index {
            return ui.format("{0} · {1}枚 · {2}",arguments:[index.deck.sourceFile,String(index.deck.pageCount),model.formatLabel])
        }
        return model.documentLabel.isEmpty ? ui.text("資料を選択してください"):model.documentLabel
    }
    @MainActor private func returnToStart() {
        if let session=model.liveSession {audio.stop(session:session,origin:.returnToStart)}
        model.returnToStart()
        manualInputShown=false;selectedTab=1
    }
    var body:some Scene {
        WindowGroup("SlideQA 0.32.0") {
            VStack(spacing:0) {
                HStack {
                    if model.index != nil || model.importing {
                        Button(ui.text("開始画面に戻る"),systemImage:"house") {returnToStart()}
                            .keyboardShortcut("n",modifiers:[.command,.shift])
                            .accessibilityIdentifier("presentation.home")
                            .accessibilityHint(ui.text("収音と現在の質問を停止して資料を閉じます．"))
                    }
                    Button(ui.text("ui.4b56425eecbf2940")) {selectedTab=1;model.choosePresentation(language:ui)}
                        .keyboardShortcut("o",modifiers:.command)
                        .accessibilityLabel(ui.text("ui.e4a5bb47a808ec43"))
                        .accessibilityHint(ui.text("ui.c7d36a22917d2565"))
                        .accessibilityIdentifier("presentation.open")
                        .disabled(audio.running || audio.starting || audio.stopping)
                    Text(documentHeading).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                        .accessibilityLabel(ui.text("ui.0f547e007f14d84d")).accessibilityValue(Text(documentHeading))
                    Spacer()
                    Picker(ui.text("表示言語"),selection:Binding(get:{ui.language},set:{ui.select($0)})) {
                        ForEach(InterfaceLanguage.allCases,id:\.self) {language in
                            Text(language.selectionLabel).tag(language)
                        }
                    }.pickerStyle(.segmented).labelsHidden().frame(width:270)
                        .accessibilityIdentifier("interface.language")
                        .accessibilityLabel(ui.text("表示言語"))
                    Button(ui.text("質問を入力…")) {manualInputShown=true}
                        .disabled(model.liveSession == nil || audio.running || audio.starting || audio.stopping)
                        .accessibilityIdentifier("question.manual")
                    if model.importing {
                        ProgressView().controlSize(.small).accessibilityLabel(ui.text("ui.42508c0915c419d9"))
                        Button(ui.text("ui.caef505ae9b26648")) {model.cancelImport()}
                            .accessibilityIdentifier("presentation.cancelImport")
                    }
                }.padding(12)
                if !model.importWarnings.isEmpty {
                    DisclosureGroup(ui.text("ui.aa2942e1de3e0ecd")) {
                        ForEach(model.importWarnings,id:\.self){Text(ui.text($0)).font(.caption).frame(maxWidth:.infinity,alignment:.leading)}
                    }.padding(.horizontal,12).padding(.bottom,8)
                }
                if let session=model.liveSession {
                    TabView(selection:$selectedTab) {
                        EvidenceMainView(model:model)
                            .tabItem{Text(ui.text("ui.9e4a11f727de4c34"))}.tag(0)
                        LiveSessionPanel(session:session,audio:audio,onOpenSource:{page in model.selectedPage=page;selectedTab=0})
                            .tabItem{Text(ui.text("ui.ace9f8d7189b9284"))}.tag(1)
                    }.frame(minWidth:900,minHeight:600)
                } else {
                    VStack(spacing:18) {
                        Text(model.importing ? ui.text("ui.3588d9223d82f6f6"):ui.text("ui.1a781986911ce71a")).font(.title)
                        Text(ui.text("ui.5ac01915738bd9a9"))
                        if !model.message.isEmpty {
                            Text(ui.text(model.message)).foregroundStyle(.red).textSelection(.enabled)
                                .accessibilityLabel(ui.text("ui.3f4013e2bb1e3161"))
                                .accessibilityValue(Text(ui.text(model.message)))
                        }
                    }.padding(30).frame(minWidth:900,minHeight:600,maxHeight:.infinity)
                }
            }
            .environmentObject(ui)
            .environment(\.locale,Locale(identifier:ui.language.rawValue))
#if SLIDEQA_DESKTOP_VALIDATION
            .task {
                guard !verificationStarted,LocalLaunchConfiguration(arguments:CommandLine.arguments).automaticModelCheck else {return}
                verificationStarted=true
                await DesktopVerification.run(model:model)
            }
#endif
            .sheet(isPresented:$manualInputShown) {
                if let session=model.liveSession {
                    ManualQuestionPanel(session:session).environmentObject(ui)
                }
            }
            .onReceive(NotificationCenter.default.publisher(for:NSWindow.willCloseNotification)){note in
                guard let window=note.object as? NSWindow,window.title=="SlideQA 0.32.0" else {return}
                if let session=model.liveSession {audio.stop(session:session,origin:.windowClosed)}
            }
            .onReceive(NotificationCenter.default.publisher(for:NSApplication.willTerminateNotification)){_ in
                if let session=model.liveSession {audio.stop(session:session,origin:.appTermination)}
            }
        }.defaultSize(width:1180,height:780)
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
