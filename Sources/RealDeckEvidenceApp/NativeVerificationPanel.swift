import Combine
import Foundation
import NativeLocalIO
import RealDeckEvidenceCore
import SlideQACore
import SwiftUI

/// Owner-invoked diagnostics for the bundled fictional demo only.
/// User-selected local decks never enter this diagnostic generation path.
@MainActor final class NativeVerificationModel:ObservableObject {
    @Published private(set) var running=false
    @Published private(set) var status="未実行です．確認中も録音しません．"
    @Published private(set) var readiness:[String:String]=[:]
    @Published private(set) var summaries:[String]=[]
    @Published private(set) var savedReport=""
    let safeMode=CommandLine.arguments.contains("--safe-ui-smoke")
    private var operation=UUID()
    private var workTask:Task<Void,Never>?
    private var activeReport:URL?
    private var completedCases:[[String:Any]]=[]
    private var startedUTC=""

    private func diagnosticsDirectory() throws -> URL {
        let root=try FileManager.default.url(for:.applicationSupportDirectory,in:.userDomainMask,
            appropriateFor:nil,create:true).appendingPathComponent("SlideQA/Diagnostics",isDirectory:true)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        return root
    }
    func saveLaunchOutcome(_ values:[String:Any])->String {
        do {
            let url=try diagnosticsDirectory().appendingPathComponent("launch-"+UUID().uuidString+".json")
            let data=try JSONSerialization.data(withJSONObject:values,options:[.prettyPrinted,.sortedKeys])
            try data.write(to:url,options:.atomic)
            return url.path
        } catch {return "ローカルの診断結果を保存できませんでした．"}
    }
    private func checkpoint(complete:Bool,timedOut:Bool=false,cancelled:Bool=false) {
        do {
            if activeReport == nil {activeReport=try diagnosticsDirectory().appendingPathComponent("demo-"+operation.uuidString+".json")}
            guard let activeReport else {return}
            let values:[String:Any]=["kind":"fictional-demo-on-device-check","complete":complete,
                "startedUTC":startedUTC,"updatedUTC":ISO8601DateFormatter().string(from:Date()),
                "cases":completedCases,"timedOut":timedOut,"cancelled":cancelled,
                "underlyingModelFinishedConfirmed":complete,"recordingStarted":false,"permissionRequested":false,
                "externalAPIUsed":false,"trueSpeechEndLatencyMeasured":false,"semanticTruthProved":false]
            let data=try JSONSerialization.data(withJSONObject:values,options:[.prettyPrinted,.sortedKeys])
            try data.write(to:activeReport,options:.atomic);savedReport=activeReport.path
        } catch {status="途中結果をローカルへ保存できませんでした．"}
    }
    func cancelVerification(timedOut:Bool) {
        workTask?.cancel();workTask=nil;operation=UUID();running=false
        checkpoint(complete:false,timedOut:timedOut,cancelled:true)
        status="確認を中止しました．未完了を成功には含めません．"
    }
    func inspect() {
        guard !running,!safeMode else {return}
        running=true;operation=UUID();let op=operation
        workTask=Task {
            let values=await NativeReadiness.inspect()
            guard operation == op,!Task.isCancelled else {return}
            readiness=values
            savedReport=saveLaunchOutcome(["kind":"local-readiness-metadata","values":values,
                "recordingStarted":false,"permissionRequested":false,"externalAPIUsed":false])
            running=false;status="準備状態のメタデータを確認しました．取得や許可申請は行っていません．"
        }
    }
    func verifyAnswers() {
        guard !running,!safeMode else {return}
        savedReport="";summaries=[]
        guard !Deck.hasExternalSelection() else {
            status="--deck で選択した資料にはデモ検証を実行しません．通常の質問画面だけを使用してください．"
            savedReport=saveLaunchOutcome(["kind":"demo-check-refused","reason":"external-local-deck-selected",
                "modelInvoked":false,"recordingStarted":false,"permissionRequested":false,"externalAPIUsed":false])
            return
        }
        running=true;operation=UUID();let op=operation
        activeReport=nil;completedCases=[];startedUTC=ISO8601DateFormatter().string(from:Date())
        status="架空デモの3問を端末内モデルで確認しています．録音しません．"
        workTask=Task {
            guard operation == op,!Task.isCancelled else {return}
            checkpoint(complete:false)
            do {
                let index=try EvidenceIndex.bundled()
                let questions=["オリオン装置とリラ装置は何を測定しますか．",
                    "警報だけで故障と判断しますか．","校正は何日ごとに行いますか．"]
                for question in questions {
                    guard operation == op,!Task.isCancelled else {return}
                    var report:[String:Any]=["question":question,"syntheticOnly":true]
                    let start=ContinuousClock.now
                    do {
                        var pipeline=IncrementalQuestions(phase:.qna)
                        let reference=index.search(question)
                        _=try pipeline.consume(turnID:"demo",order:0,text:question,final:true,deck:LiveQuestionDeck(index:index))
                        guard let ticket=pipeline.tickets.first else {throw LocalDraftFailure.insufficientSources}
                        let request=try LocalDraftRequest(ticket:ticket,reference:reference)
                        let generator=OnDeviceDraftGenerator(displayPolicy:.unverifiedPrototype)
                        let draft=try await generator.generate(request)
                        report["draftShown"] = !draft.abstained
                        report["answer"]=draft.text;report["reviewState"]=draft.reviewState.rawValue
                        report["strictModelReviewPassed"]=draft.localModelReviewPassed
                        report["unverifiedPrototype"]=draft.reviewState == .unverifiedAfterModelReview
                        report["sourceIDs"]=draft.citations.map(\.id)
                    } catch let error as LocalDraftFailure {
                        report["draftShown"]=false;report["failure"]=String(describing:error)
                    } catch {report["draftShown"]=false;report["failure"]="local-execution-error"}
                    guard operation == op,!Task.isCancelled else {return}
                    let elapsed=start.duration(to:.now)
                    report["requestThroughValidationSeconds"]=Double(elapsed.components.seconds)+Double(elapsed.components.attoseconds)/1e18
                    completedCases.append(report);checkpoint(complete:false)
                    summaries.append(question+((report["draftShown"] as? Bool == true) ? "：草案を作成（要確認）":"：保留又は実行失敗"))
                }
                guard operation == op,!Task.isCancelled else {return}
                checkpoint(complete:true);status="3問の確認を終了しました．表示・保留と実行失敗を区別して結果に保存しました．"
            } catch {status="架空デモを読み込めず確認を終了しました．";checkpoint(complete:false)}
            running=false;workTask=nil
        }
    }
}

struct NativeVerificationPanel:View {
    @EnvironmentObject private var ui:InterfaceLanguageStore
    @ObservedObject var model:NativeVerificationModel
    var body:some View {
        VStack(alignment:.leading,spacing:8) {
            Text(ui.text("ui.96fb12b3d90b7066")).font(.headline)
            HStack {
                Button(ui.text("ui.0b8bfa95fb96cec9")){model.inspect()}
                Button(ui.text("ui.3d866966b8dcca79")){model.verifyAnswers()}
                    .disabled(Deck.hasExternalSelection())
            }.disabled(model.running || model.safeMode)
            Text(ui.text(model.status)).font(.caption)
            if !model.readiness.isEmpty {
                Text(ui.format("ui.ee2a88d1526f5831",arguments:[String(describing:model.readiness["systemLanguageModel"] ?? ui.text("不明")),String(describing:model.readiness["japaneseSupported"] ?? ui.text("不明"))])).font(.caption)
            }
            ForEach(model.summaries,id:\.self){Text(ui.text($0)).font(.caption)}
            if !model.savedReport.isEmpty {Text(model.savedReport).font(.caption2).textSelection(.enabled)}
        }
    }
}
