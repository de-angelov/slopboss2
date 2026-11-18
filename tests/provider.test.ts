import { describe, expect, it } from "bun:test";
import { Option } from "effect";
import {
  buildAgyCommand,
  buildInteractiveCommand,
  parseAgyLine,
  UsageLimitReached,
  SessionCompleted,
} from "../dist/services/provider.js";

describe("Antigravity (agy) Provider Service", () => {
  it("builds headless agy command without model", () => {
    const cmd = buildAgyCommand(Option.none());
    expect(cmd).toEqual(["agy", "--output-format", "stream-json", "--dangerously-skip-permissions"]);
  });

  it("builds headless agy command with specified model", () => {
    const cmd = buildAgyCommand(Option.some("gemini-2.5-pro"));
    expect(cmd).toEqual([
      "agy",
      "--output-format",
      "stream-json",
      "--dangerously-skip-permissions",
      "--model",
      "gemini-2.5-pro",
    ]);
  });

  it("builds interactive agy command with prompt", () => {
    const cmd = buildInteractiveCommand(Option.none(), "Groom the backlog");
    expect(cmd).toEqual(["agy", "--dangerously-skip-permissions", "-i", "Groom the backlog"]);
  });

  it("parses usage limit event", () => {
    const eventOpt = parseAgyLine('{"error": "rate_limit_exceeded"}');
    expect(Option.isSome(eventOpt)).toBe(true);
    const event = Option.getOrThrow(eventOpt);
    expect(event._tag).toBe("UsageLimitReached");
  });

  it("parses completion event", () => {
    const eventOpt = parseAgyLine('{"status":"completed","done":true}');
    expect(Option.isSome(eventOpt)).toBe(true);
    const event = Option.getOrThrow(eventOpt);
    expect(event._tag).toBe("SessionCompleted");
  });
});
