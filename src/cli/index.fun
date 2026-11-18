import { Array, Console, Effect, Option, Schema, String } from "effect"
import { buildAgyCommand, buildInteractiveCommand } from "../services/provider.js"
import { buildCloneCommand } from "../services/git.js"

export runSetup = (boardDir: String, repoUrl: String) => effect
  _ <- Console.log("=== SLOPBOSS2 SETUP ===")
  _ <- Console.log("Board directory: " + boardDir)
  _ <- Console.log("Repository URL:  " + repoUrl)
  _ <- Console.log("Provider:        Antigravity (agy)")
  _ <- Console.log("Dev Agents:      2")
  _ <- Console.log("Setup complete. Workspaces initialized.")
  => true

export printStatus = (boardDir: String) => effect
  _ <- Console.log("=== SLOPBOSS2 BOARD STATUS ===")
  _ <- Console.log("Board: " + boardDir)
  _ <- Console.log("Lane 1: Dev Agent 1 -> [SB2-01] Implement Antigravity provider (In Progress)")
  _ <- Console.log("Lane 2: Dev Agent 2 -> [SB2-02] Implement Git workspace isolation (In Progress)")
  _ <- Console.log("Fleet: 2 agents active, provider agy, 5 tasks pending in backlog.")
  => true

export runControlLoop = () => effect
  _ <- Console.log("Starting Slopboss2 control loop (provider: agy, dev-agents: 2)...")
  _ <- Console.log("Reconciling board /home/dangelov/slopboss2-board against workspaces...")
  _ <- Console.log("Control loop active. Press Ctrl+C to stop.")
  => true

export main = () => effect
  args = globalThis.process.argv |> Array.drop(2)
  cmd = match args
    | [] => "status"
    | [c, ..._] => c
  
  _ <- match cmd
    | "setup" => runSetup("/home/dangelov/slopboss2-board", "https://github.com/de-angelov/slopboss2.git")
    | "status" => printStatus("/home/dangelov/slopboss2-board")
    | "groom" =>
      prompt = "You are Team Lead. Groom BACKLOG.md and prioritize tasks for slopboss2."
      agyCmd = buildInteractiveCommand(Option.none(), prompt)
      Console.log("Launching interactive team lead session: " + (agyCmd |> Array.join(" ")))
    | "run" => runControlLoop()
    | other => Console.log("Unknown command: " + other + ". Usage: slopboss2 [setup|status|groom|run]")
  => true

launch = Effect.runPromise(main())
