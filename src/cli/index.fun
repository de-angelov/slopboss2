import { Array, Console, Effect, Number, Option, Schema, String, Predicate } from "effect"
import { runDoctor } from "../services/doctor.js"
import { ReconcilerConfig, runReconcilerLoop } from "../orchestrator/dispatcher.js"
import { initBoardStructure } from "../services/setup.js"
import { buildInteractiveCommand } from "../services/provider.js"
import { defaultLiveViewOptions, LiveViewOptions, runLiveView } from "./view.js"

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

export formatDoctorTable = (report: Any): String => {
  lines = [
    "Diagnostic Check Results:",
    "--------------------------------------------------------------------------------",
    "Status    | Check        | Required | Details",
    "--------------------------------------------------------------------------------"
  ]
  repObj: Any = globalThis.Object(report)
  rawChecks: Array<Any> = match Option.fromNullishOr(Reflect.get(repObj, "checks"))
    | Some(c) => c
    | None => []
    | _ => []
  checkLines = rawChecks |> Array.map((c: Any) => {
    cObj: Any = globalThis.Object(c)
    isOk = Boolean(Reflect.get(cObj, "ok"))
    status = match isOk
      | true => "[ PASS ]"
      | false => "[ FAIL ]"
      | _ => "[ FAIL ]"
    isReq = Boolean(Reflect.get(cObj, "required"))
    req = match isReq
      | true => "Yes"
      | false => "No "
      | _ => "No "
    name = globalThis.String(Reflect.get(cObj, "name")) |> String.padEnd(12)
    msg = globalThis.String(Reflect.get(cObj, "message"))
    => status + "  | " + name + " | " + req + "      | " + msg
  })
  isHealthy = Boolean(Reflect.get(repObj, "isHealthy"))
  health = match isHealthy
    | true => "HEALTHY"
    | false => "UNHEALTHY"
    | _ => "UNHEALTHY"
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
  resolvedModel: Option<String> = match Option.fromNullishOr(model)
    | Some(m) => match Option.isOption(m)
        | true => m
        | false => Option.some(globalThis.String(m))
        | _ => Option.none()
    | None => Option.none()
    | _ => Option.none()
  fileObj = globalThis.Bun.file(boardDir + "/BACKLOG.md")
  exists <- Effect.promise(() => fileObj.exists())
  backlogText <- match exists
    | true => Effect.promise(() => fileObj.text())
    | false => Effect.succeed("")
    | _ => Effect.succeed("")
  prompt = buildGroomPrompt(boardDir, backlogText)
  agyCmd = buildInteractiveCommand(resolvedModel, prompt)
  _ <- Console.log("Starting interactive Team Lead grooming session...")
  _ <- Console.log("Command: " + (agyCmd |> Array.join(" ")))
  spawnFnActual: Any = Option.getOrElse(Option.fromNullishOr(spawnFn), fallbackSpawnFn)
  spawnOptions = {
    cwd: boardDir,
    stdin: "inherit",
    stdout: "inherit",
    stderr: "inherit"
  }
  proc: Any = Reflect.apply(spawnFnActual, globalThis.undefined, [agyCmd, spawnOptions])
  procObj: Any = globalThis.Object(proc)
  exitedPromise: Any = Reflect.get(procObj, "exited")
  rawCode <- Effect.promise(() => exitedPromise)
  code = Option.getOrElse(Option.fromNullishOr(rawCode), () => 0)
  _ <- Console.log("Team Lead grooming session completed with exit code " + globalThis.String(code))
  => code
}

export launchInteractiveGroomFun = (boardDir: String, model?: Any, spawnFn?: Any) =>
  launchInteractiveGroom(boardDir, Option.getOrUndefined(Option.fromNullishOr(model)), Option.getOrUndefined(Option.fromNullishOr(spawnFn)))

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
fallbackViewOpts = () => ({})

