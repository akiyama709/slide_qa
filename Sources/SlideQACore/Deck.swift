import Foundation
import NaturalLanguage
import CryptoKit

public struct Slide: Codable, Identifiable, Sendable, Equatable {
    public let page: Int
    public let title: String
    public let text: String
    public let notes: String
    public let preparedScript: String?
    public let scriptSourcePages: [Int]?
    public var id: Int { page }
    public var responseDraft: String { preparedScript ?? extractiveDraft }

    public var passages: [String] {
        let source = notes.isEmpty ? text : notes
        return source.components(separatedBy: "\n\n").map {
            $0.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.joined()
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty }
    }

    public var extractiveDraft: String {
        let paragraphs = passages
        var result = ""
        for paragraph in paragraphs {
            if result.count > 140 { break }
            result += (result.isEmpty ? "" : "\n\n") + paragraph
        }
        return result
    }

    public func selectedPassages(_ indices: [Int]) -> String {
        let originals = Array(passages.prefix(10))
        return Array(Set(indices.filter { originals.indices.contains($0) })).sorted().prefix(2)
            .map { originals[$0] }.joined(separator: "\n\n")
    }
}

public struct Route: Codable, Sendable {
    public let page: Int
    public let cues: [Cue]
    public struct Cue: Codable, Sendable {
        public let pattern: String
        public let weight: Double
    }
}

public struct SlideMatch: Sendable, Equatable {
    public let slide: Slide
    public let score: Double
    public let basis: String
}

public struct Deck: Codable, Sendable {
    public let sourceFile: String
    public let sourceSHA256: String
    public let pageCount: Int
    public let printedNumbersVerified: Bool
    public let slides: [Slide]
    public let routes: [Route]

    private static let maximumBytes=5 * 1024 * 1024
    private static let maximumPages=500
    private static let demoDigest="ae8dcf942d4acfaeece45ce0b4e914279e4c748da4dfdac177a8eec8cc71722f"
    private enum CodingKeys:String,CodingKey {case sourceFile,sourceSHA256,pageCount,printedNumbersVerified,slides,routes}
    public init(from decoder:Decoder) throws {
        let values=try decoder.container(keyedBy:CodingKeys.self)
        slides=try values.decode([Slide].self,forKey:.slides)
        pageCount=try values.decodeIfPresent(Int.self,forKey:.pageCount) ?? slides.count
        sourceFile=try values.decodeIfPresent(String.self,forKey:.sourceFile) ?? "local-deck.json"
        sourceSHA256=try values.decodeIfPresent(String.self,forKey:.sourceSHA256) ?? ""
        // A JSON assertion is not verification against an original PDF.
        printedNumbersVerified=false
        routes=try values.decodeIfPresent([Route].self,forKey:.routes) ?? []
    }
    private init(sourceFile:String,sourceSHA256:String,slides:[Slide],routes:[Route]) {
        self.sourceFile=sourceFile;self.sourceSHA256=sourceSHA256
        self.pageCount=slides.count;self.printedNumbersVerified=false
        self.slides=slides;self.routes=routes
    }
    public static func hasExternalSelection(arguments:[String]=CommandLine.arguments)->Bool {
        arguments.contains{$0 == "--deck" || $0.hasPrefix("--deck=")}
    }
    public static func configured(arguments:[String]=CommandLine.arguments) throws -> Deck {
        guard hasExternalSelection(arguments:arguments) else {return try bundled()}
        guard !arguments.contains(where:{$0.hasPrefix("--deck=")}) else {throw DeckError.arguments}
        let positions=arguments.indices.filter{arguments[$0] == "--deck"}
        guard positions.count == 1,let position=positions.first,position+1<arguments.count else {throw DeckError.arguments}
        let path=arguments[position+1]
        guard !path.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,
              path.utf8.count<=4096,!path.hasPrefix("--"),!path.contains("://"),!path.contains("\0") else {throw DeckError.arguments}
        let expanded=(path as NSString).expandingTildeInPath
        let url=URL(fileURLWithPath:expanded).standardizedFileURL
        return try loadLocal(url,sourceName:url.lastPathComponent,isDemo:false)
    }
    public static func bundled() throws -> Deck {
        let packaged=Bundle.main.resourceURL?.appendingPathComponent("Deck/demo.json")
        let url:URL
        if let packaged,FileManager.default.fileExists(atPath:packaged.path) {url=packaged}
        else if Bundle.main.bundleURL.pathExtension == "app" {throw DeckError.missing}
        else if let resource=Bundle.module.url(forResource:"demo",withExtension:"json") {url=resource}
        else {throw DeckError.missing}
        return try loadLocal(url,sourceName:"synthetic-demo.json",isDemo:true)
    }
    private static func loadLocal(_ url:URL,sourceName:String,isDemo:Bool) throws -> Deck {
        guard url.isFileURL else {throw DeckError.arguments}
        let values=try url.resourceValues(forKeys:[.isRegularFileKey,.fileSizeKey])
        guard values.isRegularFile == true,let size=values.fileSize,size>0,size<=maximumBytes else {throw DeckError.size}
        let data=try Data(contentsOf:url)
        if isDemo {
            let digest=SHA256.hash(data:data).map{String(format:"%02x",$0)}.joined()
            guard digest == demoDigest else {throw DeckError.invalid}
        }
        return try validated(data:data,sourceName:sourceName,allowDemoRoutes:isDemo)
    }
    /// Validates JSON structure only. The digest identifies this JSON input,
    /// not an original PDF, printed numbering, factual truth or visual layout.
    public static func validated(data:Data,sourceName:String="local-deck.json",allowDemoRoutes:Bool=false) throws -> Deck {
        guard !data.isEmpty,data.count<=maximumBytes else {throw DeckError.size}
        let decoded=try JSONDecoder().decode(Deck.self,from:data)
        guard (1...maximumPages).contains(decoded.slides.count),decoded.pageCount == decoded.slides.count,
              decoded.slides.map(\.page) == Array(1...decoded.slides.count) else {throw DeckError.invalid}
        var total=0
        for slide in decoded.slides {
            guard !slide.title.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,
                  slide.title.count<=300,slide.text.count<=20_000,slide.notes.count<=20_000,
                  !(slide.text+slide.notes).trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else {throw DeckError.invalid}
            total+=slide.title.count+slide.text.count+slide.notes.count
        }
        guard total<=2_000_000,decoded.routes.count<=maximumPages else {throw DeckError.size}
        for route in decoded.routes {
            guard (1...decoded.slides.count).contains(route.page),route.cues.count<=20,
                  route.cues.allSatisfy({!$0.pattern.isEmpty && $0.pattern.count<=256 && $0.weight.isFinite && $0.weight>0 && $0.weight<=100}) else {throw DeckError.invalid}
        }
        let digest=SHA256.hash(data:data).map{String(format:"%02x",$0)}.joined()
        let slides=decoded.slides.map{Slide(page:$0.page,title:$0.title,text:$0.text,notes:$0.notes,preparedScript:nil,scriptSourcePages:nil)}
        // Custom JSON routes are never executed as regular expressions.
        return Deck(sourceFile:URL(fileURLWithPath:sourceName).lastPathComponent,sourceSHA256:digest,
            slides:slides,routes:allowDemoRoutes ? decoded.routes:[])
    }

