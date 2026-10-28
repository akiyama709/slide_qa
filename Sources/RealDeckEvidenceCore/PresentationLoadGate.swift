import Foundation

/// A later selection invalidates the previous file's asynchronous completion.
public struct PresentationLoadGate:Sendable {
    private var active:UUID?
    public init() {}
    public mutating func begin()->UUID {let value=UUID();active=value;return value}
    public func isCurrent(_ value:UUID)->Bool {active==value}
    public mutating func invalidate() {active=nil}
}
