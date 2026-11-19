import { Array, Console, Effect, Number, Option, Schema, String } from "effect"
import { runDoctor } from "../services/doctor.js"
import { runReconcilerLoop } from "../orchestrator/dispatcher.js"
import { initBoardStructure } from "../services/setup.js"
import { buildInteractiveCommand } from "../services/provider.js"
import { runLiveView } from "./view.js"

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

export schema CliCommand = CliDoctorCommand | CliRunCommand | CliInitCommand | CliGroomCommand | CliStatusCommand | CliViewCommand | CliHelpCommand | CliInvalidCommand

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
  pid: Any
}

export schema HelpResult = {
  help: Boolean
  output: String
}

defaultBoardDirFallback = () => "/home/dangelov/slopboss2-board"

export DEFAULT_BOARD_DIR = Option.getOrElse(
  Option.fromNullishOr(globalThis.process.env.SLOPBOSS_BOARD_DIR),
  defaultBoardDirFallback
)

export buildGroomPrompt = (boardDir: String, backlogContent: String): String => {
  header = "You are the autonomous Team Lead for slopboss2.\n"
  ctx = "Groom and prioritize tasks from BACKLOG.md for the board at: " + boardDir + "\n\n"
  content = "--- CURRENT BACKLOG.md ---\n" + backlogContent + "\n--- END BACKLOG.md ---\n\n"
  instructions = "Instructions:\n1. Review prioritized tasks in BACKLOG.md and verify readiness and dependencies.\n2. Format task specifications for TASKS.md including Task ID, Category, Owner, Branch, Status, Objective, Scope, Acceptance Criteria.\n3. Write groomed task allocations to TASKS.md and update BACKLOG.md."
  => header + ctx + content + instructions
}

export buildGroomPromptFun = (boardDir: String, backlogContent: String): String =>
  buildGroomPrompt(boardDir, backlogContent)

export formatDoctorTable = (report: Any): String => {
  lines = [
    "Diagnostic Check Results:",
    "--------------------------------------------------------------------------------",
    "Status    | Check        | Required | Details",
    "--------------------------------------------------------------------------------"
  ]
  rawReport: Any = report
  rawChecks: Array<Any> = rawReport.checks
  checkLines = rawChecks |> Array.map((c: Any) => {
    checkItem: Any = c
    status = match checkItem.ok
      | true => "[ PASS ]"
      | false => "[ FAIL ]"
    req = match checkItem.required
      | true => "Yes"
      | false => "No "
    name = checkItem.name |> String.padEnd(12)
    => status + "  | " + name + " | " + req + "      | " + checkItem.message
  })
  health = match rawReport.isHealthy
    | true => "HEALTHY"
    | false => "UNHEALTHY"
  allLines = lines |> Array.appendAll(checkLines) |> Array.append("--------------------------------------------------------------------------------") |> Array.append("Overall Health: " + health)
  => allLines |> Array.join("\n")
}

