import Foundation
import NaturalLanguage
import SlideQACore

public enum EvidenceSource: String, Codable, Sendable {
    case slideText, speakerNotes
    public var label: String { self == .slideText ? "スライドの抽出本文" : "発表ノート（全文）" }
}

public struct EvidencePassage: Identifiable, Equatable, Sendable {
    public let page: Int
    public let title: String
    public let source: EvidenceSource
    public let paragraph: Int
    public let text: String
    public var id: String { "\(page):\(source.rawValue):\(paragraph)" }
    public var citation: String {
        "\(page)：\(title) ／ \(source.label)" + (source == .slideText ? "・第\(paragraph)段落" : "")
    }
}

public struct EvidenceCandidate: Identifiable, Sendable {
    public let page: Int
    public let title: String
    public let basis: String
    public let passages: [EvidencePassage]
    public let matchedTerms: [String]
    /// Exact page title/navigation labels; vocabulary context, not evidence.
    public let contextLabels:[String]
    public var id: Int { page }
}

public enum EvidenceDisposition: String, Sendable {
    case references, ambiguous, insufficient, unmatched, empty, invalidPage, tooLong
    public var label: String {
        switch self {
        case .references: "資料の参考箇所が見つかりました"
        case .ambiguous: "複数の資料候補があります"
        case .insufficient: "資料候補はありますが，質問に対応する本文を確認できません"
        case .unmatched: "対応する資料を確認できません"
        case .empty: "質問または探したい語を入力してください"
        case .invalidPage: "指定された番号は資料の範囲外です"
        case .tooLong: "1件の質問を4,000文字以内にしてください"
        }
    }
}

public struct EvidenceSearchResult: Identifiable, Sendable {
    public let id = UUID()
    public let question: String
    public let disposition: EvidenceDisposition
    public let candidates: [EvidenceCandidate]
    public let elapsedMilliseconds: Double
}

/// A source retriever, not an answer generator or entailment classifier.
/// Optional synthetic-demo routes guide selection. Every displayed quotation is a
/// complete original paragraph (or an entire speaker note), preserved from the selected local JSON.
public struct EvidenceIndex: Sendable {
    public let deck: Deck
    public let passages: [EvidencePassage]
    private let wordsByPassage: [String: Set<String>]
    private let wordsByPage: [Int: Set<String>]
    private let titleWordsByPage: [Int: Set<String>]
    private let passagesByPage: [Int: [EvidencePassage]]
    private let referenceEligibleIDs: Set<String>
    private let rarity: [String: Double]
    private let navigationLabelsByPage:[Int:String]
    private let normalizedTextByPage:[Int:String]

