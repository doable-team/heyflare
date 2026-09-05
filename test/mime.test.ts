import { describe, it, expect } from "vitest";
import { buildRfc822, buildRawMime, buildMimeBase64 } from "../src/worker/mime";

const base = {
  from: { email: "me@example.com", name: "Me" },
  to: [{ email: "you@example.com", name: "You" }],
  subject: "Hello",
  html: "<p>Hi</p>",
  text: "Hi",
};

describe("buildRfc822", () => {
  it("uses CRLF line endings throughout", () => {
    const raw = buildRfc822(base);
    expect(raw).toContain("\r\n");
    // A bare LF would break strict SMTP servers and some MIME parsers.
    expect(raw.replace(/\r\n/g, "")).not.toContain("\n");
  });

  it("is multipart/alternative with no attachments and multipart/mixed with them", () => {
    expect(buildRfc822(base)).toContain("Content-Type: multipart/alternative");
    const withAtt = buildRfc822({
      ...base,
      attachments: [{ filename: "a.txt", mime_type: "text/plain", data_base64: "aGk=" }],
    });
    expect(withAtt).toContain("Content-Type: multipart/mixed");
    expect(withAtt).toContain('filename="a.txt"');
  });

  it("carries threading headers only when threading", () => {
    expect(buildRfc822(base)).not.toContain("In-Reply-To:");
    const reply = buildRfc822({ ...base, inReplyTo: "<a@x>", references: "<a@x> <b@x>" });
    expect(reply).toContain("In-Reply-To: <a@x>");
    expect(reply).toContain("References: <a@x> <b@x>");
  });

  it("RFC 2047-encodes non-ASCII subjects and display names", () => {
    const raw = buildRfc822({ ...base, subject: "Résumé", from: { email: "me@example.com", name: "Zoë" } });
    expect(raw).toContain("=?UTF-8?B?");
    expect(raw).not.toContain("Subject: Résumé");
  });

  it("honours a caller-supplied Message-ID so the sender can record what it sent", () => {
    expect(buildRfc822({ ...base, messageId: "<fixed@example.com>" })).toContain("Message-ID: <fixed@example.com>");
  });

  it("omits Bcc from headers when asked (envelope-only, for a direct SMTP transport)", () => {
    const p = { ...base, bcc: [{ email: "secret@example.com", name: "" }] };
    expect(buildRfc822(p)).toContain("Bcc: secret@example.com");
    expect(buildRfc822(p, { includeBcc: false })).not.toContain("Bcc:");
  });
});

// Every build mints a fresh MIME boundary and Date, so two calls are never byte-identical.
// These assert the encoding contract instead: what comes back out is the message that went in.
describe("encoding wrappers", () => {
  const p = { ...base, messageId: "<fixed@example.com>" };

  it("buildRawMime stays base64url for Gmail", () => {
    const enc = buildRawMime(p);
    // base64url alphabet only: no +, / or = padding, so it is safe in Gmail's JSON `raw` field.
    expect(enc).toMatch(/^[A-Za-z0-9_-]+$/);
    const decoded = Buffer.from(enc, "base64url").toString("utf8");
    expect(decoded).toMatch(/^From: "Me" <me@example\.com>\r\n/);
    expect(decoded).toContain("Message-ID: <fixed@example.com>");
    expect(decoded).toContain("Subject: Hello");
  });

  it("buildMimeBase64 is standard base64 for Graph", () => {
    const enc = buildMimeBase64(p);
    const decoded = Buffer.from(enc, "base64").toString("utf8");
    expect(decoded).toMatch(/^From: "Me" <me@example\.com>\r\n/);
    expect(decoded).toContain("Message-ID: <fixed@example.com>");
  });

  it("the two wrappers differ only in alphabet", () => {
    const url = buildRawMime(p);
    const std = buildMimeBase64(p);
    // Same length modulo padding; base64url is the padding-free, +/ -> -_ variant.
    expect(url.replace(/[-_]/g, "")).toHaveLength(std.replace(/[+/=]/g, "").length);
  });
});
