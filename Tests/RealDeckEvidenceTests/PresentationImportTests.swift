import Foundation
import CoreGraphics
import CoreText
import Testing
import zlib
import CryptoKit
import SlideQACore
import RealDeckEvidenceCore

enum ImportFixture {
    @discardableResult
    static func file<T>(_ data:Data,fileExtension ext:String,body:(URL)throws->T) throws -> T {
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent("slideqa-import-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        defer {try? FileManager.default.removeItem(at:directory)}
        let url=directory.appendingPathComponent("fictional."+ext);try data.write(to:url)
        return try body(url)
    }
    static func pdf(_ pages:[[String]]) throws -> Data {
        let output=try #require(CFDataCreateMutable(nil,0))
        let consumer=try #require(CGDataConsumer(data:output))
        var box=CGRect(x:0,y:0,width:720,height:540)
        let context=try #require(CGContext(consumer:consumer,mediaBox:&box,nil))
        let font=CTFontCreateWithName("Helvetica" as CFString,20,nil)
        for lines in pages {
            context.beginPDFPage(nil)
            for (i,line) in lines.enumerated() {
                context.textPosition=CGPoint(x:40,y:CGFloat(460-i*35))
                let attributed=NSAttributedString(string:line,attributes:[NSAttributedString.Key(kCTFontAttributeName as String):font])
                CTLineDraw(CTLineCreateWithAttributedString(attributed as CFAttributedString),context)
            }
            context.endPDFPage()
        }
        context.closePDF();return output as Data
    }
    static func parts() -> [String:String] {
        let ns="http://schemas.openxmlformats.org/presentationml/2006/main"
        let a="http://schemas.openxmlformats.org/drawingml/2006/main"
        func slide(_ title:String,_ body:String)->String {
            "<p:sld xmlns:p=\"\(ns)\" xmlns:a=\"\(a)\"><p:cSld><p:spTree><p:sp><p:nvSpPr><p:nvPr><p:ph type=\"title\"/></p:nvPr></p:nvSpPr><p:txBody><a:p><a:r><a:t>\(title)</a:t></a:r></a:p></p:txBody></p:sp><p:sp><p:txBody><a:p><a:r><a:t>\(body)</a:t></a:r></a:p></p:txBody></p:sp></p:spTree></p:cSld></p:sld>"
        }
        return [
            "[Content_Types].xml":"<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\"/>",
            "ppt/presentation.xml":"<p:presentation xmlns:p=\"\(ns)\" xmlns:rel=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\"><p:sldIdLst><p:sldId id=\"256\" rel:id=\"second\"/><p:sldId id=\"257\" rel:id=\"first\"/></p:sldIdLst></p:presentation>",
            "ppt/_rels/presentation.xml.rels":"<Relationships><Relationship Id=\"first\" Type=\"x/slide\" Target=\"slides/slide1.xml\"/><Relationship Id=\"second\" Type=\"x/slide\" Target=\"slides/slide2.xml\"/></Relationships>",
            "ppt/slides/slide1.xml":slide("Willow temperature","Willow measures temperature with a sensor."),
            "ppt/slides/slide2.xml":slide("Archive humidity","The archive humidity limit is 70 percent."),
            "ppt/slides/_rels/slide2.xml.rels":"<Relationships><Relationship Id=\"notes\" Type=\"x/notesSlide\" Target=\"../notesSlides/notesSlide2.xml\"/></Relationships>",
            "ppt/notesSlides/notesSlide2.xml":"<p:notes xmlns:p=\"\(ns)\" xmlns:a=\"\(a)\"><p:cSld><p:spTree><p:sp><p:nvSpPr><p:nvPr><p:ph type=\"body\"/></p:nvPr></p:nvSpPr><p:txBody><a:p><a:r><a:t>The limit is provisional and must be checked.</a:t></a:r></a:p></p:txBody></p:sp><p:sp><p:nvSpPr><p:nvPr><p:ph type=\"sldNum\"/></p:nvPr></p:nvSpPr><p:txBody><a:p><a:r><a:t>88</a:t></a:r></a:p></p:txBody></p:sp></p:spTree></p:cSld></p:notes>"
        ]
    }
    static func zip(_ parts:[String:String],deflated:Bool=false)throws->Data {
        var body=Data(),central=Data()
        func put(_ data:inout Data,_ value:Int,_ count:Int) {for i in 0..<count {data.append(UInt8(truncatingIfNeeded:value>>(i*8)))}}
        for name in parts.keys.sorted() {
            let raw=Data(parts[name]!.utf8),filename=Data(name.utf8)
            let crc=raw.withUnsafeBytes{Int(crc32(0,$0.bindMemory(to:Bytef.self).baseAddress,uInt(raw.count)))}
            let packed:Data
            if deflated {
                var z=z_stream();#expect(deflateInit2_(&z,Z_DEFAULT_COMPRESSION,Z_DEFLATED,-MAX_WBITS,8,Z_DEFAULT_STRATEGY,ZLIB_VERSION,Int32(MemoryLayout<z_stream>.size))==Z_OK)
                defer {deflateEnd(&z)}
                var output=Data(count:raw.count+1024)
                let capacity=output.count
                let code=raw.withUnsafeBytes {input in output.withUnsafeMutableBytes {out in
                    z.next_in=UnsafeMutablePointer(mutating:input.bindMemory(to:Bytef.self).baseAddress);z.avail_in=uInt(raw.count)
                    z.next_out=out.bindMemory(to:Bytef.self).baseAddress;z.avail_out=uInt(capacity)
                    return deflate(&z,Z_FINISH)
                }}
                #expect(code==Z_STREAM_END);packed=Data(output.prefix(Int(z.total_out)))
            } else {packed=raw}
            let offset=body.count,method=deflated ? 8:0
            for (v,n) in [(0x04034b50,4),(20,2),(0,2),(method,2),(0,2),(0,2),(crc,4),(packed.count,4),(raw.count,4),(filename.count,2),(0,2)] {put(&body,v,n)}
            body.append(filename);body.append(packed)
            for (v,n) in [(0x02014b50,4),(20,2),(20,2),(0,2),(method,2),(0,2),(0,2),(crc,4),(packed.count,4),(raw.count,4),(filename.count,2),(0,2),(0,2),(0,2),(0,2),(0,4),(offset,4)] {put(&central,v,n)}
            central.append(filename)
        }
        let offset=body.count;body.append(central)
        for (v,n) in [(0x06054b50,4),(0,2),(0,2),(parts.count,2),(parts.count,2),(central.count,4),(offset,4),(0,2)] {put(&body,v,n)}
        return body
    }
}

@Suite struct PresentationImportTests {
    @Test func PDFPagesAreIndexedWithInferredTitlesAndVerbatimSources() throws {
        let pdf=try ImportFixture.pdf([["Cobalt cooling","Cobalt cooling uses a water circuit."],["Museum lighting","Museum lighting uses shielded lamps."]])
        try ImportFixture.file(pdf,fileExtension:"pdf") {url in
            let imported=try PresentationImporter.load(url)
            #expect(imported.format == .pdf && imported.deck.pageCount==2)
            #expect(imported.deck.slides[0].title=="Cobalt cooling")
            #expect(imported.deck.slides[1].notes.isEmpty)
            #expect(!imported.deck.printedNumbersVerified && imported.deck.routes.isEmpty)
            let originalDigest=SHA256.hash(data:pdf).map{String(format:"%02x",$0)}.joined()
            #expect(imported.originalFileSHA256==originalDigest)
            #expect(imported.originalFileSHA256 != imported.deck.sourceSHA256)
            let index=EvidenceIndex(deck:imported.deck),result=index.search("スライド2のlightingについて教えてください．")
            #expect(result.candidates.first?.page==2 && index.quotesAreVerbatim(result))
            #expect(result.candidates.first?.passages.contains(where:{$0.text.contains("shielded lamps")})==true)
        }
    }
    @Test func StoredAndDeflatedPPTXUseRelationshipOrderAndPreserveNotesWithoutFooter() throws {
        for deflated in [false,true] {
            let data=try ImportFixture.zip(ImportFixture.parts(),deflated:deflated)
            try ImportFixture.file(data,fileExtension:"pptx") {url in
                let imported=try PresentationImporter.load(url)
                #expect(imported.deck.slides.map(\.title)==["Archive humidity","Willow temperature"])
                #expect(imported.deck.slides[0].notes=="The limit is provisional and must be checked.")
                #expect(!imported.deck.slides[0].notes.contains("88"))
                let index=EvidenceIndex(deck:imported.deck),result=index.search("スライド1のhumidity limitを教えてください．")
                #expect(result.candidates.first?.page==1 && index.quotesAreVerbatim(result))
                #expect(result.candidates.first?.passages.contains(where:{$0.source == .speakerNotes && $0.text.contains("provisional")})==true)
            }
        }
    }
    @Test func ExternalRelationshipTraversalAndDocumentEntitiesAreRejected() throws {
        for mode in 0..<3 {
            var parts=ImportFixture.parts()
            if mode==0 {parts["ppt/slides/_rels/slide2.xml.rels"]="<Relationships><Relationship Id=\"notes\" Type=\"x/notesSlide\" TargetMode=\"External\" Target=\"https://example.invalid/notes.xml\"/></Relationships>"}
            if mode==1 {parts["../outside.xml"]="<outside/>"}
            if mode==2 {parts["ppt/presentation.xml"]="<!DOCTYPE x [<!ENTITY secret SYSTEM 'file:///not-read'>]><x>&secret;</x>"}
            try ImportFixture.file(try ImportFixture.zip(parts),fileExtension:"pptx") {url in
                #expect(throws:(any Error).self){try PresentationImporter.load(url)}
            }
        }
    }
    @Test func PackageRootTargetsAndCDATAKeepTheirSourceText() throws {
        var parts=ImportFixture.parts()
        parts["ppt/_rels/presentation.xml.rels"]=parts["ppt/_rels/presentation.xml.rels"]!.replacingOccurrences(of:"Target=\"slides/",with:"Target=\"/ppt/slides/")
        parts["ppt/slides/_rels/slide2.xml.rels"]=parts["ppt/slides/_rels/slide2.xml.rels"]!.replacingOccurrences(of:"../notesSlides/",with:"/ppt/notesSlides/")
        parts["ppt/slides/slide2.xml"]=parts["ppt/slides/slide2.xml"]!.replacingOccurrences(of:"<a:t>The archive humidity limit is 70 percent.</a:t>",with:"<a:t><![CDATA[Humidity & lighting are separate topics.]]></a:t>")
        try ImportFixture.file(try ImportFixture.zip(parts,deflated:true),fileExtension:"pptx") {url in
            let imported=try PresentationImporter.load(url)
            #expect(imported.deck.slides[0].text.contains("Humidity & lighting are separate topics."))
            #expect(imported.deck.slides[0].notes.contains("provisional"))
        }
    }
    @Test func CorruptArchiveUnknownFormatAndImageOnlyPDFGiveExplicitFailure() throws {
        try ImportFixture.file(Data("broken ZIP".utf8),fileExtension:"pptx") {url in
            #expect(throws:(any Error).self){try PresentationImporter.load(url)}
        }
        try ImportFixture.file(Data("not a supported presentation".utf8),fileExtension:"ppt") {url in
            #expect(throws:PresentationImportError.unsupportedFormat){try PresentationImporter.load(url)}
        }
        try ImportFixture.file(try ImportFixture.pdf([[]]),fileExtension:"pdf") {url in
            #expect(throws:PresentationImportError.noText){try PresentationImporter.load(url)}
        }
    }
    @Test func EmptyPDFPageKeepsPositionAndNextSelectionDoesNotReuseOldIndex() throws {
        let first=try ImportFixture.pdf([["Orchard irrigation","Orchard irrigation uses drip lines."],[],["Bridge inspection","Bridge inspection checks corrosion."]])
        try ImportFixture.file(first,fileExtension:"pdf") {url in
            let imported=try PresentationImporter.load(url),index=EvidenceIndex(deck:imported.deck)
            #expect(imported.deck.pageCount==3 && imported.deck.slides[1].text.isEmpty)
            #expect(index.search("スライド3のcorrosionについて教えてください．").candidates.first?.page==3)
        }
        let second=try ImportFixture.pdf([["Orchid propagation","Orchid propagation uses cuttings."]])
        try ImportFixture.file(second,fileExtension:"pdf") {url in
            let index=EvidenceIndex(deck:try PresentationImporter.load(url).deck)
            #expect(index.deck.pageCount==1)
            #expect(index.search("corrosion").candidates.isEmpty)
            #expect(index.search("propagation").candidates.first?.title=="Orchid propagation")
        }
    }
    @Test func LateFileCompletionCannotReplaceTheNewSelection() {
        var gate=PresentationLoadGate();let old=gate.begin(),new=gate.begin()
        #expect(!gate.isCurrent(old) && gate.isCurrent(new))
        gate.invalidate();#expect(!gate.isCurrent(old) && !gate.isCurrent(new))
    }
    @Test(arguments:[1,2,3]) func SmallDecksCanFindASpecificWordWithoutAPageNumber(count:Int) throws {
        let slides=(0..<count).map {i in ["page":i+1,"title":i==0 ? "Orchid propagation":"Plate reference \(i)",
            "text":i==0 ? "Orchid propagation uses cuttings.":"The plate reference describes storage.","notes":""] as [String:Any]}
        let data=try JSONSerialization.data(withJSONObject:["slides":slides,"pageCount":count])
        let index=EvidenceIndex(deck:try Deck.validated(data:data))
        let result=index.search("propagation")
        #expect(result.candidates.first?.page==1 && index.quotesAreVerbatim(result))
        #expect(index.search("holography").candidates.isEmpty)
        if count==3 {#expect(index.search("storage").candidates.isEmpty)}
    }
    @Test func JapaneseSpecificTwoCharacterTermsWorkInSmallDecks() throws {
        let data=try JSONSerialization.data(withJSONObject:["slides":[["page":1,"title":"温室の換気","text":"温室の換気は気温に応じて行います．","notes":""]]])
        let index=EvidenceIndex(deck:try Deck.validated(data:data))
        let result=index.search("換気")
        #expect(result.candidates.first?.page==1 && index.quotesAreVerbatim(result))
        #expect(index.search("燃料").candidates.isEmpty)
    }
    @Test(.enabled(if:ProcessInfo.processInfo.environment["SLIDEQA_IMPORT_FIXTURES"] != nil))
    func IndependentWriterFilesPassTheProductionLoaderAndSourceLookup() throws {
        let directory=URL(fileURLWithPath:try #require(ProcessInfo.processInfo.environment["SLIDEQA_IMPORT_FIXTURES"]))
        let pptx=try PresentationImporter.load(directory.appendingPathComponent("fictional.pptx"))
        #expect(pptx.deck.slides.map(\.title)==["Archive humidity","Willow ventilation"])
        #expect(pptx.deck.slides[0].notes.contains("provisional"))
        #expect(pptx.deck.slides[1].notes.contains("below 70 percent"))
        let first=EvidenceIndex(deck:pptx.deck),answer=first.search("スライド1のhumidity limitを教えてください．")
        #expect(answer.candidates.first?.page==1 && first.quotesAreVerbatim(answer))
        #expect(answer.disposition == .references && answer.candidates.first?.passages.isEmpty == false)
        #expect(answer.candidates.first?.passages.contains(where:{$0.source == .speakerNotes && $0.text.contains("provisional")}) == true)
        let vent=first.search("スライド2のvent at 28 Cについて教えてください．")
        #expect(vent.disposition == .references && first.quotesAreVerbatim(vent))
        #expect(vent.candidates.first?.passages.contains(where:{$0.text.contains("below 70 percent")}) == true)
        // A title-only term is navigation, not evidence that the body answers it.
        let titleOnly=first.search("ventilation")
        #expect(titleOnly.disposition == .insufficient && titleOnly.candidates.first?.passages.isEmpty == true)
        let pdf=try PresentationImporter.load(directory.appendingPathComponent("fictional.pdf"))
        #expect(pdf.deck.pageCount==4 && pdf.deck.slides[1].text.isEmpty)
        #expect(pdf.deck.slides[2].title=="Museum lighting")
        #expect(pdf.deck.slides[3].text.contains("換気"))
        let next=EvidenceIndex(deck:pdf.deck),japanese=next.search("換気")
        #expect(japanese.candidates.first?.page==4 && next.quotesAreVerbatim(japanese))
        #expect(japanese.disposition == .references && japanese.candidates.first?.passages.isEmpty == false)
        #expect(next.search("スライド3のlightingについて教えてください．").candidates.first?.passages.contains(where:{$0.text.contains("provisional")})==true)
        #expect(next.search("humidity").candidates.isEmpty)
    }
}
