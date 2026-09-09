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
    /// The composer's quoted preview is an in-page div at 13px in the muted colour; the
    /// message itself is 14px in the foreground.
    var fontSize: CGFloat = 14
    var muted = false

    @Environment(\.colorScheme) private var scheme
    @State private var height: CGFloat = 48
    @State private var ready = false
    @State private var quoteCount = 0
    @State private var quotesShown = false
    @State private var selection: (text: String, x: CGFloat, y: CGFloat)? = nil
    @State private var clipSize: CGSize = .zero
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
                    // `px-3 py-2` on the light slab a painted message gets in dark mode.
                    .padding(.horizontal, slab ? 12 : 0)
                    .padding(.vertical, slab ? 8 : 0)
                    .background(slab ? Color.white : Color.clear)
                    .rounded(slab ? W.radiusMd : 0)
                    .opacity(ready ? 1 : 0)
                if !ready {
                    // `w-4/5` and `w-3/5` of the column, `space-y-2 pt-1`.
                    GeometryReader { geo in
                        VStack(alignment: .leading, spacing: 8) {
                            SkeletonBlock(width: geo.size.width * 0.8)
                            SkeletonBlock(width: geo.size.width * 0.6)
                        }
                        .padding(.top, 4)
                    }
                }
            }
            // `absolute -translate-x-1/2 -translate-y-full` at the selection's centre-top:
            // the button sits centred above the selected text, 6px clear of it.
            .overlay(alignment: .topLeading) {
                if let selection, let onClip {
                    WButton("Save clip", icon: "scissors", size: .xs) {
                        onClip(selection.text)
                        self.selection = nil
                        controller.clearSelection()
                    }
                    .shadow(color: .black.opacity(0.2), radius: 6, y: 2)
                    .background(GeometryReader { g in Color.clear.onAppear { clipSize = g.size }.onChange(of: g.size) { _, s in clipSize = s } })
                    .offset(x: selection.x - clipSize.width / 2, y: max(selection.y - 6, 0) - clipSize.height)
                    .zIndex(10)
                }
            }
            if quoteCount > 0 {
                Button {
                    quotesShown.toggle()
                    controller.setQuotes(shown: quotesShown)
                } label: {
                    HStack(spacing: 4) {
                        Icon("chevronDown", size: 12).rotationEffect(.degrees(quotesShown ? 180 : 0))
                        Text(quotesShown ? "Hide quoted text" : "Show quoted text")
                    }
                }
                .buttonStyle(.web(.ghost, .xs, muted: true))
                .animation(.easeOut(duration: 0.15), value: quotesShown)
                .padding(.top, 8)
            }
        }
    }

    private var document: String {
        let raw = usePlain
            ? "<div style=\"white-space:pre-wrap\">\(HtmlBodyView.escape(text))</div>"
            : html
        let dark = scheme == .dark
        let colors = W.css(dark: dark)
        let scheme = ownBackground ? "light" : (dark ? "dark" : "light")
        let fg = ownBackground ? "#37352f" : (muted ? colors.muted : colors.fg)
        let mutedColor = ownBackground ? "rgba(55,53,47,.65)" : colors.muted
        let border = ownBackground ? "rgba(55,53,47,.12)" : colors.border
        let selectionBg = ownBackground ? "#37352f" : colors.fg
        let selectionFg = ownBackground ? "#ffffff" : colors.bg
        return """
        <!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src https: http: data: cid:; style-src 'unsafe-inline'; font-src data:">
        <style>
        \(GeistWeb.fontFace)
        html{color-scheme:\(scheme);\(dark && !ownBackground ? "--hey-page:\(colors.bg);--hey-ink:\(fg);" : "")}
        html,body{margin:0;padding:0;background:transparent;}
        body{display:flow-root;font-family:"Geist Variable",Geist,system-ui,-apple-system,sans-serif;font-size:\(HtmlBodyView.css(fontSize))px;line-height:1.6;color:\(fg);word-wrap:break-word;overflow-wrap:anywhere;}
        img{max-width:100% !important;height:auto;}
        table{max-width:100% !important;}
        a{color:\(fg);text-decoration:underline;text-underline-offset:2px;}
        blockquote{border-left:2px solid \(border);margin:.5em 0;padding-left:1em;color:\(mutedColor);}
        pre{white-space:pre-wrap;font-family:"Geist Mono Variable","Geist Mono",ui-monospace,Menlo,monospace;font-size:12.5px;}
        ::selection{background:\(selectionBg);color:\(selectionFg);}
        .hey-quoted-hidden{display:none !important;}
        </style>
        <meta name="hf-src" content="\(HtmlBodyView.escape(raw))">
        </head><body></body></html>
        """
    }

    private static func css(_ v: CGFloat) -> String {
        v == v.rounded() ? String(Int(v)) : String(format: "%.2f", v)
    }

    static func paintsOwnBackground(_ html: String) -> Bool {
        html.range(of: #"background(?:-color)?\s*:\s*(?!transparent|inherit|none)[^;"']+"#, options: [.regularExpression, .caseInsensitive]) != nil
            || html.range(of: #"\bbgcolor\s*="#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
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

    /// `sanitizeEmailHtml`: DOMPurify's default pass, run on a real DOM (`DOMParser`) before
    /// anything is put on the page. Tags off the allowlist are unwrapped (their text kept) unless they
    /// are content that must go with them — script, iframe, head, title, noscript, style
    /// outside the body…; attributes are filtered by name and, for URLs, by scheme, with
    /// `data:` allowed only where an image can carry it. `<style>` blocks survive, as they
    /// do on the web, so designed mail keeps its CSS.
    static let sanitizer = """
    (function(){
      const set = (s) => { const o = Object.create(null); for (const t of s.split(/\\s+/)) if (t) o[t.toLowerCase()] = true; return o; };
      const HTML = set("a abbr acronym address area article aside audio b bdi bdo big blink blockquote body br button canvas caption center cite code col colgroup content data datalist dd decorator del details dfn dialog dir div dl dt element em fieldset figcaption figure font footer form h1 h2 h3 h4 h5 h6 head header hgroup hr html i img input ins kbd label legend li main map mark marquee menu menuitem meter nav nobr ol optgroup option output p picture pre progress q rp rt ruby s samp section select shadow small source spacer span strike strong style sub summary sup table tbody td template textarea tfoot th thead time tr track tt u ul var video wbr");
      const SVG = set("svg a altglyph altglyphdef altglyphitem animatecolor animatemotion animatetransform circle clippath defs desc ellipse filter font g glyph glyphref hkern image line lineargradient marker mask metadata mpath path pattern polygon polyline radialgradient rect stop style switch symbol text textpath title tref tspan view vkern feBlend feColorMatrix feComponentTransfer feComposite feConvolveMatrix feDiffuseLighting feDisplacementMap feDistantLight feDropShadow feFlood feFuncA feFuncB feFuncG feFuncR feGaussianBlur feImage feMerge feMergeNode feMorphology feOffset fePointLight feSpecularLighting feSpotLight feTile feTurbulence");
      const MATH = set("math menclose merror mfenced mfrac mglyph mi mlabeledtr mmultiscripts mn mo mover mpadded mphantom mroot mrow ms mspace msqrt mstyle msub msup msubsup mtable mtd mtext mtr munder munderover mprescripts");
      const FORBID_TAGS = set("script iframe object embed form input button meta link base");
      const FORBID_CONTENTS = set("annotation-xml audio colgroup desc foreignobject head iframe math mi mn mo ms mtext noembed noframes noscript plaintext script select style svg template thead title video xmp");
      const ATTRS = set("accept action align alt autocapitalize autocomplete autopictureinpicture autoplay background bgcolor border capture cellpadding cellspacing checked cite class clear color cols colspan controls controlslist coords crossorigin datetime decoding default dir disabled disablepictureinpicture disableremoteplayback download draggable enctype enterkeyhint face for headers height hidden high href hreflang id inputmode integrity ismap kind label lang list loading loop low max maxlength media method min minlength multiple muted name nonce noshade novalidate nowrap open optimum pattern placeholder playsinline popover popovertarget popovertargetaction poster preload pubdate radiogroup readonly rel required rev reversed role rows rowspan spellcheck scope selected shape size sizes span srclang start src srcset step style summary tabindex title type usemap valign value width wrap xmlns slot accent-height accumulate additive alignment-baseline amplitude ascent attributename attributetype azimuth basefrequency baseline-shift begin bias by clip clippathunits clip-path clip-rule color-interpolation color-interpolation-filters color-profile color-rendering cx cy d dx dy diffuseconstant direction display divisor dur edgemode elevation end exponent fill fill-opacity fill-rule filter filterunits flood-color flood-opacity font-family font-size font-size-adjust font-stretch font-style font-variant font-weight fx fy g1 g2 glyph-name glyphref gradientunits gradienttransform image-rendering in in2 intercept k k1 k2 k3 k4 kerning keypoints keysplines keytimes lengthadjust letter-spacing kernelmatrix kernelunitlength lighting-color local marker-end marker-mid marker-start markerheight markerunits markerwidth maskcontentunits maskunits mask mode numoctaves offset operator opacity order orient orientation origin overflow paint-order path pathlength patterncontentunits patterntransform patternunits points preservealpha preserveaspectratio primitiveunits r rx ry radius refx refy repeatcount repeatdur restart result rotate scale seed shape-rendering slope specularconstant specularexponent spreadmethod startoffset stddeviation stitchtiles stop-color stop-opacity stroke-dasharray stroke-dashoffset stroke-linecap stroke-linejoin stroke-miterlimit stroke-opacity stroke stroke-width surfacescale systemlanguage tablevalues targetx targety transform transform-origin text-anchor text-decoration text-rendering textlength u1 u2 unicode values viewbox visibility version vert-adv-y vert-origin-x vert-origin-y word-spacing writing-mode xchannelselector ychannelselector x x1 x2 y y1 y2 z zoomandpan accent accentunder columnalign columnlines columnspan denomalign depth displaystyle encoding fence frame largeop lspace lquote mathbackground mathcolor mathsize mathvariant maxsize minsize movablelimits notation numalign open rowalign rowlines rowspacing rowspan rspace rquote scriptlevel scriptminsize scriptsizemultiplier selection separator separators stretchy subscriptshift supscriptshift symmetric voffset xlink:href xml:id xlink:title xml:space xmlns:xlink");
      const FORBID_ATTR = set("onerror onload onclick formaction");
      const URI_SAFE = set("alt class for id label name pattern placeholder role summary title value style xmlns");
      const DATA_URI_TAGS = set("audio video img source image track");
      const IS_ALLOWED_URI = /^(?:(?:(?:f|ht)tps?|mailto|tel|callto|sms|cid|xmpp|matrix):|[^a-z]|[a-z+.\\-]+(?:[^a-z+.\\-:]|$))/i;
      const ATTR_WS = /[\\u0000-\\u0020\\u00A0\\u1680\\u180E\\u2000-\\u2029\\u205F\\u3000]/g;
      const DATA_ATTR = /^data-[\\-\\w.\\u00B7-\\uFFFF]+$/;
      const ARIA_ATTR = /^aria-[\\-\\w]+$/;
      const HTML_NS = "http://www.w3.org/1999/xhtml", SVG_NS = "http://www.w3.org/2000/svg", MATH_NS = "http://www.w3.org/1998/Math/MathML";
      const formEl = document.createElement("form");
      const clobbered = (el) => typeof el.nodeName !== "string" || typeof el.textContent !== "string" || typeof el.removeChild !== "function" || !(el.attributes instanceof NamedNodeMap) || typeof el.removeAttribute !== "function" || typeof el.setAttribute !== "function" || typeof el.namespaceURI !== "string" || typeof el.insertBefore !== "function" || typeof el.hasChildNodes !== "function";
      const validNamespace = (el, tag) => {
        const parent = el.parentNode; const pns = parent ? parent.namespaceURI : HTML_NS; const ptag = parent ? String(parent.nodeName).toLowerCase() : "";
        if (el.namespaceURI === SVG_NS) { if (pns === HTML_NS) return tag === "svg"; if (pns === MATH_NS) return tag === "svg" && (ptag === "annotation-xml" || ptag === "mtext" || ptag === "mi" || ptag === "mo" || ptag === "mn" || ptag === "ms"); return pns === SVG_NS && !!SVG[tag]; }
        if (el.namespaceURI === MATH_NS) { if (pns === HTML_NS) return tag === "math"; if (pns === SVG_NS) return tag === "math" && (ptag === "foreignobject" || ptag === "desc" || ptag === "title"); return pns === MATH_NS && !!MATH[tag]; }
        if (el.namespaceURI === HTML_NS) { if (pns === SVG_NS) return ptag === "foreignobject" || ptag === "desc" || ptag === "title"; if (pns === MATH_NS) return ptag === "mi" || ptag === "mo" || ptag === "mn" || ptag === "ms" || ptag === "mtext" || ptag === "annotation-xml"; return !SVG[tag] && !MATH[tag] || !!HTML[tag]; }
        return false;
      };
      const validAttr = (tag, name, value) => {
        if ((name === "id" || name === "name") && (value in document || value in formEl)) return false;
        if (!FORBID_ATTR[name] && DATA_ATTR.test(name)) return true;
        if (ARIA_ATTR.test(name)) return true;
        if (!ATTRS[name] || FORBID_ATTR[name]) return false;
        if (URI_SAFE[name]) return true;
        if (IS_ALLOWED_URI.test(value.replace(ATTR_WS, ""))) return true;
        if ((name === "src" || name === "xlink:href" || name === "href") && tag !== "script" && value.indexOf("data:") === 0 && DATA_URI_TAGS[tag]) return true;
        return !value;
      };
      const sanitizeAttributes = (el, tag) => {
        for (const attr of Array.from(el.attributes).reverse()) {
          const name = attr.name, lc = name.toLowerCase();
          const value = lc === "value" ? attr.value : attr.value.trim();
          el.removeAttribute(name);
          if (/((--!?|])>)|<\\/(style|title)/i.test(value)) continue;
          if (!validAttr(tag, lc, value)) continue;
          try { el.setAttribute(name, value); } catch (e) {}
        }
      };
      window.__hfSanitize = function (raw) {
        const doc = new DOMParser().parseFromString(raw, "text/html");
        const body = doc.body; if (!body) return [];
        const it = doc.createNodeIterator(body, NodeFilter.SHOW_ELEMENT | NodeFilter.SHOW_COMMENT | NodeFilter.SHOW_TEXT | NodeFilter.SHOW_PROCESSING_INSTRUCTION | NodeFilter.SHOW_CDATA_SECTION);
        let node;
        while ((node = it.nextNode())) {
          if (node === body) continue;
          if (node.nodeType === 3) continue;
          if (node.nodeType === 8) { if (/<[\\/\\w]/.test(node.data)) node.remove(); continue; }
          if (node.nodeType !== 1) { node.remove(); continue; }
          if (clobbered(node)) { node.remove(); continue; }
          const tag = node.nodeName.toLowerCase();
          if (!validNamespace(node, tag)) { node.remove(); continue; }
          if (!HTML[tag] && !SVG[tag] && !MATH[tag] || FORBID_TAGS[tag] || tag === "template") {
            const parent = node.parentNode;
            if (parent && !FORBID_CONTENTS[tag] && tag !== "template") {
              const next = node.nextSibling;
              while (node.firstChild) parent.insertBefore(node.firstChild, next);
            }
            node.remove();
            continue;
          }
          if ((tag === "noscript" || tag === "noembed" || tag === "noframes") && /<\\/no(script|embed|frames)/i.test(node.innerHTML)) { node.remove(); continue; }
          sanitizeAttributes(node, tag);
        }
        return Array.from(body.childNodes);
      };
    })();
    """

    static let script = """
    (function(){
      // The raw message rides in as an attribute (entity-escaped, so none of it is markup
      // yet); the sanitiser builds the DOM that goes on the page.
      const src = document.querySelector('meta[name="hf-src"]');
      const raw = src ? (src.getAttribute("content") || "") : "";
      if (src) src.remove();
      for (const n of window.__hfSanitize(raw)) document.body.appendChild(document.adoptNode(n));
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
        user.addUserScript(WKUserScript(source: Self.sanitizer, injectionTime: .atDocumentStart, forMainFrameOnly: true))
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
                if !(raw.hasPrefix("#") || raw.lowercased().hasPrefix("javascript:") || raw.lowercased().hasPrefix("data:") || raw.lowercased().hasPrefix("cid:") || raw.lowercased().hasPrefix("blob:")) {
                    parent.onLink(url)
                }
            }
            decisionHandler(.cancel)
        }
    }
}
