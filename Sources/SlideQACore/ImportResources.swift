import Foundation
import Dispatch
import CryptoKit

/// Stops an import when macOS reports actual memory pressure. This is not a
/// document-size/page quota and does not read hardware settings or install assets.
final class ImportResourceMonitor:@unchecked Sendable {
    private let lock=NSLock()
    private var pressured=false
    private var source:DispatchSourceMemoryPressure?
    init(observeSystem:Bool=true) {
        if observeSystem {
            let source=DispatchSource.makeMemoryPressureSource(eventMask:[.warning,.critical],queue:.global(qos:.utility))
            source.setEventHandler { @Sendable [weak self] in self?.signalPressure() }
            self.source=source;source.resume()
        }
    }
    func signalPressure() {lock.lock();pressured=true;lock.unlock()}
    func check() throws {
        lock.lock();let value=pressured;lock.unlock()
        if value {throw PresentationImportError.resourcePressure}
    }
    deinit {source?.cancel()}
}

public enum ImportResources {
    @TaskLocal static var monitor:ImportResourceMonitor?
    public static func check() throws {
        try Task.checkCancellation()
        try monitor?.check()
    }
    public static func withMonitoring<T>(_ operation:() throws ->T) throws ->T {
        if monitor != nil {try check();return try operation()}
        return try $monitor.withValue(ImportResourceMonitor()) {
            try check()
            let result=try operation()
            try check()
            return result
        }
    }
    static func digest(_ data:Data) throws ->String {
        var hash=SHA256()
        let chunk=1024*1024
        for offset in stride(from:0,to:data.count,by:chunk) {
            try check()
            let start=data.startIndex+offset,end=data.startIndex+min(offset+chunk,data.count)
            hash.update(data:data[start..<end])
        }
        try check()
        return hash.finalize().map{String(format:"%02x",$0)}.joined()
    }
}