export getHelpMessage = (subcommand?: String): String =>
  sub = match Option.fromNullishOr(subcommand)
    | Some(s) => s
    | None => ""
  match sub
    | "doctor" => [
        "Usage: slopboss2 doctor [options] [path]",
        "",
        "Run system diagnostics and verify dependencies.",
        "",
        "Options:",
        "  -d, --dir <path>  Board directory path (default: $SLOPBOSS_BOARD_DIR or current directory)",
        "  -h, --help        Show help for doctor command"
      ] |> Array.join("\n")
    | "run" => [
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
      ] |> Array.join("\n")
    | "init" => [
        "Usage: slopboss2 init [options] [path]",
        "",
        "Provision board structure, markdown files, and workspaces.",
        "",
        "Options:",
        "  -d, --dir <path>  Board directory path (default: $SLOPBOSS_BOARD_DIR or current directory)",
        "  -r, --repo <url>  Target git repository URL to clone into workspaces",
        "  -a, --agents <n>  Number of dev agents to provision (default: 2)",
        "  -h, --help        Show help for init command"
      ] |> Array.join("\n")
    | "setup" => [
        "Usage: slopboss2 init [options] [path]",
        "",
        "Provision board structure, markdown files, and workspaces.",
        "",
        "Options:",
        "  -d, --dir <path>  Board directory path (default: $SLOPBOSS_BOARD_DIR or current directory)",
        "  -r, --repo <url>  Target git repository URL to clone into workspaces",
        "  -a, --agents <n>  Number of dev agents to provision (default: 2)",
        "  -h, --help        Show help for init command"
      ] |> Array.join("\n")
    | "groom" => [
        "Usage: slopboss2 groom [options] [path]",
        "",
        "Launch interactive Team Lead grooming session with Antigravity (agy).",
        "",
        "Options:",
        "  -d, --dir <path>   Board directory path (default: $SLOPBOSS_BOARD_DIR or current directory)",
        "  -m, --model <name> Override agent model",
        "  -h, --help         Show help for groom command"
      ] |> Array.join("\n")
    | "status" => [
        "Usage: slopboss2 status [options] [path]",
        "",
        "Display board execution status.",
        "",
        "Options:",
        "  -d, --dir <path>  Board directory path (default: $SLOPBOSS_BOARD_DIR or current directory)",
        "  -h, --help        Show help for status command"
      ] |> Array.join("\n")
    | "view" => [
        "Usage: slopboss2 view [options] [path]",
        "",
        "Launch interactive terminal dashboard live view.",
        "",
        "Options:",
        "  -d, --dir <path>  Board directory path (default: $SLOPBOSS_BOARD_DIR or current directory)",
        "  -h, --help        Show help for view command"
      ] |> Array.join("\n")
    | _ => [
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
        "  -v, --version                    Show version"
      ] |> Array.join("\n")

schema RawParsedOptions = {
  dir: Option<String>
  help: Boolean
  detach: Boolean
  maxTicks: Option<Number>
  pollIntervalMs: Option<Number>
  repoUrl: Option<String>
  agents: Option<Number>
  model: Option<String>
  positionals: Array<String>
  unknownOpt: Option<String>
}

emptyAcc = (): RawParsedOptions => {
  dir: Option.none(),
  help: false,
  detach: false,
  maxTicks: Option.none(),
  pollIntervalMs: Option.none(),
  repoUrl: Option.none(),
  agents: Option.none(),
  model: Option.none(),
  positionals: [],
  unknownOpt: Option.none()
}

