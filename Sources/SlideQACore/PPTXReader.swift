import Foundation
import zlib

/// Bounded ZIP reader for OOXML text only. Never writes archive entries to disk.
private struct OOXMLArchive {
    struct Entry {let flags:Int;let method:Int;let crc:UInt32;let compressed:Int;let size:Int;let offset:Int}
    let data:Data
    let entries:[String:Entry]
    let directoryOffset:Int
    init(_ data:Data) throws {
        self.data=data
        func u16(_ p:Int)->Int {Int(data[p]) | Int(data[p+1])<<8}
        func u32(_ p:Int)->Int {u16(p) | u16(p+2)<<16}
        guard data.count>=22 else {throw PresentationImportError.malformedPackage}
        var end:Int?
        for p in stride(from:data.count-22,through:max(0,data.count-22-65535),by:-1) {
            if u32(p)==0x06054b50,p+22+u16(p+20)==data.count {end=p;break}
        }
        guard let end,u16(end+4)==0,u16(end+6)==0,u16(end+8)==u16(end+10),
              (1...8000).contains(u16(end+10)),u32(end+12) != 0xffffffff,u32(end+16) != 0xffffffff else {throw PresentationImportError.malformedPackage}
        let start=u32(end+16),length=u32(end+12)
        guard start>=0,start+length==end else {throw PresentationImportError.malformedPackage}
        directoryOffset=start
        var p=start;var result:[String:Entry]=[:]
        for _ in 0..<u16(end+10) {
            guard p+46<=end,u32(p)==0x02014b50 else {throw PresentationImportError.malformedPackage}
            let nameLength=u16(p+28),extra=u16(p+30),comment=u16(p+32),next=p+46+nameLength+extra+comment
            guard next<=end,nameLength>0,
                  let name=String(data:data[(p+46)..<(p+46+nameLength)],encoding:.utf8),
                  !name.hasPrefix("/"),!name.contains("\\"),!name.contains("\0"),
                  !name.split(separator:"/").contains(".."),u16(p+34)==0,
                  u16(p+8)&1==0,u32(p+20) != 0xffffffff,u32(p+24) != 0xffffffff,u32(p+42) != 0xffffffff,
                  result[name]==nil else {throw PresentationImportError.malformedPackage}
            result[name]=Entry(flags:u16(p+8),method:u16(p+10),crc:UInt32(u32(p+16)),compressed:u32(p+20),size:u32(p+24),offset:u32(p+42))
            p=next
        }
        guard p==end else {throw PresentationImportError.malformedPackage}
        entries=result
    }
    func xml(_ name:String) throws -> Data {
        try Task.checkCancellation()
        guard let e=entries[name],e.size>0,e.size<=4*1024*1024,e.compressed<=100*1024*1024 else {throw PresentationImportError.malformedPackage}
        func u16(_ p:Int)->Int {Int(data[p]) | Int(data[p+1])<<8}
        func u32(_ p:Int)->Int {u16(p) | u16(p+2)<<16}
        let p=e.offset
        guard p>=0,p+30<=directoryOffset,u32(p)==0x04034b50,u16(p+6)&1==0,u16(p+8)==e.method else {throw PresentationImportError.malformedPackage}
        let begin=p+30+u16(p+26)+u16(p+28)
        guard begin<=directoryOffset,begin+e.compressed<=directoryOffset,
              String(data:data[(p+30)..<(p+30+u16(p+26))],encoding:.utf8)==name else {throw PresentationImportError.malformedPackage}
        let compressed=Data(data[begin..<(begin+e.compressed)])
        let output:Data
        switch e.method {
        case 0:
            guard compressed.count==e.size else {throw PresentationImportError.malformedPackage};output=compressed
        case 8:
            var stream=z_stream()
            guard inflateInit2_(&stream,-MAX_WBITS,ZLIB_VERSION,Int32(MemoryLayout<z_stream>.size))==Z_OK else {throw PresentationImportError.malformedPackage}
            defer {inflateEnd(&stream)}
            var decoded=Data(count:e.size)
            let status=compressed.withUnsafeBytes {src in decoded.withUnsafeMutableBytes {dst in
                stream.next_in=UnsafeMutablePointer(mutating:src.bindMemory(to:Bytef.self).baseAddress)
                stream.avail_in=uInt(compressed.count)
                stream.next_out=dst.bindMemory(to:Bytef.self).baseAddress;stream.avail_out=uInt(e.size)
                return inflate(&stream,Z_FINISH)
            }}
            guard status==Z_STREAM_END,Int(stream.total_out)==e.size,Int(stream.total_in)==compressed.count else {throw PresentationImportError.malformedPackage}
            output=decoded
        default:throw PresentationImportError.malformedPackage
        }
        let checksum=output.withUnsafeBytes{crc32(0,$0.bindMemory(to:Bytef.self).baseAddress,uInt(output.count))}
        guard UInt32(checksum)==e.crc else {throw PresentationImportError.malformedPackage}
        return output
    }
}

