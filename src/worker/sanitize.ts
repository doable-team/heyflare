const TRACKER_PATTERNS: RegExp[] = [
  /list-manage\.com\/track/i,
  /open\.convertkit/i,
  /convertkit-mail\d*\.com\/o\//i,
  /sendgrid\.net\/wf\/open/i,
  /sendgrid\.net\/wf\/click/i,
  /^(click|track|open|t|o)\.[a-z0-9.-]*sendgrid/i,
  /^(click|track|open|email)\.[a-z0-9.-]*mailgun/i,
  /mailgun\.(org|net|com)\/o\//i,
  /hubspotlinks\.com/i,
  /t\.hubspotemail\.net/i,
  /hubspot\.com\/e2t/i,
  /^(track|click|t)\.[a-z0-9.-]*hubspot/i,
  /mandrillapp\.com\/track/i,
  /mailtrack\.io/i,
  /ea\.mailtrack/i,
  /yesware(app)?\.com/i,
  /bananatag\.com/i,
  /mixmax\.com\/api\/track/i,
  /mixmax\.com\/(e|t)\//i,
  /mailfoogae\.appspot\.com/i, // streak
  /streak\.com/i,
  /getnotify\.com/i,
  /mailstat\.us/i,
  /salesforceiq\.com/i,
  /pardot\.com\/r\//i,
  /go\.pardot\.com/i,
  /r20\.rs6\.net\/on\.jsp/i, // constant contact open pixel
  /constantcontact\.com\/.*\/open/i,
  /mailspring\.com\/open/i,
  /getmailspring\.com\/open/i,
  /superhuman\.com\/.*(open|track)/i,
  /r\.superhuman\.com/i,
  /sparkpostmail\d*\.com\/.*\/open/i,
  /spgo\.io/i,
  /postmarkapp\.com\/open/i,
  /pstmrk\.it\/open/i,
  /google-analytics\.com\/collect/i,
  /mailerlite\.com\/(o|open)\//i,
  /ml\.mailersend\.com\/.*open/i,
  /sendibm\d*\.com\/.*(open|tr)/i, // sendinblue
  /sendinblue\.com\/tr\//i,
  /brevo\.com\/.*open/i,
  /trk\.klaviyomail\.com/i,
  /klaviyo\.com\/.*\/open/i,
  /substack(cdn)?\.com\/o\//i,
  /substack\.com\/open/i,
  /beehiiv\.com\/.*\/(open|o)/i,
  /customeriomail\.com\/.*\/open/i,
  /(track|e)\.customer\.io/i,
  /\/open\.gif(\?|$)/i,
  /\/open\.php(\?|$)/i,
  /\/track\/open/i,
  /\/o\.gif(\?|$)/i,
  /\/open\?/i,
  /\/wf\/open/i,
  /\/pixel\.(gif|png)/i,
  /\/1x1\.(gif|png)/i,
  /\/beacon/i,
  /\/trk\.php/i,
  /emltrk\.com/i,
  /litmus\.com\/(e|track)/i,
  /mailchimp\.com\/.*\/open/i,
  /mailchimpapp\.net/i,
  /cmail\d*\.com\/t\//i, // campaign monitor
  /createsend\d*\.com\/t\//i,
  /returnpath\.net/i,
  /rpr\.email/i,
  /intercom-mail\.com\/.*(open|track)/i,
  /via\.intercom\.io/i,
  /mailtrack\.rocks/i,
  /activehosted\.com\/lt\.php/i,
  /gmailtrack/i,
  /cirrusinsight\.com/i,
  /toutapp\.com/i,
  /outreach\.io\/.*(open|track)/i,
  /salesloft\.com\/.*(open|track)/i,
  /reply\.io\/.*open/i,
  /mailbutler\.io/i,
  /getsidekick\.com/i,
];

const MAX_HTML = 900 * 1024;

export interface StripResult {
  html: string;
  trackers: string[];
}

function hostOf(src: string): string {
  try {
    return new URL(src).hostname.toLowerCase();
  } catch {
    return "";
  }
}

function attr(tag: string, name: string): string | null {
  const re = new RegExp(`\\s${name}\\s*=\\s*(?:"([^"]*)"|'([^']*)'|([^\\s>]+))`, "i");
  const m = tag.match(re);
  if (!m) return null;
  return (m[1] ?? m[2] ?? m[3] ?? "").trim();
}

