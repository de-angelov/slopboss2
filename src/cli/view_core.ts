import * as fs from "node:fs";
  import * as path from "node:path";
  import { Effect, Option } from "effect";
  import { loadBoardStoreSync } from "../domain/boardstore.js";
  import {
    renderDashboard,
    renderFullDashboard,
    type AgentLane,
    type DashboardState,
    type TokenUsage,
  } from "../ui/dashboard.js";

  export interface LiveViewOptions {
    stdin?: NodeJS.ReadableStream | any;
    stdout?: NodeJS.WritableStream | { write: (str: string) => boolean | void } | any;
    maxTicks?: number;
    signal?: AbortSignal;
    onTick?: (state: DashboardState, output: string) => void;
  }

  export function readDashboardState(boardDir: string): DashboardState {
    let lanes: AgentLane[] = [];
    let tokens: TokenUsage = { inputTokens: 0, outputTokens: 0, totalTokens: 0 };
    let recentLogs: string[] = [];

    // 1. Read Board Store & Lanes
    try {
      const store = loadBoardStoreSync(boardDir);
      const sections = store.tasksDoc.sections || [];

      if (sections.length > 0) {
        for (const sec of sections) {
          const laneId = sec.name.replace(/\s+In Progress$/i, "").trim() || sec.name;
          const activeTask =
            sec.tasks && sec.tasks.length > 0
              ? sec.tasks.find((t) => t.status === "In Progress") || sec.tasks[0]
              : null;

          if (activeTask && activeTask.id) {
            lanes.push({
              id: laneId,
              status: activeTask.status || "In Progress",
              task: Option.some(activeTask.id),
              branch: activeTask.branch ? Option.some(activeTask.branch) : Option.none(),
            });
            recentLogs.push(`[TASK] ${laneId} working on ${activeTask.id} (${activeTask.title || ""})`);
          } else {
            lanes.push({
              id: laneId,
              status: "Idle",
              task: Option.none(),
              branch: Option.none(),
            });
          }
        }
      }

      // Add recent completed events from archive
      if (store.archiveDoc && store.archiveDoc.sections) {
        for (const sec of store.archiveDoc.sections) {
          if (sec.tasks && sec.tasks.length > 0) {
            for (const t of sec.tasks.slice(-3)) {
              if (t.id) {
                recentLogs.push(`[MERGE TRAIN] Task ${t.id} landed cleanly.`);
              }
            }
          }
        }
      }
    } catch (_e) {
      // Graceful fallback on parse error
    }

    if (lanes.length === 0) {
      lanes = [
        { id: "Dev Agent 1", status: "Idle", task: Option.none(), branch: Option.none() },
        { id: "Dev Agent 2", status: "Idle", task: Option.none(), branch: Option.none() },
      ];
    }

    // 2. Read Tokens if available
    try {
      const tokenPath = path.join(boardDir, ".tokens.json");
      const altTokenPath = path.join(boardDir, "tokens.json");
      const targetTokenPath = fs.existsSync(tokenPath)
        ? tokenPath
        : fs.existsSync(altTokenPath)
        ? altTokenPath
        : null;
      if (targetTokenPath) {
        const raw = fs.readFileSync(targetTokenPath, "utf-8");
        const parsed = JSON.parse(raw);
        tokens = {
          inputTokens: typeof parsed.inputTokens === "number" ? parsed.inputTokens : 0,
          outputTokens: typeof parsed.outputTokens === "number" ? parsed.outputTokens : 0,
          totalTokens: typeof parsed.totalTokens === "number" ? parsed.totalTokens : 0,
        };
      }
    } catch (_e) {
      // Ignore token read error
    }

    // 3. Read custom event log if available
    try {
      const logPath = path.join(boardDir, ".slopboss.log");
      if (fs.existsSync(logPath)) {
        const raw = fs.readFileSync(logPath, "utf-8");
        const lines = raw.split(/\r?\n/).filter((l) => l.trim().length > 0);
        if (lines.length > 0) {
          recentLogs = lines.slice(-5);
        }
      }
    } catch (_e) {
      // Ignore log read error
    }

    if (recentLogs.length === 0) {
      recentLogs.push("[IDLE] Waiting for next dispatch cycle...");
    }

    const uniqueLogs = [...new Set(recentLogs)].slice(-6);

    return {
      boardDir,
      lanes,
      tokens,
      recentLogs: uniqueLogs,
    };
  }

  export function runLiveView(
    boardDir: string,
    pollMs: number = 1000,
    options?: LiveViewOptions
  ): Effect.Effect<boolean, Error> {
    return Effect.tryPromise({
      try: () =>
        new Promise<boolean>((resolve, reject) => {
          const stdin = options?.stdin ?? process.stdin;
          const stdout = options?.stdout ?? process.stdout;
          const maxTicks =
            options?.maxTicks && options.maxTicks > 0 ? options.maxTicks : Infinity;
          const intervalMs = Math.max(pollMs, 10);

          let tickCount = 0;
          let isCleanedUp = false;
          let timer: any = null;

          const cleanup = () => {
            if (isCleanedUp) return;
            isCleanedUp = true;

            if (timer !== null) {
              clearInterval(timer);
              timer = null;
            }

            try {
              if (stdin && typeof stdin.setRawMode === "function") {
                stdin.setRawMode(false);
              }
            } catch (_e) {}

            try {
              if (stdin && typeof stdin.pause === "function") {
                stdin.pause();
              }
            } catch (_e) {}

            if (stdin && typeof stdin.removeListener === "function") {
              stdin.removeListener("data", onData);
            }

            process.removeListener("SIGINT", onSigint);

            try {
              if (stdout && typeof stdout.write === "function") {
                stdout.write("\u001b[?25h\nLive view closed.\n");
              }
            } catch (_e) {}
          };

          const finish = (result: boolean) => {
            cleanup();
            resolve(result);
          };

          const onSigint = () => {
            finish(true);
          };

          const onData = (chunk: any) => {
            const str =
              typeof chunk === "string" ? chunk : chunk?.toString?.("utf8") ?? "";
            if (str === "q" || str === "Q" || str === "\u0003") {
              finish(true);
            }
          };

          // Set up SIGINT handling
          process.on("SIGINT", onSigint);

          // Set up stdin keypress handling
          try {
            if (stdin && typeof stdin.setRawMode === "function") {
              stdin.setRawMode(true);
            }
          } catch (_e) {}

          try {
            if (stdin && typeof stdin.resume === "function") {
              stdin.resume();
            }
          } catch (_e) {}

          try {
            if (stdin && typeof stdin.setEncoding === "function") {
              stdin.setEncoding("utf8");
            }
          } catch (_e) {}

          if (stdin && typeof stdin.on === "function") {
            stdin.on("data", onData);
          }

          // Set up abort signal handling if provided
          if (options?.signal) {
            if (options.signal.aborted) {
              finish(true);
              return;
            }
            options.signal.addEventListener(
              "abort",
              () => {
                finish(true);
              },
              { once: true }
            );
          }

          const tick = () => {
            if (isCleanedUp) return;
            try {
              const state = readDashboardState(boardDir);
              const output = renderFullDashboard(state);
              if (stdout && typeof stdout.write === "function") {
                stdout.write(output);
              }
              if (options?.onTick) {
                options.onTick(state, output);
              }

              tickCount++;
              if (tickCount >= maxTicks) {
                finish(true);
              }
            } catch (err: any) {
              cleanup();
              reject(err instanceof Error ? err : new Error(String(err)));
            }
          };

          // Run initial tick immediately
          tick();

          // Schedule periodic refresh if not finished
          if (!isCleanedUp) {
            timer = setInterval(tick, intervalMs);
          }
        }),
      catch: (err) => (err instanceof Error ? err : new Error(String(err))),
    });
  }

  export async function runLiveViewAsync(
    boardDir: string,
    pollMs: number = 1000,
    options?: LiveViewOptions
  ): Promise<boolean> {
    return Effect.runPromise(runLiveView(boardDir, pollMs, options));
  }

export const runLiveViewFun = (boardDir: string, pollMs: number = 1000) => runLiveView(boardDir, pollMs);
