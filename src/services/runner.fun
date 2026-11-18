import { Array, Console, Effect, Option, Schema, Scope, String } from "effect"
import { parseAgyLine } from "./provider.js"

export schema SessionResult = {
  exitCode: Number
  totalTokens: Number
  completed: Boolean
}

// Spawns a process wrapped in Effect Scope lifecycle.
// On Scope exit (interruption, error, or completion), SIGTERM is sent to guarantee no orphaned processes.
export spawnScopedProcess = (cmd: Array<String>, cwd: String) => effect
  proc = globalThis.Bun.spawn(cmd, {
    cwd: cwd,
    stdin: "pipe",
    stdout: "pipe",
    stderr: "pipe"
  })

  _ <- Effect.addFinalizer(() => effect
    _ <- Console.log("[SUPERVISOR] Terminating agent process pid=" + globalThis.String(proc.pid))
    _ = proc.kill("SIGTERM")
    => true
  )

  => proc

export runMockAgentSession = (agentName: String, taskId: String) => effect
  _ <- Console.log("[RUNNER] Agent " + agentName + " started executing task " + taskId)
  _ <- Console.log("[RUNNER] Workspace clean, branch checked out.")
  _ <- Console.log("[RUNNER] Agent session completed successfully.")
  => {
    exitCode: 0,
    totalTokens: 1420,
    completed: true
  }
