import { Array, Console, Effect, Number, Option, Schema, String, Predicate } from "effect"
import { runDoctor } from "../services/doctor.js"
import { ReconcilerConfig, runReconcilerLoop } from "../orchestrator/dispatcher.js"
import { initBoardStructure, readRuntimeConfig, readRuntimeConfigSync } from "../services/setup.js"
import { buildInteractiveCommand } from "../services/provider.js"
import { defaultLiveViewOptions, LiveViewOptions, runLiveView } from "./view.js"
import { findTask, loadBoardStoreSync, updateTaskStatus } from "../domain/boardstore.js"
import { acquireBoardLock } from "../services/coordination.js"
import { writeCoordinationReport } from "../services/coordination_report.js"

export schema CliDoctorCommand = {
  command: String
  type: String
  dir: String
  help: Boolean
}

export schema CliRunCommand = {
  command: String
  type: String
  dir: String
  detach: Boolean
  maxTicks?: Number
  pollIntervalMs?: Number
  help: Boolean
}

export schema CliInitCommand = {
  command: String
  type: String
  dir: String
  repoUrl: String
  agents: Number
  originUrl?: String
  baseBranch?: String
  provider?: String
  help: Boolean
}

export schema CliGroomCommand = {
  command: String
  type: String
  dir: String
  model?: String
  help: Boolean
}

export schema CliStatusCommand = {
  command: String
  type: String
  dir: String
  help: Boolean
}

export schema CliViewCommand = {
  command: String
  type: String
  dir: String
  pollIntervalMs?: Number
  help: Boolean
}

export schema CliCoordinationCommand = {
  command: String
  type: String
  status: String
  summary: String
}

export schema CliHelpCommand = {
  command: String
  type: String
  subcommand?: String
  help?: Boolean
}

export schema CliInvalidCommand = {
  command: String
  type: String
  error: String
  subcommand?: String
  help?: Boolean
}

export schema CliCommand = CliDoctorCommand | CliRunCommand | CliInitCommand | CliGroomCommand | CliStatusCommand | CliViewCommand | CliCoordinationCommand | CliHelpCommand | CliInvalidCommand

export schema DispatchOptions = {
  spawnFn?: Unknown
  mockRunner?: Boolean
  maxIterations?: Number
  pollIntervalMs?: Number
  runnerFn?: Unknown
  viewOptions?: Unknown
}

export schema DetachedResult = {
  detached: Boolean
  pid: Unknown
}

export schema HelpResult = {
  help: Boolean
  output: String
}

export error CliCommandError(message: String)

export getEnvVar = (name: String): Option<String> =>
  Option.fromNullishOr(process)
  |> flatMap((proc) => Option.fromNullishOr(Reflect.get(proc, "env")))
  |> flatMap((env) => Option.fromNullishOr(Reflect.get(env, name)))
  |> map((val) => "" + val)

export getProcessArgv = (): Array<String> =>
  Option.fromNullishOr(process)
  |> flatMap((proc) => Option.fromNullishOr(Reflect.get(proc, "argv")))
  |> getOrElse(() => [])

export getProcessExecPath = (): String =>
  Option.fromNullishOr(process)
  |> flatMap((proc) => Option.fromNullishOr(Reflect.get(proc, "execPath")))
  |> map((ep) => "" + ep)
  |> getOrElse(() => "bun")

defaultBoardDirFallback = () => "/home/dangelov/slopboss2-board"

export DEFAULT_BOARD_DIR = Option.getOrElse(getEnvVar("SLOPBOSS_BOARD_DIR"), defaultBoardDirFallback)

export buildGroomPrompt = (boardDir: String, backlogContent: String): String =>
  header = "You are the autonomous Team Lead for slopboss2.\n"
  ctx = "Groom and prioritize tasks from BACKLOG.md for the board at: " + boardDir + "\n\n"
  content = "--- CURRENT BACKLOG.md ---\n" + backlogContent + "\n--- END BACKLOG.md ---\n\n"
  instructions = "Instructions:\n1. Review prioritized tasks in BACKLOG.md and verify readiness and dependencies.\n2. Format task specifications for TASKS.md including Task ID, Category, Owner, Branch, Status, Objective, Scope, Acceptance Criteria.\n3. Write groomed task allocations to TASKS.md and update BACKLOG.md."
  => header + ctx + content + instructions

export buildGroomPromptFun = (boardDir: String, backlogContent: String): String =>
  buildGroomPrompt(boardDir, backlogContent)

export schema CheckItem = {
  name: String
  ok: Boolean
  message: String
  required: Boolean
}

export schema DoctorReport = {
  isHealthy: Boolean
  checks: Array<CheckItem>
}

statusTag = (isOk: Boolean): String =>
  match isOk
    | true => "[ PASS ]"
    | false => "[ FAIL ]"

requiredTag = (isReq: Boolean): String =>
  match isReq
    | true => "Yes"
    | false => "No "