function isTinyDim(v: string | null): boolean {
  if (v == null) return false;
  const n = parseFloat(v);
  return !Number.isNaN(n) && n <= 2;
}

/** Decide if an <img> tag is a tracking pixel. Returns the host (or reason) when it is. */
function trackerReason(tag: string): string | null {
  const src = attr(tag, "src") ?? "";
  const host = hostOf(src);
  if (src) {
    for (const p of TRACKER_PATTERNS) {
      if (p.test(host) || p.test(src)) return host || "tracker";
    }
  }
  const w = attr(tag, "width");
  const h = attr(tag, "height");
  const style = (attr(tag, "style") ?? "").toLowerCase();
  const styleW = style.match(/width\s*:\s*([\d.]+)px/);
  const styleH = style.match(/height\s*:\s*([\d.]+)px/);
  const tinyW = isTinyDim(w) || (styleW ? parseFloat(styleW[1]) <= 2 : false);
  const tinyH = isTinyDim(h) || (styleH ? parseFloat(styleH[1]) <= 2 : false);
  if (tinyW && tinyH) return host || "pixel";
  if ((tinyW || tinyH) && /^https?:/i.test(src) && !/\.(svg|png|jpe?g)$/i.test(src.split("?")[0])) return host || "pixel";
  if (/display\s*:\s*none/.test(style) || /visibility\s*:\s*hidden/.test(style)) {
    if (/^https?:/i.test(src)) return host || "hidden-image";
  }
  return null;
}

export function stripTrackers(input: string): StripResult {
  let html = input ?? "";
  const trackers = new Set<string>();

  // Remove dangerous elements outright.
  html = html.replace(/<script\b[\s\S]*?<\/script\s*>/gi, "");
  html = html.replace(/<script\b[^>]*\/?>/gi, "");
  html = html.replace(/<iframe\b[\s\S]*?<\/iframe\s*>/gi, "");
  html = html.replace(/<iframe\b[^>]*\/?>/gi, "");
  html = html.replace(/<object\b[\s\S]*?<\/object\s*>/gi, "");
  html = html.replace(/<embed\b[^>]*\/?>/gi, "");
  html = html.replace(/<base\b[^>]*\/?>/gi, "");
  html = html.replace(/<meta\b[^>]*http-equiv[^>]*\/?>/gi, "");

  // Tracking pixels.
  html = html.replace(/<img\b[^>]*\/?>/gi, (tag) => {
    const reason = trackerReason(tag);
    if (reason) {
      trackers.add(reason);
      return "";
    }
    return tag;
  });

  // Inline event handlers + javascript: urls.
  html = html.replace(/<([a-z][a-z0-9:-]*)\b([^>]*)>/gi, (whole, name: string, attrs: string) => {
    if (!attrs) return whole;
    let cleaned = attrs.replace(/\s+on[a-z]+\s*=\s*(?:"[^"]*"|'[^']*'|[^\s>]+)/gi, "");
    cleaned = cleaned.replace(/\s(href|src|action|formaction|xlink:href)\s*=\s*(?:"\s*javascript:[^"]*"|'\s*javascript:[^']*'|javascript:[^\s>]+)/gi, "");
    cleaned = cleaned.replace(/\s(href|src)\s*=\s*(?:"\s*data:text\/html[^"]*"|'\s*data:text\/html[^']*')/gi, "");
    return `<${name}${cleaned}>`;
  });

  if (html.length > MAX_HTML) {
    html = html.slice(0, MAX_HTML) + "\n<p><em>[Message truncated: too large to store]</em></p>";
  }

  return { html, trackers: [...trackers] };
}

/** Very small HTML -> text conversion for plain-text alternatives and search. */
export function htmlToText(html: string): string {
  return (html ?? "")
    .replace(/<style\b[\s\S]*?<\/style\s*>/gi, "")
    .replace(/<script\b[\s\S]*?<\/script\s*>/gi, "")
    .replace(/<br\s*\/?>/gi, "\n")
    .replace(/<\/(p|div|tr|li|h[1-6]|blockquote)>/gi, "\n")
    .replace(/<[^>]+>/g, "")
    .replace(/&nbsp;/g, " ")
    .replace(/&amp;/g, "&")
    .replace(/&lt;/g, "<")
    .replace(/&gt;/g, ">")
    .replace(/&quot;/g, '"')
    .replace(/&#39;/g, "'")
    .replace(/\n{3,}/g, "\n\n")
    .trim();
}
