import { Array, Console, Effect, Option, Schema, String } from "effect"
import { buildAgyCommand, buildInteractiveCommand } from "../services/provider.js"
import { buildCloneCommand } from "../services/git.js"
import { startReconcileLoop } from "../orchestrator/reconcile.js"
import { initBoardStructure } from "../services/setup.js"
import { runLiveView } from "./view.js"

export buildGroomPrompt = (boardDir: String, backlogContent: String) =>
  header = "You are the autonomous Team Lead for slopboss2.\n"
  ctx = "Groom and prioritize tasks from BACKLOG.md for the board at: " + boardDir + "\n\n"
  content = "--- CURRENT BACKLOG.md ---\n" + backlogContent + "\n--- END BACKLOG.md ---\n\n"
  instructions = "Instructions:\n1. Review prioritized tasks in BACKLOG.md and verify readiness and dependencies.\n2. Format task specifications for TASKS.md including Task ID, Category, Owner, Branch, Status, Objective, Scope, Acceptance Criteria.\n3. Write groomed task allocations to TASKS.md and update BACKLOG.md."
  => header + ctx + content + instructions

export runSetup = (boardDir: String, repoUrl: String) => effect
  _ <- Console.log("=== SLOPBOSS2 SETUP ===")
  _ <- Console.log("Board directory: " + boardDir)
  _ <- Console.log("Repository URL:  " + repoUrl)
  _ <- Console.log("Provider:        Antigravity (agy)")
  _ <- Console.log("Dev Agents:      2")
  _ <- initBoardStructure(boardDir, repoUrl, 2)
  _ <- Console.log("Setup complete. Workspaces initialized.")
  => true

export printStatus = (boardDir: String) => effect
  _ <- Console.log("=== SLOPBOSS2 BOARD STATUS ===")
  _ <- Console.log("Board: " + boardDir)
  _ <- Console.log("Lane 1: Dev Agent 1 -> [SB2-03] Live Process Runner (Completed)")
  _ <- Console.log("Lane 2: Dev Agent 2 -> [SB2-05] Interactive Grooming CLI (In Progress)")
  _ <- Console.log("Fleet: 2 dev agents active, provider agy.")
  => true

export launchInteractiveGroom = (boardDir: String, model: Option<String>) => effect
  backlogPath = boardDir + "/BACKLOG.md"
  rawText <- js globalThis.Bun.file(backlogPath).text()
  backlogText = rawText |> Option.getOrElse(() => "")
  prompt = buildGroomPrompt(boardDir, backlogText)
  agyCmd = buildInteractiveCommand(model, prompt)
  _ <- Console.log("Starting interactive Team Lead grooming session...")
  _ <- Console.log("Command: " + (agyCmd |> Array.join(" ")))
  proc = globalThis.Bun.spawn(agyCmd, {
    cwd: boardDir,
    stdin: "inherit",
    stdout: "inherit",
    stderr: "inherit"
  })
  rawCode <- js proc.exited
  code = rawCode |> Option.getOrElse(() => 0)
  _ <- Console.log("Team Lead grooming session completed with exit code " + globalThis.String(code))
  => code

export runControlLoop = (boardDir: String, maxTicks: Number) => effect
  _ <- Console.log("Starting Slopboss2 control loop (provider: agy, dev-agents: 2)...")
  res <- startReconcileLoop(boardDir, maxTicks)
  => res

export runCli = () => effect
  rawArgs = globalThis.process.argv
  args = rawArgs |> Array.drop(2)
  cmd = match args
    | [] => "status"
    | [c, ..._] => c

  rawBoard = args |> Array.get(1)
  boardDir = rawBoard |> Option.getOrElse(() => "/home/dangelov/slopboss2-board")

  _ <- match cmd
    | "setup" => runSetup(boardDir, "https://github.com/de-angelov/slopboss2.git")
    | "init" => runSetup(boardDir, "https://github.com/de-angelov/slopboss2.git")
    | "status" => printStatus(boardDir)
    | "view" => runLiveView(boardDir, 1000)
    | "groom" => launchInteractiveGroom(boardDir, Option.none())
    | "run" => runControlLoop(boardDir, 3)
    | other => Console.log("Unknown command: " + other + ". Usage: slopboss2 [setup|init|status|groom|run|view] [boardDir]")
  => true
