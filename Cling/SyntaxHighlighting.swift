//
//  SyntaxHighlighting.swift
//  Cling
//
//  Syntax highlighting (via HighlighterSwift / highlight.js, "horizon-dark"
//  theme) for the file preview and the script editor.
//

import AppKit
import Highlighter
import SwiftUI

// MARK: - SyntaxHighlighter

/// Wraps `Highlighter` (JavaScriptCore based, so it must be used from a single
/// thread) on a dedicated serial queue. Results come back on the main thread.
final class SyntaxHighlighter {
    private init() {
        queue.async { [self] in
            let hl = Highlighter()
            hl?.setTheme("horizon-dark")
            if let bg = hl?.theme.themeBackgroundColour {
                DispatchQueue.main.async { self.backgroundColor = bg }
            }
            highlighter = hl
        }
    }

    static let shared = SyntaxHighlighter()

    /// horizon-dark theme colors, also used as fallbacks before the engine loads.
    static let background = NSColor(srgbRed: 0x1C / 255, green: 0x1E / 255, blue: 0x26 / 255, alpha: 1)
    static let foreground = NSColor(srgbRed: 0xCB / 255, green: 0xCE / 255, blue: 0xD0 / 255, alpha: 1)

    private(set) var backgroundColor: NSColor = SyntaxHighlighter.background

    static func plain(_ code: String, font: NSFont) -> NSAttributedString {
        NSAttributedString(string: code, attributes: [.font: font, .foregroundColor: foreground])
    }

    /// Maps a file extension to a highlight.js language id; nil → plain text.
    static func language(forExtension ext: String) -> String? {
        switch ext.lowercased() {
        case "swift": "swift"
        case "py", "pyw", "pyi": "python"
        case "js", "mjs", "cjs", "jsx": "javascript"
        case "ts", "tsx": "typescript"
        case "rb", "gemspec", "podspec": "ruby"
        case "go": "go"
        case "rs": "rust"
        case "c", "h": "c"
        case "cpp", "cc", "cxx", "hpp", "hh", "hxx": "cpp"
        case "m", "mm": "objectivec"
        case "java": "java"
        case "kt", "kts": "kotlin"
        case "cs": "csharp"
        case "php": "php"
        case "sh", "bash", "zsh", "fish", "command", "zshrc", "bashrc", "profile": "bash"
        case "json", "jsonc": "json"
        case "yml", "yaml": "yaml"
        case "toml": "ini"
        case "ini", "conf", "cfg", "cnf": "ini"
        case "xml", "plist", "storyboard", "xib", "svg", "xcconfig": "xml"
        case "html", "htm", "xhtml": "xml"
        case "css": "css"
        case "scss", "sass": "scss"
        case "less": "less"
        case "md", "markdown", "mdown", "mkd": "markdown"
        case "sql": "sql"
        case "diff", "patch": "diff"
        case "makefile", "make", "mk": "makefile"
        case "dockerfile": "dockerfile"
        case "lua": "lua"
        case "pl", "pm": "perl"
        case "r": "r"
        case "scala", "sbt": "scala"
        case "dart": "dart"
        case "vim": "vim"
        case "tex", "sty": "latex"
        case "gradle", "groovy": "groovy"
        case "ps1", "psm1": "powershell"
        case "ex", "exs": "elixir"
        case "erl": "erlang"
        case "clj", "cljs", "edn": "clojure"
        case "hs": "haskell"
        default: nil
        }
    }

    /// Highlights `code` and returns the attributed result on the main thread.
    /// Falls back to plain monospaced text if the engine is unavailable.
    func highlight(
        _ code: String,
        language: String?,
        font: NSFont,
        lineNumbers: Bool,
        completion: @escaping (NSAttributedString) -> Void
    ) {
        queue.async { [self] in
            let attributed: NSAttributedString
            if let hl = highlighter {
                hl.theme.setCodeFont(font)
                let lang = language ?? "plaintext"
                let result: NSAttributedString?
                if lineNumbers {
                    let data = LineNumberData(usingDarkTheme: true, lineBreak: "\n", fontSize: font.pointSize)
                    result = hl.highlight(code, as: lang, doFastRender: true, lineNumbering: data)
                } else {
                    result = hl.highlight(code, as: lang, doFastRender: true)
                }
                attributed = result ?? Self.plain(code, font: font)
            } else {
                attributed = Self.plain(code, font: font)
            }
            DispatchQueue.main.async { completion(attributed) }
        }
    }

    private let queue = DispatchQueue(label: "com.lowtechguys.Cling.highlighter", qos: .userInitiated)
    private var highlighter: Highlighter?

}

// MARK: - CodePreviewView

/// Read-only, syntax-highlighted, line-numbered code view for the file preview.
struct CodePreviewView: NSViewRepresentable {
    final class Coordinator {
        weak var textView: NSTextView?
        weak var scroll: NSScrollView?

