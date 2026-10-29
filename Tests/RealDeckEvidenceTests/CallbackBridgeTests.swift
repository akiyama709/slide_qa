import Foundation
import Testing
@testable import NativeLocalIO

@MainActor @Suite struct CallbackBridgeTests {
    @Test func backgroundPermissionStyleCallbackResumesTheRequestingActor() async {
        let value:Bool=await CallbackBridge.value { @Sendable completion in
            DispatchQueue.global().async {completion(true)}
        }
        MainActor.assertIsolated()
        #expect(value)
    }
    @Test func callbackMayCompleteSynchronouslyWithoutRecordingOrPermissions() async {
        let value:Int=await CallbackBridge.value { @Sendable completion in completion(7) }
        MainActor.assertIsolated()
        #expect(value==7)
    }
}
