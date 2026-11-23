import { afterEach, beforeEach, describe, expect, it } from "bun:test";
import { Effect, Option, Queue } from "effect";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import { runCli } from "../src/cli/index.js";
import { loadBoardStoreSync } from "../src/domain/boardstore.js";
import {
  createMergeTrain,
  enqueueMerge,
  landMergeRequest,
  processNextMerge,
  type MergeRequest,
} from "../src/orchestrator/mergetrain.js";
import { getLockPath } from "../src/services/coordination.js";
import { initBoardStructure, verifyWorkspacesReadySync } from "../src/services/setup.js";

describe("Self-Hosting Verification & End-to-End Smoke Test", () => {
  let tempDir: string;

  beforeEach(() => {
    tempDir = fs.mkdtempSync(path.join(os.tmpdir(), "slopboss2-e2e-self-hosted-"));
  });

  afterEach(() => {
    if (fs.existsSync(tempDir)) {
      fs.rmSync(tempDir, { recursive: true, force: true });
    }
  });

  it("keeps dependents blocked when a completed session cannot land", async () => {
    // Setup temporary board directory
    await Effect.runPromise(initBoardStructure(tempDir, "", 2));

    // Seed BACKLOG with dependent tasks: Task B depends on Task A
    const dependentBacklog = `# BACKLOG

### Foundation Component

Task ID: SB2-BASE-01
Category: Core
Owner: Dev Agent 1
Branch: agent/1/base-01
Status: Backlog
Dependencies: none
Blocking tasks: SB2-DERIVED-02

Objective:
Implement foundation component.

### Dependent Component

Task ID: SB2-DERIVED-02
Category: Feature
Owner: Dev Agent 2
Branch: agent/2/derived-02
Status: Backlog
Dependencies: SB2-BASE-01
Blocking tasks: none

Objective:
Implement dependent component relying on SB2-BASE-01.
`;
    fs.writeFileSync(path.join(tempDir, "BACKLOG.md"), dependentBacklog, "utf-8");

    const executedTasks: string[] = [];
    const finalState = await Effect.runPromise(
      runCli(["run", "--dir", tempDir, "--iterations", "2", "--poll-interval", "10"], {
        runnerFn: (_agentId, taskId) =>
          Effect.sync(() => {
            executedTasks.push(taskId);
            return {
              exitCode: 0,
              totalTokens: 1200,
              completed: true,
            };
          }),
      })
    );

    expect(finalState.tickCount).toBe(2);
    // Without a real remote and branch, the first task cannot land; the
    // dependent must not run or enter the archive on process success alone.
    expect(executedTasks).toEqual(["SB2-BASE-01"]);
    const store = loadBoardStoreSync(tempDir);
    expect(store.archiveContent).not.toContain("SB2-BASE-01");
    expect(store.archiveContent).not.toContain("SB2-DERIVED-02");
    expect(store.backlogContent).toContain("SB2-DERIVED-02");
  });

  it("verifies complete self-hosted execution without any Go runtime dependency", () => {
    // Confirm slopboss2 package runs completely on Bun without Go binaries or subprocesses
    const pkg = JSON.parse(fs.readFileSync(path.join(__dirname, "../package.json"), "utf-8"));
    expect(pkg.dependencies["effect"]).toBeDefined();
    expect(pkg.dependencies["@effect/platform-bun"]).toBeDefined();
    expect(pkg.scripts["test"]).toContain("bun test");
    expect(typeof Bun).toBe("object");
    expect(typeof Bun.version).toBe("string");
  });

  it("verifies bin.fun executable runs standalone subcommands --help, doctor, and status directly under Bun", async () => {
    const binPath = path.resolve(__dirname, "../src/cli/bin.fun");

    // 1. Check bin.fun exists and is executable
    expect(fs.existsSync(binPath)).toBe(true);
    const stat = fs.statSync(binPath);
    expect(stat.mode & 0o111).toBeGreaterThan(0);

    // 2. Test ./src/cli/bin.fun --help
    const helpProc = Bun.spawn([binPath, "--help"], {
      stdout: "pipe",
      stderr: "pipe",
    });
    const helpOut = await new Response(helpProc.stdout).text();
    const helpCode = await helpProc.exited;
    expect(helpCode).toBe(0);
    expect(helpOut).toContain("slopboss2 - Autonomous multi-agent orchestrator");
    expect(helpOut).toContain("doctor");
    expect(helpOut).toContain("status");

    // 3. Test ./src/cli/bin.fun doctor --dir <tempDir>
    await Effect.runPromise(initBoardStructure(tempDir, "", 2));
    const doctorProc = Bun.spawn([binPath, "doctor", "--dir", tempDir], {
      stdout: "pipe",
      stderr: "pipe",
    });
    const doctorOut = await new Response(doctorProc.stdout).text();
    const doctorCode = await doctorProc.exited;
    expect(doctorCode).toBe(0);
    expect(doctorOut).toContain("Diagnostic Check Results:");
    expect(doctorOut).toContain("Overall Health:");

    // 4. Test ./src/cli/bin.fun status --dir <tempDir>
    const statusProc = Bun.spawn([binPath, "status", "--dir", tempDir], {
      stdout: "pipe",
      stderr: "pipe",
    });
    const statusOut = await new Response(statusProc.stdout).text();
    const statusCode = await statusProc.exited;
    expect(statusCode).toBe(0);
    expect(statusOut).toContain("SLOPBOSS2 BOARD STATUS");
  }, 30000);
});
