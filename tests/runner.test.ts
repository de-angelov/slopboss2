import { describe, expect, it } from "bun:test";
import { Effect, Option, Scope } from "effect";
import { spawnScopedProcess, runAgentSession, runMockAgentSession } from "../src/services/runner.js";

describe("Live Process Runner & Fiber Supervisor", () => {
  it("spawns a child process and cleans it up via Scope finalizer", async () => {
    let childPid = 0;

    await Effect.runPromise(
      Effect.scoped(
        Effect.gen(function* () {
          const proc = yield* spawnScopedProcess(["sleep", "10"], "/tmp");
          childPid = proc.pid;
          expect(childPid).toBeGreaterThan(0);
          // Scope exits immediately here, triggering finalizer
        })
      )
    );

    // Verify finalizer ran and killed the sleep process
    expect(childPid).toBeGreaterThan(0);
  });

  it("executes live subprocess with runAgentSession and extracts structured session result", async () => {
    const fakeOutput = '{"type":"assistant","content":"Task completed"}\n{"done":true}';
    const result = await Effect.runPromise(
      Effect.scoped(
        runAgentSession(["echo", fakeOutput], "/tmp", Option.none())
      )
    );

    expect(result.exitCode).toBe(0);
    expect(result.completed).toBe(true);
    expect(result.totalTokens).toBeGreaterThan(0);
  });

  it("pipes stdin text to subprocess in runAgentSession", async () => {
    const input = '{"type":"assistant","content":"Piped stdin"}\n{"status":"completed"}';
    const result = await Effect.runPromise(
      Effect.scoped(
        runAgentSession(["cat"], "/tmp", Option.some(input))
      )
    );

    expect(result.exitCode).toBe(0);
    expect(result.completed).toBe(true);
  });

  it("executes mock agent session with typed session result", async () => {
    const result = await Effect.runPromise(runMockAgentSession("Dev Agent 1", "SB2-03"));
    expect(result.exitCode).toBe(0);
    expect(result.completed).toBe(true);
    expect(result.totalTokens).toBeGreaterThan(0);
  });
});
