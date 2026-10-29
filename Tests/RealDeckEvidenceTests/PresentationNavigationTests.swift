import Foundation
import Testing
@testable import RealDeckEvidenceApp

@MainActor @Suite struct PresentationNavigationTests {
    private func file(_ title:String) throws -> URL {
        let url=FileManager.default.temporaryDirectory.appendingPathComponent("slideqa-navigation-"+UUID().uuidString+".json")
        let object:[String:Any]=["pageCount":1,"slides":[["page":1,"title":title,"text":"This fictional page describes "+title+".","notes":""]]]
        try JSONSerialization.data(withJSONObject:object).write(to:url)
        return url
    }
    private func finish(_ model:EvidenceViewModel) async throws {
        for _ in 0..<200 {
            if !model.importing {return}
            try await Task.sleep(for:.milliseconds(10))
        }
        Issue.record("Import did not finish within the bounded test wait.")
    }
    @Test func ordinaryAndObsoleteDiagnosticLaunchesDoNotLoadADemo() {
        for args in [[],["SlideQA"],["SlideQA","--safe-ui-smoke"],["SlideQA","--verify-local-answers-no-audio"]] {
            let model=EvidenceViewModel(arguments:args)
            #expect(model.index==nil && model.liveSession==nil && !model.importing)
        }
    }
    @Test func returnToStartStopsTheSessionAndAllowsAnotherPresentation() async throws {
        let a=try file("Fictional cobalt"),b=try file("Fictional willow")
        defer {try? FileManager.default.removeItem(at:a);try? FileManager.default.removeItem(at:b)}
        let model=EvidenceViewModel(arguments:[])
        model.load(a);try await finish(model)
        let retired=try #require(model.liveSession)
        retired.beginContinuousQuestions()
        model.question="A previous question";model.selectedPage=1
        model.returnToStart()
        #expect(!retired.acceptingInput)
        #expect(model.index==nil && model.liveSession==nil && !model.importing)
        #expect(model.question.isEmpty && model.results.isEmpty && model.documentLabel.isEmpty)
        #expect(model.selectedPage==nil && model.importWarnings.isEmpty)
        model.load(b);try await finish(model)
        #expect(model.index?.deck.slides.first?.title=="Fictional willow")
    }
    @Test func returningDuringImportRejectsItsLateCompletion() async throws {
        let url=try file("Fictional late import")
        defer {try? FileManager.default.removeItem(at:url)}
        let model=EvidenceViewModel(arguments:[])
        model.load(url);model.returnToStart()
        try await Task.sleep(for:.milliseconds(100))
        #expect(model.index==nil && model.liveSession==nil && !model.importing)
        #expect(model.documentLabel.isEmpty)
    }
    @Test func failedImportCanReturnHomeAndLoadAnotherFileWithoutOldAnswers() async throws {
        let good=try file("Fictional recovery"),bad=good.deletingPathExtension().appendingPathExtension("pptx")
        defer {try? FileManager.default.removeItem(at:good);try? FileManager.default.removeItem(at:bad)}
        try Data("This is not an OOXML archive.".utf8).write(to:bad)
        let model=EvidenceViewModel(arguments:[])
        model.load(good);try await finish(model)
        let previous=try #require(model.liveSession)
        previous.beginInput(phase:.qna)
        model.question="An old question";model.selectedPage=1
        model.load(bad);try await finish(model)
        #expect(!previous.acceptingInput && model.liveSession==nil && model.index==nil)
        #expect(!model.message.isEmpty && !model.importing && model.question.isEmpty)
        #expect(model.originalFileSHA256==nil && model.selectedPage==nil)
        model.returnToStart()
        #expect(model.message.isEmpty && model.documentLabel.isEmpty)
        model.load(good);try await finish(model)
        #expect(model.index?.deck.slides.first?.title=="Fictional recovery")
        #expect(model.liveSession !== previous && model.question.isEmpty && model.results.isEmpty)
    }
}