    public init(deck: Deck) {
        self.deck = deck
        normalizedTextByPage=Dictionary(uniqueKeysWithValues:deck.slides.map{($0.page,normalize($0.title+"\n"+$0.text+"\n"+$0.notes))})
        let navigationCandidates=deck.slides.compactMap {slide -> (Int,String)? in
            let first=(slide.text.components(separatedBy:"\n\n").first ?? "").trimmingCharacters(in:.whitespacesAndNewlines)
            let sections=["背景","目的","研究計画","実施体制","評価"].filter{first.contains($0)}.count
            guard first.count<=150,sections>=3,!first.contains("。"),!first.contains("．") else {return nil}
            return(slide.page,first)
        }
        let navigationFrequency=Dictionary(grouping:navigationCandidates,by:{normalize($0.1)}).mapValues(\.count)
        navigationLabelsByPage=Dictionary(uniqueKeysWithValues:navigationCandidates.filter{navigationFrequency[normalize($0.1),default:0]>=2})
        var passages: [EvidencePassage] = []
        for slide in deck.slides {
            for (offset, paragraph) in slide.text.components(separatedBy: "\n\n").enumerated() {
                let original = paragraph.trimmingCharacters(in: .whitespacesAndNewlines)
                if !original.isEmpty {
                    passages.append(EvidencePassage(page: slide.page, title: slide.title, source: .slideText,
                        paragraph: offset + 1, text: original))
                }
            }
            // Preserve qualifications and negations rather than picking an
            // isolated sentence out of a short explanatory speaker note.
            if !slide.notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                passages.append(EvidencePassage(page: slide.page, title: slide.title,
                    source: .speakerNotes, paragraph: 1, text: slide.notes))
            }
        }
        self.passages = passages
        wordsByPassage = Dictionary(uniqueKeysWithValues: passages.map { ($0.id, Self.words($0.text)) })
        passagesByPage = Dictionary(grouping: passages, by: \.page)
        referenceEligibleIDs = Set(passages.filter { passage in
            if passage.source == .speakerNotes { return true }
            let withoutLeadingPage = passage.text.replacingOccurrences(
                of: #"^\s*[0-9]+\s*[:：]?\s*"#, with: "", options: .regularExpression)
            // A repeated heading or page number is navigation, not evidence.
            return normalize(passage.text) != normalize(passage.title) &&
                normalize(withoutLeadingPage) != normalize(passage.title) &&
                !Self.words(passage.text).isEmpty
        }.map(\.id))
        var pageWords: [Int: Set<String>] = [:]
        var titleWords: [Int: Set<String>] = [:]
        var frequencies: [String: Int] = [:]
        for slide in deck.slides {
            let terms = Self.words(slide.title + "\n" + slide.text + "\n" + slide.notes)
            pageWords[slide.page] = terms
            titleWords[slide.page] = Self.words(slide.title)
            for term in terms { frequencies[term, default: 0] += 1 }
        }
        wordsByPage = pageWords
        titleWordsByPage = titleWords
        rarity = frequencies.mapValues { log(1 + Double(deck.slides.count) / Double($0)) }
    }

    public static func bundled() throws -> EvidenceIndex { EvidenceIndex(deck: try Deck.bundled()) }
    public static func configured(arguments:[String]=CommandLine.arguments) throws -> EvidenceIndex { EvidenceIndex(deck:try Deck.configured(arguments:arguments)) }

    public func slide(page: Int) -> Slide? { deck.slides.first { $0.page == page } }

