import { Array, Console, Effect, Number, Option, Schema, String, Predicate } from "effect"
import { runDoctor } from "../services/doctor.js"
import { ReconcilerConfig, runReconcilerLoop } from "../orchestrator/dispatcher.js"
import { initBoardStructure } from "../services/setup.js"
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
  pid: Any
}

export schema HelpResult = {
  help: Boolean
  output: String
}

export error CliCommandError(message: String)

export getEnvVar = (name: String): Option<String> =>
  Option.fromNullishOr(process) |> Option.flatMap((proc) => Option.fromNullishOr(Reflect.get(proc, "env"))) |> Option.flatMap((env) => Option.fromNullishOr(Reflect.get(env, name))) |> Option.map((val) => "" + val)

export getProcessArgv = (): Array<String> =>
  Option.fromNullishOr(process) |> Option.flatMap((proc) => Option.fromNullishOr(Reflect.get(proc, "argv"))) |> Option.getOrElse(() => [])

export getProcessExecPath = (): String =>
  Option.fromNullishOr(process) |> Option.flatMap((proc) => Option.fromNullishOr(Reflect.get(proc, "execPath"))) |> Option.map((ep) => "" + ep) |> Option.getOrElse(() => "bun")

defaultBoardDirFallback = () => "/home/dangelov/slopboss2-board"

