import Foundation
import CryptoKit
import Testing
@testable import SlideQACore
import RealDeckEvidenceCore

@Suite(.serialized) struct ImportResourceRegressionTests {
    @Test func JSONBeyondPreviousBytePageAndTextQuotasRetainsAllContent() throws {
        let text=String(repeating:"Fictional archive description. ",count:410)
        let note=String(repeating:"A fictional qualification remains. ",count:700)
        let title=String(repeating:"Long fictional title ",count:20)
        let slides=(1...501).map {page in
            ["page":page,"title":page==1 ? title:"Fictional page \(page)","text":text,"notes":page==1 ? note:""] as [String:Any]
        }
        let bytes=try JSONSerialization.data(withJSONObject:["pageCount":501,"slides":slides])
        #expect(bytes.count>5*1024*1024)
        try ImportFixture.file(bytes,fileExtension:"json") {url in
            let imported=try PresentationImporter.load(url)
            #expect(imported.deck.pageCount==501)
            #expect(imported.deck.slides.first?.title==title)
            #expect(imported.deck.slides.first?.notes==note)
            #expect(imported.deck.slides.last?.text==text)
        }
    }
    @Test func PPTXAbovePrevious100MiBFileQuotaLoadsItsActualText() throws {
        var parts=ImportFixture.parts()
        // Unread media represents a large presentation without adding any
        // private material. Only its XML text is requested by the real loader.
        parts["ppt/media/fictional-padding.bin"]=String(repeating:"p",count:101*1024*1024)
        let bytes=try ImportFixture.zip(parts)
        #expect(bytes.count>100*1024*1024)
        try ImportFixture.file(bytes,fileExtension:"pptx") {url in
            let imported=try PresentationImporter.load(url)
            #expect(imported.deck.slides.map(\.title)==["Archive humidity","Willow temperature"])
            #expect(imported.deck.slides.first?.notes=="The limit is provisional and must be checked.")
        }
    }
    @Test func DeflatedXMLBeyondPreviousPartAndTextLimitsIsNotTruncated() throws {
        var parts=ImportFixture.parts()
        let body=String(repeating:"Fictional archive text. ",count:210_000)
        parts["ppt/slides/slide2.xml"]=parts["ppt/slides/slide2.xml"]!
            .replacingOccurrences(of:"The archive humidity limit is 70 percent.",with:body)
        let bytes=try ImportFixture.zip(parts,deflated:true)
        try ImportFixture.file(bytes,fileExtension:"pptx") {url in
            let imported=try PresentationImporter.load(url)
            #expect(imported.deck.slides[0].text.hasSuffix(body.trimmingCharacters(in:.whitespaces)))
            #expect(imported.deck.slides[0].text.utf8.count>4*1024*1024)
        }
    }
    @Test func ForgedHugeInflationLengthIsRejectedWithoutPreallocatingThatLength() throws {
        var bytes=try ImportFixture.zip(ImportFixture.parts(),deflated:true)
        let name=Data("ppt/presentation.xml".utf8)
        let localName=try #require(bytes.range(of:name)).lowerBound
        let centralName=try #require(bytes.range(of:name,in:(localName+name.count)..<bytes.endIndex)).lowerBound
        #expect(Data(bytes[(localName-30)..<(localName-26)])==Data([0x50,0x4b,0x03,0x04]))
        #expect(Data(bytes[(centralName-46)..<(centralName-42)])==Data([0x50,0x4b,0x01,0x02]))
        for offset in [localName-30+22,centralName-46+24] {
            for i in 0..<4 {bytes[offset+i]=UInt8(truncatingIfNeeded:0x7fff_ffff>>(i*8))}
        }
        try ImportFixture.file(bytes,fileExtension:"pptx") {url in
            #expect(throws:PresentationImportError.malformedPackage){try PresentationImporter.load(url)}
        }
    }
    @Test func ActualPressureSignalAndIndexCheckpointsFailGracefully() throws {
        let monitor=ImportResourceMonitor(observeSystem:false)
        monitor.signalPressure()
        #expect(throws:PresentationImportError.resourcePressure) {
            try ImportResources.$monitor.withValue(monitor) {
                try PresentationImporter.load(URL(fileURLWithPath:"/not-opened.json"))
            }
        }
        let deck=try Deck.bundled()
        var checkpoints=0
        #expect(throws:CancellationError.self) {
            try EvidenceIndex(deck:deck,checkpoint:{
                checkpoints+=1
                if checkpoints==5 {throw CancellationError()}
            })
        }
        #expect(checkpoints==5)
    }
    @Test func ChunkedDigestAcceptsANonzeroDataSlice() throws {
        let bytes=Data("prefix:fictional payload".utf8)
        let slice=bytes[7...]
        let expected=SHA256.hash(data:slice).map{String(format:"%02x",$0)}.joined()
        #expect(try ImportResources.digest(slice)==expected)
    }
}
