import Foundation
import Testing
import SlideQACore
import RealDeckEvidenceCore
import NativeLocalIO

private func containsJapaneseCharacters(_ value:String)->Bool {
    value.unicodeScalars.contains { scalar in
        switch scalar.value {
        case 0x3000...0x30ff,0x3400...0x9fff,0xf900...0xfaff,0xff66...0xff9f,0x20000...0x323af:return true
        default:return false
        }
    }
}

@Suite struct InterfaceLocalizationTests {
    @Test func englishTypographyIsNotClassifiedAsJapaneseText() {
        #expect(!containsJapaneseCharacters("Draft · sources 1–5…"))
        #expect(containsJapaneseCharacters("日本語"))
        #expect(containsJapaneseCharacters("ｶﾀｶﾅ"))
    }
    @Test func languageResolutionHonorsChoiceAndHasDeterministicFallbacks() {
        #expect(InterfaceLanguage.resolve(stored:"en",preferredLanguages:["ja-JP"]) == .english)
        #expect(InterfaceLanguage.resolve(stored:"ja",preferredLanguages:["en-US"]) == .japanese)
        #expect(InterfaceLanguage.resolve(stored:nil,preferredLanguages:["fr-CA","ja-JP"]) == .japanese)
        #expect(InterfaceLanguage.resolve(stored:"unsupported",preferredLanguages:["de-DE"]) == .english)
        #expect(InterfaceLanguage.resolve(stored:nil,preferredLanguages:["en_GB"]) == .english)
    }
    @MainActor @Test func languageSelectionPersistsInAnIsolatedPreferenceDomain() throws {
        let domain="local.slideqa.localization-test."+UUID().uuidString
        let defaults=try #require(UserDefaults(suiteName:domain))
        defer {defaults.removePersistentDomain(forName:domain)}
        let store=InterfaceLanguageStore(defaults:defaults,preferredLanguages:["en"])
        #expect(store.language == .english)
        let languageChoices=InterfaceLanguage.allCases.map(\.selectionLabel)
        #expect(languageChoices==["English（英語）","日本語（Japanese）"])
        store.select(.english)
        #expect(defaults.string(forKey:InterfaceLanguageStore.preferenceKey) == "en")
        store.select(.japanese)
        #expect(InterfaceLanguage.allCases.map(\.selectionLabel)==languageChoices)
        #expect(defaults.string(forKey:InterfaceLanguageStore.preferenceKey) == "ja")
        #expect(defaults.synchronize())
        let reopened=try #require(UserDefaults(suiteName:domain))
        let restored=InterfaceLanguageStore(defaults:reopened,preferredLanguages:["en"])
        #expect(restored.language == .japanese)
        #expect(restored.text("開始") == "開始")
        restored.select(.english)
        #expect(InterfaceLanguage.allCases.map(\.selectionLabel)==languageChoices)
        #expect(restored.text("開始") == "Start")
        #expect(reopened.string(forKey:InterfaceLanguageStore.preferenceKey) == "en")
        #expect(InterfaceLanguageStore(defaults:defaults,preferredLanguages:["ja"]).language == .english)
    }
    @Test func bothNativeCatalogsLoadAndEnglishResourcesContainNoJapanese() throws {
        let en=InterfaceCatalog.entries(for:.english),ja=InterfaceCatalog.entries(for:.japanese)
        #expect(!en.isEmpty && Set(en.keys)==Set(ja.keys))
        let regex=try NSRegularExpression(pattern:#"\{[0-9]+\}"#)
        func tokens(_ value:String)->Set<String> {
            Set(regex.matches(in:value,range:NSRange(value.startIndex...,in:value)).compactMap{Range($0.range,in:value).map{String(value[$0])}})
        }
        for (key,value) in en {
            #expect(!value.isEmpty)
            #expect(!containsJapaneseCharacters(key+value))
            #expect(tokens(value)==tokens(try #require(ja[key])))
        }
        #expect(InterfaceCatalog.render("資料を開く…",language:.english) == "Open presentation…")
        #expect(InterfaceCatalog.render("資料を開く…",language:.japanese) == "資料を開く…")
        #expect(InterfaceCatalog.render("未登録のサービス診断",language:.english) == "未登録のサービス診断")
    }
    @Test func formattingDoesNotTranslateOrReinterpretSourceArguments() {
        let original="資料{1}：名前.pdf"
        let en=InterfaceCatalog.renderTemplate("{0} · {1}枚 · {2}",arguments:[original,"4","PDF"],language:.english)
        let ja=InterfaceCatalog.renderTemplate("{0} · {1}枚 · {2}",arguments:[original,"4","PDF"],language:.japanese)
        #expect(en == original+" · Slides: 4 · PDF")
        #expect(ja == original+" · 4枚 · PDF")
        #expect(InterfaceCatalog.renderTemplate("出典：{0}",arguments:["開始 {1}"],language:.english) == "Source: 開始 {1}")
    }
    @Test func legacySystemMessagesUseOnlyCompleteKnownTemplates() {
        let status="質問を待っています．SFSpeechRecognizerで端末内認識中です．"
        #expect(InterfaceCatalog.render(status,language:.english) == "Waiting for questions. On-device recognition uses SFSpeechRecognizer.")
        #expect(InterfaceCatalog.render(status,language:.japanese) == status)
        #expect(InterfaceCatalog.render("prefix "+status,language:.english) == "prefix "+status)
    }
    @Test func sourceAndDraftFailureLabelsHaveEnglishTranslations() {
        let dispositions:[EvidenceDisposition]=[.references,.ambiguous,.insufficient,.unmatched,.empty,.invalidPage,.tooLong]
        let failures:[LocalDraftFailure]=[.modelUnavailable,.modelStillRunning,.modelServiceFailed,.japaneseUnavailable,.insufficientSources,.inputLimit,
            .invalidCitations,.invalidText,.verbatimOnly,.unsupportedNumbers,.qualificationMissing,
            .groundingReviewFailed,.subjectMismatch,.unsupportedTerms,.deadlineExceeded,.generationFailed,
            .questionNotAnswered,.unclearResponse,.sourceRelationMismatch]
        let audio:[AudioFailure]=[.unavailable,.japaneseNotInstalled,.format,.conversion,.microphoneLocked,.microphoneDenied,.speechDenied,.overflow,.recognitionInterrupted]
        let imports:[PresentationImportError]=[.unsupportedFormat,.invalidInput,.protectedPDF,.noText,.malformedPDF,
            .malformedPackage,.malformedXML,.noPages,.unsafePart,.resourcePressure]
        let deck:[DeckError]=[.missing,.invalid,.size,.arguments]
        let messages=dispositions.map(\.label)+failures.map(\.message)+audio.compactMap(\.errorDescription)+imports.compactMap(\.errorDescription)+deck.compactMap(\.errorDescription)
        for original in messages {
            let value=InterfaceCatalog.render(original,language:.english)
            #expect(!containsJapaneseCharacters(value))
        }
    }
}
