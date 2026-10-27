import AVFoundation
import Foundation
import FoundationModels
import Speech

/// Read-only metadata. Does not prepare an analyzer, start a recognition
/// request, request authorization, install assets or generate content.
public enum NativeReadiness {
    @MainActor public static func inspect() async -> [String:String] {
        let model=SystemLanguageModel.default
        let modelState:String
        switch model.availability {
        case .available:modelState="available"
        case .unavailable(let reason):
            switch reason {
            case .deviceNotEligible:modelState="deviceNotEligible"
            case .appleIntelligenceNotEnabled:modelState="appleIntelligenceNotEnabled"
            case .modelNotReady:modelState="modelNotReady"
            @unknown default:modelState="unknownUnavailableReason"
            }
        }
        let locales=await SpeechTranscriber.installedLocales
        let japanese=locales.first{$0.language.languageCode?.identifier == "ja"}
        var installed=false
        if let japanese {
            let module=SpeechTranscriber(locale:japanese,transcriptionOptions:[],
                reportingOptions:[.volatileResults,.alternativeTranscriptions,.fastResults],attributeOptions:[.audioTimeRange])
            installed=await AssetInventory.status(forModules:[module]) == .installed
        }
        let dictationLocales=await DictationTranscriber.installedLocales
        let dictationJapanese=dictationLocales.first{$0.language.languageCode?.identifier == "ja"}
        var dictationInstalled=false
        if let dictationJapanese {
            let module=DictationTranscriber(locale:dictationJapanese,contentHints:[.farField],transcriptionOptions:[.punctuation],
                reportingOptions:[.volatileResults,.alternativeTranscriptions,.frequentFinalization],attributeOptions:[.audioTimeRange])
            dictationInstalled=await AssetInventory.status(forModules:[module]) == .installed
        }
        let legacy=SFSpeechRecognizer(locale:Locale(identifier:"ja-JP"))
        let microphone:String
        switch AVCaptureDevice.authorizationStatus(for:.audio) {
        case .authorized:microphone="authorized"
        case .notDetermined:microphone="notDetermined"
        case .denied:microphone="denied"
        case .restricted:microphone="restricted"
        @unknown default:microphone="unknown"
        }
        return ["systemLanguageModel":modelState,"japaneseSupported":String(model.supportsLocale(Locale(identifier:"ja-JP"))),
            "speechTranscriberAvailable":String(SpeechTranscriber.isAvailable),"japaneseSpeechLocaleInstalled":String(japanese != nil),
            "japaneseSpeechAssetsInstalled":String(installed),"microphoneAuthorization":microphone,
            "japaneseDictationLocaleInstalled":String(dictationJapanese != nil),"japaneseDictationAssetsInstalled":String(dictationInstalled),
            "legacyJapaneseOnDeviceSupport":String(legacy?.supportsOnDeviceRecognition ?? false),
            "recordingStarted":"false","permissionRequested":"false","downloadRequested":"false"]
    }
}