private final class XMLTextReader:NSObject,XMLParserDelegate {
    struct Shape {let placeholder:String?;let text:String}
    var paragraphs:[String]=[];var shapes:[Shape]=[];var slideIDs:[String]=[]
    var relationships:[String:(target:String,type:String,external:Bool)]=[:]
    private var paragraph:String?;private var textDepth=0;private var depth=0
    private var shapeDepth:Int?;private var shapeParagraphs:[String]=[];private var placeholder:String?
    private var characters=0;private var rejected=false
    static func read(_ data:Data) throws -> XMLTextReader {
        guard let text=String(data:data,encoding:.utf8),!text.uppercased().contains("<!DOCTYPE") else {throw PresentationImportError.malformedXML}
        let reader=XMLTextReader();let parser=XMLParser(data:data)
        parser.shouldProcessNamespaces=true;parser.shouldResolveExternalEntities=false;parser.externalEntityResolvingPolicy = .never
        parser.delegate=reader
        guard parser.parse(),!reader.rejected else {throw PresentationImportError.malformedXML}
        return reader
    }
    func parser(_ parser:XMLParser,didStartElement name:String,namespaceURI:String?,qualifiedName:String?,attributes:[String:String]) {
        depth+=1
        if name=="sldId",let id=attributes.first(where:{$0.key.hasSuffix(":id")})?.value {slideIDs.append(id)}
        if name=="Relationship",let id=attributes["Id"],let target=attributes["Target"],let type=attributes["Type"] {
            if relationships[id] != nil {rejected=true;parser.abortParsing();return}
            relationships[id]=(target,type,attributes["TargetMode"]?.lowercased()=="external")
        }
        if name=="sp" {shapeDepth=depth;shapeParagraphs=[];placeholder=nil}
        if name=="ph",shapeDepth != nil {placeholder=attributes["type"]}
        if name=="p" {paragraph=""}
        if name=="t" {textDepth=depth}
        if name=="br",paragraph != nil {paragraph!.append("\n")}
        if name=="tab",paragraph != nil {paragraph!.append("\t")}
    }
    func parser(_ parser:XMLParser,foundCharacters string:String) {
        characters+=string.count
        if characters>2_000_000 {rejected=true;parser.abortParsing();return}
        if textDepth>0,paragraph != nil {paragraph!.append(string)}
    }
    func parser(_ parser:XMLParser,foundCDATA data:Data) {
        guard let string=String(data:data,encoding:.utf8) else {rejected=true;parser.abortParsing();return}
        self.parser(parser,foundCharacters:string)
    }
    func parser(_ parser:XMLParser,didEndElement name:String,namespaceURI:String?,qualifiedName:String?) {
        if name=="t" {textDepth=0}
        if name=="p",let value=paragraph {
            let value=value.trimmingCharacters(in:.whitespacesAndNewlines)
            if !value.isEmpty {paragraphs.append(value);if shapeDepth != nil {shapeParagraphs.append(value)}}
            paragraph=nil
        }
        if name=="sp",shapeDepth==depth {shapes.append(Shape(placeholder:placeholder,text:shapeParagraphs.joined(separator:"\n\n")));shapeDepth=nil}
        depth-=1
    }
}