        func load(_ url: URL, fontSize: CGFloat) {
            guard loadedURL != url else { return }
            loadedURL = url
            let language = SyntaxHighlighter.language(forExtension: url.pathExtension)
            DispatchQueue.global(qos: .userInitiated).async {
                let cap = 256 * 1024
                let handle = try? FileHandle(forReadingFrom: url)
                let data = (try? handle?.read(upToCount: cap)) ?? Data()
                try? handle?.close()
                var text = String(decoding: data, as: UTF8.self)
                if data.count >= cap { text += "\n\n… preview truncated" }
                let font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
                SyntaxHighlighter.shared.highlight(text, language: language, font: font, lineNumbers: true) { attributed in
                    guard self.loadedURL == url, let textView = self.textView else { return }
                    textView.textStorage?.setAttributedString(attributed)
                    textView.scroll(.zero)
                    self.scroll?.backgroundColor = SyntaxHighlighter.shared.backgroundColor
                }
            }
        }

        private var loadedURL: URL?

    }

    let url: URL
    var fontSize: CGFloat = 11

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = true
        scroll.backgroundColor = SyntaxHighlighter.shared.backgroundColor

        if let textView = scroll.documentView as? NSTextView {
            configureCodeTextView(textView, editable: false)
            context.coordinator.textView = textView
            context.coordinator.scroll = scroll
        }
        context.coordinator.load(url, fontSize: fontSize)
        return scroll
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        context.coordinator.load(url, fontSize: fontSize)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

}

// MARK: - CodeEditorView

/// Editable, syntax-highlighted code editor. Re-highlights shortly after typing
/// pauses so editing stays responsive.
struct CodeEditorView: NSViewRepresentable {
    final class Coordinator: NSObject, NSTextViewDelegate {
        weak var textView: NSTextView?
        weak var scroll: NSScrollView?
        var parent: CodeEditorView?

        func textDidChange(_ notification: Notification) {
            guard !applyingHighlight, let textView else { return }
            parent?.source = textView.string
            rehighlight(immediately: false)
        }

        func rehighlight(immediately: Bool) {
            debounce?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.applyHighlight() }
            debounce = work
            if immediately {
                DispatchQueue.main.async(execute: work)
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
            }
        }

        private var debounce: DispatchWorkItem?
        private var applyingHighlight = false

        private func applyHighlight() {
            guard let textView, let parent else { return }
            let code = textView.string
            let font = NSFont.monospacedSystemFont(ofSize: parent.fontSize, weight: .regular)
            SyntaxHighlighter.shared.highlight(code, language: parent.language, font: font, lineNumbers: false) { [weak self] attributed in
                guard let self, let textView = self.textView, textView.string == code else { return }
                let selected = textView.selectedRanges
                applyingHighlight = true
                textView.textStorage?.setAttributedString(attributed)
                textView.selectedRanges = selected
                textView.typingAttributes = [.font: font, .foregroundColor: SyntaxHighlighter.foreground]
                applyingHighlight = false
                scroll?.backgroundColor = SyntaxHighlighter.shared.backgroundColor
            }
        }
    }

    @Binding var source: String

    var language: String?
    var fontSize: CGFloat = 12

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = true
        scroll.backgroundColor = SyntaxHighlighter.shared.backgroundColor

        if let textView = scroll.documentView as? NSTextView {
            configureCodeTextView(textView, editable: true)
            textView.delegate = context.coordinator
            textView.string = source
            context.coordinator.textView = textView
            context.coordinator.scroll = scroll
            context.coordinator.parent = self
            context.coordinator.rehighlight(immediately: true)
        }
        return scroll
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = context.coordinator.textView else { return }
        if textView.string != source {
            textView.string = source
            context.coordinator.rehighlight(immediately: true)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

}

// MARK: - Shared NSTextView setup

@MainActor
private func configureCodeTextView(_ textView: NSTextView, editable: Bool) {
    textView.isEditable = editable
    textView.isSelectable = true
    textView.isRichText = false
    textView.allowsUndo = editable
    textView.drawsBackground = false
    textView.backgroundColor = .clear
    textView.insertionPointColor = SyntaxHighlighter.foreground
    textView.textColor = SyntaxHighlighter.foreground
    textView.textContainerInset = NSSize(width: 8, height: 8)
    textView.isAutomaticQuoteSubstitutionEnabled = false
    textView.isAutomaticDashSubstitutionEnabled = false
    textView.isAutomaticSpellingCorrectionEnabled = false
    textView.isAutomaticTextReplacementEnabled = false
    textView.isGrammarCheckingEnabled = false
    // Don't wrap long lines: scroll horizontally instead.
    textView.isHorizontallyResizable = true
    textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
    textView.textContainer?.widthTracksTextView = false
    textView.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
    textView.layoutManager?.allowsNonContiguousLayout = true
}