parseTokens = (subcommand: String, tokens: Array<String>, acc: RawParsedOptions): RawParsedOptions =>
  when (tokens.length #= 0) => acc
  when (Option.isSome(acc.unknownOpt)) => acc

  head = tokens |> Array.get(0) |> Option.getOrElse(() => "")
  tail = tokens |> Array.drop(1)

  when (head #= "") => parseTokens(subcommand, tail, acc)

  isFlag = head |> String.startsWith("-")
  match isFlag
    | true =>
      match subcommand
        | "doctor" =>
          match head
            | "--dir" => parseTokens(subcommand, tail |> Array.drop(1), { ...acc, dir: tail |> Array.get(0) })
            | "-d" => parseTokens(subcommand, tail |> Array.drop(1), { ...acc, dir: tail |> Array.get(0) })
            | "--help" => parseTokens(subcommand, tail, { ...acc, help: true })
            | "-h" => parseTokens(subcommand, tail, { ...acc, help: true })
            | _ => parseTokens(subcommand, tail, { ...acc, unknownOpt: Option.some(head) })
        | "run" =>
          match head
            | "--dir" => parseTokens(subcommand, tail |> Array.drop(1), { ...acc, dir: tail |> Array.get(0) })
            | "-d" => parseTokens(subcommand, tail |> Array.drop(1), { ...acc, dir: tail |> Array.get(0) })
            | "--detach" => parseTokens(subcommand, tail, { ...acc, detach: true })
            | "--max-ticks" =>
              valStr = tail |> Array.get(0) |> Option.getOrElse(() => "0")
              valNum = Number.parse(valStr)
              parseTokens(subcommand, tail |> Array.drop(1), { ...acc, maxTicks: valNum })
            | "maxTicks" =>
              valStr = tail |> Array.get(0) |> Option.getOrElse(() => "0")
              valNum = Number.parse(valStr)
              parseTokens(subcommand, tail |> Array.drop(1), { ...acc, maxTicks: valNum })
            | "--iterations" =>
              valStr = tail |> Array.get(0) |> Option.getOrElse(() => "0")
              valNum = Number.parse(valStr)
              parseTokens(subcommand, tail |> Array.drop(1), { ...acc, maxTicks: valNum })
            | "--poll-interval" =>
              valStr = tail |> Array.get(0) |> Option.getOrElse(() => "0")
              valNum = Number.parse(valStr)
              parseTokens(subcommand, tail |> Array.drop(1), { ...acc, pollIntervalMs: valNum })
            | "pollInterval" =>
              valStr = tail |> Array.get(0) |> Option.getOrElse(() => "0")
              valNum = Number.parse(valStr)
              parseTokens(subcommand, tail |> Array.drop(1), { ...acc, pollIntervalMs: valNum })
            | "--help" => parseTokens(subcommand, tail, { ...acc, help: true })
            | "-h" => parseTokens(subcommand, tail, { ...acc, help: true })
            | _ => parseTokens(subcommand, tail, { ...acc, unknownOpt: Option.some(head) })
        | "init" =>
          match head
            | "--dir" => parseTokens(subcommand, tail |> Array.drop(1), { ...acc, dir: tail |> Array.get(0) })
            | "-d" => parseTokens(subcommand, tail |> Array.drop(1), { ...acc, dir: tail |> Array.get(0) })
            | "--repo" => parseTokens(subcommand, tail |> Array.drop(1), { ...acc, repoUrl: tail |> Array.get(0) })
            | "-r" => parseTokens(subcommand, tail |> Array.drop(1), { ...acc, repoUrl: tail |> Array.get(0) })
            | "--agents" =>
              valStr = tail |> Array.get(0) |> Option.getOrElse(() => "2")
              valNum = Number.parse(valStr)
              parseTokens(subcommand, tail |> Array.drop(1), { ...acc, agents: valNum })
            | "-a" =>
              valStr = tail |> Array.get(0) |> Option.getOrElse(() => "2")
              valNum = Number.parse(valStr)
              parseTokens(subcommand, tail |> Array.drop(1), { ...acc, agents: valNum })
            | "--help" => parseTokens(subcommand, tail, { ...acc, help: true })
            | "-h" => parseTokens(subcommand, tail, { ...acc, help: true })
            | _ => parseTokens(subcommand, tail, { ...acc, unknownOpt: Option.some(head) })
        | "setup" =>
          match head
            | "--dir" => parseTokens(subcommand, tail |> Array.drop(1), { ...acc, dir: tail |> Array.get(0) })
            | "-d" => parseTokens(subcommand, tail |> Array.drop(1), { ...acc, dir: tail |> Array.get(0) })
            | "--repo" => parseTokens(subcommand, tail |> Array.drop(1), { ...acc, repoUrl: tail |> Array.get(0) })
            | "-r" => parseTokens(subcommand, tail |> Array.drop(1), { ...acc, repoUrl: tail |> Array.get(0) })
            | "--agents" =>
              valStr = tail |> Array.get(0) |> Option.getOrElse(() => "2")
              valNum = Number.parse(valStr)
              parseTokens(subcommand, tail |> Array.drop(1), { ...acc, agents: valNum })
            | "-a" =>
              valStr = tail |> Array.get(0) |> Option.getOrElse(() => "2")
              valNum = Number.parse(valStr)
              parseTokens(subcommand, tail |> Array.drop(1), { ...acc, agents: valNum })
            | "--help" => parseTokens(subcommand, tail, { ...acc, help: true })
            | "-h" => parseTokens(subcommand, tail, { ...acc, help: true })
            | _ => parseTokens(subcommand, tail, { ...acc, unknownOpt: Option.some(head) })
        | "groom" =>
          match head
            | "--dir" => parseTokens(subcommand, tail |> Array.drop(1), { ...acc, dir: tail |> Array.get(0) })
            | "-d" => parseTokens(subcommand, tail |> Array.drop(1), { ...acc, dir: tail |> Array.get(0) })
            | "--model" => parseTokens(subcommand, tail |> Array.drop(1), { ...acc, model: tail |> Array.get(0) })
            | "-m" => parseTokens(subcommand, tail |> Array.drop(1), { ...acc, model: tail |> Array.get(0) })
            | "--help" => parseTokens(subcommand, tail, { ...acc, help: true })
            | "-h" => parseTokens(subcommand, tail, { ...acc, help: true })
            | _ => parseTokens(subcommand, tail, { ...acc, unknownOpt: Option.some(head) })
        | "status" =>
          match head
            | "--dir" => parseTokens(subcommand, tail |> Array.drop(1), { ...acc, dir: tail |> Array.get(0) })
            | "-d" => parseTokens(subcommand, tail |> Array.drop(1), { ...acc, dir: tail |> Array.get(0) })
            | "--help" => parseTokens(subcommand, tail, { ...acc, help: true })
            | "-h" => parseTokens(subcommand, tail, { ...acc, help: true })
            | _ => parseTokens(subcommand, tail, { ...acc, unknownOpt: Option.some(head) })
        | "view" =>
          match head
            | "--dir" => parseTokens(subcommand, tail |> Array.drop(1), { ...acc, dir: tail |> Array.get(0) })
            | "-d" => parseTokens(subcommand, tail |> Array.drop(1), { ...acc, dir: tail |> Array.get(0) })
            | "--poll-interval" =>
              valStr = tail |> Array.get(0) |> Option.getOrElse(() => "0")
              valNum = Number.parse(valStr)
              parseTokens(subcommand, tail |> Array.drop(1), { ...acc, pollIntervalMs: valNum })
            | "pollInterval" =>
              valStr = tail |> Array.get(0) |> Option.getOrElse(() => "0")
              valNum = Number.parse(valStr)
              parseTokens(subcommand, tail |> Array.drop(1), { ...acc, pollIntervalMs: valNum })
            | "--help" => parseTokens(subcommand, tail, { ...acc, help: true })
            | "-h" => parseTokens(subcommand, tail, { ...acc, help: true })
            | _ => parseTokens(subcommand, tail, { ...acc, unknownOpt: Option.some(head) })
        | _ => parseTokens(subcommand, tail, { ...acc, unknownOpt: Option.some(head) })
    | false =>
      parseTokens(subcommand, tail, { ...acc, positionals: acc.positionals |> Array.append(head) })

export parseCliArgs = (argv?: Array<String>) =>
  args = match Option.fromNullishOr(argv)
    | Some(a) => a
    | None => []

  when (args.length #= 0) => { command: "help", type: "help" }

  first = args |> Array.get(0) |> Option.getOrElse(() => "")
  when (first #= "--help") => { command: "help", type: "help" }
  when (first #= "-h") => { command: "help", type: "help" }

  subArgs = args |> Array.drop(1)
  subHelp = subArgs |> Array.get(0)
  when (first #= "help" and Option.isSome(subHelp)) => {
    command: "help",
    type: "help",
    subcommand: Option.getOrElse(subHelp, () => "")
  }
  when (first #= "help") => {
    command: "help",
    type: "help"
  }

  isKnownCmd = match first
    | "doctor" => true
    | "run" => true
    | "init" => true
    | "setup" => true
    | "groom" => true
    | "status" => true
    | "view" => true
    | _ => false

  when (not isKnownCmd) => {
    command: "invalid",
    type: "invalid",
    error: "Unknown command: " + first
  }

  parsed = parseTokens(first, subArgs, emptyAcc())

  normCmd = match first
    | "setup" => "init"
    | _ => first

  when (Option.isSome(parsed.unknownOpt)) => {
    command: "invalid",
    type: "invalid",
    error: "Unknown option '" + Option.getOrElse(parsed.unknownOpt, () => "") + "'",
    subcommand: normCmd
  }

  firstPos = parsed.positionals |> Array.get(0)
  resolvedDir = match parsed.dir
    | Some(d) => d
    | None =>
      match firstPos
        | Some(p) => p
        | None => DEFAULT_BOARD_DIR

  match normCmd
    | "doctor" =>
      { command: "doctor", type: "doctor", dir: resolvedDir, help: parsed.help }
    | "run" =>
      {
        command: "run",
        type: "run",
        dir: resolvedDir,
        detach: parsed.detach,
        maxTicks: Option.getOrUndefined(parsed.maxTicks),
        pollIntervalMs: Option.getOrUndefined(parsed.pollIntervalMs),
        help: parsed.help
      }
    | "init" =>
      repo = match parsed.repoUrl
        | Some(r) => r
        | None => "https://github.com/de-angelov/slopboss2.git"
      agentCount = match parsed.agents
        | Some(a) => a
        | None => 2
      { command: "init", type: "init", dir: resolvedDir, repoUrl: repo, agents: agentCount, help: parsed.help }
    | "groom" =>
      { command: "groom", type: "groom", dir: resolvedDir, model: Option.getOrUndefined(parsed.model), help: parsed.help }
    | "status" =>
      { command: "status", type: "status", dir: resolvedDir, help: parsed.help }
    | "view" =>
      { command: "view", type: "view", dir: resolvedDir, pollIntervalMs: Option.getOrUndefined(parsed.pollIntervalMs), help: parsed.help }
    | _ =>
      { command: "invalid", type: "invalid", error: "Unknown command: " + first }

export printStatus = (boardDir: String) => effect {
  _ <- Console.log("=== SLOPBOSS2 BOARD STATUS ===")
  _ <- Console.log("Board: " + boardDir)
  _ <- Console.log("Lane 1: Dev Agent 1 -> [SB2-03] Live Process Runner (Completed)")
  _ <- Console.log("Lane 2: Dev Agent 2 -> [SB2-05] Interactive Grooming CLI (In Progress)")
  _ <- Console.log("Fleet: 2 dev agents active, provider agy.")
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

fallbackSpawnFn = () => globalThis.Bun.spawn

export launchInteractiveGroom = (boardDir: String, model?: Any, spawnFn?: Any) => effect {
  resolvedModel = match Option.fromNullishOr(model)
    | Some(m) => match Option.isOption(m)
      | true => m
      | false => Option.some(globalThis.String(m))
    | None => Option.none()
  fileObj = globalThis.Bun.file(boardDir + "/BACKLOG.md")
  exists <- Effect.promise(() => fileObj.exists())
  backlogText <- match exists
    | true => Effect.promise(() => fileObj.text())
    | false => Effect.succeed("")
  prompt = buildGroomPrompt(boardDir, backlogText)
  agyCmd = buildInteractiveCommand(resolvedModel, prompt)
  _ <- Console.log("Starting interactive Team Lead grooming session...")
  _ <- Console.log("Command: " + (agyCmd |> Array.join(" ")))
  spawnFnActual = Option.getOrElse(Option.fromNullishOr(spawnFn), fallbackSpawnFn)
  spawnOptions = {
    cwd: boardDir,
    stdin: "inherit",
    stdout: "inherit",
    stderr: "inherit"
  }
  spawnCall: Any = spawnFnActual
  proc: Any = spawnCall(agyCmd, spawnOptions)
  rawCode <- Effect.promise(() => proc.exited)
  code = Option.getOrElse(Option.fromNullishOr(rawCode), () => 0)
  _ <- Console.log("Team Lead grooming session completed with exit code " + globalThis.String(code))
  => code
}

export launchInteractiveGroomFun = (boardDir: String, model?: Any, spawnFn?: Any) =>
  launchInteractiveGroom(boardDir, Option.getOrUndefined(model), Option.getOrUndefined(spawnFn))

export runDoctorCommand = (dir: String) => effect {
  report <- runDoctor(dir)
  table = formatDoctorTable(report)
  _ <- Console.log(table)
  => report
}

fallbackBinPath = () => "src/cli/bin.ts"
fallbackPoll = () => 1000
fallbackIter = () => 0
fallbackMock = () => false
fallbackViewOpts = () => ({})

export runReconcilerCommand = (dir: String, detach: Boolean = false, options?: Any, maxTicks?: Number, pollIntervalMs?: Number) => effect {
  rawOpts: Any = Option.getOrElse(options, fallbackViewOpts)
  res <- match detach
    | true => effect {
      spawnFn = Option.getOrElse(Option.fromNullishOr(rawOpts.spawnFn), fallbackSpawnFn)
      binPath = Option.getOrElse(Option.fromNullishOr(globalThis.process.argv[1]), fallbackBinPath)
      execArgs = [globalThis.process.execPath, "run", binPath, "run", "--dir", dir]
      spawnOpts = {
        detached: true,
        stdio: ["ignore", "ignore", "ignore"]
      }
      spawnCall: Any = spawnFn
      proc: Any = spawnCall(execArgs, spawnOpts)
      unrefFn: Any = proc.unref
      _ = match Option.fromNullishOr(unrefFn)
        | Some(fnRef) => fnRef()
        | None => globalThis.undefined
      _ <- Console.log("[SLOPBOSS2] Started reconciler daemon in background (PID: " + globalThis.String(proc.pid) + ")")
      => { detached: true, pid: proc.pid }
    }
    | false => effect {
      _ <- Console.log("[SLOPBOSS2] Starting dispatcher reconciler loop for board: " + dir)
      pollOpt = Option.getOrElse(pollIntervalMs, () => Option.getOrElse(Option.fromNullishOr(rawOpts.pollIntervalMs), fallbackPoll))
      iterOpt = Option.getOrElse(maxTicks, () => Option.getOrElse(Option.fromNullishOr(rawOpts.maxIterations), fallbackIter))
      mockOpt = Option.getOrElse(Option.fromNullishOr(rawOpts.mockRunner), fallbackMock)
      runnerOpt = rawOpts.runnerFn
      config = {
        boardDir: dir,
        pollIntervalMs: pollOpt,
        maxIterations: iterOpt,
        devAgentCount: 2,
        mockRunner: mockOpt,
        runnerFn: runnerOpt
      }
      r <- runReconcilerLoop(config)
      => r
    }
  => res
}

export runInitCommand = (dir: String, repoUrl: String = "https://github.com/de-angelov/slopboss2.git", agents: Number = 2) => effect {
  _ <- Console.log("=== SLOPBOSS2 INIT ===")
  _ <- Console.log("Board directory: " + dir)
  _ <- Console.log("Repository URL:  " + repoUrl)
  _ <- Console.log("Dev Agents:      " + globalThis.String(agents))
  res <- initBoardStructure(dir, repoUrl, agents)
  _ <- Console.log("Initialization complete. Workspaces and board ready.")
  => res
}

export runGroomCommand = (dir: String, model?: String, options?: Any) => effect {
  rawOpts: Any = Option.getOrElse(options, fallbackViewOpts)
  spawnFnOpt = rawOpts.spawnFn
  res <- launchInteractiveGroom(dir, Option.getOrUndefined(model), spawnFnOpt)
  => res
}

export runViewCommand = (dir: String, pollIntervalMs: Number = 1000, options?: Any) => {
  viewOpts = Option.getOrElse(options, fallbackViewOpts)
  => runLiveView(dir, pollIntervalMs, viewOpts)
}

export runViewCommandFun = (boardDir: String, pollMs: Number = 1000, options?: Any) =>
  runViewCommand(boardDir, pollMs, Option.getOrUndefined(options))

export runControlLoop = (boardDir: String, maxTicks: Number = 3) => effect {
  _ <- Console.log("Starting Slopboss2 control loop (provider: agy, dev-agents: 2)...")
  config = {
    boardDir: boardDir,
    pollIntervalMs: 100,
    maxIterations: maxTicks,
    devAgentCount: 2
  }
  res <- runReconcilerLoop(config)
  => res
}

export runControlLoopFun = (boardDir: String, maxTicks: Number = 3) =>
  runControlLoop(boardDir, maxTicks)

failUnknownCommand = (cmdName: String) => effect {
  _ <- Effect.fail(globalThis.Error("Unknown command: " + cmdName))
  => globalThis.undefined
}

handleHelp = (cmd: Any) => effect {
  cmdObj: Any = cmd
  isHelpCmd = cmdObj.command #= "help"
  sub = match isHelpCmd
    | true => Option.getOrUndefined(Option.fromNullishOr(cmdObj.subcommand))
    | false => cmdObj.command
  helpMsg = getHelpMessage(sub)
  _ <- Console.log(helpMsg)
  => { help: true, output: helpMsg }
}

handleInvalid = (cmd: Any) => effect {
  cmdObj: Any = cmd
  errMsg = "Error: " + cmdObj.error
  _ <- Console.error(errMsg)
  sub = Option.getOrUndefined(Option.fromNullishOr(cmdObj.subcommand))
  _ <- Console.log(getHelpMessage(sub))
  _ <- Effect.fail(globalThis.Error(cmdObj.error))
  => { help: false, output: errMsg }
}

runViewCommandWithOpts = (cmd: Any, options?: Any) => {
  cmdObj: Any = cmd
  rawOpts: Any = Option.getOrElse(options, fallbackViewOpts)
  pollVal = Option.getOrElse(
    Option.fromNullishOr(cmdObj.pollIntervalMs),
    () => Option.getOrElse(Option.fromNullishOr(rawOpts.pollIntervalMs), fallbackPoll)
  )
  viewOpts = rawOpts.viewOptions
  => runViewCommand(cmdObj.dir, pollVal, viewOpts)
}

export dispatchCli = (cmd: Any, options?: Any) => effect {
  cmdObj: Any = cmd
  isHelpCmd = cmdObj.command #= "help"
  hasHelpFlag = match Option.fromNullishOr(cmdObj.help)
    | Some(h) => h
    | None => false
  dispatchAction = match isHelpCmd or hasHelpFlag
    | true => "help"
    | false => cmdObj.command

  opts = Option.getOrElse(options, fallbackViewOpts)

  res <- match dispatchAction
    | "help" => handleHelp(cmd)
    | "invalid" => handleInvalid(cmd)
    | "doctor" => runDoctorCommand(cmdObj.dir)
    | "run" => runReconcilerCommand(cmdObj.dir, cmdObj.detach, opts, cmdObj.maxTicks, cmdObj.pollIntervalMs)
    | "init" => runInitCommand(cmdObj.dir, cmdObj.repoUrl, cmdObj.agents)
    | "groom" => runGroomCommand(cmdObj.dir, Option.getOrUndefined(Option.fromNullishOr(cmdObj.model)), opts)
    | "status" => printStatus(cmdObj.dir)
    | "view" => runViewCommandWithOpts(cmd, Option.getOrUndefined(options))
    | _ => failUnknownCommand(cmdObj.command)
  => res
}

export runCli = (argv?: Array<String>, options?: Any) => {
  args = match Option.fromNullishOr(argv)
    | Some(a) => a
    | None => globalThis.process.argv |> Array.drop(2)
  parsed = parseCliArgs(args)
  opts = Option.getOrUndefined(Option.fromNullishOr(options))
  => dispatchCli(parsed, opts)
}

export runCliFun = () => runCli()
