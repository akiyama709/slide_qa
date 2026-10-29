import Foundation

/// An SDK callback may arrive on any executor. Resume an async value without
/// inheriting the requesting actor or touching its state in the callback.
enum CallbackBridge {
    static func value<Value:Sendable>(
        request:@Sendable (@escaping @Sendable (Value)->Void)->Void
    ) async -> Value {
        await withCheckedContinuation { continuation in
            request { @Sendable value in continuation.resume(returning:value) }
        }
    }
}
