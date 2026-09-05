import { describe, it, expect } from "vitest";
import { dotStuff, chooseAuth, SmtpError, smtpSend } from "../src/worker/smtp";

describe("dotStuff", () => {
  it("escapes a leading dot on a continuation line", () => {
    // Without this the server treats the line as end-of-message and truncates the mail.
    expect(dotStuff("Hello\r\n.hidden\r\nBye")).toBe("Hello\r\n..hidden\r\nBye");
  });

  it("escapes a dot at the very start of the message", () => {
    expect(dotStuff(".leading")).toBe("..leading");
  });

  it("leaves dots that are not line-initial alone", () => {
    expect(dotStuff("a.b\r\nc.d")).toBe("a.b\r\nc.d");
  });

  it("escapes the terminator sequence itself", () => {
    expect(dotStuff("body\r\n.\r\n")).toBe("body\r\n..\r\n");
  });
});

describe("chooseAuth", () => {
  it("prefers PLAIN when both are offered", () => {
    expect(chooseAuth("250-mx\r\n250-AUTH LOGIN PLAIN\r\n250 SIZE 1")).toBe("PLAIN");
  });

  it("falls back to LOGIN", () => {
    expect(chooseAuth("250-mx\r\n250-AUTH LOGIN\r\n250 SIZE 1")).toBe("LOGIN");
  });

  it("handles the AUTH= form some servers emit", () => {
    expect(chooseAuth("250-AUTH=LOGIN PLAIN\r\n250 OK")).toBe("PLAIN");
  });

  it("returns null when no usable mechanism is advertised", () => {
    expect(chooseAuth("250-AUTH GSSAPI NTLM\r\n250 OK")).toBeNull();
    expect(chooseAuth("250-mx\r\n250 SIZE 1")).toBeNull();
  });
});

describe("smtpSend guards", () => {
  const cfg = { host: "smtp.example.com", port: 587, security: "starttls" as const, username: "u", password: "p" };

  it("refuses port 25, which Cloudflare blocks outright", async () => {
    await expect(smtpSend({ ...cfg, port: 25 }, { from: "a@b.c", recipients: ["d@e.f"], raw: "x" })).rejects.toThrow(
      /smtp_port_25_blocked/
    );
  });

  it("refuses a message with no envelope recipients", async () => {
    await expect(smtpSend(cfg, { from: "a@b.c", recipients: [], raw: "x" })).rejects.toBeInstanceOf(SmtpError);
  });
});

describe("SmtpError", () => {
  it("marks credential rejections as permanent", () => {
    expect(new SmtpError(535, "smtp_auth_failed", { auth: true }).auth).toBe(true);
  });

  it("defaults to transient", () => {
    expect(new SmtpError(0, "smtp_timeout: greeting").auth).toBe(false);
  });
});

describe("port guards", () => {
  const cfg = { host: "h", port: 465, security: "tls" as const, username: "u", password: "p" };
  it("still refuses port 25 with an explanation", async () => {
    await expect(smtpSend({ ...cfg, port: 25 }, { from: "a@b.c", recipients: ["d@e.f"], raw: "x" })).rejects.toThrow(/port_25/);
  });
});