healthTag = (isHealthy: Boolean): String =>
  match isHealthy
    | true => "HEALTHY"
    | false => "UNHEALTHY"

ObjSchema = Schema.declare(Predicate.isObject)
ArrUnknownSchema = Schema.Array(Schema.Unknown)
FnSchema = Schema.declare(Predicate.isFunction)
PromiseSchema = Schema.declare(Predicate.isPromiseLike)

getProp = (obj: Unknown, key: String): Option.Option<Unknown> =>
  Schema.decodeUnknownOption(ObjSchema)(obj)
  |> Option.flatMap((rec) => Option.fromNullishOr(Reflect.get(rec, key)))

getPropStr = (obj: Unknown, key: String): String =>
  getProp(obj, key)
  |> Option.map((v) => "" + v)
  |> Option.getOrElse(() => "")

callSpawn = (spawnFnVal: Unknown, cmd: Array<String>, opts: Unknown): Unknown =>
  Schema.decodeUnknownOption(FnSchema)(spawnFnVal)
  |> Option.map((f) => Reflect.apply(f, Void, [cmd, opts]))
  |> Option.getOrElse(() => {})

export formatDoctorTable = (report: Unknown): String =>
  lines = [
    "Diagnostic Check Results:",
    "--------------------------------------------------------------------------------",
    "Status    | Check        | Required | Details",
    "--------------------------------------------------------------------------------"
  ]
  rawChecks: Array<Unknown> =
    getProp(report, "checks")
    |> Option.flatMap(Schema.decodeUnknownOption(ArrUnknownSchema))
    |> Option.getOrElse(() => [])
  checkLines =
    rawChecks
    |> Array.map((c: Unknown) => {
      isOk =
        getProp(c, "ok")
        |> Option.map((ok) => ok #= true)
        |> Option.getOrElse(() => false)
      status = statusTag(isOk)
      isReq =
        getProp(c, "required")
        |> Option.map((req) => req #= true)
        |> Option.getOrElse(() => false)
      req = requiredTag(isReq)
      name = getPropStr(c, "name") |> String.padEnd(12)
      msg = getPropStr(c, "message")
      => status + "  | " + name + " | " + req + "      | " + msg
    })
  isHealthy =
    getProp(report, "isHealthy")
    |> Option.map((h) => h #= true)
    |> Option.getOrElse(() => false)
  health = healthTag(isHealthy)
  allLines =
    lines
    |> Array.appendAll(checkLines)
    |> Array.append("--------------------------------------------------------------------------------")
    |> Array.append("Overall Health: " + health)
  => allLines |> Array.join("\n")

export getHelpMessage = (subcommand?: String): String =>
  sub = Option.getOrElse(Option.fromUndefinedOr(subcommand), () => "")
  match sub
    | "doctor" =>
        [
          "Usage: slopboss2 doctor [options] [path]",
          "",
          "Run system diagnostics and verify dependencies.",
          "",
          "Options:",
          "  -d, --dir <path>  Board directory path (default: $SLOPBOSS_BOARD_DIR or current directory)",
          "  -h, --help        Show help for doctor command"
        ]
        |> join("\n")
    | "run" =>
        [
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
          "  -h, --help            Show help for run command"
        ]
        |> join("\n")
    | "init" | "setup" =>
        [
          "Usage: slopboss2 init [options] [path]",
          "",
          "Provision board structure, markdown files, and workspaces.",
          "",
          "Options:",
          "  -d, --dir <path>  Board directory path (default: $SLOPBOSS_BOARD_DIR or current directory)",
          "  -r, --repo <url>  Target git repository URL to clone into workspaces",
          "  -a, --agents <n>  Number of dev agents to provision (default: 2)",
          "  -h, --help        Show help for init command"
        ]
        |> join("\n")
    | "groom" =>
        [
          "Usage: slopboss2 groom [options] [path]",
          "",
          "Launch interactive Team Lead grooming session with Antigravity (agy).",
          "",
          "Options:",
          "  -d, --dir <path>   Board directory path (default: $SLOPBOSS_BOARD_DIR or current directory)",
          "  -m, --model <name> Override agent model",
          "  -h, --help         Show help for groom command"
        ]
        |> join("\n")
    | "status" =>
        [
          "Usage: slopboss2 status [options] [path]",
          "",
          "Display board execution status.",
          "",
          "Options:",
          "  -d, --dir <path>  Board directory path (default: $SLOPBOSS_BOARD_DIR or current directory)",
          "  -h, --help        Show help for status command"
        ]
        |> join("\n")
    | "view" =>
        [
          "Usage: slopboss2 view [options] [path]",
          "",
          "Launch interactive terminal dashboard live view.",
          "",
          "Options:",
          "  -d, --dir <path>  Board directory path (default: $SLOPBOSS_BOARD_DIR or current directory)",
          "  -h, --help        Show help for view command"
        ]
        |> join("\n")
    | _ =>
        [
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
          "  coordination report --status <acted|idle|blocked> --summary <text>  Record a session result",
          "",
          "Options:",
          "  -h, --help                       Show help information",
          "  -v, --version                    Show version"
        ]
        |> join("\n")

schema RawParsedOptions = {
  dir: Option<String>
  help: Boolean
  detach: Boolean
  maxTicks: Option<Number>
  pollIntervalMs: Option<Number>
  repoUrl: Option<String>
  agents: Option<Number>
  originUrl: Option<String>
  baseBranch: Option<String>
  provider: Option<String>
  model: Option<String>
  positionals: Array<String>
  unknownOpt: Option<String>
}

emptyAcc = (): RawParsedOptions => {
  dir: Option.none()
  help: false
  detach: false
  maxTicks: Option.none()
  pollIntervalMs: Option.none()
  repoUrl: Option.none()
  agents: Option.none()
  originUrl: Option.none()
  baseBranch: Option.none()
  provider: Option.none()
  model: Option.none()
  positionals: []
  unknownOpt: Option.none()
}

parseTokenStep = (subcommand: String, tokens: Array<String>, acc: RawParsedOptions): RawParsedOptions =>
  head =
    tokens
    |> Array.get(0)
    |> Option.getOrElse(() => "")
  tail = tokens |> Array.drop(1)
  isDirCommand = subcommand #= "doctor" or subcommand #= "run" or subcommand #= "init" or subcommand #= "setup" or subcommand #= "groom" or subcommand #= "status" or subcommand #= "view"
  numericArg =
    tail
    |> Array.get(0)
    |> Option.getOrElse(() => "0")
    |> Number.parse
  agentCount =
    tail
    |> Array.get(0)
    |> Option.getOrElse(() => "2")
    |> Number.parse

  isPositional = not (head |> String.startsWith("-"))
  isDir = isDirCommand and (head #= "--dir" or head #= "-d")
  isPoll = (subcommand #= "run" or subcommand #= "view") and (head #= "--poll-interval" or head #= "pollInterval")
  isMaxTicks = subcommand #= "run" and (head #= "--max-ticks" or head #= "maxTicks" or head #= "--iterations")
  isDetach = subcommand #= "run" and head #= "--detach"
  isRepo = (subcommand #= "init" or subcommand #= "setup") and (head #= "--repo" or head #= "-r")
  isAgents = (subcommand #= "init" or subcommand #= "setup") and (head #= "--agents" or head #= "-a")
  isOrigin = (subcommand #= "init" or subcommand #= "setup") and head #= "--origin"
  isBranch = (subcommand #= "init" or subcommand #= "setup") and (head #= "--branch" or head #= "--base-branch")
  isProvider = (subcommand #= "init" or subcommand #= "setup") and head #= "--provider"
  isModel = subcommand #= "groom" and (head #= "--model" or head #= "-m")
  isHelp = (head #= "--help" or head #= "-h") and isDirCommand

  => match
    | head #= "" => parseTokens(subcommand, tail, acc)
    | isPositional =>
        parseTokens(subcommand, tail, {
          ...acc
          positionals: acc.positionals |> Array.append(head)
        })
    | isDir =>
        parseTokens(subcommand, tail |> Array.drop(1), { ...acc, dir: tail |> Array.get(0) })
    | isPoll =>
        parseTokens(subcommand, tail |> Array.drop(1), { ...acc, pollIntervalMs: numericArg })
    | isMaxTicks =>
        parseTokens(subcommand, tail |> Array.drop(1), { ...acc, maxTicks: numericArg })
    | isDetach =>
        parseTokens(subcommand, tail, { ...acc, detach: true })
    | isRepo =>
        parseTokens(subcommand, tail |> Array.drop(1), { ...acc, repoUrl: tail |> Array.get(0) })
    | isAgents =>
        parseTokens(subcommand, tail |> Array.drop(1), { ...acc, agents: agentCount })
    | isOrigin =>
        parseTokens(subcommand, tail |> Array.drop(1), {
          ...acc
          originUrl: tail |> Array.get(0)
        })
    | isBranch =>
        parseTokens(subcommand, tail |> Array.drop(1), {
          ...acc
          baseBranch: tail |> Array.get(0)
        })
    | isProvider =>
        parseTokens(subcommand, tail |> Array.drop(1), { ...acc, provider: tail |> Array.get(0) })
    | isModel =>
        parseTokens(subcommand, tail |> Array.drop(1), { ...acc, model: tail |> Array.get(0) })
    | isHelp =>
        parseTokens(subcommand, tail, { ...acc, help: true })
    | _ =>
        parseTokens(subcommand, tail, { ...acc, unknownOpt: Option.some(head) })

parseTokens = (subcommand: String, tokens: Array<String>, acc: RawParsedOptions): RawParsedOptions =>
  match
    | tokens.length #= 0 or Option.isSome(acc.unknownOpt) => acc
    | _ => parseTokenStep(subcommand, tokens, acc)

isKnownSubcommand = (cmd: String): Boolean =>
  match cmd
    | "doctor" | "run" | "init" | "setup" | "groom" | "status" | "view" | "board" | "recover" | "coordination" => true
    | _ => false

normalizeSubcommand = (cmd: String): String =>
  match cmd
    | "setup" => "init"
    | _ => cmd

ArrStrSchema = Schema.Array(Schema.String)
OptSchema = Schema.declare(Option.isOption)

buildParsedSubcommand = (normCmd: String, first: String, parsed: RawParsedOptions) =>
  resolvedDir =
    parsed.dir
    |> Option.orElse(() => parsed.positionals |> Array.head)
    |> Option.getOrElse(() => DEFAULT_BOARD_DIR)

  repo =
    parsed.repoUrl
    |> Option.getOrElse(() => "https://github.com/de-angelov/slopboss2.git")
  agentCount = parsed.agents |> Option.getOrElse(() => 2)

  => match normCmd
    | "doctor" => {
      command: "doctor"
      "type": "doctor"
      dir: resolvedDir
      help: parsed.help
    }
    | "run" => {
      command: "run"
      "type": "run"
      dir: resolvedDir
      detach: parsed.detach
      maxTicks: Option.getOrUndefined(parsed.maxTicks)
      pollIntervalMs: Option.getOrUndefined(parsed.pollIntervalMs)
      help: parsed.help
    }
    | "init" => {
      command: "init"
      "type": "init"
      dir: resolvedDir
      repoUrl: repo
      agents: agentCount
      originUrl: Option.getOrUndefined(parsed.originUrl)
      baseBranch: Option.getOrUndefined(parsed.baseBranch)
      provider: Option.getOrUndefined(parsed.provider)
      help: parsed.help
    }
    | "groom" => {
      command: "groom"
      "type": "groom"
      dir: resolvedDir
      model: Option.getOrUndefined(parsed.model)
      help: parsed.help
    }
    | "status" => {
      command: "status"
      "type": "status"
      dir: resolvedDir
      help: parsed.help
    }
    | "view" => {
      command: "view"
      "type": "view"
      dir: resolvedDir
      pollIntervalMs: Option.getOrUndefined(parsed.pollIntervalMs)
      help: parsed.help
    }
    | _ => {
      command: "invalid"
      "type": "invalid"
      "error": "Unknown command: " + first
    }

parseKnownSubcommand = (first: String, subArgs: Array<String>) =>
  parsed = parseTokens(first, subArgs, emptyAcc())
  normCmd = normalizeSubcommand(first)
  => match Option.isSome(parsed.unknownOpt)
    | true => {
      command: "invalid"
      "type": "invalid"
      "error": "Unknown option '" + Option.getOrElse(parsed.unknownOpt, () => "") + "'"
      subcommand: normCmd
    }
    | false => buildParsedSubcommand(normCmd, first, parsed)

parseSubcommandArgs = (first: String, subArgs: Array<String>) =>
  subHelp = subArgs |> Array.get(0)
  isHelpWithSub = first #= "help" and Option.isSome(subHelp)
  isPlainHelp = first #= "help" or first #= "--help" or first #= "-h"
  => match
    | isHelpWithSub => {
      command: "help"
      "type": "help"
      subcommand: Option.getOrElse(subHelp, () => "")
    }
    | isPlainHelp => {
      command: "help"
      "type": "help"
    }
    | first #= "board" => parseBoardCommand(subArgs)
    | first #= "recover" => parseRecoverCommand(subArgs)
    | first #= "coordination" => parseCoordinationCommand(subArgs)
    | not isKnownSubcommand(first) => {
      command: "invalid"
      "type": "invalid"
      "error": "Unknown command: " + first
    }
    | _ => parseKnownSubcommand(first, subArgs)

export parseCliArgs = (argv?: Unknown) =>
  rawArgv = Option.fromNullishOr(argv)
  optVal = Option.flatMap(rawArgv, Schema.decodeUnknownOption(OptSchema))
  directVal = Option.flatMap(rawArgv, Schema.decodeUnknownOption(ArrStrSchema))
  args: Array<String> =
    optVal
    |> Option.flatMap((o) => Schema.decodeUnknownOption(ArrStrSchema)(Option.getOrUndefined(o)))
    |> Option.orElse(() => directVal)
    |> Option.getOrElse(() => [])
  first =
    args
    |> Array.get(0)
    |> Option.getOrElse(() => "")
  subArgs = args |> Array.drop(1)
  => match args.length #= 0
    | true => { command: "help", "type": "help" }
    | false => parseSubcommandArgs(first, subArgs)

parseBoardCommand = (args: Array<String>) =>
  action =
    args
    |> get(0)
    |> Option.getOrElse(() => "")
  rest = args |> drop(1)
  id =
    rest
    |> get(0)
    |> Option.getOrElse(() => "")
  status =
    rest
    |> get(1)
    |> Option.getOrElse(() => "")
  dirOpt =
    rest
    |> findFirstIndex((v) => v #= "--dir")
    |> Option.flatMap((i) => rest |> get(i + 1))
  dir = Option.getOrElse(dirOpt, () => DEFAULT_BOARD_DIR)
  => {
    command: "board"
    "type": "board"
    action: action
    id: id
    status: status
    dir: dir
  }

parseRecoverCommand = (args: Array<String>) =>
  dirOpt =
    args
    |> findFirstIndex((v) => v #= "--dir" or v #= "-d")
    |> Option.flatMap((i) => args |> get(i + 1))
  dir = Option.getOrElse(dirOpt, () =>
    args
    |> get(0)
    |> Option.getOrElse(() => DEFAULT_BOARD_DIR)
  )
  => {
    command: "recover"
    "type": "recover"
    dir: dir
  }

parseCoordinationCommand = (args: Array<String>) =>
  action =
    args
    |> get(0)
    |> Option.getOrElse(() => "")
  rest = args |> drop(1)
  statusAt = rest |> findFirstIndex((v) => v #= "--status")
  summaryAt = rest |> findFirstIndex((v) => v #= "--summary")
  status =
    statusAt
    |> Option.flatMap((i) => rest |> get(i + 1))
    |> getOrElse(() => "")
  summary =
    summaryAt
    |> Option.flatMap((i) => rest |> get(i + 1))
    |> getOrElse(() => "")
  match
    | action #! "report" => {
      command: "invalid"
      "type": "invalid"
      "error": "Usage: slopboss2 coordination report --status <acted|idle|blocked> --summary <text>"
    }
    | status #= "" or summary #= "" => {
      command: "invalid"
      "type": "invalid"
      "error": "coordination report requires --status and --summary"
    }
    | _ => {
      command: "coordination"
      "type": "coordination"
      status: status
      summary: summary
    }

export printStatus = (boardDir: String) => effect {
  store = loadBoardStoreSync(boardDir)
  lanes =
    store.tasksDoc.sections
    |> Array.map((section) => {
      lane = section.name |> String.replace(RegExp("\\s+In Progress$", "i"), "")
      task = section.tasks |> Array.findFirst((t) => t.status #= "In Progress")
      match task
        | Some(t) => lane + " -> [" + t.id + "] " + t.title + " (" + t.status + ")"
        | None => lane + " -> Idle"
    })
  lockPath = boardDir + "/.slopboss-board.lock"
  lockExists <- Effect.promise(() => Bun.file(lockPath).exists())
  controller =
    match lockExists
      | true => "Controller: lock present (PID/session evidence available in " + lockPath + ")"
      | false => "Controller: missing (idle or stopped)"
  cfg <- readRuntimeConfig(boardDir)
  _ <- Console.log("=== SLOPBOSS2 BOARD STATUS ===")
  _ <- Console.log("Board: " + boardDir)
  _ <- Console.log(lanes |> join("\n"))
  _ <- Console.log(controller)
  _ <- Console.log("Fleet: " + cfg.devAgentCount + " dev agents configured, provider " + cfg.provider + ", base branch " + cfg.baseBranch + ".")
  => true
}

export printStatusFun = (boardDir: String) => printStatus(boardDir)

export runSetup = (boardDir: String, repoUrl: String) => effect {
  _ <- Console.log("=== SLOPBOSS2 SETUP ===")
  _ <- Console.log("Board directory: " + boardDir)
  _ <- Console.log("Repository URL:  " + repoUrl)
  _ <- Console.log("Provider:        Antigravity (agy)")
  _ <- Console.log("Dev Agents:      2")
  _ <- initBoardStructure(boardDir, repoUrl, 2)
  _ <- Console.log("Setup complete. Workspaces initialized.")
  => true
}

export runSetupFun = (boardDir: String, repoUrl: String) => runSetup(boardDir, repoUrl)

fallbackSpawnFn = () => Bun.spawn

normalizeModelOption = (model: Unknown): Option<String> =>
  optVal = Schema.decodeUnknownOption(OptSchema)(model)
  => match optVal
    | Some(o) => Option.map(o, (v) => "" + v)
    | None => Option.some("" + model)

resolveModelOption = (modelOpt: Option<Unknown>): Option<String> =>
  Option.flatMap(modelOpt, normalizeModelOption)

readBacklogTextWorkflow = (boardDir: String) => effect {
  fileObj = Bun.file(boardDir + "/BACKLOG.md")
  exists <- Effect.promise(() => fileObj.exists())
  res <- match exists
    | false => Effect.succeed("")
    | true => Effect.promise(() => fileObj.text())
  => res
}

export launchInteractiveGroom = (boardDir: String, model?: Unknown, spawnFn?: Unknown) => effect {
  resolvedModel = resolveModelOption(Option.fromUndefinedOr(model))
  backlogText <- readBacklogTextWorkflow(boardDir)
  prompt = buildGroomPrompt(boardDir, backlogText)
  agyCmd = buildInteractiveCommand(resolvedModel, prompt)
  _ <- Console.log("Starting interactive Team Lead grooming session...")
  _ <- Console.log("Command: " + (agyCmd |> Array.join(" ")))
  spawnFnActual: Unknown = Option.getOrElse(Option.fromUndefinedOr(spawnFn), fallbackSpawnFn)
  spawnOptions = {
    cwd: boardDir
    stdin: "inherit"
    stdout: "inherit"
    stderr: "inherit"
  }
  proc: Unknown = callSpawn(spawnFnActual, agyCmd, spawnOptions)
  exitedOpt =
    getProp(proc, "exited")
    |> Option.flatMap(Schema.decodeUnknownOption(PromiseSchema))
  rawCode <- match exitedOpt
    | Some(p) => Effect.promise(() => p)
    | None => Effect.succeed(0)
  code = Option.getOrElse(Option.fromNullishOr(rawCode), () => 0)
  _ <- Console.log("Team Lead grooming session completed with exit code " + code)
  => code
}

export launchInteractiveGroomFun = (boardDir: String, model?: Unknown, spawnFn?: Unknown) =>
  launchInteractiveGroom(boardDir, model, spawnFn)

export runDoctorCommand = (dir: String) => effect {
  report <- runDoctor(dir)
  table = formatDoctorTable(report)
  _ <- Console.log(table)
  => report
}

fallbackBinPath = () => "src/cli/bin.fun"
fallbackPoll = () => 1000
fallbackIter = () => 0
fallbackMock = () => false
fallbackViewOpts = () => {}

safelyUnrefProcess = (procObj: Unknown, proc: Unknown) =>
  unrefOpt =
    getProp(procObj, "unref")
    |> Option.flatMap(Schema.decodeUnknownOption(FnSchema))
  => Option.map(unrefOpt, (f) => Reflect.apply(f, proc, []))

runReconcilerDetached = (dir: String, rawOptsObj: Unknown) => effect {
  spawnFnActual: Unknown = Option.getOrElse(getProp(rawOptsObj, "spawnFn"), fallbackSpawnFn)
  procArgv = getProcessArgv()
  binPath =
    procArgv
    |> Array.get(1)
    |> Option.getOrElse(fallbackBinPath)
  execPath = getProcessExecPath()
  execArgs = [execPath, "run", binPath, "run", "--dir", dir]
  spawnOpts = {
    detached: true
    stdio: ["ignore", "ignore", "ignore"]
  }
  proc: Unknown = callSpawn(spawnFnActual, execArgs, spawnOpts)
  _unused = safelyUnrefProcess(proc, proc)
  procPid: Unknown = Option.getOrUndefined(getProp(proc, "pid"))
  _ <- Console.log("[SLOPBOSS2] Started reconciler daemon in background (PID: " + ("" + procPid) + ")")
  => { detached: true, pid: procPid }
}

runReconcilerForeground = (dir: String, rawOptsObj: Unknown, maxTicks?: Number, pollIntervalMs?: Number) => effect {
  _ <- Console.log("[SLOPBOSS2] Starting dispatcher reconciler loop for board: " + dir)
  rawOptsPoll = getProp(rawOptsObj, "pollIntervalMs")
  pollVal =
    Option.fromUndefinedOr(pollIntervalMs)
    |> Option.orElse(() => rawOptsPoll)
    |> Option.flatMap((p) => Number.parse("" + p))
    |> Option.getOrElse(() => 1000)

  rawOptsIter = getProp(rawOptsObj, "maxIterations")
  iterVal =
    Option.fromUndefinedOr(maxTicks)
    |> Option.orElse(() => rawOptsIter)
    |> Option.flatMap((m) => Number.parse("" + m))
    |> Option.getOrElse(() => 0)

  mockOpt = getProp(rawOptsObj, "mockRunner") |> Option.map((m) => m #= true)

  runnerOpt: Option<Unknown> = getProp(rawOptsObj, "runnerFn")

  persisted <- readRuntimeConfig(dir)
  config: ReconcilerConfig = {
    boardDir: dir
    pollIntervalMs: pollVal
    maxIterations: iterVal
    devAgentCount: persisted.devAgentCount
    baseBranch: Option.some(persisted.baseBranch)
    provider: Option.some(persisted.provider)
    mockRunner: mockOpt
    runnerFn: runnerOpt
    mergeQueue: Option.none()
  }
  r <- runReconcilerLoop(config)
  => r
}

export runReconcilerCommand = (dir: String, detach: Boolean = false, options?: Unknown, maxTicks?: Number, pollIntervalMs?: Number) =>
  rawOpts: Unknown = Option.getOrElse(Option.fromUndefinedOr(options), fallbackViewOpts)
  rawOptsObj: Unknown = rawOpts
  => match detach
    | true => runReconcilerDetached(dir, rawOptsObj)
    | false => runReconcilerForeground(dir, rawOptsObj, maxTicks, pollIntervalMs)

export runInitCommand = (dir: String, repoUrl: String = "https://github.com/de-angelov/slopboss2.git", agents: Number = 2, originUrl: String = "", baseBranch: String = "main", provider: String = "agy") => effect {
  _ <- Console.log("=== SLOPBOSS2 INIT ===")
  _ <- Console.log("Board directory: " + dir)
  _ <- Console.log("Repository URL:  " + repoUrl)
  _ <- Console.log("Dev Agents:      " + agents)
  _ <- match agents < 1
    | true => Effect.fail(CliCommandError({ message: "--agents must be a positive number" }))
    | false => Effect.void
  _ <- match provider #! "agy" and provider #! "gemini"
    | true => Effect.fail(CliCommandError({ message: "--provider must be agy or gemini" }))
    | false => Effect.void
  res <- initBoardStructure(dir, repoUrl, agents, originUrl, baseBranch, provider)
  _ <- Console.log("Initialization complete. Workspaces and board ready.")
  => res
}

export runGroomCommand = (dir: String, model?: String, options?: Unknown) => effect {
  rawOpts: Unknown = Option.getOrElse(Option.fromUndefinedOr(options), fallbackViewOpts)
  spawnFnOpt: Unknown = Option.getOrUndefined(getProp(rawOpts, "spawnFn"))
  res <- launchInteractiveGroom(dir, model, spawnFnOpt)
  => res
}

export runViewCommand = (dir: String, pollIntervalMs: Number = 1000, options: LiveViewOptions = defaultLiveViewOptions) =>
  runLiveView(dir, pollIntervalMs, options)

export runViewCommandFun = (boardDir: String, pollMs: Number = 1000, options: LiveViewOptions = defaultLiveViewOptions) =>
  runViewCommand(boardDir, pollMs, options)

export runControlLoop = (boardDir: String, maxTicks: Number = 3) => effect {
  _ <- Console.log("Starting Slopboss2 control loop (provider: agy, dev-agents: 2)...")
  config: ReconcilerConfig = {
    boardDir: boardDir
    pollIntervalMs: 100
    maxIterations: maxTicks
    devAgentCount: 2
    baseBranch: Option.none()
    provider: Option.none()
    mockRunner: Option.none()
    runnerFn: Option.none()
    mergeQueue: Option.none()
  }
  res <- runReconcilerLoop(config)
  => res
}

export runControlLoopFun = (boardDir: String, maxTicks: Number = 3) =>
  runControlLoop(boardDir, maxTicks)

failUnknownCommand = (cmdName: String) => effect {
  _ <- Effect.fail(CliCommandError({ message: "Unknown command: " + cmdName }))
  => Option.none()
}

handleHelp = (cmd: Unknown) => effect {
  rawCmd = getPropStr(cmd, "command")
  subStr =
    match rawCmd #= "help"
      | true => getProp(cmd, "subcommand")
      |> Option.map((s) => "" + s)
      |> Option.getOrUndefined
      | false => rawCmd
  helpMsg = getHelpMessage(subStr)
  _ <- Console.log(helpMsg)
  => { help: true, output: helpMsg }
}

handleInvalid = (cmd: Unknown) => effect {
  errText =
    getProp(cmd, "error")
    |> Option.map((e) => "" + e)
    |> Option.getOrElse(() => "Unknown error")
  errMsg = "Error: " + errText
  _ <- Console.error(errMsg)
  subOpt = getProp(cmd, "subcommand") |> Option.map((s) => "" + s)
  _ <- Console.log(getHelpMessage(Option.getOrUndefined(subOpt)))
  _ <- Effect.fail(CliCommandError({ message: errText }))
  => { help: false, output: errMsg }
}

runViewCommandWithOpts = (cmd: Unknown, options?: Unknown) =>
  rawOpts: Unknown = Option.getOrElse(Option.fromUndefinedOr(options), fallbackViewOpts)
  dirStr =
    getProp(cmd, "dir")
    |> Option.map((d) => "" + d)
    |> Option.getOrElse(() => DEFAULT_BOARD_DIR)
  rawCmdPoll = getProp(cmd, "pollIntervalMs")
  rawOptsPoll = getProp(rawOpts, "pollIntervalMs")
  pollValNum =
    rawCmdPoll
    |> Option.orElse(() => rawOptsPoll)
    |> Option.flatMap((p) => Number.parse("" + p))
    |> Option.getOrElse(() => 1000)
  viewOpts: LiveViewOptions =
    getProp(rawOpts, "viewOptions")
    |> Option.flatMap(Schema.decodeUnknownOption(LiveViewOptions))
    |> Option.getOrElse(() => defaultLiveViewOptions)
  => runViewCommand(dirStr, pollValNum, viewOpts)

resolveDispatchAction = (rawCmd: String, rawHelp: Boolean): String =>
  match rawCmd #= "help" or rawHelp
    | true => "help"
    | false => rawCmd

export dispatchCli = (cmd: Unknown, options?: Unknown) =>
  rawCmd = getPropStr(cmd, "command")
  rawHelp =
    getProp(cmd, "help")
    |> Option.map((h) => h #= true)
    |> Option.getOrElse(() => false)
  dispatchAction = resolveDispatchAction(rawCmd, rawHelp)

  rawOptions: Unknown = Option.getOrElse(Option.fromUndefinedOr(options), fallbackViewOpts)
  dirStr =
    getProp(cmd, "dir")
    |> Option.map((d) => "" + d)
    |> Option.getOrElse(() => DEFAULT_BOARD_DIR)
  modelOpt = getProp(cmd, "model") |> Option.map((m) => "" + m)
  rawDetach =
    getProp(cmd, "detach")
    |> Option.map((d) => d #= true)
    |> Option.getOrElse(() => false)
  maxTicksOpt =
    getProp(cmd, "maxTicks")
    |> Option.flatMap((m) => Number.parse("" + m))
  pollOpt =
    getProp(cmd, "pollIntervalMs")
    |> Option.flatMap((p) => Number.parse("" + p))
  repoStr =
    getProp(cmd, "repoUrl")
    |> Option.map((r) => "" + r)
    |> Option.getOrElse(() => "https://github.com/de-angelov/slopboss2.git")
  agentsNum =
    getProp(cmd, "agents")
    |> Option.flatMap((a) => Number.parse("" + a))
    |> Option.getOrElse(() => 2)
  originUrl = getPropStr(cmd, "originUrl")
  baseBranch =
    getProp(cmd, "baseBranch")
    |> Option.map((v) => "" + v)
    |> Option.getOrElse(() => "main")
  provider =
    getProp(cmd, "provider")
    |> Option.map((v) => "" + v)
    |> Option.getOrElse(() => "agy")

  => match dispatchAction
    | "board" => dispatchBoardCommand(cmd, dirStr)
    | "recover" => acquireBoardLock(dirStr).pipe(Effect.scoped)
    | "coordination" => dispatchCoordinationCommand(cmd)
    | "help" => handleHelp(cmd)
    | "invalid" => handleInvalid(cmd)
    | "doctor" => runDoctorCommand(dirStr)
    | "run" => runReconcilerCommand(dirStr, rawDetach, rawOptions, Option.getOrUndefined(maxTicksOpt), Option.getOrUndefined(pollOpt))
    | "init" => runInitCommand(dirStr, repoStr, agentsNum, originUrl, baseBranch, provider)
    | "groom" => runGroomCommand(dirStr, Option.getOrUndefined(modelOpt), rawOptions)
    | "status" => printStatus(dirStr)
    | "view" => runViewCommandWithOpts(cmd, rawOptions)
    | _ => failUnknownCommand(rawCmd)

dispatchCoordinationCommand = (cmd: Unknown) =>
  reportPath = getEnvVar("SLOPBOSS_COORDINATION_REPORT") |> Option.getOrElse(() => "")
  report = {
    status: getPropStr(cmd, "status")
    summary: getPropStr(cmd, "summary")
  }
  => writeCoordinationReport(reportPath, report)

dispatchBoardCommand = (cmd: Unknown, dir: String) => effect {
  action = getPropStr(cmd, "action")
  id = getPropStr(cmd, "id")
  status = getPropStr(cmd, "status")
  result <- match action
    | "get" => boardGet(dir, id)
    | "list" => boardList(dir)
    | "set" => boardSet(dir, id, status)
    | _ => Effect.fail(CliCommandError({
      message: "Usage: slopboss2 board <get <id>|list|set <id> <status>>"
    }))
  => result
}

boardGet = (dir: String, id: String) => effect {
  task = findTask(loadBoardStoreSync(dir), id)
  _ <- Console.log(Option.match(task, {
    onNone: () => "Task not found: " + id
    onSome: (t) => t.rawBody
  }))
  => task
}

boardList = (dir: String) => effect {
  tasks =
    loadBoardStoreSync(dir).tasksDoc.sections
    |> Array.flatMap((section) => section.tasks)
  _ <- Console.log(tasks
  |> map((t) => t.id + "  " + t.title + " (" + t.status + ")")
  |> join("\n"))
  => tasks
}

boardSet = (dir: String, id: String, status: String) => effect {
  updated: Unknown = updateTaskStatus(loadBoardStoreSync(dir), id, status)
  _ <- Console.log("Updated " + id + " to " + status)
  => updated
}

export runCli = (argv?: Array<String>, options?: Unknown) =>
  fallbackArgs = getProcessArgv() |> Array.drop(2)
  args = Option.getOrElse(Option.fromUndefinedOr(argv), () => fallbackArgs)
  parsed = parseCliArgs(args)
  opts: Unknown = options
  => dispatchCli(parsed, opts)

export runCliFun = () => runCli()
