import Testing
import RealDeckEvidenceCore
@testable import NativeLocalIO

@MainActor @Suite struct MicrophoneOwnershipTests {
    @Test func verificationLaunchesCannotOpenMicrophoneEvenWithoutTheRedundantDisableFlag() {
        let native=LocalLaunchConfiguration(arguments:["SlideQA","--verify-local-answers-no-audio"])
        #expect(native.automaticModelCheck && !native.microphoneStartAllowed)
        #expect(!native.writesOwnerDiagnostics)
        let both=LocalLaunchConfiguration(arguments:["SlideQA","--verify-local-answers-no-audio","--safe-ui-smoke"])
        #expect(both.safeSmoke && !both.automaticModelCheck && !both.microphoneStartAllowed)
        #expect(!both.writesOwnerDiagnostics)
        #expect(!LocalLaunchConfiguration(arguments:["SlideQA","--disable-microphone"]).microphoneStartAllowed)
        let normal=LocalLaunchConfiguration(arguments:["SlideQA"])
        #expect(!normal.safeSmoke && !normal.automaticModelCheck)
        #expect(normal.writesOwnerDiagnostics)
    }
    @Test func nativePipelineCannotReachPermissionsWithoutOwnerConsent() async {
        let pipeline=NativeAudioPipeline()
        do {
            try await pipeline.startMicrophone(authorizedLaunch:true,ownerConsent:false,allowPermissionPrompt:true,
                onUpdate:{_ in Issue.record("未確認の入力コールバック")},onEndpoint:{_ in},onFailure:{_ in})
            Issue.record("本人確認なしで開始が成功しました")
        } catch AudioFailure.microphoneLocked {} catch {Issue.record("本人確認のゲートより先へ進みました")}
    }
    @Test func compatibilityPipelineCannotReachPermissionsWithoutOwnerConsent() async {
        let pipeline=LegacyOfflineMicrophone()
        do {
            try await pipeline.start(authorizedLaunch:true,ownerConsent:false,allowPermissionPrompt:true,
                onUpdate:{_ in Issue.record("未確認の入力コールバック")},onEndpoint:{_ in},onFailure:{_ in})
            Issue.record("本人確認なしで互換認識が開始しました")
        } catch AudioFailure.microphoneLocked {} catch {Issue.record("互換認識が本人確認のゲートより先へ進みました")}
    }
}