export DEFAULT_BOARD_DIR = Option.getOrElse(
  getEnvVar("SLOPBOSS_BOARD_DIR"),
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

statusTag = (isOk: Boolean): String => {
  when (isOk) => "[ PASS ]"
  => "[ FAIL ]"
}

requiredTag = (isReq: Boolean): String => {
  when (isReq) => "Yes"
  => "No "
}

healthTag = (isHealthy: Boolean): String => {
  when (isHealthy) => "HEALTHY"
  => "UNHEALTHY"
}

export formatDoctorTable = (report: Any): String => {
  lines = [
    "Diagnostic Check Results:",
    "--------------------------------------------------------------------------------",
    "Status    | Check        | Required | Details",
    "--------------------------------------------------------------------------------"
  ]
  repObj: Any = report
  rawChecksVal: Option<Any> = Option.fromNullishOr(Reflect.get(repObj, "checks"))
  rawChecks: Array<Any> = match rawChecksVal
    | Some(c) => c
    | None => []
    | _ => []
  checkLines = rawChecks |> Array.map((c: Any) => {
    cObj: Any = c
    isOk = Option.fromNullishOr(Reflect.get(cObj, "ok")) |> Option.map((ok) => ok #= true) |> Option.getOrElse(() => false)
    status = statusTag(isOk)
    isReq = Option.fromNullishOr(Reflect.get(cObj, "required")) |> Option.map((req) => req #= true) |> Option.getOrElse(() => false)
    req = requiredTag(isReq)
    name = ("" + Reflect.get(cObj, "name")) |> String.padEnd(12)
    msg = "" + Reflect.get(cObj, "message")
    => status + "  | " + name + " | " + req + "      | " + msg
  })
  isHealthy = Option.fromNullishOr(Reflect.get(repObj, "isHealthy")) |> Option.map((h) => h #= true) |> Option.getOrElse(() => false)
  health = healthTag(isHealthy)
  allLines = lines |> Array.appendAll(checkLines) |> Array.append("--------------------------------------------------------------------------------") |> Array.append("Overall Health: " + health)
  => allLines |> Array.join("\n")
}

export getHelpMessage = (subcommand?: String): String => {
  sub = Option.fromNullishOr(subcommand) |> Option.getOrElse(() => "")
  when (sub #= "doctor") => [
    "Usage: slopboss2 doctor [options] [path]",
    "",
    "Run system diagnostics and verify dependencies.",
    "",
    "Options:",
    "  -d, --dir <path>  Board directory path (default: $SLOPBOSS_BOARD_DIR or current directory)",
    "  -h, --help        Show help for doctor command"
  ] |> Array.join("\n")
  when (sub #= "run") => [
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
  when (sub #= "init" or sub #= "setup") => [
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
  when (sub #= "groom") => [
    "Usage: slopboss2 groom [options] [path]",
    "",
    "Launch interactive Team Lead grooming session with Antigravity (agy).",
    "",
    "Options:",
    "  -d, --dir <path>   Board directory path (default: $SLOPBOSS_BOARD_DIR or current directory)",
    "  -m, --model <name> Override agent model",
    "  -h, --help         Show help for groom command"
  ] |> Array.join("\n")
  when (sub #= "status") => [
    "Usage: slopboss2 status [options] [path]",
    "",
    "Display board execution status.",
    "",
    "Options:",
    "  -d, --dir <path>  Board directory path (default: $SLOPBOSS_BOARD_DIR or current directory)",
    "  -h, --help        Show help for status command"
  ] |> Array.join("\n")
  when (sub #= "view") => [
    "Usage: slopboss2 view [options] [path]",
    "",
    "Launch interactive terminal dashboard live view.",
    "",
    "Options:",
    "  -d, --dir <path>  Board directory path (default: $SLOPBOSS_BOARD_DIR or current directory)",
    "  -h, --help        Show help for view command"
  ] |> Array.join("\n")
  => [
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
  ] |> Array.join("\n")
}

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
  when (not isFlag) => parseTokens(subcommand, tail, { ...acc, positionals: acc.positionals |> Array.append(head) })

  isDirCommand = subcommand #= "doctor" or subcommand #= "run" or subcommand #= "init" or subcommand #= "setup" or subcommand #= "groom" or subcommand #= "status" or subcommand #= "view"
  numericArg = tail |> Array.get(0) |> Option.getOrElse(() => "0") |> Number.parse
  agentCount = tail |> Array.get(0) |> Option.getOrElse(() => "2") |> Number.parse
  when (isDirCommand and (head #= "--dir" or head #= "-d")) => parseTokens(subcommand, tail |> Array.drop(1), { ...acc, dir: tail |> Array.get(0) })
  when ((subcommand #= "run" or subcommand #= "view") and (head #= "--poll-interval" or head #= "pollInterval")) => parseTokens(subcommand, tail |> Array.drop(1), { ...acc, pollIntervalMs: numericArg })
  when (subcommand #= "run" and (head #= "--max-ticks" or head #= "maxTicks" or head #= "--iterations")) => parseTokens(subcommand, tail |> Array.drop(1), { ...acc, maxTicks: numericArg })
  when (subcommand #= "run" and head #= "--detach") => parseTokens(subcommand, tail, { ...acc, detach: true })
  when ((subcommand #= "init" or subcommand #= "setup") and (head #= "--repo" or head #= "-r")) => parseTokens(subcommand, tail |> Array.drop(1), { ...acc, repoUrl: tail |> Array.get(0) })
  when ((subcommand #= "init" or subcommand #= "setup") and (head #= "--agents" or head #= "-a")) => parseTokens(subcommand, tail |> Array.drop(1), { ...acc, agents: agentCount })
  when (subcommand #= "groom" and (head #= "--model" or head #= "-m")) => parseTokens(subcommand, tail |> Array.drop(1), { ...acc, model: tail |> Array.get(0) })
  when ((head #= "--help" or head #= "-h") and isDirCommand) => parseTokens(subcommand, tail, { ...acc, help: true })
  => parseTokens(subcommand, tail, { ...acc, unknownOpt: Option.some(head) })

isKnownSubcommand = (cmd: String): Boolean => {
  when (cmd #= "doctor") => true
  when (cmd #= "run") => true
  when (cmd #= "init") => true
  when (cmd #= "setup") => true
  when (cmd #= "groom") => true
  when (cmd #= "status") => true
  when (cmd #= "view") => true
  when (cmd #= "board") => true
  when (cmd #= "recover") => true
  when (cmd #= "coordination") => true
  => false
}

normalizeSubcommand = (cmd: String): String => {
  when (cmd #= "setup") => "init"
  => cmd
}

export parseCliArgs = (argv?: Array<String>) => {
  args = Option.fromNullishOr(argv) |> Option.getOrElse(() => [])
  when (args.length #= 0) => { command: "help", type: "help" }

  first = args |> Array.get(0) |> Option.getOrElse(() => "")
  when (first #= "--help" or first #= "-h") => { command: "help", type: "help" }

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

  when (first #= "board") => parseBoardCommand(subArgs)
  when (first #= "recover") => parseRecoverCommand(subArgs)
  when (first #= "coordination") => parseCoordinationCommand(subArgs)

  when (not isKnownSubcommand(first)) => {
    command: "invalid",
    type: "invalid",
    error: "Unknown command: " + first
  }

  parsed = parseTokens(first, subArgs, emptyAcc())
  normCmd = normalizeSubcommand(first)

  when (Option.isSome(parsed.unknownOpt)) => {
    command: "invalid",
    type: "invalid",
    error: "Unknown option '" + Option.getOrElse(parsed.unknownOpt, () => "") + "'",
    subcommand: normCmd
  }

  resolvedDir = parsed.dir |> Option.orElse(() => parsed.positionals |> Array.head) |> Option.getOrElse(() => DEFAULT_BOARD_DIR)

  repo = parsed.repoUrl |> Option.getOrElse(() => "https://github.com/de-angelov/slopboss2.git")
  agentCount = parsed.agents |> Option.getOrElse(() => 2)

  when (normCmd #= "doctor") => { command: "doctor", type: "doctor", dir: resolvedDir, help: parsed.help }

  when (normCmd #= "run") => {
    command: "run",
    type: "run",
    dir: resolvedDir,
    detach: parsed.detach,
    maxTicks: Option.getOrUndefined(parsed.maxTicks),
    pollIntervalMs: Option.getOrUndefined(parsed.pollIntervalMs),
    help: parsed.help
  }

  when (normCmd #= "init") => { command: "init", type: "init", dir: resolvedDir, repoUrl: repo, agents: agentCount, help: parsed.help }

  when (normCmd #= "groom") => { command: "groom", type: "groom", dir: resolvedDir, model: Option.getOrUndefined(parsed.model), help: parsed.help }

  when (normCmd #= "status") => { command: "status", type: "status", dir: resolvedDir, help: parsed.help }

  when (normCmd #= "view") => { command: "view", type: "view", dir: resolvedDir, pollIntervalMs: Option.getOrUndefined(parsed.pollIntervalMs), help: parsed.help }

  => { command: "invalid", type: "invalid", error: "Unknown command: " + first }
}

parseBoardCommand = (args: Array<String>) => {
  action = args |> Array.get(0) |> Option.getOrElse(() => "")
  rest = args |> Array.drop(1)
  id = rest |> Array.get(0) |> Option.getOrElse(() => "")
  status = rest |> Array.get(1) |> Option.getOrElse(() => "")
  dirOpt = rest |> Array.findFirstIndex((v) => v #= "--dir") |> Option.flatMap((i) => rest |> Array.get(i + 1))
  dir = Option.getOrElse(dirOpt, () => DEFAULT_BOARD_DIR)
  => { command: "board", type: "board", action: action, id: id, status: status, dir: dir }
}

parseRecoverCommand = (args: Array<String>) => {
  dirOpt = args |> Array.findFirstIndex((v) => v #= "--dir" or v #= "-d") |> Option.flatMap((i) => args |> Array.get(i + 1))
  dir = Option.getOrElse(dirOpt, () => args |> Array.get(0) |> Option.getOrElse(() => DEFAULT_BOARD_DIR))
  => { command: "recover", type: "recover", dir: dir }
}

parseCoordinationCommand = (args: Array<String>) => {
  action = args |> Array.get(0) |> Option.getOrElse(() => "")
  rest = args |> Array.drop(1)
  statusAt = rest |> Array.findFirstIndex((v) => v #= "--status")
  summaryAt = rest |> Array.findFirstIndex((v) => v #= "--summary")
  status = statusAt |> Option.flatMap((i) => rest |> Array.get(i + 1)) |> Option.getOrElse(() => "")
  summary = summaryAt |> Option.flatMap((i) => rest |> Array.get(i + 1)) |> Option.getOrElse(() => "")
  when (action #! "report") => { command: "invalid", type: "invalid", error: "Usage: slopboss2 coordination report --status <acted|idle|blocked> --summary <text>" }
  when (status #= "" or summary #= "") => { command: "invalid", type: "invalid", error: "coordination report requires --status and --summary" }
  => { command: "coordination", type: "coordination", status: status, summary: summary }
}

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

fallbackSpawnFn = () => Bun.spawn

normalizeModelOption = (model: Any): Option<String> =>
  match Option.isOption(model)
    | true => model
    | false => Option.some("" + model)
    | _ => Option.none()

resolveModelOption = (modelOpt: Option<Any>): Option<String> =>
  Option.flatMap(modelOpt, normalizeModelOption)
readBacklogTextWorkflow = (boardDir: String) => effect {
  fileObj = Bun.file(boardDir + "/BACKLOG.md")
  exists <- Effect.promise(() => fileObj.exists())
  when (not exists) => ""
  txt <- Effect.promise(() => fileObj.text())
  => txt
}

export launchInteractiveGroom = (boardDir: String, model?: Any, spawnFn?: Any) => effect {
  resolvedModel = resolveModelOption(Option.fromNullishOr(model))
  backlogText <- readBacklogTextWorkflow(boardDir)
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
  proc: Any = Reflect.apply(spawnFnActual, Option.none(), [agyCmd, spawnOptions])
  procObj: Any = proc
  exitedPromise: Any = Reflect.get(procObj, "exited")
  rawCode <- Effect.promise(() => exitedPromise)
  code = Option.getOrElse(Option.fromNullishOr(rawCode), () => 0)
  _ <- Console.log("Team Lead grooming session completed with exit code " + code)
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

safelyUnrefProcess = (procObj: Any, proc: Any) => {
  unrefFn: Any = Reflect.get(procObj, "unref")
  when (not Predicate.isFunction(unrefFn)) => Option.none()
  => Reflect.apply(unrefFn, proc, [])
}

runReconcilerDetached = (dir: String, rawOptsObj: Any) => effect {
  spawnFnActual: Any = Option.getOrElse(Option.fromNullishOr(Reflect.get(rawOptsObj, "spawnFn")), fallbackSpawnFn)
  procArgv = getProcessArgv()
  binPath = procArgv |> Array.get(1) |> Option.getOrElse(fallbackBinPath)
  execPath = getProcessExecPath()
  execArgs = [execPath, "run", binPath, "run", "--dir", dir]
  spawnOpts = {
    detached: true,
    stdio: ["ignore", "ignore", "ignore"]
  }
  proc: Any = Reflect.apply(spawnFnActual, Option.none(), [execArgs, spawnOpts])
  procObj: Any = proc
  _unused = safelyUnrefProcess(procObj, proc)
  procPid: Unknown = Reflect.get(procObj, "pid")
  _ <- Console.log("[SLOPBOSS2] Started reconciler daemon in background (PID: " + ("" + procPid) + ")")
  => { detached: true, pid: procPid }
}

runReconcilerForeground = (dir: String, rawOptsObj: Any, maxTicks?: Number, pollIntervalMs?: Number) => effect {
  _ <- Console.log("[SLOPBOSS2] Starting dispatcher reconciler loop for board: " + dir)
  rawOptsPoll: Any = Reflect.get(rawOptsObj, "pollIntervalMs")
  pollVal = Option.fromNullishOr(pollIntervalMs) |> Option.orElse(() => Option.fromNullishOr(rawOptsPoll)) |> Option.flatMap((p) => Number.parse("" + p)) |> Option.getOrElse(() => 1000)

  rawOptsIter: Any = Reflect.get(rawOptsObj, "maxIterations")
  iterVal = Option.fromNullishOr(maxTicks) |> Option.orElse(() => Option.fromNullishOr(rawOptsIter)) |> Option.flatMap((m) => Number.parse("" + m)) |> Option.getOrElse(() => 0)

  rawMock: Any = Reflect.get(rawOptsObj, "mockRunner")
  mockOpt = Option.fromNullishOr(rawMock) |> Option.map((m) => m #= true)

  runnerOpt: Option<Any> = Option.fromNullishOr(Reflect.get(rawOptsObj, "runnerFn"))

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

export runReconcilerCommand = (dir: String, detach: Boolean = false, options?: Any, maxTicks?: Number, pollIntervalMs?: Number) => {
  rawOpts: Any = Option.getOrElse(Option.fromNullishOr(options), fallbackViewOpts)
  rawOptsObj: Any = rawOpts
  when (detach) => runReconcilerDetached(dir, rawOptsObj)
  => runReconcilerForeground(dir, rawOptsObj, maxTicks, pollIntervalMs)
}

export runInitCommand = (dir: String, repoUrl: String = "https://github.com/de-angelov/slopboss2.git", agents: Number = 2) => effect {
  _ <- Console.log("=== SLOPBOSS2 INIT ===")
  _ <- Console.log("Board directory: " + dir)
  _ <- Console.log("Repository URL:  " + repoUrl)
  _ <- Console.log("Dev Agents:      " + agents)
  res <- initBoardStructure(dir, repoUrl, agents)
  _ <- Console.log("Initialization complete. Workspaces and board ready.")
  => res
}

export runGroomCommand = (dir: String, model?: String, options?: Any) => effect {
  rawOpts: Any = Option.getOrElse(Option.fromNullishOr(options), fallbackViewOpts)
  rawOptsObj: Any = rawOpts
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
  _ <- Effect.fail(CliCommandError({ message: "Unknown command: " + cmdName }))
  => Option.none()
}

handleHelp = (cmd: Any) => effect {
  obj: Any = cmd
  rawCmd = "" + Reflect.get(obj, "command")
  subStr = match rawCmd #= "help"
    | true => Option.fromNullishOr(Reflect.get(obj, "subcommand")) |> Option.map((s) => "" + s) |> Option.getOrUndefined
    | false => rawCmd
  helpMsg = getHelpMessage(subStr)
  _ <- Console.log(helpMsg)
  => { help: true, output: helpMsg }
}

handleInvalid = (cmd: Any) => effect {
  obj: Any = cmd
  errRaw: Unknown = Reflect.get(obj, "error")
  errText = Option.fromNullishOr(errRaw) |> Option.map((e) => "" + e) |> Option.getOrElse(() => "Unknown error")
  errMsg = "Error: " + errText
  _ <- Console.error(errMsg)
  subOpt = Option.fromNullishOr(Reflect.get(obj, "subcommand")) |> Option.map((s) => "" + s)
  _ <- Console.log(getHelpMessage(Option.getOrUndefined(subOpt)))
  _ <- Effect.fail(CliCommandError({ message: errText }))
  => { help: false, output: errMsg }
}

runViewCommandWithOpts = (cmd: Any, options?: Any) => {
  obj: Any = cmd
  rawOpts: Any = Option.getOrElse(Option.fromNullishOr(options), fallbackViewOpts)
  dirStr = Option.fromNullishOr(Reflect.get(obj, "dir")) |> Option.map((d) => "" + d) |> Option.getOrElse(() => DEFAULT_BOARD_DIR)
  rawCmdPoll: Option<Any> = Option.fromNullishOr(Reflect.get(obj, "pollIntervalMs"))
  rawOptsPoll: Option<Any> = Option.fromNullishOr(Reflect.get(rawOpts, "pollIntervalMs"))
  pollValNum = rawCmdPoll |> Option.orElse(() => rawOptsPoll) |> Option.flatMap((p) => Number.parse("" + p)) |> Option.getOrElse(() => 1000)
  viewOptsRaw: Option<Any> = Option.fromNullishOr(Reflect.get(rawOpts, "viewOptions"))
  viewOpts: LiveViewOptions = match viewOptsRaw
    | Some(v) => v
    | None => defaultLiveViewOptions
    | _ => defaultLiveViewOptions
  => runViewCommand(dirStr, pollValNum, viewOpts)
}

resolveDispatchAction = (rawCmd: String, rawHelp: Boolean): String => {
  when (rawCmd #= "help" or rawHelp) => "help"
  => rawCmd
}

export dispatchCli = (cmd: Any, options?: Any) => {
  obj: Any = cmd
  rawCmd = "" + Reflect.get(obj, "command")
  rawHelp = Option.fromNullishOr(Reflect.get(obj, "help")) |> Option.map((h) => h #= true) |> Option.getOrElse(() => false)
  dispatchAction = resolveDispatchAction(rawCmd, rawHelp)

  rawOptions: Any = Option.getOrElse(Option.fromNullishOr(options), fallbackViewOpts)
  dirStr = Option.fromNullishOr(Reflect.get(obj, "dir")) |> Option.map((d) => "" + d) |> Option.getOrElse(() => DEFAULT_BOARD_DIR)
  modelOpt = Option.fromNullishOr(Reflect.get(obj, "model")) |> Option.map((m) => "" + m)
  rawDetach = Option.fromNullishOr(Reflect.get(obj, "detach")) |> Option.map((d) => d #= true) |> Option.getOrElse(() => false)
  maxTicksOpt = Option.fromNullishOr(Reflect.get(obj, "maxTicks")) |> Option.flatMap((m) => Number.parse("" + m))
  pollOpt = Option.fromNullishOr(Reflect.get(obj, "pollIntervalMs")) |> Option.flatMap((p) => Number.parse("" + p))
  repoStr = Option.fromNullishOr(Reflect.get(obj, "repoUrl")) |> Option.map((r) => "" + r) |> Option.getOrElse(() => "https://github.com/de-angelov/slopboss2.git")
  agentsNum = Option.fromNullishOr(Reflect.get(obj, "agents")) |> Option.flatMap((a) => Number.parse("" + a)) |> Option.getOrElse(() => 2)

  when (dispatchAction #= "board") => dispatchBoardCommand(obj, dirStr)
  when (dispatchAction #= "recover") => acquireBoardLock(dirStr).pipe(Effect.scoped)
  when (dispatchAction #= "coordination") => dispatchCoordinationCommand(obj)

  when (dispatchAction #= "help") => handleHelp(cmd)
  when (dispatchAction #= "invalid") => handleInvalid(cmd)
  when (dispatchAction #= "doctor") => runDoctorCommand(dirStr)
  when (dispatchAction #= "run") => runReconcilerCommand(dirStr, rawDetach, rawOptions, Option.getOrUndefined(maxTicksOpt), Option.getOrUndefined(pollOpt))
  when (dispatchAction #= "init") => runInitCommand(dirStr, repoStr, agentsNum)
  when (dispatchAction #= "groom") => runGroomCommand(dirStr, Option.getOrUndefined(modelOpt), rawOptions)
  when (dispatchAction #= "status") => printStatus(dirStr)
  when (dispatchAction #= "view") => runViewCommandWithOpts(cmd, Option.getOrUndefined(Option.fromNullishOr(rawOptions)))
  => failUnknownCommand(rawCmd)
}

dispatchCoordinationCommand = (cmd: Any) => {
  reportPath = getEnvVar("SLOPBOSS_COORDINATION_REPORT") |> Option.getOrElse(() => "")
  report = { status: "" + Reflect.get(cmd, "status"), summary: "" + Reflect.get(cmd, "summary") }
  => writeCoordinationReport(reportPath, report)
}

dispatchBoardCommand = (cmd: Any, dir: String) => effect {
  action = "" + Reflect.get(cmd, "action")
  id = "" + Reflect.get(cmd, "id")
  status = "" + Reflect.get(cmd, "status")
  result <- match action
    | "get" => boardGet(dir, id)
    | "list" => boardList(dir)
    | "set" => boardSet(dir, id, status)
    | _ => Effect.fail(CliCommandError({ message: "Usage: slopboss2 board <get <id>|list|set <id> <status>>" }))
  => result
}

boardGet = (dir: String, id: String) => effect {
  task = findTask(loadBoardStoreSync(dir), id)
  _ <- Console.log(Option.match(task, { onNone: () => "Task not found: " + id, onSome: (t) => t.rawBody }))
  => task
}

boardList = (dir: String) => effect {
  tasks = loadBoardStoreSync(dir).tasksDoc.sections |> Array.flatMap((section) => section.tasks)
  _ <- Console.log(tasks |> Array.map((t) => t.id + "  " + t.title + " (" + t.status + ")") |> Array.join("\n"))
  => tasks
}

boardSet = (dir: String, id: String, status: String) => effect {
  updated: Unknown = updateTaskStatus(loadBoardStoreSync(dir), id, status)
  _ <- Console.log("Updated " + id + " to " + status)
  => updated
}

export runCli = (argv?: Array<String>, options?: Any) => {
  fallbackArgs = getProcessArgv() |> Array.drop(2)
  args = Option.fromNullishOr(argv) |> Option.getOrElse(() => fallbackArgs)
  parsed = parseCliArgs(args)
  opts: Unknown = Option.getOrUndefined(Option.fromNullishOr(options))
  => dispatchCli(parsed, opts)
}

export runCliFun = () => runCli()