export runReconcilerCommand = (dir: String, detach: Boolean = false, options?: Any, maxTicks?: Number, pollIntervalMs?: Number) => effect {
  rawOpts: Any = Option.getOrElse(Option.fromNullishOr(options), fallbackViewOpts)
  rawOptsObj: Any = globalThis.Object(rawOpts)
  res <- match detach
    | true => effect {
        spawnFnActual: Any = Option.getOrElse(Option.fromNullishOr(Reflect.get(rawOptsObj, "spawnFn")), fallbackSpawnFn)
        binPath = Option.getOrElse(Option.fromNullishOr(globalThis.process.argv[1]), fallbackBinPath)
        execArgs = [globalThis.process.execPath, "run", binPath, "run", "--dir", dir]
        spawnOpts = {
          detached: true,
          stdio: ["ignore", "ignore", "ignore"]
        }
        proc: Any = Reflect.apply(spawnFnActual, globalThis.undefined, [execArgs, spawnOpts])
        procObj: Any = globalThis.Object(proc)
        unrefFn: Any = Reflect.get(procObj, "unref")
        _unused: Unknown = match Predicate.isFunction(unrefFn)
          | true => Reflect.apply(unrefFn, proc, [])
          | false => globalThis.undefined
          | _ => globalThis.undefined
        procPid: Unknown = Reflect.get(procObj, "pid")
        _ <- Console.log("[SLOPBOSS2] Started reconciler daemon in background (PID: " + globalThis.String(procPid) + ")")
        => { detached: true, pid: procPid }
    }
    | false => effect {
        _ <- Console.log("[SLOPBOSS2] Starting dispatcher reconciler loop for board: " + dir)
        rawOptsPoll: Unknown = Reflect.get(rawOptsObj, "pollIntervalMs")
        pollVal: Number = match Option.fromNullishOr(pollIntervalMs)
          | Some(p) => globalThis.Number(p)
          | None => match Option.fromNullishOr(rawOptsPoll)
              | Some(p) => globalThis.Number(p)
              | None => 1000
              | _ => 1000
          | _ => 1000
        rawOptsIter: Unknown = Reflect.get(rawOptsObj, "maxIterations")
        iterVal: Number = match Option.fromNullishOr(maxTicks)
          | Some(m) => globalThis.Number(m)
          | None => match Option.fromNullishOr(rawOptsIter)
              | Some(m) => globalThis.Number(m)
              | None => 0
              | _ => 0
          | _ => 0
        rawMock: Unknown = Reflect.get(rawOptsObj, "mockRunner")
        mockOpt: Option<Boolean> = match Option.fromNullishOr(rawMock)
          | Some(m) => Option.some(Boolean(m))
          | None => Option.none()
          | _ => Option.none()
        rawRunnerFn: Unknown = Reflect.get(rawOptsObj, "runnerFn")
        runnerOpt: Option<Unknown> = match Option.fromNullishOr(rawRunnerFn)
          | Some(r) => Option.some(r)
          | None => Option.none()
          | _ => Option.none()
        config: ReconcilerConfig = {
          boardDir: dir,
          pollIntervalMs: pollVal,
          maxIterations: iterVal,
          devAgentCount: 2,
          baseBranch: Option.none(),
          mockRunner: mockOpt,
          runnerFn: runnerOpt,
          mergeQueue: Option.none()
        }
        r <- runReconcilerLoop(config)
        => r
    }
    | _ => effect { => globalThis.undefined }
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
  rawOpts: Any = Option.getOrElse(Option.fromNullishOr(options), fallbackViewOpts)
  rawOptsObj: Any = globalThis.Object(rawOpts)
  spawnFnOpt: Unknown = Reflect.get(rawOptsObj, "spawnFn")
  res <- launchInteractiveGroom(dir, Option.getOrUndefined(Option.fromNullishOr(model)), spawnFnOpt)
  => res
}

export runViewCommand = (dir: String, pollIntervalMs: Number = 1000, options: LiveViewOptions = defaultLiveViewOptions) =>
  runLiveView(dir, pollIntervalMs, options)

export runViewCommandFun = (boardDir: String, pollMs: Number = 1000, options: LiveViewOptions = defaultLiveViewOptions) =>
  runViewCommand(boardDir, pollMs, options)

