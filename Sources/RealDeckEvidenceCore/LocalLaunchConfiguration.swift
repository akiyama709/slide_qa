import Foundation

/// Test launches may exercise local inference, but can never open a microphone.
/// Ordinary launches remain idle until the owner presses Start.
public struct LocalLaunchConfiguration:Sendable {
    public let safeSmoke:Bool
    public let automaticModelCheck:Bool
    public let microphoneStartAllowed:Bool
    public init(arguments:[String]) {
        safeSmoke=arguments.contains("--safe-ui-smoke")
        automaticModelCheck = !safeSmoke && arguments.contains("--verify-local-answers-no-audio")
        microphoneStartAllowed = !safeSmoke && !automaticModelCheck && !arguments.contains("--disable-microphone")
    }
}