enum PPTXReader {
    private static func resolved(_ target:String,relativeTo part:String) throws -> String {
        guard target.utf8.count<=4096,let decoded=target.removingPercentEncoding,!decoded.isEmpty,
              !decoded.contains(":"),!decoded.contains("\\"),!decoded.contains("\0") else {throw PresentationImportError.unsafePart}
        // A leading slash denotes the OOXML package root, never a filesystem path.
        var pieces=decoded.hasPrefix("/") ? []:part.split(separator:"/").dropLast().map(String.init)
        for component in decoded.split(separator:"/") {
            if component=="." {continue}
            if component==".." {guard !pieces.isEmpty else {throw PresentationImportError.unsafePart};pieces.removeLast()}
            else {pieces.append(String(component))}
        }
        return pieces.joined(separator:"/")
    }
    private static func relationshipsPart(_ part:String)->String {
        let pieces=part.split(separator:"/").map(String.init)
        return pieces.dropLast().joined(separator:"/")+"/_rels/"+(pieces.last ?? "")+".rels"
    }
    static func read(_ data:Data) throws -> ([Slide],[String]) {
        let archive=try OOXMLArchive(data)
        guard archive.entries["[Content_Types].xml"] != nil else {throw PresentationImportError.malformedPackage}
        let main=try XMLTextReader.read(archive.xml("ppt/presentation.xml"))
        let rels=try XMLTextReader.read(archive.xml("ppt/_rels/presentation.xml.rels"))
        guard (1...500).contains(main.slideIDs.count) else {throw PresentationImportError.tooManyPages}
        guard Set(main.slideIDs).count==main.slideIDs.count else {throw PresentationImportError.malformedPackage}
        var slides:[Slide]=[];var paths:Set<String>=[];var extractedBytes=0;var empty=0;var inferred=0
        for (i,id) in main.slideIDs.enumerated() {
            try Task.checkCancellation()
            guard let link=rels.relationships[id],link.type.hasSuffix("/slide"),!link.external else {throw PresentationImportError.unsafePart}
            let path=try resolved(link.target,relativeTo:"ppt/presentation.xml")
            guard path.hasPrefix("ppt/slides/"),path.hasSuffix(".xml"),paths.insert(path).inserted else {throw PresentationImportError.malformedPackage}
            let raw=try archive.xml(path);extractedBytes+=raw.count
            let page=try XMLTextReader.read(raw)
            let text=page.paragraphs.joined(separator:"\n\n")
            let explicit=page.shapes.first{["title","ctrTitle"].contains($0.placeholder ?? "") && !$0.text.isEmpty}?.text
            let title=explicit ?? page.paragraphs.first ?? "スライド \(i+1)"
            if explicit==nil {inferred+=1}
            var notes=""
            let notesRels=relationshipsPart(path)
            if archive.entries[notesRels] != nil {
                let relData=try archive.xml(notesRels);extractedBytes+=relData.count
                let links=try XMLTextReader.read(relData)
                let noteLinks=links.relationships.values.filter{$0.type.hasSuffix("/notesSlide")}
                guard noteLinks.count<=1 else {throw PresentationImportError.malformedPackage}
                if let link=noteLinks.first {
                    guard !link.external else {throw PresentationImportError.unsafePart}
                    let notePath=try resolved(link.target,relativeTo:path)
                    guard notePath.hasPrefix("ppt/notesSlides/"),notePath.hasSuffix(".xml") else {throw PresentationImportError.unsafePart}
                    let noteData=try archive.xml(notePath);extractedBytes+=noteData.count
                    let note=try XMLTextReader.read(noteData)
                    notes=note.shapes.filter{!["sldImg","sldNum","dt","hdr","ftr"].contains($0.placeholder ?? "")}
                        .map(\.text).filter{!$0.isEmpty}.joined(separator:"\n\n")
                }
            }
            guard extractedBytes<=32*1024*1024 else {throw PresentationImportError.tooLarge}
            if text.isEmpty && notes.isEmpty {empty+=1}
            slides.append(Slide(page:i+1,title:String(title.replacingOccurrences(of:"\n",with:" ").prefix(300)),text:text,notes:notes,preparedScript:nil,scriptSourcePages:nil))
        }
        var warnings=["PPTXのスライド順序と文字・発表ノートを抽出しました．図表・画像・数式の意味や配置は再現しません．",
            "番号はファイル内のスライド順序です．非表示スライドも含め，印刷番号は検証しません．"]
        if inferred>0 {warnings.append("\(inferred)枚の表題は先頭の文字から推定しています．")}
        if empty>0 {warnings.append("\(empty)枚は本文・ノートの文字を抽出できませんでした．順序は保持しています．")}
        return(slides,warnings)
    }
}
