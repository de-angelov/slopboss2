import { Console, Effect, Option, Queue, Ref, Schema, Scope, String } from "effect"

ts {
  import * as fs from "node:fs";
  import * as path from "node:path";
  import { Effect, Option, Queue, Ref } from "effect";
  import {
    archiveTask,
    loadBoardStoreSync,
    moveTask,
    parseBacklogTasks,
    persistBoardStoreSync,
    type BoardStore,
    type TaskBlock,
  } from "../domain/boardstore.js";
  import { findReadyTasks, type TaskNode } from "../domain/dag.js";
  import { acquireBoardLock } from "../services/coordination.js";
  import { buildDevAgentPrompt } from "../services/prompt.js";
  import { runMockAgentSession, type SessionResult } from "../services/runner.js";
  import {
    createMergeTrain,
    enqueueMergeRequest,
    landMergeRequest,
    type MergeRequest,
  } from "./mergetrain.js";

  export interface RunningSession {
    agentId: string;
    taskId: string;
    branch: string;
    workspace: string;
    status: string;
  }

  export interface TokenCounter {
    inputTokens: number;
    outputTokens: number;
    totalTokens: number;
  }

  export interface ReconcilerConfig {
    boardDir: string;
    pollIntervalMs: number;
    maxIterations: number;
    devAgentCount: number;
    baseBranch?: string;
    mockRunner?: boolean;
    runnerFn?: (
      agentId: string,
      taskId: string,
      prompt?: string
    ) => Effect.Effect<SessionResult, Error>;
    mergeQueue?: Queue.Queue<MergeRequest>;
  }

  export interface ReconcilerState {
    tickCount: number;
    activeSessions: RunningSession[];
    tokenCounter: TokenCounter;
  }

  export function initialReconcilerState(devAgentCount: number = 2): ReconcilerState {
    return {
      tickCount: 0,
      activeSessions: [],
      tokenCounter: {
        inputTokens: 0,
        outputTokens: 0,
        totalTokens: 0,
      },
    };
  }

  function getCompletedTaskIds(store: BoardStore): string[] {
    const ids = new Set<string>();

    if (store.archiveDoc && Array.isArray(store.archiveDoc.sections)) {
      for (const sec of store.archiveDoc.sections) {
        if (Array.isArray(sec.tasks)) {
          for (const t of sec.tasks) {
            if (t.id) ids.add(t.id);
          }
        }
      }
    }

    if (store.archiveContent) {
      const bulletRegex = /- \[x\]\s+([A-Za-z0-9_-]+):/gi;
      let match: RegExpExecArray | null;
      while ((match = bulletRegex.exec(store.archiveContent)) !== null) {
        if (match[1]) ids.add(match[1]);
      }
      const taskIdRegex = /Task ID:\s*([A-Za-z0-9_-]+)/gi;
      while ((match = taskIdRegex.exec(store.archiveContent)) !== null) {
        if (match[1]) ids.add(match[1]);
      }
    }

    return [...ids];
  }

  export function reconcileTick(
    config: ReconcilerConfig,
    state: ReconcilerState
  ): Effect.Effect<ReconcilerState, Error> {
    return Effect.gen(function* () {
      const nextTick = state.tickCount + 1;
      const boardDir = config.boardDir;
      const baseBranch = config.baseBranch || "main";
      const devAgentCount = config.devAgentCount > 0 ? config.devAgentCount : 2;

      // 1. Load board store
      const store = loadBoardStoreSync(boardDir);

      // 2. Discover completed task IDs
      const completedIds = getCompletedTaskIds(store);

      // 3. Collect backlog tasks
      const backlogTasks = parseBacklogTasks(store.backlogContent || "");

      // Also include any tasks in a section named "backlog" in TASKS.md if present
      if (store.tasksDoc && Array.isArray(store.tasksDoc.sections)) {
        const backlogSec = store.tasksDoc.sections.find((s) =>
          s.title.toLowerCase().includes("backlog")
        );
        if (backlogSec && Array.isArray(backlogSec.tasks)) {
          for (const t of backlogSec.tasks) {
            if (!backlogTasks.some((b) => b.id === t.id)) {
              backlogTasks.push(t);
            }
          }
        }
      }

      // Filter out tasks already completed or active
      const activeTaskIds = new Set(state.activeSessions.map((s) => s.taskId));
      const pendingBacklog = backlogTasks.filter(
        (t) => !completedIds.includes(t.id) && !activeTaskIds.has(t.id)
      );

      // 4. DAG dependency resolution: compute unblocked tasks
      const dagNodes: TaskNode[] = pendingBacklog.map((t) => ({
        id: t.id,
        dependsOn: Array.isArray(t.dependencies) ? t.dependencies : [],
      }));

      const readyIds = findReadyTasks(dagNodes, completedIds);
      const unblockedTasks = pendingBacklog.filter((t) => readyIds.includes(t.id));

      // 5. Detect idle lanes
      const idleAgents: Array<{ agentId: string; laneTitle: string; agentIndex: number }> = [];

      for (let i = 1; i <= devAgentCount; i++) {
        const agentId = `Dev Agent ${i}`;
        const laneTitle = `Dev Agent ${i} In Progress`;

        const isSessionRunning = state.activeSessions.some(
          (s) => s.agentId === agentId && s.status === "Running"
        );

        let hasActiveTaskInLane = false;
        if (store.tasksDoc && Array.isArray(store.tasksDoc.sections)) {
          const laneSec = store.tasksDoc.sections.find((s) =>
            s.title.toLowerCase().includes(agentId.toLowerCase())
          );
          if (laneSec && Array.isArray(laneSec.tasks) && laneSec.tasks.length > 0) {
            hasActiveTaskInLane = laneSec.tasks.some(
              (t) => t.status.toLowerCase() === "in progress"
            );
          }
        }

        if (!isSessionRunning && !hasActiveTaskInLane) {
          idleAgents.push({ agentId, laneTitle, agentIndex: i });
        }
      }

      // 6. Assign ready tasks to idle lanes and execute
      let accumulatedTokens = { ...state.tokenCounter };
      const currentActiveSessions = [...state.activeSessions];

      for (const idle of idleAgents) {
        if (unblockedTasks.length === 0) break;

        const taskToAssign = unblockedTasks.shift()!;
        taskToAssign.owner = idle.agentId;
        taskToAssign.status = "In Progress";
        if (!taskToAssign.branch || taskToAssign.branch.trim() === "") {
          taskToAssign.branch = `agent/${idle.agentIndex}/${taskToAssign.id.toLowerCase()}`;
        }

        // Move task from BACKLOG.md to agent's lane in TASKS.md
        moveTask(store, taskToAssign.id, idle.laneTitle);
        persistBoardStoreSync(store);

        const workspacePath = path.join(boardDir, `workspaces/repo-agent-${idle.agentIndex}`);

        const session: RunningSession = {
          agentId: idle.agentId,
          taskId: taskToAssign.id,
          branch: taskToAssign.branch,
          workspace: workspacePath,
          status: "Running",
        };

        // Generate prompt
        const prompt = buildDevAgentPrompt(boardDir, taskToAssign, idle.agentId);

        // Execute agent session
        let result: SessionResult;
        if (config.runnerFn) {
          result = yield* config.runnerFn(idle.agentId, taskToAssign.id, prompt);
        } else {
          result = yield* runMockAgentSession(idle.agentId, taskToAssign.id);
        }

        // Update token counter
        const used = result.totalTokens || 1420;
        accumulatedTokens = {
          inputTokens: accumulatedTokens.inputTokens + Math.floor(used * 0.7),
          outputTokens: accumulatedTokens.outputTokens + Math.ceil(used * 0.3),
          totalTokens: accumulatedTokens.totalTokens + used,
        };

        // If completed, enqueue merge request and archive task
        if (result.completed || result.exitCode === 0) {
          session.status = "Completed";

          const mergeReq: MergeRequest = {
            taskId: taskToAssign.id,
            branch: taskToAssign.branch,
            workspace: workspacePath,
            isZeroCommit: false,
            verificationCmd: Option.none(),
          };

          if (config.mergeQueue) {
            yield* enqueueMergeRequest(config.mergeQueue, mergeReq);
          } else {
            yield* landMergeRequest(mergeReq, baseBranch);
          }

          // Move task from TASKS.md to ARCHIVE.md
          archiveTask(store, taskToAssign.id);
          persistBoardStoreSync(store);
        } else {
          currentActiveSessions.push(session);
        }
      }

      // Filter out completed sessions from activeSessions
      const remainingSessions = currentActiveSessions.filter((s) => s.status === "Running");

      return {
        tickCount: nextTick,
        activeSessions: remainingSessions,
        tokenCounter: accumulatedTokens,
      };
    });
  }

  export function runReconcilerLoop(
    config: ReconcilerConfig
  ): Effect.Effect<ReconcilerState, Error, Scope.Scope> {
    return Effect.scoped(
      Effect.gen(function* () {
        // 1. Acquire coordination lock (released on scope exit or interruption)
        yield* acquireBoardLock(config.boardDir);

        // 2. Initialize merge train queue
        const mergeQueue = yield* createMergeTrain(100);
        const resolvedConfig: ReconcilerConfig = {
          ...config,
          mergeQueue: config.mergeQueue || mergeQueue,
        };

        // 3. Initialize state
        let currentState = initialReconcilerState(config.devAgentCount || 2);
        const stateRef = yield* Ref.make(currentState);

        const maxIterations = config.maxIterations > 0 ? config.maxIterations : Infinity;

        while (currentState.tickCount < maxIterations) {
          currentState = yield* reconcileTick(resolvedConfig, currentState);
          yield* Ref.set(stateRef, currentState);

          if (currentState.tickCount < maxIterations && config.pollIntervalMs > 0) {
            yield* Effect.sleep(`${config.pollIntervalMs} millis`);
          }
        }

        return currentState;
      })
    );
  }
}

export schema RunningSession = {
  agentId: String
  taskId: String
  branch: String
  workspace: String
  status: String
}

export schema TokenCounter = {
  inputTokens: Number
  outputTokens: Number
  totalTokens: Number
}

export schema ReconcilerConfig = {
  boardDir: String
  pollIntervalMs: Number
  maxIterations: Number
  devAgentCount: Number
}

export schema ReconcilerState = {
  tickCount: Number
  activeSessions: Array<RunningSession>
  tokenCounter: TokenCounter
}

export initialReconcilerStateFun = (devAgentCount: Number) =>
  initialReconcilerState(devAgentCount)

export reconcileTickFun = (config: ReconcilerConfig, state: ReconcilerState) => effect {
  res <- reconcileTick(config, state)
  => res
}

export runReconcilerLoopFun = (config: ReconcilerConfig) => effect {
  res <- runReconcilerLoop(config)
  => res
}
