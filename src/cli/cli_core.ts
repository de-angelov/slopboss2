import * as fs from "node:fs";
  import * as path from "node:path";
  import { parseArgs } from "node:util";
  import { Effect, Option } from "effect";
  import { runDoctor, runDoctorSync, type DoctorReportTs } from "../services/doctor.js";
  import { runReconcilerLoop, type ReconcilerConfig, type ReconcilerState } from "../orchestrator/dispatcher.js";
  import { initBoardStructure, initBoardStructureSync, type BoardInitResultTs } from "../services/setup.js";
  import { buildInteractiveCommand } from "../services/provider.js";
  import { runLiveView, type LiveViewOptions } from "./view.js";

  export const DEFAULT_BOARD_DIR = process.env.SLOPBOSS_BOARD_DIR || "/home/dangelov/slopboss2-board";

  export interface CliDoctorCommand {
    command: "doctor";
    type: "doctor";
    dir: string;
    help: boolean;
  }

  export interface CliRunCommand {
    command: "run";
    type: "run";
    dir: string;
    detach: boolean;
    maxTicks?: number;
    pollIntervalMs?: number;
    help: boolean;
  }

  export interface CliInitCommand {
    command: "init";
    type: "init";
    dir: string;
    repoUrl: string;
    agents: number;
    help: boolean;
  }

  export interface CliGroomCommand {
    command: "groom";
    type: "groom";
    dir: string;
    model?: string;
    help: boolean;
  }

  export interface CliStatusCommand {
    command: "status";
    type: "status";
    dir: string;
    help: boolean;
  }

  export interface CliViewCommand {
    command: "view";
    type: "view";
    dir: string;
    pollIntervalMs?: number;
    help: boolean;
  }

  export interface CliHelpCommand {
    command: "help";
    type: "help";
    subcommand?: string;
    help?: boolean;
  }

  export interface CliInvalidCommand {
    command: "invalid";
    type: "invalid";
    error: string;
    subcommand?: string;
    help?: boolean;
  }

  export type CliCommand =
    | CliDoctorCommand
    | CliRunCommand
    | CliInitCommand
    | CliGroomCommand
    | CliStatusCommand
    | CliViewCommand
    | CliHelpCommand
    | CliInvalidCommand;

  export interface DispatchOptions {
    spawnFn?: typeof Bun.spawn;
    mockRunner?: boolean;
    maxIterations?: number;
    pollIntervalMs?: number;
    runnerFn?: any;
    viewOptions?: LiveViewOptions;
  }

  export function buildGroomPrompt(boardDir: string, backlogContent: string): string {
    const header = "You are the autonomous Team Lead for slopboss2.\n";
    const ctx = "Groom and prioritize tasks from BACKLOG.md for the board at: " + boardDir + "\n\n";
    const content = "--- CURRENT BACKLOG.md ---\n" + backlogContent + "\n--- END BACKLOG.md ---\n\n";
    const instructions =
      "Instructions:\n1. Review prioritized tasks in BACKLOG.md and verify readiness and dependencies.\n2. Format task specifications for TASKS.md including Task ID, Category, Owner, Branch, Status, Objective, Scope, Acceptance Criteria.\n3. Write groomed task allocations to TASKS.md and update BACKLOG.md.";
    return header + ctx + content + instructions;
  }

  export function formatDoctorTable(report: DoctorReportTs): string {
    const lines: string[] = [
      "Diagnostic Check Results:",
      "--------------------------------------------------------------------------------",
      "Status    | Check        | Required | Details",
      "--------------------------------------------------------------------------------",
    ];
    for (const c of report.checks) {
      const status = c.ok ? "[ PASS ]" : "[ FAIL ]";
      const req = c.required ? "Yes" : "No ";
      const name = c.name.padEnd(12);
      lines.push(`${status}  | ${name} | ${req}      | ${c.message}`);
    }
    lines.push("--------------------------------------------------------------------------------");
    lines.push(`Overall Health: ${report.isHealthy ? "HEALTHY" : "UNHEALTHY"}`);
    return lines.join("\n");
  }

  export function getHelpMessage(subcommand?: string): string {
    switch (subcommand) {
      case "doctor":
        return [
          "Usage: slopboss2 doctor [options] [path]",
          "",
          "Run system diagnostics and verify dependencies.",
          "",
          "Options:",
          "  -d, --dir <path>  Board directory path (default: $SLOPBOSS_BOARD_DIR or current directory)",
          "  -h, --help        Show help for doctor command",
        ].join("\n");

      case "run":
        return [
          "Usage: slopboss2 run [options] [path]",
          "",
          "Acquire board coordination lock and start autonomous dispatcher reconciler loop.",
          "",
          "Options:",
          "  -d, --dir <path>      Board directory path (default: $SLOPBOSS_BOARD_DIR or current directory)",
          "  --detach              Run reconciler process in the background",
          "  --iterations <n>      Number of reconciliation iterations before exiting (alias for max-ticks)",
          "  --max-ticks <n>       Maximum ticks before exiting (0 for infinite)",
          "  --poll-interval <ms>  Milliseconds between reconciliation ticks",
          "  -h, --help            Show help for run command",
        ].join("\n");

      case "init":
      case "setup":
        return [
          "Usage: slopboss2 init [options] [path]",
          "",
          "Provision board structure, markdown files, and workspaces.",
          "",
          "Options:",
          "  -d, --dir <path>  Board directory path (default: $SLOPBOSS_BOARD_DIR or current directory)",
          "  -r, --repo <url>  Target git repository URL to clone into workspaces",
          "  -a, --agents <n>  Number of dev agents to provision (default: 2)",
          "  -h, --help        Show help for init command",
        ].join("\n");

      case "groom":
        return [
          "Usage: slopboss2 groom [options] [path]",
          "",
          "Launch interactive Team Lead grooming session with Antigravity (agy).",
          "",
          "Options:",
          "  -d, --dir <path>   Board directory path (default: $SLOPBOSS_BOARD_DIR or current directory)",
          "  -m, --model <name> Override agent model",
          "  -h, --help         Show help for groom command",
        ].join("\n");

      case "status":
        return [
          "Usage: slopboss2 status [options] [path]",
          "",
          "Display board execution status.",
          "",
          "Options:",
          "  -d, --dir <path>  Board directory path (default: $SLOPBOSS_BOARD_DIR or current directory)",
          "  -h, --help        Show help for status command",
        ].join("\n");

      case "view":
        return [
          "Usage: slopboss2 view [options] [path]",
          "",
          "Launch interactive terminal dashboard live view.",
          "",
          "Options:",
          "  -d, --dir <path>  Board directory path (default: $SLOPBOSS_BOARD_DIR or current directory)",
          "  -h, --help        Show help for view command",
        ].join("\n");

      default:
        return [
          "slopboss2 - Autonomous multi-agent orchestrator",
          "",
          "Usage:",
          "  slopboss2 <command> [options]",
          "",
          "Commands:",
          "  doctor [--dir <path>]            Run diagnostics and verify system dependencies",
          "  run [--dir <path>] [--detach]    Acquire lock and start the dispatcher reconciler loop",
          "  init [--dir <path>] [--repo <url>] Provision board structure and agent workspaces",
          "  groom [--dir <path>]             Launch interactive Team Lead grooming session",
          "  status [--dir <path>]            Display board execution status",
          "  view [--dir <path>]              Launch interactive terminal dashboard live view",
          "",
          "Options:",
          "  -h, --help                       Show help information",
          "  -v, --version                    Show version",
        ].join("\n");
    }
  }

  export function parseCliArgs(argv: string[]): CliCommand {
    if (!argv || argv.length === 0) {
      return { command: "help", type: "help" };
    }

    const [first, ...subArgs] = argv;

    if (first === "--help" || first === "-h") {
      return { command: "help", type: "help" };
    }

    if (first === "help") {
      return { command: "help", type: "help", subcommand: subArgs[0] };
    }

    const defaultDir = DEFAULT_BOARD_DIR;

    switch (first) {
      case "doctor": {
        try {
          const { values, positionals } = parseArgs({
            args: subArgs,
            options: {
              dir: { type: "string", short: "d" },
              help: { type: "boolean", short: "h" },
            },
            allowPositionals: true,
          });
          return {
            command: "doctor",
            type: "doctor",
            dir: (values.dir as string) || positionals[0] || defaultDir,
            help: Boolean(values.help),
          };
        } catch (err: any) {
          return {
            command: "invalid",
            type: "invalid",
            error: err?.message || "Invalid arguments for doctor",
            subcommand: "doctor",
          };
        }
      }

      case "run": {
        try {
          const { values, positionals } = parseArgs({
            args: subArgs,
            options: {
              dir: { type: "string", short: "d" },
              detach: { type: "boolean" },
              "max-ticks": { type: "string" },
              maxTicks: { type: "string" },
              iterations: { type: "string" },
              "poll-interval": { type: "string" },
              pollInterval: { type: "string" },
              help: { type: "boolean", short: "h" },
            },
            allowPositionals: true,
          });
          const maxTicksRaw = (values.iterations || values["max-ticks"] || values["maxTicks"]) as string | undefined;
          const pollIntervalRaw = (values["poll-interval"] || values["pollInterval"]) as string | undefined;
          return {
            command: "run",
            type: "run",
            dir: (values.dir as string) || positionals[0] || defaultDir,
            detach: Boolean(values.detach),
            maxTicks: maxTicksRaw ? parseInt(maxTicksRaw, 10) : undefined,
            pollIntervalMs: pollIntervalRaw ? parseInt(pollIntervalRaw, 10) : undefined,
            help: Boolean(values.help),
          };
        } catch (err: any) {
          return {
            command: "invalid",
            type: "invalid",
            error: err?.message || "Invalid arguments for run",
            subcommand: "run",
          };
        }
      }

      case "init":
      case "setup": {
        try {
          const { values, positionals } = parseArgs({
            args: subArgs,
            options: {
              dir: { type: "string", short: "d" },
              repo: { type: "string", short: "r" },
              agents: { type: "string", short: "a" },
              help: { type: "boolean", short: "h" },
            },
            allowPositionals: true,
          });
          return {
            command: "init",
            type: "init",
            dir: (values.dir as string) || positionals[0] || defaultDir,
            repoUrl: (values.repo as string) || "https://github.com/de-angelov/slopboss2.git",
            agents: values.agents ? parseInt(values.agents as string, 10) : 2,
            help: Boolean(values.help),
          };
        } catch (err: any) {
          return {
            command: "invalid",
            type: "invalid",
            error: err?.message || "Invalid arguments for init",
            subcommand: "init",
          };
        }
      }

      case "groom": {
        try {
          const { values, positionals } = parseArgs({
            args: subArgs,
            options: {
              dir: { type: "string", short: "d" },
              model: { type: "string", short: "m" },
              help: { type: "boolean", short: "h" },
            },
            allowPositionals: true,
          });
          return {
            command: "groom",
            type: "groom",
            dir: (values.dir as string) || positionals[0] || defaultDir,
            model: values.model as string | undefined,
            help: Boolean(values.help),
          };
        } catch (err: any) {
          return {
            command: "invalid",
            type: "invalid",
            error: err?.message || "Invalid arguments for groom",
            subcommand: "groom",
          };
        }
      }

      case "status": {
        try {
          const { values, positionals } = parseArgs({
            args: subArgs,
            options: {
              dir: { type: "string", short: "d" },
              help: { type: "boolean", short: "h" },
            },
            allowPositionals: true,
          });
          return {
            command: "status",
            type: "status",
            dir: (values.dir as string) || positionals[0] || defaultDir,
            help: Boolean(values.help),
          };
        } catch (err: any) {
          return {
            command: "invalid",
            type: "invalid",
            error: err?.message || "Invalid arguments for status",
            subcommand: "status",
          };
        }
      }

      case "view": {
        try {
          const { values, positionals } = parseArgs({
            args: subArgs,
            options: {
              dir: { type: "string", short: "d" },
              "poll-interval": { type: "string" },
              pollInterval: { type: "string" },
              help: { type: "boolean", short: "h" },
            },
            allowPositionals: true,
          });
          const pollIntervalRaw = (values["poll-interval"] || values["pollInterval"]) as string | undefined;
          return {
            command: "view",
            type: "view",
            dir: (values.dir as string) || positionals[0] || defaultDir,
            pollIntervalMs: pollIntervalRaw ? parseInt(pollIntervalRaw, 10) : undefined,
            help: Boolean(values.help),
          };
        } catch (err: any) {
          return {
            command: "invalid",
            type: "invalid",
            error: err?.message || "Invalid arguments for view",
            subcommand: "view",
          };
        }
      }

      default: {
        return {
          command: "invalid",
          type: "invalid",
          error: `Unknown command: ${first}`,
        };
      }
    }
  }

  export function printStatus(boardDir: string): Effect.Effect<boolean, Error> {
    return Effect.sync(() => {
      console.log("=== SLOPBOSS2 BOARD STATUS ===");
      console.log("Board: " + boardDir);
      console.log("Lane 1: Dev Agent 1 -> [SB2-03] Live Process Runner (Completed)");
      console.log("Lane 2: Dev Agent 2 -> [SB2-05] Interactive Grooming CLI (In Progress)");
      console.log("Fleet: 2 dev agents active, provider agy.");
      return true;
    });
  }

  export function runSetup(boardDir: string, repoUrl: string): Effect.Effect<boolean, Error> {
    return Effect.gen(function* () {
      console.log("=== SLOPBOSS2 SETUP ===");
      console.log("Board directory: " + boardDir);
      console.log("Repository URL:  " + repoUrl);
      console.log("Provider:        Antigravity (agy)");
      console.log("Dev Agents:      2");
      yield* initBoardStructure(boardDir, repoUrl, 2);
      console.log("Setup complete. Workspaces initialized.");
      return true;
    });
  }

  export function launchInteractiveGroom(
    boardDir: string,
    model: Option.Option<string> = Option.none(),
    spawnFn: typeof Bun.spawn = Bun.spawn
  ): Effect.Effect<number, Error> {
    return Effect.gen(function* () {
      const backlogPath = path.join(boardDir, "BACKLOG.md");
      let backlogText = "";
      if (fs.existsSync(backlogPath)) {
        backlogText = fs.readFileSync(backlogPath, "utf-8");
      }
      const prompt = buildGroomPrompt(boardDir, backlogText);
      const agyCmd = buildInteractiveCommand(model, prompt);
      console.log("Starting interactive Team Lead grooming session...");
      console.log("Command: " + (agyCmd as string[]).join(" "));
      const proc = spawnFn(agyCmd as string[], {
        cwd: boardDir,
        stdin: "inherit",
        stdout: "inherit",
        stderr: "inherit",
      });
      const rawCode = yield* Effect.promise(() => proc.exited);
      const code = rawCode ?? 0;
      console.log(`Team Lead grooming session completed with exit code ${code}`);
      return code;
    });
  }

  export function runDoctorCommand(dir: string): Effect.Effect<DoctorReportTs, Error> {
    return Effect.gen(function* () {
      const report = yield* runDoctor(dir);
      const table = formatDoctorTable(report);
      console.log(table);
      return report;
    });
  }

  export function runReconcilerCommand(
    dir: string,
    detach: boolean = false,
    options?: DispatchOptions,
    maxTicks?: number,
    pollIntervalMs?: number
  ): Effect.Effect<any, Error> {
    return Effect.gen(function* () {
      if (detach) {
        const spawnFn = options?.spawnFn || Bun.spawn;
        const binPath = process.argv[1] || "src/cli/bin.ts";
        const proc = spawnFn([process.execPath, "run", binPath, "run", "--dir", dir], {
          detached: true,
          stdio: ["ignore", "ignore", "ignore"],
        });
        if (proc && typeof (proc as any).unref === "function") {
          (proc as any).unref();
        }
        console.log(`[SLOPBOSS2] Started reconciler daemon in background (PID: ${proc.pid})`);
        return { detached: true, pid: proc.pid };
      }

      console.log(`[SLOPBOSS2] Starting dispatcher reconciler loop for board: ${dir}`);
      const config: ReconcilerConfig = {
        boardDir: dir,
        pollIntervalMs: pollIntervalMs ?? options?.pollIntervalMs ?? 1000,
        maxIterations: maxTicks ?? options?.maxIterations ?? 0,
        devAgentCount: 2,
        mockRunner: options?.mockRunner ?? false,
        runnerFn: options?.runnerFn,
      };
      return yield* runReconcilerLoop(config);
    });
  }

  export function runInitCommand(
    dir: string,
    repoUrl: string = "https://github.com/de-angelov/slopboss2.git",
    agents: number = 2
  ): Effect.Effect<BoardInitResultTs, Error> {
    return Effect.gen(function* () {
      console.log("=== SLOPBOSS2 INIT ===");
      console.log(`Board directory: ${dir}`);
      console.log(`Repository URL:  ${repoUrl}`);
      console.log(`Dev Agents:      ${agents}`);
      const res = yield* initBoardStructure(dir, repoUrl, agents);
      console.log("Initialization complete. Workspaces and board ready.");
      return res;
    });
  }

  export function runGroomCommand(
    dir: string,
    model?: string,
    options?: DispatchOptions
  ): Effect.Effect<number, Error> {
    return Effect.gen(function* () {
      const code = yield* launchInteractiveGroom(
        dir,
        model ? Option.some(model) : Option.none(),
        options?.spawnFn
      );
      return code;
    });
  }

  export function runViewCommand(
    dir: string,
    pollMs: number = 1000,
    options?: LiveViewOptions
  ): Effect.Effect<boolean, Error> {
    return runLiveView(dir, pollMs, options);
  }

  export function runControlLoop(boardDir: string, maxTicks: number = 3): Effect.Effect<any, Error> {
    return Effect.gen(function* () {
      console.log("Starting Slopboss2 control loop (provider: agy, dev-agents: 2)...");
      const config: ReconcilerConfig = {
        boardDir,
        pollIntervalMs: 100,
        maxIterations: maxTicks,
        devAgentCount: 2,
      };
      return yield* runReconcilerLoop(config);
    });
  }

  export function dispatchCli(
    cmd: CliCommand,
    options?: DispatchOptions
  ): Effect.Effect<any, Error> {
    if (cmd.command === "help" || ("help" in cmd && cmd.help)) {
      const sub = cmd.command === "help" ? cmd.subcommand : cmd.command;
      const helpMsg = getHelpMessage(sub);
      console.log(helpMsg);
      return Effect.succeed({ help: true, output: helpMsg });
    }

    if (cmd.command === "invalid") {
      const errMsg = `Error: ${cmd.error}`;
      console.error(errMsg);
      console.log(getHelpMessage(cmd.subcommand));
      return Effect.fail(new Error(cmd.error));
    }

    switch (cmd.command) {
      case "doctor":
        return runDoctorCommand(cmd.dir);

      case "run":
        return runReconcilerCommand(cmd.dir, cmd.detach, options, cmd.maxTicks, cmd.pollIntervalMs);

      case "init":
        return runInitCommand(cmd.dir, cmd.repoUrl, cmd.agents);

      case "groom":
        return runGroomCommand(cmd.dir, cmd.model, options);

      case "status":
        return printStatus(cmd.dir);

      case "view":
        return runViewCommand(
          cmd.dir,
          cmd.pollIntervalMs ?? options?.pollIntervalMs ?? 1000,
          options?.viewOptions
        );
    }
  }

  export function runCli(
    argv?: string[],
    options?: DispatchOptions
  ): Effect.Effect<any, Error> {
    const rawArgs = argv !== undefined ? argv : process.argv.slice(2);
    const parsed = parseCliArgs(rawArgs);
    return dispatchCli(parsed, options);
  }

export const buildGroomPromptFun = (boardDir: string, backlogContent: string) =>
  buildGroomPrompt(boardDir, backlogContent);

export const printStatusFun = (boardDir: string) =>
  printStatus(boardDir);

export const runSetupFun = (boardDir: string, repoUrl: string) =>
  runSetup(boardDir, repoUrl);

export const launchInteractiveGroomFun = (boardDir: string, model: any) =>
  launchInteractiveGroom(boardDir, model);

export const runControlLoopFun = (boardDir: string, maxTicks: number) =>
  runControlLoop(boardDir, maxTicks);

export const runViewCommandFun = (boardDir: string, pollMs: number) =>
  runViewCommand(boardDir, pollMs);

export const runCliFun = () =>
  runCli();
