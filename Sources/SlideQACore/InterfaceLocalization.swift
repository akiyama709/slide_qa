import Combine
import Foundation

public enum InterfaceLanguage:String,CaseIterable,Hashable,Sendable {
    case english="en",japanese="ja"
    public static func resolve(stored:String?,preferredLanguages:[String])->InterfaceLanguage {
        if let stored,let value=Self(rawValue:stored) {return value}
        for preferred in preferredLanguages {
            let code=preferred.lowercased().split(whereSeparator:{$0=="-" || $0=="_"}).first.map(String.init)
            if let code,let value=Self(rawValue:code) {return value}
        }
        return .english
    }
}

/// Renders app-owned labels/status only. Source text, questions and model prose
/// are never passed through this catalog.
public enum InterfaceCatalog {
    private static func load(_ language:InterfaceLanguage)->[String:String] {
        let base:URL?
        if Bundle.main.bundleURL.pathExtension=="app" {
            base=Bundle.main.resourceURL
        } else {base=Bundle.module.resourceURL}
        guard let url=base?.appendingPathComponent(language.rawValue+".lproj/Localizable.strings"),
              let data=try? Data(contentsOf:url),
              let table=try? PropertyListSerialization.propertyList(from:data,options:[],format:nil) as? [String:String] else {return [:]}
        return table
    }
    private static let tables:[InterfaceLanguage:[String:String]] = [
        .english:load(.english),.japanese:load(.japanese)
    ]
    private static func reverse(_ language:InterfaceLanguage)->[String:String] {
        var result:[String:String]=[:]
        for key in (tables[language] ?? [:]).keys.sorted() {
            if let value=tables[language]?[key],result[value]==nil {result[value]=key}
        }
        return result
    }
    private static let japaneseKeys=reverse(.japanese)
    private static let englishKeys=reverse(.english)
    private static func canonical(_ original:String)->String {
        if tables[.english]?[original] != nil {return original}
        return japaneseKeys[original] ?? englishKeys[original] ?? original
    }
    public static func entries(for language:InterfaceLanguage)->[String:String] {tables[language] ?? [:]}
    private static func replaceTokens(_ template:String,arguments:[String])->String {
        let regex=try! NSRegularExpression(pattern:#"\{([0-9]+)\}"#)
        let matches=regex.matches(in:template,range:NSRange(template.startIndex...,in:template))
        var result="";var last=template.startIndex
        for match in matches {
            guard let range=Range(match.range,in:template),
                  let numberRange=Range(match.range(at:1),in:template),
                  let index=Int(template[numberRange]),arguments.indices.contains(index) else {continue}
            result+=template[last..<range.lowerBound]
            result+=arguments[index]
            last=range.upperBound
        }
        result+=template[last...]
        return result
    }
    public static func renderTemplate(_ key:String,arguments:[String],language:InterfaceLanguage)->String {
        let resolved=canonical(key)
        return replaceTokens(tables[language]?[resolved] ?? tables[.english]?[resolved] ?? key,arguments:arguments)
    }
    private struct Template:Sendable {
        let key:String
        let value:String
        let pattern:String
        let positions:[Int]
        let specificity:Int
    }
    private static let templates:[Template] = {
        let tokens=try! NSRegularExpression(pattern:#"\{([0-9]+)\}"#)
        return (tables[.japanese] ?? [:]).compactMap { identifier,key -> Template? in
            guard let value=tables[.english]?[identifier] else {return nil}
            let matches=tokens.matches(in:key,range:NSRange(key.startIndex...,in:key))
            guard !matches.isEmpty else {return nil}
            var pattern="\\A";var last=key.startIndex;var positions:[Int]=[];var specificity=0
            for match in matches {
                guard let range=Range(match.range,in:key),let number=Range(match.range(at:1),in:key),
                      let index=Int(key[number]) else {return nil}
                let literal=String(key[last..<range.lowerBound])
                pattern+=NSRegularExpression.escapedPattern(for:literal)+"(.*?)"
                specificity+=literal.count;positions.append(index);last=range.upperBound
            }
            let trailing=String(key[last...]);pattern+=NSRegularExpression.escapedPattern(for:trailing)+"\\z"
            return Template(key:key,value:value,pattern:pattern,positions:positions,specificity:specificity+trailing.count)
        }.sorted { $0.specificity==$1.specificity ? $0.key<$1.key:$0.specificity>$1.specificity }
    }()
    public static func render(_ original:String,language:InterfaceLanguage)->String {
        if let direct=tables[language]?[canonical(original)] {return direct}
        guard language == .english else {return original}
        // Legacy system messages have already interpolated their arguments.
        // Only complete known app-owned templates are recognized.
        for template in templates {
            guard let regex=try? NSRegularExpression(pattern:template.pattern,options:.dotMatchesLineSeparators),
                  let match=regex.firstMatch(in:original,range:NSRange(original.startIndex...,in:original)) else {continue}
            var values=[String](repeating:"",count:(template.positions.max() ?? -1)+1)
            var valid=true;var assigned:Set<Int>=[]
            for (offset,index) in template.positions.enumerated() {
                guard let range=Range(match.range(at:offset+1),in:original) else {valid=false;break}
                let value=String(original[range])
                if assigned.contains(index),values[index] != value {valid=false;break}
                values[index]=value;assigned.insert(index)
            }
            if valid {return replaceTokens(template.value,arguments:values)}
        }
        // Original service diagnostics are retained, not falsely translated.
        return original
    }
}

@MainActor public final class InterfaceLanguageStore:ObservableObject {
    public static let preferenceKey="SlideQA.interfaceLanguage"
    @Published public private(set) var language:InterfaceLanguage
    private let defaults:UserDefaults
    private var renderedCache:[String:String]=[:]
    public init(defaults:UserDefaults = .standard,preferredLanguages:[String] = Locale.preferredLanguages) {
        self.defaults=defaults
        language=InterfaceLanguage.resolve(stored:defaults.string(forKey:Self.preferenceKey),preferredLanguages:preferredLanguages)
    }
    public func select(_ value:InterfaceLanguage) {
        if language != value {language=value;renderedCache=[:]}
        defaults.set(value.rawValue,forKey:Self.preferenceKey)
    }
    public func text(_ ownedMessage:String)->String {
        if let cached=renderedCache[ownedMessage] {return cached}
        let result=InterfaceCatalog.render(ownedMessage,language:language)
        if renderedCache.count>1000 {renderedCache=[:]}
        renderedCache[ownedMessage]=result
        return result
    }
    public func format(_ template:String,arguments:[String])->String {
        InterfaceCatalog.renderTemplate(template,arguments:arguments,language:language)
    }
}
