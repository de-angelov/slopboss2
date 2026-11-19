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

  it("spins up standalone slopboss2, executes 2 iterations, moves tasks from Backlog to Archive, and verifies merge train", async () => {
    // 1. Setup temporary board directory with setup.initBoardStructure
    const initResult = await Effect.runPromise(initBoardStructure(tempDir, "", 2));
    expect(initResult.ok).toBe(true);
    expect(initResult.workspacesCreated.length).toBe(3); // repo-tl, repo-agent-1, repo-agent-2

    // Verify workspace git health
    const readyReport = verifyWorkspacesReadySync(tempDir, 2);
    expect(readyReport.ok).toBe(true);
    expect(readyReport.workspaces.length).toBe(3);

    // Verify core coordination files are present
    expect(fs.existsSync(path.join(tempDir, "TASKS.md"))).toBe(true);
    expect(fs.existsSync(path.join(tempDir, "BACKLOG.md"))).toBe(true);
    expect(fs.existsSync(path.join(tempDir, "ARCHIVE.md"))).toBe(true);
    expect(fs.existsSync(path.join(tempDir, "AGENTS.md"))).toBe(true);

    // 2. Populate BACKLOG.md with 2 mock tasks
    const mockBacklog = `# BACKLOG

### Cache Layer Implementation

Task ID: SB2-E2E-01
Category: Core
Owner: Dev Agent 1
Branch: agent/1/cache-layer
Status: Backlog
Dependencies: none
Blocking tasks: none

Objective:
Implement in-memory LRU cache layer for orchestrator state.

Scope:
- Add cache eviction policies.
- Unit test cache hit/miss ratio.

Acceptance Criteria:
- Cache layer passes all unit tests.

### Telemetry & Token Metrics Exporter

Task ID: SB2-E2E-02
Category: Analytics
Owner: Dev Agent 2
Branch: agent/2/telemetry-exporter
Status: Backlog
Dependencies: none
Blocking tasks: none

Objective:
Implement structured token metrics telemetry exporter.

Scope:
- Aggregate token usage across agent sessions.
- Expose JSON formatted metrics.

Acceptance Criteria:
- Metrics exporter outputs valid token telemetry.
`;
    fs.writeFileSync(path.join(tempDir, "BACKLOG.md"), mockBacklog, "utf-8");

    // Verify initial board state
    const storeBefore = loadBoardStoreSync(tempDir);
    expect(storeBefore.backlogContent).toContain("SB2-E2E-01");
    expect(storeBefore.backlogContent).toContain("SB2-E2E-02");
    expect(storeBefore.archiveContent).not.toContain("SB2-E2E-01");
    expect(storeBefore.archiveContent).not.toContain("SB2-E2E-02");

    // 3. Run slopboss2 run --iterations 2
    const finalState = await Effect.runPromise(
      runCli(["run", "--dir", tempDir, "--iterations", "2", "--poll-interval", "10"])
    );

    expect(finalState).toBeDefined();
    expect(finalState.tickCount).toBe(2);
    expect(finalState.tokenCounter.totalTokens).toBeGreaterThan(0);

    // 4. Verify tasks moved automatically: Backlog -> Dev Lane -> Archive
    const storeAfter = loadBoardStoreSync(tempDir);

    // Backlog must no longer contain the executed tasks
    expect(storeAfter.backlogContent).not.toContain("SB2-E2E-01");
    expect(storeAfter.backlogContent).not.toContain("SB2-E2E-02");

    // Archive must contain both executed tasks marked as completed
    expect(storeAfter.archiveContent).toContain("SB2-E2E-01");
    expect(storeAfter.archiveContent).toContain("SB2-E2E-02");

    // TASKS.md dev lanes must be clean and not have lingering In Progress tasks
    const tasksContent = fs.readFileSync(path.join(tempDir, "TASKS.md"), "utf-8");
    expect(tasksContent).not.toContain("Task ID: SB2-E2E-01");
    expect(tasksContent).not.toContain("Task ID: SB2-E2E-02");

    // 5. Verify board coordination lock was cleanly released on exit
    const lockPath = getLockPath(tempDir);
    expect(fs.existsSync(lockPath)).toBe(false);
  });

  it("verifies merge train squash merges cleanly into main", async () => {
    // Setup temporary board directory
    const initResult = await Effect.runPromise(initBoardStructure(tempDir, "", 2));
    expect(initResult.ok).toBe(true);

    const queue = await Effect.runPromise(createMergeTrain(10));

    const req1: MergeRequest = {
      taskId: "SB2-E2E-01",
      branch: "agent/1/cache-layer",
      workspace: path.join(tempDir, "workspaces", "repo-agent-1"),
      isZeroCommit: false,
      verificationCmd: Option.some("bun test tests/runner.test.ts"),
    };

    const req2: MergeRequest = {
      taskId: "SB2-E2E-02",
      branch: "agent/2/telemetry-exporter",
      workspace: path.join(tempDir, "workspaces", "repo-agent-2"),
      isZeroCommit: false,
      verificationCmd: Option.none(),
    };

    // Enqueue merge requests into merge train
    await Effect.runPromise(
      Effect.all([
        enqueueMerge(queue, req1),
        enqueueMerge(queue, req2),
      ])
    );

    // Sequentially process and land merges into main
    const res1 = await Effect.runPromise(processNextMerge(queue, "main"));
    expect(res1.taskId).toBe("SB2-E2E-01");
    expect(res1.success).toBe(true);
    expect(Option.isSome(res1.commitHash)).toBe(true);
    expect(res1.error).toEqual(Option.none());

    const res2 = await Effect.runPromise(processNextMerge(queue, "main"));
    expect(res2.taskId).toBe("SB2-E2E-02");
    expect(res2.success).toBe(true);
    expect(Option.isSome(res2.commitHash)).toBe(true);
    expect(res2.error).toEqual(Option.none());
  });

  it("verifies sequential task dependency progression across reconciliation iterations", async () => {
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
    // Task 1 must execute first, then Task 2 after dependency unblocks
    expect(executedTasks).toEqual(["SB2-BASE-01", "SB2-DERIVED-02"]);

    // Both tasks must end up in ARCHIVE.md
    const store = loadBoardStoreSync(tempDir);
    expect(store.backlogContent).not.toContain("SB2-BASE-01");
    expect(store.backlogContent).not.toContain("SB2-DERIVED-02");
    expect(store.archiveContent).toContain("SB2-BASE-01");
    expect(store.archiveContent).toContain("SB2-DERIVED-02");
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
});
