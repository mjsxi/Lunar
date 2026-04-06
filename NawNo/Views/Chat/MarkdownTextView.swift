import AppKit
import SwiftUI

struct MarkdownTextView: NSViewRepresentable {
    let markdown: String
    var fontSize: CGFloat = 14
    var textColor: NSColor = .labelColor

    func makeNSView(context: Context) -> MarkdownNSTextView {
        let textView = MarkdownNSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return textView
    }

    func updateNSView(_ textView: MarkdownNSTextView, context: Context) {
        textView.textStorage?.setAttributedString(Self.renderMarkdown(markdown, fontSize: fontSize, textColor: textColor))
        textView.invalidateIntrinsicContentSize()
    }

    // MARK: - Markdown Parsing

    static func renderMarkdown(_ text: String, fontSize: CGFloat = 14, textColor: NSColor = .labelColor) -> NSAttributedString {
        let baseFont = NSFont.systemFont(ofSize: fontSize)
        let boldFont = NSFont.boldSystemFont(ofSize: fontSize)
        let italicFont = NSFontManager.shared.convert(baseFont, toHaveTrait: .italicFontMask)
        let monoFont = NSFont.monospacedSystemFont(ofSize: fontSize - 1, weight: .regular)

        let bodyStyle = NSMutableParagraphStyle()
        bodyStyle.lineSpacing = 3.5
        bodyStyle.paragraphSpacing = 4

        let result = NSMutableAttributedString()
        let lines = text.components(separatedBy: "\n")
        var lastWasEmpty = false

        for (i, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Collapse consecutive empty lines
            if trimmed.isEmpty {
                if lastWasEmpty { continue }
                lastWasEmpty = true
            } else {
                lastWasEmpty = false
            }

            if i > 0 { result.append(NSAttributedString(string: "\n")) }

            // Headers
            if trimmed.hasPrefix("### ") {
                let font = NSFont.boldSystemFont(ofSize: fontSize + 1)
                append(to: result, text: String(trimmed.dropFirst(4)), font: font, color: textColor, style: bodyStyle, boldFont: font, italicFont: italicFont, monoFont: monoFont)
            } else if trimmed.hasPrefix("## ") {
                let font = NSFont.boldSystemFont(ofSize: fontSize + 2)
                append(to: result, text: String(trimmed.dropFirst(3)), font: font, color: textColor, style: bodyStyle, boldFont: font, italicFont: italicFont, monoFont: monoFont)
            } else if trimmed.hasPrefix("# ") {
                let font = NSFont.boldSystemFont(ofSize: fontSize + 4)
                append(to: result, text: String(trimmed.dropFirst(2)), font: font, color: textColor, style: bodyStyle, boldFont: font, italicFont: italicFont, monoFont: monoFont)
            }
            // Bullets
            else if trimmed.hasPrefix("* ") || trimmed.hasPrefix("- ") {
                let listStyle = NSMutableParagraphStyle()
                listStyle.lineSpacing = 3.5
                listStyle.paragraphSpacing = 8
                listStyle.headIndent = 20
                listStyle.firstLineHeadIndent = 0
                let tabStop = NSTextTab(textAlignment: .left, location: 20)
                listStyle.tabStops = [tabStop]
                let attrs: [NSAttributedString.Key: Any] = [.font: baseFont, .foregroundColor: textColor, .paragraphStyle: listStyle]
                let bulletAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: fontSize + 4), .foregroundColor: textColor, .paragraphStyle: listStyle]
                result.append(NSAttributedString(string: "\u{2022}", attributes: bulletAttrs))
                result.append(NSAttributedString(string: "\t", attributes: attrs))
                append(to: result, text: String(trimmed.dropFirst(2)), font: baseFont, color: textColor, style: listStyle, boldFont: boldFont, italicFont: italicFont, monoFont: monoFont)
            }
            // Numbered list
            else if let match = trimmed.range(of: #"^\d+\.\s"#, options: .regularExpression) {
                let num = String(trimmed[match])
                let content = String(trimmed[match.upperBound...])
                let listStyle = NSMutableParagraphStyle()
                listStyle.lineSpacing = 3.5
                listStyle.paragraphSpacing = 8
                listStyle.headIndent = 20
                listStyle.firstLineHeadIndent = 0
                let tabStop = NSTextTab(textAlignment: .left, location: 20)
                listStyle.tabStops = [tabStop]
                let attrs: [NSAttributedString.Key: Any] = [.font: baseFont, .foregroundColor: textColor, .paragraphStyle: listStyle]
                result.append(NSAttributedString(string: "\(num)\t", attributes: attrs))
                append(to: result, text: content, font: baseFont, color: textColor, style: listStyle, boldFont: boldFont, italicFont: italicFont, monoFont: monoFont)
            }
            // Regular text
            else {
                append(to: result, text: trimmed, font: baseFont, color: textColor, style: bodyStyle, boldFont: boldFont, italicFont: italicFont, monoFont: monoFont)
            }
        }

        return result
    }

    private static func append(to result: NSMutableAttributedString, text: String, font: NSFont, color: NSColor, style: NSParagraphStyle, boldFont: NSFont, italicFont: NSFont, monoFont: NSFont) {
        let baseAttrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .paragraphStyle: style]
        let attributed = NSMutableAttributedString(string: text, attributes: baseAttrs)

        // Bold: **text**
        applyPattern(#"\*\*(.+?)\*\*"#, in: attributed, attrs: [.font: boldFont])
        // Inline code: `text`
        applyPattern(#"`([^`]+)`"#, in: attributed, attrs: [.font: monoFont, .backgroundColor: NSColor.quaternaryLabelColor], padContent: true)
        // Italic: *text*
        applyPattern(#"(?<!\*)\*(?!\*)(.+?)(?<!\*)\*(?!\*)"#, in: attributed, attrs: [.font: italicFont])

        result.append(attributed)
    }

    private static func applyPattern(_ pattern: String, in attributed: NSMutableAttributedString, attrs: [NSAttributedString.Key: Any], padContent: Bool = false) {
        let regex = try! NSRegularExpression(pattern: pattern)
        let text = attributed.string
        for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
            let contentRange = match.range(at: 1)
            var content = (text as NSString).substring(with: contentRange)
            if padContent { content = " \(content) " }
            let existing = attributed.attributes(at: match.range.location, effectiveRange: nil)
            let merged = existing.merging(attrs) { _, new in new }
            attributed.replaceCharacters(in: match.range, with: NSAttributedString(string: content, attributes: merged))
        }
    }
}

// MARK: - NSTextView subclass with intrinsic height

class MarkdownNSTextView: NSTextView {
    override var intrinsicContentSize: NSSize {
        guard let layoutManager, let textContainer else { return super.intrinsicContentSize }
        layoutManager.ensureLayout(for: textContainer)
        let height = layoutManager.usedRect(for: textContainer).height
        return NSSize(width: NSView.noIntrinsicMetric, height: height)
    }

    override func layout() {
        super.layout()
        invalidateIntrinsicContentSize()
    }
}
