import { describe, it, expect, vi, beforeAll, beforeEach, afterEach } from "vitest";
import { sendMail } from "../src/worker/send";
import { migrate, resetData, seedUser, seedOutlookAccount, testEnv } from "./helpers";

let fetchMock: ReturnType<typeof vi.fn>;

beforeAll(migrate);
beforeEach(async () => {
  await resetData();
  await seedUser();
  fetchMock = vi.fn();
  vi.stubGlobal("fetch", fetchMock);
});
afterEach(() => vi.unstubAllGlobals());

const params = {
  to: [{ email: "you@example.com", name: "You" }],
  subject: "Hi there",
  body_html: "<p>Hello</p>",
};

describe("sendMail routes on provider", () => {
  it("sends an Outlook account through Graph, not Gmail", async () => {
    fetchMock.mockResolvedValueOnce(new Response("", { status: 202 }));
    const acc = await seedOutlookAccount();

    await sendMail(testEnv, acc, params);

    // Ingesting the sent copy also resolves BIMI logos over DNS, so pick out the send call itself.
    const call = fetchMock.mock.calls.find((c) => String(c[0]).endsWith("/sendMail"));
    expect(call).toBeDefined();
    const [url, init] = call!;
    expect(String(url)).toBe("https://graph.microsoft.com/v1.0/me/sendMail");
    expect((init as RequestInit).method).toBe("POST");
    // Graph's MIME form: base64 of the whole RFC822 message, declared as text/plain.
    const headers = (init as RequestInit).headers as Record<string, string>;
    expect(headers["content-type"]).toBe("text/plain");
    const decoded = Buffer.from(String((init as RequestInit).body), "base64").toString("utf8");
    expect(decoded).toContain("Subject: Hi there");
    expect(decoded).toContain("To: \"You\" <you@example.com>");
  });

  it("never touches the Gmail API for an Outlook account", async () => {
    // Guards the fall-through class of bug: every Gmail guard used to read `provider === "domain"`.
    fetchMock.mockResolvedValueOnce(new Response("", { status: 202 }));
    await sendMail(testEnv, await seedOutlookAccount(), params);
    for (const call of fetchMock.mock.calls) {
      expect(String(call[0])).not.toContain("googleapis.com");
    }
  });

  it("records the sent message locally, since Graph returns an empty 202", async () => {
    fetchMock.mockResolvedValueOnce(new Response("", { status: 202 }));
    const r = await sendMail(testEnv, await seedOutlookAccount(), params);

    expect(r.message_id).not.toBe("");
    const row = await testEnv.DB.prepare(`SELECT * FROM messages WHERE id = ?`).bind(r.message_id).first<any>();
    expect(row).toBeTruthy();
    expect(row.gmail_labels_json).toContain("SENT");
    expect(row.subject).toBe("Hi there");
  });

  it("surfaces a Graph failure instead of reporting success", async () => {
    fetchMock.mockResolvedValueOnce(new Response(JSON.stringify({ error: { code: "ErrorMimeContentInvalidBase64String" } }), { status: 400 }));
    await expect(sendMail(testEnv, await seedOutlookAccount(), params)).rejects.toThrow(/outlook_send_failed/);
    const n = await testEnv.DB.prepare(`SELECT COUNT(*) AS n FROM messages`).first<{ n: number }>();
    expect(n!.n).toBe(0);
  });

  it("puts Bcc in the MIME headers, which is how Graph learns the recipients", async () => {
    fetchMock.mockResolvedValueOnce(new Response("", { status: 202 }));
    await sendMail(testEnv, await seedOutlookAccount(), { ...params, bcc: [{ email: "secret@example.com", name: "" }] });
    const call = fetchMock.mock.calls.find((c) => String(c[0]).endsWith("/sendMail"))!;
    const decoded = Buffer.from(String((call[1] as RequestInit).body), "base64").toString("utf8");
    expect(decoded).toContain("Bcc: secret@example.com");
  });
});
