import Foundation
import SwiftUI
import WebKit

// MARK: - Plain text

enum HTMLText {
    /// A cheap tag stripper for snippets and quoted replies. This is not a parser and is
    /// never used to render — the message body goes through `MessageWebView`, which keeps
    /// remote content boxed inside a web view rather than trusting it here.
    static func plain(from html: String) -> String {
        guard !html.isEmpty else { return "" }
        var out = html
        // Drop whole elements whose text content is not body copy.
        out = stripElements(["script", "style", "head", "title"], from: out)
        // Turn block boundaries into newlines before the tags disappear.
        out = out.replacingOccurrences(of: "<br[^>]*>", with: "\n", options: [.regularExpression, .caseInsensitive])
        out = out.replacingOccurrences(of: "</(p|div|tr|li|h[1-6])>", with: "\n", options: [.regularExpression, .caseInsensitive])
        out = out.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        out = decodeEntities(out)
        // Collapse the whitespace HTML leaves behind.
        out = out.replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression)
        out = out.replacingOccurrences(of: " *\n *", with: "\n", options: .regularExpression)
        out = out.replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Removes whole elements, tags and contents together.
    ///
    /// These run through `NSRegularExpression` rather than `replacingOccurrences` because
    /// `String.CompareOptions` has no dot-matches-newline flag, and `.` otherwise stops at
    /// the first line break — which nearly every HTML mail has inside its `<style>` block.
    /// The generic tag pass below would still strip the tags, leaving the CSS behind as
    /// body copy: quoted into every reply and forward, and shown as the message's own text
    /// wherever the snippet is empty.
    private static func stripElements(_ tags: [String], from html: String) -> String {
        var out = html
        for tag in tags {
            guard let regex = try? NSRegularExpression(
                pattern: "<\(tag)[^>]*>.*?</\(tag)>",
                options: [.dotMatchesLineSeparators, .caseInsensitive]
            ) else { continue }
            out = regex.stringByReplacingMatches(
                in: out,
                range: NSRange(out.startIndex..., in: out),
                withTemplate: " "
            )
        }
        return out
    }

    /// Every named entity except `&amp;`, in a fixed order.
    ///
    /// An array rather than a `Dictionary`: dictionary iteration order is unspecified and
    /// re-seeded on every process launch, so the same bytes decoded to different text from
    /// one launch to the next.
    private static let entities: [(entity: String, replacement: String)] = [
        ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'"),
        ("&nbsp;", " "), ("&mdash;", "—"), ("&ndash;", "–"), ("&hellip;", "…"), ("&rsquo;", "’"),
        ("&lsquo;", "‘"), ("&ldquo;", "“"), ("&rdquo;", "”"), ("&trade;", "™"), ("&copy;", "©"), ("&reg;", "®"),
    ]

    static func decodeEntities(_ text: String) -> String {
        var out = text
        for (entity, replacement) in entities {
            out = out.replacingOccurrences(of: entity, with: replacement, options: .caseInsensitive)
        }
        // Numeric references, decimal and hex.
        out = replaceMatches(in: out, pattern: "&#(\\d+);") { UInt32($0, radix: 10) }
        out = replaceMatches(in: out, pattern: "&#[xX]([0-9a-fA-F]+);") { UInt32($0, radix: 16) }
        // `&amp;` is decoded last, after every other form, because it is the escape for the
        // escapes: decoding it first turns the literal text `&amp;lt;` into `&lt;`, which a
        // later pass then decodes again into `<` — markup the sender deliberately escaped.
        out = out.replacingOccurrences(of: "&amp;", with: "&", options: .caseInsensitive)
        return out
    }

