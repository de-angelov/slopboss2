import { Array, Number, Option, Schema, String } from "effect"
import * as core from "./cli_core.js"

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

export DEFAULT_BOARD_DIR = Option.getOrElse(
  Option.fromNullishOr(globalThis.process.env.SLOPBOSS_BOARD_DIR),
  () => "/home/dangelov/slopboss2-board"
)

export buildGroomPrompt = (boardDir: String, backlogContent: String) => core.buildGroomPrompt(boardDir, backlogContent)

export buildGroomPromptFun = (boardDir: String, backlogContent: String) => core.buildGroomPrompt(boardDir, backlogContent)

export formatDoctorTable = (report: ts { any }) => core.formatDoctorTable(report)

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

export printStatus = (boardDir: String) => core.printStatus(boardDir)

export printStatusFun = (boardDir: String) => core.printStatus(boardDir)

export runSetup = (boardDir: String, repoUrl: String) => core.runSetup(boardDir, repoUrl)

export runSetupFun = (boardDir: String, repoUrl: String) => core.runSetup(boardDir, repoUrl)

export launchInteractiveGroom = (boardDir: String, model: ts { any }) => core.launchInteractiveGroom(boardDir, model)

export launchInteractiveGroomFun = (boardDir: String, model: ts { any }) => core.launchInteractiveGroom(boardDir, model)

export runDoctorCommand = (dir: String) => core.runDoctorCommand(dir)

export runReconcilerCommand = (dir: String, detach: Boolean, options: ts { any }, maxTicks: Number, pollIntervalMs: Number) => core.runReconcilerCommand(dir, detach, options, maxTicks, pollIntervalMs)

export runInitCommand = (dir: String, repoUrl: String, agents: Number) => core.runInitCommand(dir, repoUrl, agents)

export runGroomCommand = (dir: String, model: ts { any }) => core.runGroomCommand(dir, model)

export runViewCommand = (dir: String, pollIntervalMs: Number, options?: ts { any }) => core.runViewCommand(dir, pollIntervalMs, Option.getOrUndefined(options))

export runViewCommandFun = (boardDir: String, pollMs: Number, options?: ts { any }) => core.runViewCommand(boardDir, pollMs, Option.getOrUndefined(options))

export runControlLoop = (boardDir: String, maxTicks: Number) => core.runControlLoop(boardDir, maxTicks)

export runControlLoopFun = (boardDir: String, maxTicks: Number) => core.runControlLoop(boardDir, maxTicks)

export dispatchCli = (command: ts { any }, options: ts { any }) => core.dispatchCli(command, options)

export runCli = (argv: ts { any }, options: ts { any }) => core.runCli(argv, options)

export runCliFun = () => core.runCli()
