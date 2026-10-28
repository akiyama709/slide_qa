import Foundation
import PDFKit
import CryptoKit

public enum PresentationFormat:String,Sendable,Codable {case pdf,pptx,json,demo}

public struct ImportedPresentation:Sendable {
    public let deck:Deck
    public let format:PresentationFormat
    public let warnings:[String]
    /// Hash of the exact selected file bytes, separate from the text-index hash.
    /// Neither digest certifies factual truth, printed numbering or visual layout.
    public let originalFileSHA256:String?
}

public enum PresentationImportError:Error,LocalizedError,Equatable {
    case unsupportedFormat,tooLarge,protectedPDF,noText,malformedPDF,malformedPackage,malformedXML,tooManyPages,unsafePart,oversizedText
    public var errorDescription:String? {
        switch self {
        case .unsupportedFormat:"PDF・PPTX・資料JSONのいずれかを選択してください．PPT・PPTM・Keynoteには対応していません．"
        case .tooLarge:"資料のサイズが上限を超えています（PDF/PPTX 100 MiB，JSON 5 MiB）．"
        case .protectedPDF:"パスワード又はコピー制限のあるPDFは読み込めません．"
        case .noText:"検索できる文字を抽出できませんでした．画像のみの資料のOCRや図表の意味理解には対応していません．"
        case .malformedPDF:"PDFを読み込めませんでした．"
        case .malformedPackage:"PPTXの構造を確認できません．破損・暗号化・ZIP64形式などの資料は読み込めません．"
        case .malformedXML:"PPTX内のXMLを読み込めません．UTF-8のXMLに対応し，外部実体やDOCTYPEは使用できません．"
        case .tooManyPages:"資料は1〜500枚にしてください．"
        case .unsafePart:"PPTX内の参照先を確認できません．外部ファイルやネットワーク参照は読み込みません．"
        case .oversizedText:"抽出した本文・ノートが上限を超えています．1ページの各欄は20,000文字，全文は2,000,000文字までです．"
        }
    }
}

/// Reads owner-selected files locally. No model, audio, subprocess, download or
/// filesystem extraction is involved. Empty pages retain their source positions.
public enum PresentationImporter {
    public static func load(_ url:URL) throws -> ImportedPresentation {
        guard url.isFileURL else {throw PresentationImportError.unsupportedFormat}
        let kind=PresentationFormat(rawValue:url.pathExtension.lowercased())
        guard let kind,kind != .demo else {throw PresentationImportError.unsupportedFormat}
        let scoped=url.startAccessingSecurityScopedResource()
        defer {if scoped {url.stopAccessingSecurityScopedResource()}}
        let values=try url.resourceValues(forKeys:[.isRegularFileKey,.fileSizeKey])
        let limit=kind == .json ? 5*1024*1024:100*1024*1024
        guard values.isRegularFile == true,let size=values.fileSize,size>0,size<=limit else {throw PresentationImportError.tooLarge}
        try Task.checkCancellation()
        let data=try Data(contentsOf:url)
        guard data.count<=limit else {throw PresentationImportError.tooLarge}
        let originalDigest=SHA256.hash(data:data).map{String(format:"%02x",$0)}.joined()
        if kind == .json {
            return ImportedPresentation(deck:try Deck.validated(data:data,sourceName:url.lastPathComponent),format:.json,
                warnings:["JSONの構造検査です．元のPDFや印刷番号との照合は行っていません．"],originalFileSHA256:originalDigest)
        }
        let extracted:([Slide],[String])
        if kind == .pdf {extracted=try readPDF(data)} else {extracted=try PPTXReader.read(data)}
        guard extracted.0.contains(where:{!($0.text+$0.notes).trimmingCharacters(in:.whitespacesAndNewlines).isEmpty}) else {throw PresentationImportError.noText}
        let total=extracted.0.reduce(0){$0+$1.title.count+$1.text.count+$1.notes.count}
        guard total<=2_000_000,extracted.0.allSatisfy({$0.text.count<=20_000 && $0.notes.count<=20_000}) else {throw PresentationImportError.oversizedText}
        let deck=try Deck.extracted(slides:extracted.0,sourceName:url.lastPathComponent)
        return ImportedPresentation(deck:deck,format:kind,warnings:extracted.1,originalFileSHA256:originalDigest)
    }
    public static func demo() throws -> ImportedPresentation {
        ImportedPresentation(deck:try Deck.bundled(),format:.demo,warnings:["これは架空6枚の合成デモです．ご自身の資料は「資料を開く」から選択してください．"],originalFileSHA256:nil)
    }
    private static func readPDF(_ data:Data) throws -> ([Slide],[String]) {
        guard let document=PDFDocument(data:data) else {throw PresentationImportError.malformedPDF}
        guard !document.isLocked,document.allowsCopying else {throw PresentationImportError.protectedPDF}
        guard (1...500).contains(document.pageCount) else {throw PresentationImportError.tooManyPages}
        var slides:[Slide]=[];var empty=0
        for i in 0..<document.pageCount {
            try Task.checkCancellation()
            guard let page=document.page(at:i) else {throw PresentationImportError.malformedPDF}
            let text=(page.string ?? "").trimmingCharacters(in:.whitespacesAndNewlines)
            guard text.count<=20_000 else {throw PresentationImportError.oversizedText}
            if text.isEmpty {empty+=1}
            let first=text.components(separatedBy:.newlines).map{$0.trimmingCharacters(in:.whitespacesAndNewlines)}
                .first(where:{!$0.isEmpty && $0.range(of:#"[\p{L}]"#,options:.regularExpression) != nil})
            let title=first.map{String($0.prefix(300))} ?? "ページ \(i+1)"
            slides.append(Slide(page:i+1,title:title,text:text,notes:"",preparedScript:nil,scriptSourcePages:nil))
        }
        var warnings=["PDFの表題は抽出した先頭行から推定しています．ページ番号はファイル内の順序です．",
            "PDFからは発表ノートを取得できません．段組・図表・画像・印刷番号の意味は再現しません．"]
        if empty>0 {warnings.append("\(empty)ページは文字を抽出できませんでした．ページの順序は保持しています．")}
        return(slides,warnings)
    }
}
