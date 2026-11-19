import { afterEach, beforeEach, describe, expect, it } from "bun:test";
import { Effect, Fiber, Option, Queue, Ref } from "effect";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import {
  initialReconcilerState,
  initialReconcilerStateFun,
  reconcileTick,
  reconcileTickFun,
  runReconcilerLoop,
  runReconcilerLoopFun,
  type ReconcilerConfig,
  type ReconcilerState,
} from "../src/orchestrator/dispatcher.js";
import { loadBoardStoreSync } from "../src/domain/boardstore.js";
import { getLockPath } from "../src/services/coordination.js";
import { createMergeTrain } from "../src/orchestrator/mergetrain.js";

describe("Autonomous Dispatcher & Reconciler Loop", () => {
  let tempDir: string;

  beforeEach(() => {
    tempDir = fs.mkdtempSync(path.join(os.tmpdir(), "slopboss-dispatcher-test-"));
  });

  afterEach(() => {
    if (fs.existsSync(tempDir)) {
      fs.rmSync(tempDir, { recursive: true, force: true });
    }
  });

  const setupBoard = (
    backlogTasks: string,
    tasksContent: string = "# TASKS\n\n## Dev Agent 1 In Progress\n\n*Idle - Ready for next backlog assignment.*\n\n## Dev Agent 2 In Progress\n\n*Idle - Ready for next backlog assignment.*\n",
    archiveContent: string = "# ARCHIVE\n\nCompleted tasks for slopboss2.\n"
  ) => {
    fs.writeFileSync(path.join(tempDir, "TASKS.md"), tasksContent, "utf-8");
    fs.writeFileSync(path.join(tempDir, "BACKLOG.md"), backlogTasks, "utf-8");
    fs.writeFileSync(path.join(tempDir, "ARCHIVE.md"), archiveContent, "utf-8");
  };

  it("initializes reconciler state with zero ticks and empty sessions", () => {
    const state = initialReconcilerState(2);
    expect(state.tickCount).toBe(0);
    expect(state.activeSessions).toEqual([]);
    expect(state.tokenCounter.totalTokens).toBe(0);
    expect(state.tokenCounter.inputTokens).toBe(0);
    expect(state.tokenCounter.outputTokens).toBe(0);

    const funState = initialReconcilerStateFun(2);
    expect(funState.tickCount).toBe(0);
  });

  it("detects idle lanes and automatically assigns unblocked tasks from Backlog", async () => {
    const backlog = `# BACKLOG

### Workspace Setup & Init

Task ID: SB2-TEST-01
Category: Core
Owner: Dev Agent 1
Branch: agent/1/test-01
Status: Backlog
Dependencies: none
Blocking tasks: none

Objective:
Test assignment.

### Git Helper Refactor

Task ID: SB2-TEST-02
Category: Core
Owner: Dev Agent 2
Branch: agent/2/test-02
Status: Backlog
Dependencies: none
Blocking tasks: none

Objective:
Test second assignment.
`;
    setupBoard(backlog);

    const config: ReconcilerConfig = {
      boardDir: tempDir,
      pollIntervalMs: 0,
      maxIterations: 1,
      devAgentCount: 2,
      mockRunner: true,
    };

    const initialState = initialReconcilerState(2);
    const nextState = await Effect.runPromise(reconcileTick(config, initialState));

    expect(nextState.tickCount).toBe(1);
    expect(nextState.tokenCounter.totalTokens).toBeGreaterThan(0);

    // A mock runner has no Git remote to land; completed work remains unarchived for recovery.
    const store = loadBoardStoreSync(tempDir);
    expect(store.backlogContent).not.toContain("SB2-TEST-01");
    expect(store.backlogContent).not.toContain("SB2-TEST-02");

    expect(store.archiveContent).not.toContain("SB2-TEST-01");
    expect(store.archiveContent).not.toContain("SB2-TEST-02");
  });

  it("holds blocked tasks in Backlog until dependencies are archived", async () => {
    const backlog = `# BACKLOG

### Foundation Service

Task ID: SB2-DEP-01
Category: Core
Owner: Dev Agent 1
Branch: agent/1/dep-01
Status: Backlog
Dependencies: none
Blocking tasks: SB2-DEP-02

Objective:
Implement foundation.

### Dependent UI Feature

Task ID: SB2-DEP-02
Category: UI
Owner: Dev Agent 2
Branch: agent/2/dep-02
Status: Backlog
Dependencies: SB2-DEP-01
Blocking tasks: none

Objective:
Implement dependent UI.
`;
    setupBoard(backlog);

    const executedTasks: string[] = [];
    const config: ReconcilerConfig = {
      boardDir: tempDir,
      pollIntervalMs: 0,
      maxIterations: 2,
      devAgentCount: 2,
      runnerFn: (agentId, taskId) =>
        Effect.sync(() => {
          executedTasks.push(taskId);
          return {
            exitCode: 0,
            totalTokens: 1000,
            completed: true,
          };
        }),
    };

    // --- Tick 1 ---
    const state1 = await Effect.runPromise(reconcileTick(config, initialReconcilerState(2)));
    expect(state1.tickCount).toBe(1);

    // Only SB2-DEP-01 should have been executed in Tick 1!
    expect(executedTasks).toEqual(["SB2-DEP-01"]);

    // SB2-DEP-02 must still be in BACKLOG.md during tick 1
    const storeAfterTick1 = loadBoardStoreSync(tempDir);
    expect(storeAfterTick1.backlogContent).toContain("SB2-DEP-02");
    expect(storeAfterTick1.archiveContent).not.toContain("SB2-DEP-01");

    // --- Tick 2 ---
    const state2 = await Effect.runPromise(reconcileTick(config, state1));
    expect(state2.tickCount).toBe(2);

    // Failed landing leaves the dependency unarchived, so dependent work stays blocked.
    expect(executedTasks).toEqual(["SB2-DEP-01"]);

    const storeAfterTick2 = loadBoardStoreSync(tempDir);
    expect(storeAfterTick2.backlogContent).toContain("SB2-DEP-02");
    expect(storeAfterTick2.archiveContent).not.toContain("SB2-DEP-02");
  });

  it("advances tickCount and updates token usage across iterations", async () => {
    const backlog = `# BACKLOG

### Token Counter Test Task

Task ID: SB2-TOK-01
Category: Core
Owner: Dev Agent 1
Branch: agent/1/tok-01
Status: Backlog
Dependencies: none
Blocking tasks: none

Objective:
Test token accounting.
`;
    setupBoard(backlog);

    const config: ReconcilerConfig = {
      boardDir: tempDir,
      pollIntervalMs: 0,
      maxIterations: 3,
      devAgentCount: 1,
      runnerFn: () =>
        Effect.sync(() => ({
          exitCode: 0,
          totalTokens: 2500,
          completed: true,
        })),
    };

    const s0 = initialReconcilerState(1);
    expect(s0.tickCount).toBe(0);
    expect(s0.tokenCounter.totalTokens).toBe(0);

    const s1 = await Effect.runPromise(reconcileTick(config, s0));
    expect(s1.tickCount).toBe(1);
    expect(s1.tokenCounter.totalTokens).toBe(2500);
    expect(s1.tokenCounter.inputTokens).toBe(1750);
    expect(s1.tokenCounter.outputTokens).toBe(750);

    // Subsequent tick with no new tasks still advances tickCount and preserves tokens
    const s2 = await Effect.runPromise(reconcileTick(config, s1));
    expect(s2.tickCount).toBe(2);
    expect(s2.tokenCounter.totalTokens).toBe(2500);
  });

  it("runs multi-tick cycle with mock runner cleanly using runReconcilerLoop", async () => {
    const backlog = `# BACKLOG

### Task Alpha

Task ID: SB2-ALPHA
Category: Core
Owner: Dev Agent 1
Branch: agent/1/alpha
Status: Backlog
Dependencies: none
Blocking tasks: none

Objective:
Alpha task.

### Task Beta

Task ID: SB2-BETA
Category: Core
Owner: Dev Agent 2
Branch: agent/2/beta
Status: Backlog
Dependencies: none
Blocking tasks: none

Objective:
Beta task.
`;
    setupBoard(backlog);

    const mergeQueue = await Effect.runPromise(createMergeTrain(10));

    const config: ReconcilerConfig = {
      boardDir: tempDir,
      pollIntervalMs: 10,
      maxIterations: 2,
      devAgentCount: 2,
      mockRunner: true,
      mergeQueue,
    };

    const finalState = await Effect.runPromise(runReconcilerLoop(config));
    expect(finalState.tickCount).toBe(2);
    expect(finalState.tokenCounter.totalTokens).toBeGreaterThan(0);

    const store = loadBoardStoreSync(tempDir);
    expect(store.archiveContent).not.toContain("SB2-ALPHA");
    expect(store.archiveContent).not.toContain("SB2-BETA");
  });

  it("acquires coordination lock and releases it upon fiber interruption", async () => {
    setupBoard("# BACKLOG\n");
    const lockPath = getLockPath(tempDir);

    const config: ReconcilerConfig = {
      boardDir: tempDir,
      pollIntervalMs: 100,
      maxIterations: 100, // Long-running
      devAgentCount: 1,
      mockRunner: true,
    };

    const fiber = Effect.runFork(runReconcilerLoop(config));

    // Wait for fiber to start and acquire the coordination lock
    await new Promise((resolve) => setTimeout(resolve, 50));
    expect(fs.existsSync(lockPath)).toBe(true);

    const rawLock = fs.readFileSync(lockPath, "utf-8");
    const lockData = JSON.parse(rawLock);
    expect(lockData.pid).toBe(process.pid);

    // Interrupt the fiber
    await Effect.runPromise(Fiber.interrupt(fiber));

    // Lock file must be cleanly unlinked by the Effect Scope finalizer
    expect(fs.existsSync(lockPath)).toBe(false);
  });

  it("supports FunScript exported reconciler functions", async () => {
    setupBoard("# BACKLOG\n");
    const config: ReconcilerConfig = {
      boardDir: tempDir,
      pollIntervalMs: 0,
      maxIterations: 1,
      devAgentCount: 1,
      mockRunner: true,
    };

    const state = initialReconcilerStateFun(1);
    const tickResult = await Effect.runPromise(reconcileTickFun(config, state));
    expect(tickResult.tickCount).toBe(1);

    const loopResult = await Effect.runPromise(runReconcilerLoopFun(config));
    expect(loopResult.tickCount).toBe(1);
  });
});