    public func match(_ question: String) -> SlideMatch? {
        let q = question.precomposedStringWithCompatibilityMapping.lowercased()
        var scores: [Int: Double] = [:]
        for route in routes {
            let score = route.cues.reduce(0.0) { total, cue in
                total + (q.range(of: cue.pattern, options: .regularExpression) == nil ? 0 : cue.weight)
            }
            if score > 0 { scores[route.page] = score }
        }
        let normalized = normalize(q)
        for slide in slides {
            let title = normalize(slide.title)
            if title.count >= 8, normalized.contains(title) { scores[slide.page] = max(scores[slide.page] ?? 0, 20) }
        }
        let ranked = scores.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
        guard let first = ranked.first, first.value >= 6 else { return nil }
        if ranked.count > 1, first.value - ranked[1].value <= 2 { return nil }
        guard let slide = slides.first(where: { $0.page == first.key }) else { return nil }
        return SlideMatch(slide: slide, score: first.value, basis: "資料専用ルール／正確な表題索引")
    }

    public func modelCandidate(page: Int, question: String) -> SlideMatch? {
        guard let slide = slides.first(where: { $0.page == page }) else { return nil }
        // A model suggestion alone is insufficient. Require a non-generic
        // content word in the actual source; otherwise keep "no match".
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = question; tokenizer.setLanguage(.japanese)
        let generic: Set<String> = ["研究", "今回", "予定", "内容", "意味", "根拠", "質問", "方法"]
        var supported = false
        let source = normalize(slide.title + slide.text)
        tokenizer.enumerateTokens(in: question.startIndex..<question.endIndex) { range, _ in
            let word = normalize(String(question[range]))
            if word.count >= 2, !generic.contains(word), word.range(of: #"[\p{Han}a-z0-9]"#, options: .regularExpression) != nil,
               source.contains(word) { supported = true }
            return true
        }
        guard supported else { return nil }
        return SlideMatch(slide: slide, score: 0, basis: "端末内モデルの照合候補（認識誤記の可能性）")
    }
}

public enum DeckError:Error,LocalizedError {
    case missing,invalid,size,arguments
    public var errorDescription:String? {
        switch self {
        case .missing:"同梱の架空デモを読み込めません．"
        case .invalid:"資料JSONのページ連番・表題・本文などを確認してください．"
        case .size:"資料JSONのサイズ又はページ数が上限を超えています．"
        case .arguments:"ローカルJSONを --deck /absolute/path/deck.json の形式で一つ指定してください．"
        }
    }
}

public func normalize(_ text: String) -> String {
    text.precomposedStringWithCompatibilityMapping.lowercased().replacingOccurrences(of: #"[\W_]+"#, with: "", options: .regularExpression)
}
