import SwiftUI
import WebKit
import AppKit

/// `HtmlBody.tsx`: the message in a sandboxed web view that sizes itself, follows the theme,
/// collapses quoted history, blocks trackers, hands links to the browser and offers
/// "Save clip" on a selection.
struct HtmlBodyView: View {
    let html: String
    var text: String = ""
    var trackers: [String] = []
    var plain = false
    var collapseQuotes = true
    var onClip: ((String) -> Void)? = nil

    @Environment(\.colorScheme) private var scheme
    @State private var height: CGFloat = 48
    @State private var ready = false
    @State private var quoteCount = 0
    @State private var quotesShown = false
    @State private var selection: (text: String, x: CGFloat, y: CGFloat)? = nil
    @State private var controller = HtmlBodyController()

    private var usePlain: Bool { plain || html.isEmpty }
    private var ownBackground: Bool { !usePlain && HtmlBodyView.paintsOwnBackground(html) }
    private var slab: Bool { ownBackground && scheme == .dark }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !trackers.isEmpty {
                WBadge("Blocked \(trackers.count) tracker\(trackers.count == 1 ? "" : "s") · \(trackers.prefix(2).joined(separator: ", "))\(trackers.count > 2 ? " +\(trackers.count - 2)" : "")", icon: "shieldCheck", variant: .secondary, muted: true)
                    .help(trackers.joined(separator: ", "))
                    .padding(.bottom, 8)
            }
            ZStack(alignment: .topLeading) {
                MessageWebView(document: document, controller: controller, height: $height, ready: $ready, quoteCount: $quoteCount, selection: $selection, onLink: { NSWorkspace.shared.open($0) }, collapseQuotes: collapseQuotes)
                    // A theme switch reloads the document, and the script collapses quotes again.
                    .onChange(of: scheme) { _, _ in quotesShown = false }
                    .frame(height: max(height, ready ? 0 : 48))
                    .padding(slab ? 8 : 0)
                    .background(slab ? Color.white : Color.clear)
                    .rounded(slab ? W.radiusMd : 0)
                    .opacity(ready ? 1 : 0)
                if !ready {
                    VStack(alignment: .leading, spacing: 8) {
                        SkeletonBlock(width: 320)
                        SkeletonBlock(width: 220)
                    }
                    .padding(.top, 4)
                }
                if let selection, let onClip {
                    WButton("Save clip", icon: "scissors", size: .xs) {
                        onClip(selection.text)
                        self.selection = nil
                        controller.clearSelection()
                    }
                    .shadow(color: .black.opacity(0.2), radius: 6, y: 2)
                    .offset(x: max(0, selection.x - 40), y: max(0, selection.y - 30))
                }
            }
            if quoteCount > 0 {
                WButton(quotesShown ? "Hide quoted text" : "Show quoted text", icon: "chevronDown", variant: .ghost, size: .xs, muted: true) {
                    quotesShown.toggle()
                    controller.setQuotes(shown: quotesShown)
                }
                .padding(.top, 8)
            }
        }
    }

    private var document: String {
        let body = usePlain
            ? "<div style=\"white-space:pre-wrap\">\(HtmlBodyView.escape(text))</div>"
            : HtmlBodyView.sanitize(html)
        let dark = scheme == .dark
        let colors = W.css(dark: dark)
        let scheme = ownBackground ? "light" : (dark ? "dark" : "light")
        let fg = ownBackground ? "#37352f" : colors.fg
        let muted = ownBackground ? "rgba(55,53,47,.65)" : colors.muted
        let border = ownBackground ? "rgba(55,53,47,.12)" : colors.border
        let selectionBg = fg
        let selectionFg = ownBackground ? "#ffffff" : colors.bg
        return """
        <!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src https: http: data: cid:; style-src 'unsafe-inline'; font-src data:">
        <style>
        \(GeistWeb.fontFace)
        html{color-scheme:\(scheme);\(dark && !ownBackground ? "--hey-page:\(colors.bg);--hey-ink:\(fg);" : "")}
        html,body{margin:0;padding:0;background:transparent;}
        body{display:flow-root;font-family:"Geist Variable",Geist,system-ui,-apple-system,sans-serif;font-size:14px;line-height:1.6;color:\(fg);word-wrap:break-word;overflow-wrap:anywhere;}
        img{max-width:100% !important;height:auto;}
        table{max-width:100% !important;}
        a{color:\(fg);text-decoration:underline;text-underline-offset:2px;}
        blockquote{border-left:2px solid \(border);margin:.5em 0;padding-left:1em;color:\(muted);}
        pre{white-space:pre-wrap;font-family:"Geist Mono Variable","Geist Mono",ui-monospace,Menlo,monospace;font-size:12.5px;}
        ::selection{background:\(selectionBg);color:\(selectionFg);}
        .hey-quoted-hidden{display:none !important;}
        </style></head><body>\(body)</body></html>
        """
    }

    static func paintsOwnBackground(_ html: String) -> Bool {
        html.range(of: #"background(?:-color)?\s*:\s*(?!transparent|inherit|none)[^;"']+"#, options: [.regularExpression, .caseInsensitive]) != nil
            || html.range(of: #"\bbgcolor\s*="#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// The shape of DOMPurify's pass: scripts, frames, forms and event handlers go.
    static func sanitize(_ html: String) -> String {
        var s = html
        for tag in ["script", "iframe", "object", "embed", "form", "style", "title", "head", "noscript"] {
            s = s.replacingOccurrences(of: "<\(tag)\\b[^>]*>[\\s\\S]*?</\(tag)>", with: "", options: [.regularExpression, .caseInsensitive])
        }
        for tag in ["meta", "link", "base", "input", "button"] {
            s = s.replacingOccurrences(of: "<\(tag)\\b[^>]*/?>", with: "", options: [.regularExpression, .caseInsensitive])
        }
        s = s.replacingOccurrences(of: "\\s+on[a-z]+\\s*=\\s*(\"[^\"]*\"|'[^']*'|[^\\s>]+)", with: "", options: [.regularExpression, .caseInsensitive])
        s = s.replacingOccurrences(of: "javascript:", with: "", options: [.caseInsensitive])
        return s
    }
}

/// The web-font faces, embedded as data URLs so the sandboxed document can use Geist.
enum GeistWeb {
    static let fontFace: String = {
        func face(_ file: String, _ family: String) -> String {
            guard let url = Bundle.main.url(forResource: file, withExtension: "woff2"), let data = try? Data(contentsOf: url) else { return "" }
            return "@font-face{font-family:\"\(family)\";font-style:normal;font-weight:100 900;src:url(data:font/woff2;base64,\(data.base64EncodedString())) format(\"woff2\");}"
        }
        return face("geist-latin", "Geist Variable") + face("geist-mono-latin", "Geist Mono Variable")
    }()
}

/// Lets SwiftUI poke the web view (quotes, selection) without owning it.
@MainActor
final class HtmlBodyController {
    weak var webView: WKWebView?
    func setQuotes(shown: Bool) { webView?.evaluateJavaScript("window.__hf && __hf.quotes(\(shown))") }
    func clearSelection() { webView?.evaluateJavaScript("window.getSelection() && getSelection().removeAllRanges()") }
}

struct MessageWebView: NSViewRepresentable {
    let document: String
    let controller: HtmlBodyController
    @Binding var height: CGFloat
    @Binding var ready: Bool
    @Binding var quoteCount: Int
    @Binding var selection: (text: String, x: CGFloat, y: CGFloat)?
    var onLink: (URL) -> Void
    var collapseQuotes = true

    static let script = """
    (function(){
      const Q = ".gmail_quote,blockquote[type=cite],.yahoo_quoted,#divRplyFwdMsg,#appendonsend,.moz-cite-prefix,.protonmail_quote,div[id^='yiv'] blockquote,.hey-quote";
      const post = (m) => window.webkit.messageHandlers.hf.postMessage(m);
      const tops = () => { const n = Array.from(document.querySelectorAll(Q)); return n.filter(x => !n.some(o => o !== x && o.contains(x))); };
      window.__hf = { quotes(show) { for (const n of tops()) n.classList.toggle("hey-quoted-hidden", !show); setTimeout(measure, 30); } };
      function measure(){ const b = document.body; if(!b) return; const h = Math.max(b.getBoundingClientRect().height, b.offsetHeight, b.scrollHeight); post({type:"height", h: Math.min(Math.ceil(h)+2, 20000)}); }
      const t = tops(); if (__COLLAPSE__) for (const n of t) n.classList.add("hey-quoted-hidden");
      post({type:"quotes", count: t.length});
      measure();
      try { new ResizeObserver(measure).observe(document.body); } catch(e){}
      document.querySelectorAll("img").forEach(i => i.addEventListener("load", measure));
      setTimeout(measure, 300); setTimeout(measure, 1500);
      // Senders write for a white page: `color:#000` on a paragraph, a `<font color>`, lands on
      // our dark one still wearing black and disappears. Anything that cannot be read against
      // the page gives up its colour and takes ours; legible colour is left as the sender set it.
      const page = getComputedStyle(document.documentElement).getPropertyValue("--hey-page").trim();
      const ink = getComputedStyle(document.documentElement).getPropertyValue("--hey-ink").trim();
      if (page && ink) {
        const parse = (c, over) => {
          const h = c.trim().match(/^#([0-9a-f]{3}|[0-9a-f]{6})$/i);
          if (h) { const x = h[1].length === 3 ? h[1].replace(/./g, d => d + d) : h[1];
            return [parseInt(x.slice(0,2),16), parseInt(x.slice(2,4),16), parseInt(x.slice(4,6),16)]; }
          const n = c.match(/-?\\d*\\.?\\d+/g); if (!n || n.length < 3) return null;
          const v = n.slice(0,3).map(Number), a = n.length > 3 ? Number(n[3]) : 1;
          return (a >= 1 || !over) ? v : v.map((x,i) => x*a + over[i]*(1-a));
        };
        const lum = (c) => { const f = (v) => { const x = v/255; return x <= 0.03928 ? x/12.92 : Math.pow((x+0.055)/1.055, 2.4); };
          return 0.2126*f(c[0]) + 0.7152*f(c[1]) + 0.0722*f(c[2]); };
        const bg = parse(page);
        const ratio = (c) => { const f = parse(c, bg); if (!f || !bg) return 21;
          const a = lum(f), b = lum(bg); return (Math.max(a,b)+0.05)/(Math.min(a,b)+0.05); };
        for (const el of document.body.querySelectorAll("*")) {
          const own = getComputedStyle(el).color; if (!own) continue;
          const parent = el.parentElement;
          if (parent && getComputedStyle(parent).color === own) continue;
          if (ratio(own) >= 3) continue;
          el.style.setProperty("color", ink, "important");
        }
        measure();
      }
      const sel = () => { const s = document.getSelection(); const txt = s ? s.toString().trim() : ""; if(!txt || !s || s.rangeCount===0){ post({type:"sel", text:""}); return; } const r = s.getRangeAt(0).getBoundingClientRect(); post({type:"sel", text: txt, x: r.left + r.width/2, y: r.top}); };
      document.addEventListener("selectionchange", sel); document.addEventListener("mouseup", sel);
    })();
    """

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        let user = WKUserContentController()
        user.add(context.coordinator, name: "hf")
        user.addUserScript(WKUserScript(source: Self.script.replacingOccurrences(of: "__COLLAPSE__", with: collapseQuotes ? "true" : "false"), injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        config.userContentController = user
        let view = WKWebView(frame: .zero, configuration: config)
        view.navigationDelegate = context.coordinator
        view.setValue(false, forKey: "drawsBackground")
        view.allowsMagnification = false
        controller.webView = view
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        context.coordinator.parent = self
        if context.coordinator.lastDocument != document {
            context.coordinator.lastDocument = document
            view.loadHTMLString(document, baseURL: nil)
        }
    }

    static func dismantleNSView(_ view: WKWebView, coordinator: Coordinator) {
        view.configuration.userContentController.removeScriptMessageHandler(forName: "hf")
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var parent: MessageWebView
        var lastDocument: String?
        init(_ parent: MessageWebView) { self.parent = parent }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
            Task { @MainActor in
                switch type {
                case "height":
                    if let h = body["h"] as? Double, h > 0 { parent.height = CGFloat(h); parent.ready = true }
                case "quotes":
                    parent.quoteCount = body["count"] as? Int ?? 0
                case "sel":
                    let text = body["text"] as? String ?? ""
                    if text.isEmpty { parent.selection = nil } else { parent.selection = (text, CGFloat(body["x"] as? Double ?? 0), CGFloat(body["y"] as? Double ?? 0)) }
                default: break
                }
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(150))
                if !parent.ready { parent.ready = true }
            }
        }

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if action.navigationType == .other, action.request.url == nil || action.request.url?.scheme == "about" { decisionHandler(.allow); return }
            if action.navigationType == .linkActivated, let url = action.request.url {
                let raw = url.absoluteString
                if !(raw.hasPrefix("#") || raw.lowercased().hasPrefix("javascript:") || raw.lowercased().hasPrefix("data:") || raw.lowercased().hasPrefix("cid:")) {
                    parent.onLink(url)
                }
            }
            decisionHandler(.cancel)
        }
    }
}
