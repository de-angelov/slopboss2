import { describe, expect, it } from "bun:test";
import { Effect, Option } from "effect";
import * as fs from "node:fs/promises";
import * as os from "node:os";
import * as path from "node:path";
import {
  buildGroomPrompt,
  printStatus,
  runSetup,
} from "../src/cli/index.js";

describe("CLI & Interactive Grooming Module", () => {
  it("builds structured grooming prompt containing backlog content and task guidelines", () => {
    const backlog = "- [ ] SB2-07: Interactive TUI live view\n- [ ] SB2-08: Merge train";
    const prompt = buildGroomPrompt("/tmp/test-board", backlog);

    expect(prompt).toContain("/tmp/test-board");
    expect(prompt).toContain("--- CURRENT BACKLOG.md ---");
    expect(prompt).toContain("SB2-07: Interactive TUI live view");
    expect(prompt).toContain("SB2-08: Merge train");
    expect(prompt).toContain("Task ID");
    expect(prompt).toContain("Acceptance Criteria");
  });

  it("executes printStatus cleanly", async () => {
    const result = await Effect.runPromise(printStatus("/tmp/test-board"));
    expect(result).toBe(true);
  });

  it("executes runSetup cleanly", async () => {
    const result = await Effect.runPromise(
      runSetup("/tmp/test-board", "https://github.com/de-angelov/slopboss2.git")
    );
    expect(result).toBe(true);
  });
});
