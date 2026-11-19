import { Array, Console, Effect, Option, Schema, Scope, String } from "effect"
import { parseAgyLine, SessionCompleted } from "./provider.js"

export schema SessionResult = {
  exitCode: Number
  totalTokens: Number
  completed: Boolean
}

// Spawns a process wrapped in the caller's Effect Scope lifecycle.
// On Scope exit (interruption, error, or completion), SIGTERM is sent to guarantee no orphaned processes.
export spawnScopedProcess = (cmd: Array<String>, cwd: String) => effect (unscoped) {
  cmdArr = globalThis.Array.from(cmd)
  proc = globalThis.Bun.spawn(cmdArr, {
    cwd: cwd,
    stdin: "pipe",
    stdout: "pipe",
    stderr: "pipe"
  })

  _ <- Effect.addFinalizer(() => effect {
    _ <- Console.log("[SUPERVISOR] Terminating agent process pid=" + globalThis.String(proc.pid))
    _ = proc.kill("SIGTERM")
    => true
  })

  => proc
}

// Executes an agent subprocess to completion inside an Effect Scope,
// piping stdin, collecting stdout stream, and extracting structured events.
export runAgentSession = (cmd: Array<String>, cwd: String, stdinText: Option<String>) => effect {
  proc <- spawnScopedProcess(cmd, cwd)
  _ = match stdinText
    | Some(text) =>
      proc.stdin.write(text)
      proc.stdin.flush()
      proc.stdin.end()
    | None =>
      proc.stdin.end()
  rawOut <- js globalThis.Bun.readableStreamToText(proc.stdout)
  outText = rawOut |> Option.flatMap(Schema.decodeUnknownOption(Schema.String)) |> Option.getOrElse(() => "")
  rawCode <- js proc.exited
  code = rawCode |> Option.flatMap(Schema.decodeUnknownOption(Schema.Number)) |> Option.getOrElse(() => 0)
  lines = outText |> String.split("\n")
  events = lines |> Array.map(parseAgyLine) |> Array.getSomes
  isCompleted = events |> Array.some((e) => match e
    | SessionCompleted => true
    | _ => false
  )
  => {
    exitCode: code,
    totalTokens: lines |> Array.length,
    completed: isCompleted or code #= 0
  }
}

export runMockAgentSession = (agentName: String, taskId: String) => effect {
  _ <- Console.log("[RUNNER] Agent " + agentName + " started executing task " + taskId)
  _ <- Console.log("[RUNNER] Workspace clean, branch checked out.")
  _ <- Console.log("[RUNNER] Agent session completed successfully.")
  => {
    exitCode: 0,
    totalTokens: 1420,
    completed: true
  }
}
