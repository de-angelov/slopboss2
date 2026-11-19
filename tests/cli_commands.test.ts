import { afterEach, beforeEach, describe, expect, it } from "bun:test";
import { Effect, Option } from "effect";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import {
  DEFAULT_BOARD_DIR,
  buildGroomPrompt,
  dispatchCli,
  formatDoctorTable,
  getHelpMessage,
  launchInteractiveGroom,
  parseCliArgs,
  printStatus,
  runCli,
  runDoctorCommand,
  runGroomCommand,
  runInitCommand,
  runReconcilerCommand,
  runViewCommand,
  type CliCommand,
} from "../src/cli/index.js";
import type { DoctorReportTs } from "../src/services/doctor.js";

describe("CLI Unified Command Dispatcher & Binary Entrypoint", () => {
  let tempDir: string;

  beforeEach(() => {
    tempDir = fs.mkdtempSync(path.join(os.tmpdir(), "slopboss-cli-test-"));
  });

  afterEach(() => {
    if (fs.existsSync(tempDir)) {
      fs.rmSync(tempDir, { recursive: true, force: true });
    }
  });

  describe("CLI Argument Parser (parseCliArgs)", () => {
    it("parses 'doctor' command with default and custom arguments", () => {
      // Default
      const cmdDefault = parseCliArgs(["doctor"]);
      expect(cmdDefault.command).toBe("doctor");
      expect(cmdDefault.type).toBe("doctor");
      expect((cmdDefault as any).dir).toBe(DEFAULT_BOARD_DIR);
      expect((cmdDefault as any).help).toBe(false);

      // With --dir
      const cmdDir = parseCliArgs(["doctor", "--dir", "/tmp/test-board"]);
      expect((cmdDir as any).dir).toBe("/tmp/test-board");

      // With short flag -d
      const cmdShort = parseCliArgs(["doctor", "-d", "/tmp/short-board"]);
      expect((cmdShort as any).dir).toBe("/tmp/short-board");

      // Positional path
      const cmdPos = parseCliArgs(["doctor", "/tmp/pos-board"]);
      expect((cmdPos as any).dir).toBe("/tmp/pos-board");

      // Help flag
      const cmdHelp = parseCliArgs(["doctor", "--help"]);
      expect((cmdHelp as any).help).toBe(true);

      // Unknown option
      const cmdInvalid = parseCliArgs(["doctor", "--unknown-flag"]);
      expect(cmdInvalid.command).toBe("invalid");
      expect((cmdInvalid as any).subcommand).toBe("doctor");
    });

    it("parses 'run' command with default, options, and --detach", () => {
      // Default
      const cmdDefault = parseCliArgs(["run"]);
      expect(cmdDefault.command).toBe("run");
      expect((cmdDefault as any).dir).toBe(DEFAULT_BOARD_DIR);
      expect((cmdDefault as any).detach).toBe(false);

      // With --detach
      const cmdDetach = parseCliArgs(["run", "--detach"]);
      expect((cmdDetach as any).detach).toBe(true);

      // With --dir and --detach
      const cmdAll = parseCliArgs(["run", "--dir", "/tmp/board", "--detach"]);
      expect((cmdAll as any).dir).toBe("/tmp/board");
      expect((cmdAll as any).detach).toBe(true);

      // With --max-ticks and --poll-interval
      const cmdTicks = parseCliArgs([
        "run",
        "--dir",
        "/tmp/board",
        "--max-ticks",
        "5",
        "--poll-interval",
        "250",
      ]);
      expect((cmdTicks as any).maxTicks).toBe(5);
      expect((cmdTicks as any).pollIntervalMs).toBe(250);

      // Help flag
      const cmdHelp = parseCliArgs(["run", "-h"]);
      expect((cmdHelp as any).help).toBe(true);

      // Unknown option
      const cmdInvalid = parseCliArgs(["run", "--invalid"]);
      expect(cmdInvalid.command).toBe("invalid");
      expect((cmdInvalid as any).subcommand).toBe("run");
    });

    it("parses 'init' and alias 'setup' with repo and agent options", () => {
      // Default
      const cmdDefault = parseCliArgs(["init"]);
      expect(cmdDefault.command).toBe("init");
      expect((cmdDefault as any).repoUrl).toBe("https://github.com/de-angelov/slopboss2.git");
      expect((cmdDefault as any).agents).toBe(2);

      // With options
      const cmdOpts = parseCliArgs([
        "init",
        "--dir",
        "/tmp/custom",
        "--repo",
        "https://example.com/repo.git",
        "--agents",
        "3",
      ]);
      expect((cmdOpts as any).dir).toBe("/tmp/custom");
      expect((cmdOpts as any).repoUrl).toBe("https://example.com/repo.git");
      expect((cmdOpts as any).agents).toBe(3);

      // Short flags
      const cmdShort = parseCliArgs([
        "init",
        "-d",
        "/tmp/short",
        "-r",
        "https://example.com/short.git",
        "-a",
        "4",
      ]);
      expect((cmdShort as any).dir).toBe("/tmp/short");
      expect((cmdShort as any).repoUrl).toBe("https://example.com/short.git");
      expect((cmdShort as any).agents).toBe(4);

      // Setup alias
      const cmdSetup = parseCliArgs(["setup", "--dir", "/tmp/setup"]);
      expect(cmdSetup.command).toBe("init");
      expect((cmdSetup as any).dir).toBe("/tmp/setup");

      // Unknown option
      const cmdInvalid = parseCliArgs(["init", "--fake"]);
      expect(cmdInvalid.command).toBe("invalid");
    });

    it("parses 'groom' with dir and model options", () => {
      // Default
      const cmdDefault = parseCliArgs(["groom"]);
      expect(cmdDefault.command).toBe("groom");
      expect((cmdDefault as any).dir).toBe(DEFAULT_BOARD_DIR);
      expect((cmdDefault as any).model).toBeUndefined();

      // With options
      const cmdOpts = parseCliArgs([
        "groom",
        "--dir",
        "/tmp/groom-board",
        "--model",
        "gemini-2.5-pro",
      ]);
      expect((cmdOpts as any).dir).toBe("/tmp/groom-board");
      expect((cmdOpts as any).model).toBe("gemini-2.5-pro");

      // Short flags
      const cmdShort = parseCliArgs(["groom", "-d", "/tmp/short", "-m", "flash"]);
      expect((cmdShort as any).dir).toBe("/tmp/short");
      expect((cmdShort as any).model).toBe("flash");

      // Unknown option
      const cmdInvalid = parseCliArgs(["groom", "--bogus"]);
      expect(cmdInvalid.command).toBe("invalid");
    });

    it("parses 'status' with dir option", () => {
      const cmdDefault = parseCliArgs(["status"]);
      expect(cmdDefault.command).toBe("status");

      const cmdDir = parseCliArgs(["status", "--dir", "/tmp/board"]);
      expect((cmdDir as any).dir).toBe("/tmp/board");
    });

    it("parses 'view' with dir and poll-interval options", () => {
      // Default
      const cmdDefault = parseCliArgs(["view"]);
      expect(cmdDefault.command).toBe("view");
      expect(cmdDefault.type).toBe("view");
      expect((cmdDefault as any).dir).toBe(DEFAULT_BOARD_DIR);
      expect((cmdDefault as any).help).toBe(false);

      // With --dir
      const cmdDir = parseCliArgs(["view", "--dir", "/tmp/view-board"]);
      expect((cmdDir as any).dir).toBe("/tmp/view-board");

      // With short flag -d
      const cmdShort = parseCliArgs(["view", "-d", "/tmp/short-view"]);
      expect((cmdShort as any).dir).toBe("/tmp/short-view");

      // Positional path
      const cmdPos = parseCliArgs(["view", "/tmp/pos-view"]);
      expect((cmdPos as any).dir).toBe("/tmp/pos-view");

      // With --poll-interval
      const cmdPoll = parseCliArgs(["view", "--poll-interval", "500"]);
      expect((cmdPoll as any).pollIntervalMs).toBe(500);

      // Help flag
      const cmdHelp = parseCliArgs(["view", "--help"]);
      expect((cmdHelp as any).help).toBe(true);

      // Unknown option
      const cmdInvalid = parseCliArgs(["view", "--unknown-flag"]);
      expect(cmdInvalid.command).toBe("invalid");
      expect((cmdInvalid as any).subcommand).toBe("view");
    });

    it("parses global help and unknown commands", () => {
      expect(parseCliArgs([]).command).toBe("help");
      expect(parseCliArgs(["--help"]).command).toBe("help");
      expect(parseCliArgs(["-h"]).command).toBe("help");
      expect(parseCliArgs(["help"]).command).toBe("help");

      const helpDoctor = parseCliArgs(["help", "doctor"]);
      expect(helpDoctor.command).toBe("help");
      expect((helpDoctor as any).subcommand).toBe("doctor");

      const unknown = parseCliArgs(["not-a-command"]);
      expect(unknown.command).toBe("invalid");
      expect((unknown as any).error).toContain("not-a-command");
    });
  });

  describe("Diagnostic Table Formatting (formatDoctorTable)", () => {
    it("formats healthy check report into a clear table", () => {
      const report: DoctorReportTs = {
        isHealthy: true,
        checks: [
          { name: "git", ok: true, message: "git version 2.43.0", required: true },
          { name: "bun", ok: true, message: "bun 1.4.4", required: true },
          { name: "provider", ok: true, message: "Found agy", required: true },
          { name: "board", ok: true, message: "Board files valid", required: true },
          { name: "workspaces", ok: true, message: "Workspaces valid", required: true },
        ],
      };

      const table = formatDoctorTable(report);
      expect(table).toContain("Diagnostic Check Results:");
      expect(table).toContain("[ PASS ]  | git");
      expect(table).toContain("[ PASS ]  | bun");
      expect(table).toContain("[ PASS ]  | provider");
      expect(table).toContain("[ PASS ]  | board");
      expect(table).toContain("[ PASS ]  | workspaces");
      expect(table).toContain("Overall Health: HEALTHY");
    });

    it("formats unhealthy report highlighting failures", () => {
      const report: DoctorReportTs = {
        isHealthy: false,
        checks: [
          { name: "git", ok: true, message: "git version 2.43.0", required: true },
          { name: "board", ok: false, message: "Missing TASKS.md", required: true },
        ],
      };

      const table = formatDoctorTable(report);
      expect(table).toContain("[ PASS ]  | git");
      expect(table).toContain("[ FAIL ]  | board");
      expect(table).toContain("Missing TASKS.md");
      expect(table).toContain("Overall Health: UNHEALTHY");
    });
  });

  describe("Help Messages (getHelpMessage)", () => {
    it("returns general overview for root help", () => {
      const help = getHelpMessage();
      expect(help).toContain("slopboss2 - Autonomous multi-agent orchestrator");
      expect(help).toContain("doctor [--dir <path>]");
      expect(help).toContain("run [--dir <path>] [--detach]");
      expect(help).toContain("init [--dir <path>] [--repo <url>]");
      expect(help).toContain("groom [--dir <path>]");
      expect(help).toContain("status [--dir <path>]");
      expect(help).toContain("view [--dir <path>]");
    });

    it("returns command-specific options for subcommands", () => {
      expect(getHelpMessage("doctor")).toContain("Usage: slopboss2 doctor");
      expect(getHelpMessage("run")).toContain("--detach");
      expect(getHelpMessage("init")).toContain("--repo <url>");
      expect(getHelpMessage("groom")).toContain("--model <name>");
      expect(getHelpMessage("status")).toContain("Usage: slopboss2 status");
      expect(getHelpMessage("view")).toContain("Usage: slopboss2 view");
    });
  });

  describe("Command Dispatch & Execution (dispatchCli / runCli)", () => {
    it("executes 'doctor' command and prints diagnostic table", async () => {
      // Scaffolding valid board
      fs.writeFileSync(path.join(tempDir, "TASKS.md"), "# TASKS\n");
      fs.writeFileSync(path.join(tempDir, "ARCHIVE.md"), "# ARCHIVE\n");
      fs.writeFileSync(path.join(tempDir, "AGENTS.md"), "# AGENTS\n");
      fs.mkdirSync(path.join(tempDir, "workspaces"), { recursive: true });

      const report = await Effect.runPromise(
        runCli(["doctor", "--dir", tempDir])
      );
      expect(report.isHealthy).toBe(true);
      expect(report.checks.length).toBe(5);
    });

    it("executes 'init' command to provision board structure and workspaces", async () => {
      const result = await Effect.runPromise(
        runCli(["init", "--dir", tempDir, "--agents", "2"])
      );

      expect(result.boardDir).toBe(tempDir);
      expect(result.filesCreated).toContain("TASKS.md");
      expect(result.filesCreated).toContain("BACKLOG.md");
      expect(result.filesCreated).toContain("ARCHIVE.md");
      expect(result.filesCreated).toContain("AGENTS.md");
      expect(fs.existsSync(path.join(tempDir, "TASKS.md"))).toBe(true);
      expect(fs.existsSync(path.join(tempDir, "workspaces"))).toBe(true);
    });

    it("executes 'run' in foreground reconciler loop", async () => {
      // Create minimal board
      fs.writeFileSync(path.join(tempDir, "TASKS.md"), "# TASKS\n\n## Dev Agent 1 In Progress\n*Idle*\n\n## Dev Agent 2 In Progress\n*Idle*\n");
      fs.writeFileSync(path.join(tempDir, "BACKLOG.md"), "# BACKLOG\n");
      fs.writeFileSync(path.join(tempDir, "ARCHIVE.md"), "# ARCHIVE\n");

      const state = await Effect.runPromise(
        runCli(["run", "--dir", tempDir, "--max-ticks", "1"], {
          mockRunner: true,
        })
      );

      expect(state.tickCount).toBe(1);
    });

    it("executes 'run --detach' and spawns background process", async () => {
      let spawnCalled = false;
      let spawnArgs: string[] = [];
      let spawnOpts: any = null;

      const mockSpawn = ((args: string[], opts: any) => {
        spawnCalled = true;
        spawnArgs = args;
        spawnOpts = opts;
        return {
          pid: 4242,
          unref: () => {},
        };
      }) as any;

      const result = await Effect.runPromise(
        runCli(["run", "--dir", tempDir, "--detach"], {
          spawnFn: mockSpawn,
        })
      );

      expect(spawnCalled).toBe(true);
      expect(spawnOpts.detached).toBe(true);
      expect(spawnArgs).toContain("run");
      expect(spawnArgs).toContain("--dir");
      expect(spawnArgs).toContain(tempDir);
      expect(result.detached).toBe(true);
      expect(result.pid).toBe(4242);
    });

    it("executes 'groom' command with interactive prompt builder", async () => {
      fs.writeFileSync(
        path.join(tempDir, "BACKLOG.md"),
        "- [ ] SB2-99: Test backlog task\n"
      );

      let spawnCalled = false;
      let spawnedCmd: string[] = [];
      let spawnedCwd: string = "";

      const mockSpawn = ((cmd: string[], opts: any) => {
        spawnCalled = true;
        spawnedCmd = cmd;
        spawnedCwd = opts.cwd;
        return {
          exited: Promise.resolve(0),
        };
      }) as any;

      const exitCode = await Effect.runPromise(
        runCli(["groom", "--dir", tempDir, "--model", "gemini-pro"], {
          spawnFn: mockSpawn,
        })
      );

      expect(spawnCalled).toBe(true);
      expect(spawnedCwd).toBe(tempDir);
      expect(spawnedCmd).toContain("agy");
      expect(spawnedCmd).toContain("-i");
      expect(spawnedCmd).toContain("--model");
      expect(spawnedCmd).toContain("gemini-pro");
      expect(exitCode).toBe(0);
    });

    it("executes 'view' command and dispatches to runLiveView", async () => {
      fs.writeFileSync(
        path.join(tempDir, "TASKS.md"),
        "# TASKS\n\n## Dev Agent 1 In Progress\n*Idle*\n\n## Dev Agent 2 In Progress\n*Idle*\n"
      );
      fs.writeFileSync(path.join(tempDir, "BACKLOG.md"), "# BACKLOG\n");
      fs.writeFileSync(path.join(tempDir, "ARCHIVE.md"), "# ARCHIVE\n");

      let ticked = false;
      let outputCaptured = "";
      const mockStdout = {
        write: (str: string) => {
          outputCaptured += str;
          return true;
        },
      };
      const mockStdin = {
        on: () => {},
        removeListener: () => {},
        setRawMode: () => {},
        resume: () => {},
        pause: () => {},
        setEncoding: () => {},
      };

      const result = await Effect.runPromise(
        runCli(["view", "--dir", tempDir], {
          pollIntervalMs: 50,
          viewOptions: {
            stdout: mockStdout,
            stdin: mockStdin,
            maxTicks: 1,
            onTick: (state, output) => {
              ticked = true;
              expect(state.boardDir).toBe(tempDir);
              expect(output).toContain("SLOPBOSS2 LIVE AGENT DASHBOARD");
            },
          },
        })
      );

      expect(result).toBe(true);
      expect(ticked).toBe(true);
      expect(outputCaptured).toContain("SLOPBOSS2 LIVE AGENT DASHBOARD");
    });

    it("executes runViewCommand directly", async () => {
      fs.writeFileSync(path.join(tempDir, "TASKS.md"), "# TASKS\n");
      let ticked = false;
      const res = await Effect.runPromise(
        runViewCommand(tempDir, 50, {
          stdout: { write: () => true },
          stdin: { on: () => {}, removeListener: () => {} },
          maxTicks: 1,
          onTick: () => {
            ticked = true;
          },
        })
      );
      expect(res).toBe(true);
      expect(ticked).toBe(true);
    });

    it("handles '--help' without errors", async () => {
      const res = await Effect.runPromise(runCli(["--help"]));
      expect(res.help).toBe(true);
      expect(res.output).toContain("slopboss2");

      const resDoctor = await Effect.runPromise(runCli(["doctor", "--help"]));
      expect(resDoctor.help).toBe(true);
      expect(resDoctor.output).toContain("slopboss2 doctor");
    });

    it("fails with informative error on unknown command", async () => {
      expect(
        Effect.runPromise(runCli(["nonexistent-command"]))
      ).rejects.toThrow("Unknown command: nonexistent-command");
    });

    it("fails with informative error on invalid argument", async () => {
      expect(
        Effect.runPromise(runCli(["doctor", "--bad-flag"]))
      ).rejects.toThrow();
    });
  });

  describe("Binary Executable (src/cli/bin.fun)", () => {
    it("runs binary directly with --help and exits 0", async () => {
      const proc = Bun.spawn(["bun", "run", "src/cli/bin.fun", "--help"], {
        stdout: "pipe",
        stderr: "pipe",
      });
      const stdout = await new Response(proc.stdout).text();
      const code = await proc.exited;

      expect(code).toBe(0);
      expect(stdout).toContain("slopboss2 - Autonomous multi-agent orchestrator");
      expect(stdout).toContain("doctor");
      expect(stdout).toContain("run");
      expect(stdout).toContain("init");
      expect(stdout).toContain("groom");
      expect(stdout).toContain("view");
    }, 15000);

    it("runs binary with doctor command and prints diagnostic table", async () => {
      const proc = Bun.spawn(["bun", "run", "src/cli/bin.fun", "doctor", "--dir", tempDir], {
        stdout: "pipe",
        stderr: "pipe",
      });
      const stdout = await new Response(proc.stdout).text();
      const code = await proc.exited;

      expect(code).toBe(0);
      expect(stdout).toContain("Diagnostic Check Results:");
      expect(stdout).toContain("Status    | Check");
      expect(stdout).toContain("Overall Health:");
    }, 15000);

    it("runs binary with invalid subcommand and exits with code 1", async () => {
      const proc = Bun.spawn(["bun", "run", "src/cli/bin.fun", "bogus-command"], {
        stdout: "pipe",
        stderr: "pipe",
      });
      const stderr = await new Response(proc.stderr).text();
      const stdout = await new Response(proc.stdout).text();
      const code = await proc.exited;

      expect(code).toBe(1);
      const output = stdout + stderr;
      expect(output).toContain("Unknown command: bogus-command");
    }, 15000);
  });
});
