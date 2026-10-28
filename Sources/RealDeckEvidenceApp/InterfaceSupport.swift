import Foundation
import RealDeckEvidenceCore
import SlideQACore

@MainActor extension InterfaceLanguageStore {
    func citation(_ quotation:DraftSourceQuotation)->String {
        let label=quotation.source == .speakerNotes ? text("発表ノートからの引用"):
            format("スライド本文・第{0}段落からの引用",arguments:[String(quotation.paragraph)])
        return "\(quotation.page): \(quotation.title) / "+label
    }
    func citation(_ passage:EvidencePassage)->String {
        let label=text(passage.source.label)
        let paragraph=passage.source == .slideText ? " · "+format("第{0}段落",arguments:[String(passage.paragraph)]):""
        return "\(passage.page): \(passage.title) / "+label+paragraph
    }
    func displayTitle(_ slide:Slide)->String {
        if slide.text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty &&
           slide.notes.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty {
            return format("ページ {0}",arguments:[String(slide.page)])
        }
        return slide.title
    }
}
