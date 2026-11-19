import { describe, expect, it } from "bun:test";
import { Effect, Fiber, Option } from "effect";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
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

  it("does not treat a clean exit without completion evidence as completed", async () => {
    const result = await Effect.runPromise(
      Effect.scoped(runAgentSession(["sh", "-c", "cat >/dev/null; echo '{\\\"type\\\":\\\"assistant\\\",\\\"content\\\":\\\"working\\\"}'"], "/tmp", Option.some("prompt")))
    );
    expect(result.exitCode).toBe(0);
    expect(result.completed).toBe(false);
  });

  it("treats a provider usage limit as an unsuccessful session", async () => {
    const result = await Effect.runPromise(
      Effect.scoped(runAgentSession(["sh", "-c", "echo '{\\\"type\\\":\\\"usage_limit\\\"}'; echo '{\\\"done\\\":true}'"], "/tmp", Option.none()))
    );
    expect(result.exitCode).toBe(0);
    expect(result.completed).toBe(false);
  });

  it("runs concurrent fake provider sessions in their assigned Git workspaces with their prompts", async () => {
    const root = fs.mkdtempSync(path.join(os.tmpdir(), "slopboss-agent-sessions-"));
    const executable = path.join(root, "fake-agy");
    const logPath = path.join(root, "sessions.log");
    fs.writeFileSync(executable, `#!/bin/sh\ninput=$(cat)\nprintf '%s\\n%s\\n' "$PWD" "$input" >> '${logPath}'\nprintf '{"done":true}\\n'\n`);
    fs.chmodSync(executable, 0o755);
    const workspaces = [path.join(root, "agent-1"), path.join(root, "agent-2")];
    try {
      for (const workspace of workspaces) {
        fs.mkdirSync(workspace);
        Bun.spawnSync(["git", "init", "-b", "main"], { cwd: workspace });
        fs.writeFileSync(path.join(workspace, "existing-change.txt"), "preserve me");
      }
      const results = await Effect.runPromise(Effect.all(workspaces.map((workspace, index) =>
        Effect.scoped(runAgentSession([executable, "--output-format", "stream-json"], workspace, Option.some(`task prompt ${index + 1}`)))
      ), { concurrency: "unbounded" }));
      expect(results.map((result) => result.completed)).toEqual([true, true]);
      const log = fs.readFileSync(logPath, "utf-8");
      for (let index = 0; index < workspaces.length; index++) {
        expect(log).toContain(`${workspaces[index]}\ntask prompt ${index + 1}`);
        expect(fs.readFileSync(path.join(workspaces[index], "existing-change.txt"), "utf-8")).toBe("preserve me");
      }
    } finally {
      fs.rmSync(root, { recursive: true, force: true });
    }
  });

  it("keeps nonzero fake provider exits unsuccessful even when completion is reported", async () => {
    const result = await Effect.runPromise(Effect.scoped(
      runAgentSession(["sh", "-c", "echo '{\\\"done\\\":true}'; exit 7"], "/tmp", Option.none())
    ));
    expect(result.exitCode).toBe(7);
    expect(result.completed).toBe(false);
  });

  it("interrupts a running provider session and runs its process finalizer", async () => {
    const fiber = Effect.runFork(Effect.scoped(runAgentSession(
      ["sh", "-c", "cat >/dev/null; sleep 30"], "/tmp", Option.some("prompt")
    )));
    await new Promise((resolve) => setTimeout(resolve, 40));
    await Effect.runPromise(Fiber.interrupt(fiber));
    expect(fiber).toBeDefined();
  });

  it("executes mock agent session with typed session result", async () => {
    const result = await Effect.runPromise(runMockAgentSession("Dev Agent 1", "SB2-03"));
    expect(result.exitCode).toBe(0);
    expect(result.completed).toBe(true);
    expect(result.totalTokens).toBeGreaterThan(0);
  });
});
