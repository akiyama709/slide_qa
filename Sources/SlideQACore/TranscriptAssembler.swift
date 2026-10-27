import Foundation

public struct TranscriptPiece: Sendable {
    public let start: Double
    public let end: Double
    public let text: String
    public let final: Bool
    public let alternatives: [String]
    public init(start: Double, end: Double, text: String, final: Bool, alternatives: [String] = []) {
        self.start = start; self.end = end; self.text = text; self.final = final; self.alternatives = alternatives
    }
}

public struct AssembledTranscript: Sendable {
    public let group: Int
    public let start: Double
    public let end: Double
    public let text: String
    public let final: Bool
    public let alternatives: [String]
}

/// Accumulates native word/phrase finalizations and replaces overlapping
/// volatile revisions. ASR "final" does not mean the whole question ended.
public struct TranscriptAssembler: Sendable {
    private var pieces: [TranscriptPiece] = []
    private var boundaries: [Double] = [0]
    public init() {}
    public mutating func endpoint(_ voicedEnd: Double) {
        let boundary = voicedEnd + 0.15
        if boundary > (boundaries.last ?? 0) + 0.05 { boundaries.append(boundary) }
    }
    private func group(for start: Double) -> Int { boundaries.lastIndex(where: { $0 <= start }) ?? 0 }

    public mutating func accept(_ piece: TranscriptPiece) -> [AssembledTranscript] {
        var touched: Set<Int> = [group(for: piece.start)]
        var retained: [TranscriptPiece] = []
        for old in pieces {
            let overlap = min(old.end, piece.end) - max(old.start, piece.start)
            let sameStart = abs(old.start - piece.start) < 0.001
            if overlap > 0.002 || sameStart { touched.insert(group(for: old.start)) }
            else { retained.append(old) }
        }
        pieces = retained
        pieces.append(piece)
        pieces.sort { $0.start < $1.start }
        let cutoff = (pieces.last?.end ?? piece.end) - 90
        pieces.removeAll { $0.final && $0.end < cutoff }
        return touched.sorted().map { bucket in
            let entries = pieces.filter { group(for: $0.start) == bucket }
            let text = entries.map(\.text).joined()
            var alternatives: [String] = []
            for (index, entry) in entries.enumerated() {
                for alternative in entry.alternatives where alternative != entry.text {
                    var parts = entries.map(\.text); parts[index] = alternative
                    alternatives.append(parts.joined())
                    if alternatives.count >= 12 { break }
                }
                if alternatives.count >= 12 { break }
            }
            return AssembledTranscript(group: bucket, start: entries.first?.start ?? piece.start,
                end: entries.last?.end ?? piece.end, text: text,
                final: entries.allSatisfy(\.final), alternatives: alternatives)
        }
    }
}