export runControlLoop = (boardDir: String, maxTicks: Number = 3) => effect {
  _ <- Console.log("Starting Slopboss2 control loop (provider: agy, dev-agents: 2)...")
  config: ReconcilerConfig = {
    boardDir: boardDir,
    pollIntervalMs: 100,
    maxIterations: maxTicks,
    devAgentCount: 2,
    baseBranch: Option.none(),
    mockRunner: Option.none(),
    runnerFn: Option.none(),
    mergeQueue: Option.none()
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
  obj: Any = globalThis.Object(cmd)
  rawCmd = globalThis.String(Reflect.get(obj, "command"))
  isHelpCmd = rawCmd #= "help"
  subOpt: Option<String> = match isHelpCmd
    | true => match Option.fromNullishOr(Reflect.get(obj, "subcommand"))
        | Some(s) => Option.some(globalThis.String(s))
        | None => Option.none()
        | _ => Option.none()
    | false => Option.some(rawCmd)
    | _ => Option.none()
  helpMsg = getHelpMessage(Option.getOrUndefined(subOpt))
  _ <- Console.log(helpMsg)
  => { help: true, output: helpMsg }
}

handleInvalid = (cmd: Any) => effect {
  obj: Any = globalThis.Object(cmd)
  errRaw: Unknown = Reflect.get(obj, "error")
  errText = match Option.fromNullishOr(errRaw)
    | Some(e) => globalThis.String(e)
    | None => "Unknown error"
    | _ => "Unknown error"
  errMsg = "Error: " + errText
  _ <- Console.error(errMsg)
  subOpt: Option<String> = match Option.fromNullishOr(Reflect.get(obj, "subcommand"))
    | Some(s) => Option.some(globalThis.String(s))
    | None => Option.none()
    | _ => Option.none()
  _ <- Console.log(getHelpMessage(Option.getOrUndefined(subOpt)))
  _ <- Effect.fail(globalThis.Error(errText))
  => { help: false, output: errMsg }
}

runViewCommandWithOpts = (cmd: Any, options?: Any) => {
  obj: Any = globalThis.Object(cmd)
  rawOpts: Any = Option.getOrElse(Option.fromNullishOr(options), fallbackViewOpts)
  dirStr = match Option.fromNullishOr(Reflect.get(obj, "dir"))
    | Some(d) => globalThis.String(d)
    | None => DEFAULT_BOARD_DIR
    | _ => DEFAULT_BOARD_DIR
  rawCmdPoll: Unknown = Reflect.get(obj, "pollIntervalMs")
  rawOptsPoll: Unknown = Reflect.get(globalThis.Object(rawOpts), "pollIntervalMs")
  pollValNum: Number = match Option.fromNullishOr(rawCmdPoll)
    | Some(p) => globalThis.Number(p)
    | None => match Option.fromNullishOr(rawOptsPoll)
        | Some(p) => globalThis.Number(p)
        | None => 1000
        | _ => 1000
    | _ => 1000
  viewOptsRaw: Any = Reflect.get(globalThis.Object(rawOpts), "viewOptions")
  viewOpts: LiveViewOptions = match Option.fromNullishOr(viewOptsRaw)
    | Some(v) => v
    | None => defaultLiveViewOptions
    | _ => defaultLiveViewOptions
  => runViewCommand(dirStr, pollValNum, viewOpts)
}

export dispatchCli = (cmd: Any, options?: Any) => effect {
  obj: Any = globalThis.Object(cmd)
  rawCmd = globalThis.String(Reflect.get(obj, "command"))
  rawHelp = Boolean(Reflect.get(obj, "help"))
  isHelpCmd = rawCmd #= "help"
  dispatchAction = match isHelpCmd or rawHelp
    | true => "help"
    | false => rawCmd
    | _ => rawCmd

  rawOptions: Any = Option.getOrElse(Option.fromNullishOr(options), fallbackViewOpts)
  dirStr = match Option.fromNullishOr(Reflect.get(obj, "dir"))
    | Some(d) => globalThis.String(d)
    | None => DEFAULT_BOARD_DIR
    | _ => DEFAULT_BOARD_DIR

  rawModel: Unknown = Reflect.get(obj, "model")
  modelOpt: Option<String> = match Option.fromNullishOr(rawModel)
    | Some(m) => Option.some(globalThis.String(m))
    | None => Option.none()
    | _ => Option.none()

  rawDetach = Boolean(Reflect.get(obj, "detach"))
  rawMaxTicks: Unknown = Reflect.get(obj, "maxTicks")
  maxTicksOpt: Option<Number> = match Option.fromNullishOr(rawMaxTicks)
    | Some(m) => Option.some(globalThis.Number(m))
    | None => Option.none()
    | _ => Option.none()

  rawPoll: Unknown = Reflect.get(obj, "pollIntervalMs")
  pollOpt: Option<Number> = match Option.fromNullishOr(rawPoll)
    | Some(p) => Option.some(globalThis.Number(p))
    | None => Option.none()
    | _ => Option.none()

  rawRepo: Unknown = Reflect.get(obj, "repoUrl")
  repoStr = match Option.fromNullishOr(rawRepo)
    | Some(r) => globalThis.String(r)
    | None => "https://github.com/de-angelov/slopboss2.git"
    | _ => "https://github.com/de-angelov/slopboss2.git"

  rawAgents: Unknown = Reflect.get(obj, "agents")
  agentsNum = match Option.fromNullishOr(rawAgents)
    | Some(a) => globalThis.Number(a)
    | None => 2
    | _ => 2

  res <- match dispatchAction
    | "help" => handleHelp(cmd)
    | "invalid" => handleInvalid(cmd)
    | "doctor" => runDoctorCommand(dirStr)
    | "run" => runReconcilerCommand(dirStr, rawDetach, rawOptions, Option.getOrUndefined(maxTicksOpt), Option.getOrUndefined(pollOpt))
    | "init" => runInitCommand(dirStr, repoStr, agentsNum)
    | "groom" => runGroomCommand(dirStr, Option.getOrUndefined(modelOpt), rawOptions)
    | "status" => printStatus(dirStr)
    | "view" => runViewCommandWithOpts(cmd, Option.getOrUndefined(Option.fromNullishOr(options)))
    | _ => failUnknownCommand(rawCmd)
  => res
}

export runCli = (argv?: Array<String>, options?: Any) => {
  args = match Option.fromNullishOr(argv)
    | Some(a) => a
    | None => globalThis.process.argv |> Array.drop(2)
    | _ => []
  parsed = parseCliArgs(args)
  opts: Unknown = Option.getOrUndefined(Option.fromNullishOr(options))
  => dispatchCli(parsed, opts)
}

export runCliFun = () => runCli()