    private static func replaceMatches(in text: String, pattern: String, scalar: (String) -> UInt32?) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        var out = text
        let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed()
        for match in matches {
            guard match.numberOfRanges > 1,
                  let full = Range(match.range, in: out),
                  let digits = Range(match.range(at: 1), in: out),
                  let value = scalar(String(out[digits])),
                  let unicode = Unicode.Scalar(value) else { continue }
            out.replaceSubrange(full, with: String(Character(unicode)))
        }
        return out
    }

    /// Splits a reply off from the quoted history under it, so the thread view can fold
    /// the old text away the way the web client does.
    static func splitQuoted(_ text: String) -> (body: String, quoted: String?) {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        // The first line that begins a quote block, provided real text came before it.
        for (index, line) in lines.enumerated() where index > 0 {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let isQuoteStart = trimmed.hasPrefix(">")
                || trimmed.range(of: "^On .+ wrote:$", options: .regularExpression) != nil
                || trimmed.range(of: "^-{2,} ?Original Message ?-{2,}$", options: [.regularExpression, .caseInsensitive]) != nil
                || trimmed == "--"
            guard isQuoteStart else { continue }
            let head = lines[0..<index].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !head.isEmpty else { continue }
            let tail = lines[index...].joined(separator: "\n")
            return (head, tail)
        }
        return (text, nil)
    }

    /// Wraps a composed plain-text body as the minimal HTML the send endpoint expects.
    static func htmlBody(from text: String) -> String {
        let escaped = text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        let paragraphs = escaped
            .components(separatedBy: "\n\n")
            .map { "<p>" + $0.replacingOccurrences(of: "\n", with: "<br>") + "</p>" }
            .joined()
        return paragraphs.isEmpty ? "<p></p>" : paragraphs
    }
}

// MARK: - Message body

/// Renders one message's HTML in a web view that sizes itself to its content.
///
/// Mail is arbitrary third-party HTML, so it stays inside a web view rather than being
/// converted to `AttributedString`: layout survives, and the content stays boxed. The
/// worker already strips tracker pixels; this side adds the rest of the containment —
/// no JavaScript, no navigation, no back/forward list, and every tapped link handed
/// back to the app instead of loaded here.
/// The shell both platforms wrap a message in. See `html(_:dark:blockRemoteImages:)`.
enum MessageDocument {
    /// The shell around the message: a grayscale reset, a hard `max-width` so wide
    /// marketing tables cannot force a horizontal scroll, and a height probe.
    static func html(_ html: String, dark: Bool, blockRemoteImages: Bool) -> String {
        let fg = dark ? "#fafafa" : "#171717"
        let muted = dark ? "#a1a1a1" : "#737373"
        let border = dark ? "rgba(255,255,255,.14)" : "rgba(0,0,0,.12)"
        // The policy is the actual enforcement for remote images; the stylesheet only hides
        // them. `default-src 'none'` is not used: WebKit then declines to render the document
        // loaded through `loadHTMLString` at all, leaving a blank box where the mail should be.
        // Naming each risky directive blocks the same things and still paints.
        let images = blockRemoteImages ? "data: cid:" : "data: cid: https: http:"
        let csp = [
            "script-src 'none'",
            "object-src 'none'",
            "frame-src 'none'",
            "child-src 'none'",
            "connect-src 'none'",
            "font-src 'none'",
            "media-src 'none'",
            "form-action 'none'",
            "base-uri 'none'",
            "style-src 'unsafe-inline'",
            "img-src \(images)",
        ].joined(separator: "; ")

        return """
        <!doctype html><html><head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1">
        <meta http-equiv="Content-Security-Policy" content="\(csp)">
        <style>
          :root { color-scheme: \(dark ? "dark" : "light"); }
          html, body { margin:0; padding:0; background:transparent; }
          body {
            color:\(fg);
            font: 15px/1.55 -apple-system, system-ui, "Helvetica Neue", sans-serif;
            -webkit-text-size-adjust: 100%;
            word-break: break-word;
            overflow-wrap: anywhere;
          }
          * { max-width: 100% !important; }
          img { height: auto !important; border-radius: 4px; }
          table { width: auto !important; border-collapse: collapse; }
          /* Mail routinely hard-codes white backgrounds; neutralise them so dark mode holds. */
          [bgcolor], [style*="background"] { background-color: transparent !important; }
          a { color:\(fg); text-decoration: underline; text-underline-offset: 2px; }
          blockquote {
            margin: 8px 0; padding-left: 12px;
            border-left: 2px solid \(border); color:\(muted);
          }
          pre, code { font-family: ui-monospace, SFMono-Regular, Menlo, monospace; font-size: 13px; white-space: pre-wrap; }
          hr { border:0; border-top:1px solid \(border); }
        </style>
        </head><body>\(html)</body></html>
        """
    }

}