    public func search(_ raw: String) -> EvidenceSearchResult {
        let start = ContinuousClock.now
        let question = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        func result(_ disposition: EvidenceDisposition, _ candidates: [EvidenceCandidate] = []) -> EvidenceSearchResult {
            let duration = start.duration(to: .now).components
            return EvidenceSearchResult(question: question, disposition: disposition, candidates: candidates,
                elapsedMilliseconds: Double(duration.seconds) * 1_000 + Double(duration.attoseconds) / 1e15)
        }
        guard !question.isEmpty else { return result(.empty) }
        guard question.count <= 4_000 else { return result(.tooLong) }
        let q = normalize(question)
        let terms = Self.queryWords(question)
        let phrases=Self.queryPhrases(q)
        // Retrieval-only vocabulary expansion. These related terms never add
        // claims to a source or bypass the separate answer-grounding gate.
        let explicit = Self.requestedPages(question)
        if explicit.contains(where: { !(1...deck.pageCount).contains($0) }) { return result(.invalidPage) }
        let route = deck.match(question)
        var ranked: [(slide: Slide, score: Double, basis: String, matches: Set<String>, anchored: Bool)] = []
        for slide in deck.slides {
            let title = normalize(slide.title)
            let exactTitle = title.count >= 5 && q.contains(title)
            let numbered = explicit.contains(slide.page)
            if !explicit.isEmpty && !numbered { continue }
            let matches = terms.intersection(wordsByPage[slide.page] ?? [])
            let titleTerms = titleWordsByPage[slide.page] ?? []
            let lexical = matches.reduce(0.0) { $0 + (rarity[$1] ?? 1) * (titleTerms.contains($1) ? 2 : 1) }
            let routed = route?.slide.page == slide.page
            // One rare, specific source term is useful for reference lookup;
            // weak/common single-word overlap must not force a source match.
            let specific = matches.contains { $0.count >= 3 && (rarity[$0] ?? 0) > 1.5 }
            guard numbered || exactTitle || routed || (matches.count >= 2 && lexical >= 4) || specific else { continue }
            // Coherent content phrases distinguish relation questions from
            // pages sharing isolated topic words. Retrieval remains a hint,
            // and every answer still goes through the source/meaning gates.
            let phraseMatches=phrases.filter{normalizedTextByPage[slide.page]?.contains($0) == true}.count
            let score = lexical + Double(phraseMatches) + (routed ? 12 : 0) + (exactTitle ? 30 : 0) + (numbered ? 50 : 0)
            let basis = numbered ? "指定されたスライド番号" : exactTitle ? "正確な表題との一致" : routed ? "合成デモの照合規則＋原文内の語" : "質問語と原文内の語の一致"
            ranked.append((slide, score, basis, matches, numbered || exactTitle))
        }
        ranked.sort { $0.score == $1.score ? $0.slide.page < $1.slide.page : $0.score > $1.score }
        guard let first = ranked.first else { return result(.unmatched) }
        let threshold = first.score * 0.78
        let anchored = ranked.filter { $0.anchored }
        let contenders = (anchored.isEmpty ? ranked.filter { $0.score >= threshold } : anchored).prefix(3)
        let candidates = contenders.map { entry in
            let originals = passagesByPage[entry.slide.page] ?? []
            let matching = originals.compactMap { passage -> (EvidencePassage, Double)? in
                guard referenceEligibleIDs.contains(passage.id) else { return nil }
                let intersection = terms.intersection(wordsByPassage[passage.id] ?? [])
                guard !intersection.isEmpty else { return nil }
                let weight = intersection.reduce(0.0) { $0 + (rarity[$1] ?? 1) }
                return (passage, weight + (passage.source == .speakerNotes ? 0.5 : 0))
            }.sorted { $0.1 == $1.1 ? $0.0.id < $1.0.id : $0.1 > $1.1 }
            // A number or title selects a slide for inspection; it does not
            // prove that this source answers an unrelated question.
            let note=originals.first(where:{$0.source == .speakerNotes})
            func compact(_ text:String)->String {
                text.precomposedStringWithCompatibilityMapping.replacingOccurrences(of:#"\s+"#,with:"",options:.regularExpression)
            }
            let completeNote=note.map{compact($0.text)} ?? ""
            // A full note already contains its duplicated PDF narration.
            // Use the remaining slots for matching PDF facts absent from that
            // note, instead of spending them on the same paragraph twice.
            let distinctPDF=matching.filter {item in
                guard item.0.source == .slideText else {return false}
                let text=compact(item.0.text)
                return note == nil || !completeNote.contains(text)
            }
            var selected=Array(distinctPDF.prefix(note == nil ? 3:2)).map{$0.0}
            // An unrelated numbered page still has no selected evidence.
            if !matching.isEmpty,let note {
                selected.insert(note,at:0)
            }
            return EvidenceCandidate(page: entry.slide.page, title: entry.slide.title, basis: entry.basis,
                passages: selected, matchedTerms: entry.matches.sorted(),
                contextLabels:[entry.slide.title]+(navigationLabelsByPage[entry.slide.page].map{[$0]} ?? []))
        }
        if candidates.allSatisfy({ $0.passages.isEmpty }) { return result(.insufficient, candidates) }
        return result(candidates.count > 1 ? .ambiguous : .references, candidates)
    }

    private static func queryPhrases(_ normalized:String)->[String] {
        let chars=Array(normalized);guard chars.count>=5 else {return []}
        var phrases:[String]=[],seen:Set<String>=[]
        for offset in 0...(chars.count-5) {
            let phrase=String(chars[offset..<offset+5])
            guard phrase.range(of:#"[\p{Han}\p{Katakana}].*[\p{Han}\p{Katakana}]"#,options:.regularExpression) != nil else {continue}
            if seen.insert(phrase).inserted {phrases.append(phrase)}
            if phrases.count>=64 {break}
        }
        return phrases
    }

    public func quotesAreVerbatim(_ result: EvidenceSearchResult) -> Bool {
        result.candidates.allSatisfy { candidate in
            guard let slide = slide(page: candidate.page), slide.title == candidate.title else { return false }
            return candidate.passages.allSatisfy { quote in
                quote.title == slide.title && quote.page == slide.page &&
                (quote.source == .slideText ? slide.text : slide.notes).contains(quote.text)
            }
        }
    }

    public static func requestedPages(_ question: String) -> Set<Int> {
        let q = question.precomposedStringWithCompatibilityMapping
        let patterns = [#"(?:スライド|ページ)\s*(?:第\s*)?([0-9]+(?:\.[0-9]+)?)"#,
                        #"資料\s*(?:第\s*)?([0-9]+(?:\.[0-9]+)?)(?=\s*(?:ページ|頁|枚目|[：:]))"#,
                        #"第?\s*([0-9]+(?:\.[0-9]+)?)\s*(?:ページ|枚目|頁)"#]
        return Set(patterns.flatMap { pattern in
            let regex = try! NSRegularExpression(pattern: pattern)
            return regex.matches(in: q, range: NSRange(q.startIndex..., in: q)).compactMap {
                Range($0.range(at: 1), in: q).map { Int(q[$0]) ?? Int.max }
            }
        })
    }

    public static func words(_ text: String) -> Set<String> {
        let tokenizer = NLTokenizer(unit: .word)
        let source = text.precomposedStringWithCompatibilityMapping.lowercased()
            .replacingOccurrences(of:#"(?<=[\p{Han}\p{Hiragana}\p{Katakana}ー])[^\S\r\n]*\r?\n(?![^\S\r\n]*\r?\n)[^\S\r\n]*(?=[\p{Han}\p{Hiragana}\p{Katakana}ー])"#,with:"",options:.regularExpression)
        tokenizer.string = source
        tokenizer.setLanguage(.japanese)
        var words: Set<String> = []
        tokenizer.enumerateTokens(in: source.startIndex..<source.endIndex) { range, _ in
            let word = normalize(String(source[range]))
            if word.count >= 2, !stopWords.contains(word),
               word.range(of: #"[\p{Han}\p{Katakana}a-z]"#, options: .regularExpression) != nil { words.insert(word) }
            return true
        }
        // NLTokenizer may split compound loanwords (e.g. カタカナ複合語).
        // Keep the complete contiguous Katakana form as an additional key.
        let katakana = try! NSRegularExpression(pattern: #"[\p{Katakana}ー]+"#)
        for match in katakana.matches(in: source, range: NSRange(source.startIndex..., in: source)) {
            if let range = Range(match.range, in: source) {
                let word = normalize(String(source[range]))
                if word.count >= 2, !stopWords.contains(word) { words.insert(word) }
            }
        }
        return words
    }
    public static func queryWords(_ question:String)->Set<String> {
        var terms=words(question)
        if terms.contains("検証") {terms.formUnion(["確認","確かめ"])}
        return terms
    }

    private static let stopWords: Set<String> = [
        "これ", "それ", "この", "その", "どの", "どこ", "なぜ", "どう", "どれ", "です", "ます", "した", "する", "いる", "ある",
        "ください", "下さい", "教え", "教えて", "説明", "教える", "つい", "について", "ため", "こと", "もの", "今回", "本日",
        "質問", "資料", "スライド", "ページ", "内容", "意味", "方法", "予定", "根拠", "研究", "確認", "でき", "できます", "でしょう",
        "それぞれ", "どのよう", "なん", "何", "please", "what", "which", "the", "is", "of", "and"
    ]
}
