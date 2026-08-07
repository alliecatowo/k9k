import AppKit
import SwiftUI

/// A deliberately small, dependency-free source viewer for Kubernetes data.
/// It is read-only so the inspector cannot accidentally mutate a resource; the
/// manifest sheet remains the explicit, confirmed editing workflow.
struct SyntaxHighlightedTextView: NSViewRepresentable {
    enum Language { case json, yaml }

    let source: String
    let language: Language

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false

        let textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 14, height: 14)
        textView.textContainer?.widthTracksTextView = false
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.autoresizingMask = [.width]
        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        let highlighted = source.highlighted(as: language)
        if textView.attributedString() != highlighted {
            textView.textStorage?.setAttributedString(highlighted)
        }
    }
}

private extension String {
    func highlighted(as language: SyntaxHighlightedTextView.Language) -> NSAttributedString {
        let font = NSFont.monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        let result = NSMutableAttributedString(string: self, attributes: [
            .font: font,
            .foregroundColor: NSColor.labelColor,
        ])

        func color(_ pattern: String, _ color: NSColor, options: NSRegularExpression.Options = []) {
            guard let expression = try? NSRegularExpression(pattern: pattern, options: options) else { return }
            let range = NSRange(startIndex..., in: self)
            expression.enumerateMatches(in: self, range: range) { match, _, _ in
                guard let match else { return }
                result.addAttribute(.foregroundColor, value: color, range: match.range)
            }
        }

        // Apply broad values first and identifiers last so property keys stay
        // visually distinct when a JSON key looks like a scalar value.
        color(#"\b(true|false|null)\b"#, .systemPurple)
        color(#"(?<![A-Za-z0-9_])[-+]?\d+(?:\.\d+)?(?:[eE][-+]?\d+)?"#, .systemBlue)
        color(#""(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'"#, .systemOrange)
        color(#"(?m)#.*$"#, .secondaryLabelColor)

        switch language {
        case .json:
            color(#""(?:\\.|[^"\\])*"(?=\s*:)"#, .systemTeal)
        case .yaml:
            color(#"(?m)^(\s*)([^#:\n][^:\n]*)(?=:)"#, .systemTeal)
            color(#"(?m)(?<=^|\s)[&*][A-Za-z0-9_-]+"#, .systemPurple)
        }
        return result
    }
}