#if os(iOS)
struct MessageWebView: UIViewRepresentable {
    let html: String
    let blockRemoteImages: Bool
    @Binding var height: CGFloat
    var onLink: (URL) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        config.suppressesIncrementalRendering = false
        config.dataDetectorTypes = []

        let view = WKWebView(frame: .zero, configuration: config)
        view.navigationDelegate = context.coordinator
        view.scrollView.isScrollEnabled = false          // the outer SwiftUI scroll view owns scrolling
        view.scrollView.bounces = false
        view.scrollView.contentInsetAdjustmentBehavior = .never
        view.isOpaque = false
        view.backgroundColor = .clear
        view.scrollView.backgroundColor = .clear
        context.coordinator.observe(view)
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {
        let document = MessageDocument.html(html, dark: context.environment.colorScheme == .dark, blockRemoteImages: blockRemoteImages)
        let width = view.bounds.width

        if context.coordinator.lastDocument != document {
            context.coordinator.lastDocument = document
            context.coordinator.lastWidth = width
            view.loadHTMLString(document, baseURL: nil)
            return
        }

        // The document does not depend on width, so a rotation — or any other resize —
        // leaves it byte-identical and reloads nothing. Reflowed text needs a different
        // height, and this view's own scrolling is off, so without re-measuring here the
        // body simply stays clipped at the height the old width wanted.
        if width > 0, abs(width - (context.coordinator.lastWidth ?? 0)) > 1 {
            context.coordinator.lastWidth = width
            context.coordinator.remeasure(view)
        }
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        private let parent: MessageWebView
        var lastDocument: String?
        /// The width the current height was measured at, so a resize can ask again.
        var lastWidth: CGFloat?
        private var sizeObservation: NSKeyValueObservation?

        init(_ parent: MessageWebView) { self.parent = parent }

        deinit { sizeObservation?.invalidate() }

        /// Watches the laid-out document height instead of polling for it.
        ///
        /// The obvious approach — `evaluateJavaScript("document.body.scrollHeight")` on a
        /// timer — under-reports while the document is still being laid out and then stops
        /// asking, which leaves the last line of a message sliced in half. `contentSize`
        /// is the size WebKit actually laid out, it changes again when a late image or a
        /// rotation reflows the page, and reading it needs no script at all — which matters
        /// here, because content JavaScript is deliberately off for untrusted mail.
        func observe(_ webView: WKWebView) {
            sizeObservation?.invalidate()
            sizeObservation = webView.scrollView.observe(\.contentSize, options: [.initial, .new]) { [weak self] scrollView, _ in
                guard let self else { return }
                let height = scrollView.contentSize.height
                guard height > 0, abs(height - self.parent.height) > 0.5 else { return }
                // The observation can fire mid-layout, so the write is deferred rather
                // than made inside SwiftUI's own update pass.
                DispatchQueue.main.async { self.parent.height = height }
            }
        }

        /// A resize leaves the document byte-identical, so nothing reloads; this forces the
        /// relayout whose new `contentSize` the observation above then picks up.
        func remeasure(_ webView: WKWebView) {
            webView.setNeedsLayout()
            webView.layoutIfNeeded()
        }

        func webView(_ webView: WKWebView,
                     decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            // The only load this view ever performs is the one we hand it, which arrives
            // as an `.other` navigation to about:blank. Everything else — a link tap, a
            // meta refresh, a redirect a sender embedded — is refused, and a tapped link
            // is handed back to the app to open in Safari.
            if action.navigationType == .other, action.request.url == nil || action.request.url?.scheme == "about" {
                decisionHandler(.allow)
                return
            }
            if let url = action.request.url, action.navigationType == .linkActivated {
                parent.onLink(url)
            }
            decisionHandler(.cancel)
        }
    }
}

#endif
