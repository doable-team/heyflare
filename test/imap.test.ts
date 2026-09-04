import { describe, it, expect } from "vitest";
import { literalSize, quote, parseSearchUids, parseSelect, parseFetchUid } from "../src/worker/imap";

describe("literalSize", () => {
  it("reads a trailing literal marker", () => {
    expect(literalSize("* 1 FETCH (UID 5 BODY[] {1234}")).toBe(1234);
  });

  it("ignores a brace that is not at the end", () => {
    // Only a trailing {n} introduces a literal; braces elsewhere are ordinary text.
    expect(literalSize("* OK {not a literal} here")).toBeNull();
  });

  it("returns null for an ordinary line", () => {
    expect(literalSize("a001 OK LOGIN completed")).toBeNull();
  });
});

describe("quote", () => {
  it("escapes quotes and backslashes so odd passwords cannot break framing", () => {
    expect(quote('pa"ss')).toBe('"pa\\"ss"');
    expect(quote("pa\\ss")).toBe('"pa\\\\ss"');
  });

  it("wraps a plain value", () => {
    expect(quote("INBOX")).toBe('"INBOX"');
  });
});

describe("parseSearchUids", () => {
  it("collects uids from an untagged SEARCH line", () => {
    expect(parseSearchUids(["* SEARCH 3 4 7", "a002 OK"])).toEqual([3, 4, 7]);
  });

  it("handles an empty result", () => {
    expect(parseSearchUids(["* SEARCH", "a002 OK"])).toEqual([]);
    expect(parseSearchUids(["a002 OK"])).toEqual([]);
  });
});

describe("parseSelect", () => {
  it("reads UIDVALIDITY, UIDNEXT and EXISTS", () => {
    const r = parseSelect([
      "* 12 EXISTS",
      "* OK [UIDVALIDITY 1568440178] UIDs valid",
      "* OK [UIDNEXT 4321] Predicted next UID",
    ]);
    expect(r).toEqual({ uidValidity: 1568440178, uidNext: 4321, exists: 12 });
  });

  it("defaults missing fields to zero rather than NaN", () => {
    expect(parseSelect(["* OK nothing useful"])).toEqual({ uidValidity: 0, uidNext: 0, exists: 0 });
  });
});

describe("parseFetchUid", () => {
  it("finds the UID wherever the server puts it", () => {
    expect(parseFetchUid("* 1 FETCH (UID 42 BODY[] {10}")).toBe(42);
    // Some servers order the data items differently.
    expect(parseFetchUid("* 1 FETCH (BODY[] {10} UID 42)")).toBe(42);
  });

  it("returns null when absent", () => {
    expect(parseFetchUid("* 1 FETCH (BODY[] {10}")).toBeNull();
  });
});
