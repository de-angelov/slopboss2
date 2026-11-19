import { Clock, Console, Effect, FileSystem, Option, Path, Schema, String } from "effect"
import { BunServices } from "@effect/platform-bun"

export error BoardLockedError(message: String, pid: Number)

export schema BoardLock = {
  pid: Number,
  timestamp: Number
}

runSyncEffect = <A>(eff: Effect.Effect<A, Never>): A => {
  runner = Effect
  res: A = runner.runSync(eff)
  => res
}

export isPidAlive = (pid: Number) => {
  res = match
    | pid <= 0 => false
    | _ =>
      eff = Effect.try(() => globalThis.process.kill(pid, 0)) |> Effect.map(() => true) |> Effect.orElseSucceed(() => false)
      runSyncEffect(eff)
  => res
}

export getLockPath = (boardDir: String) => {
  res = match
    | boardDir |> String.endsWith("/") => boardDir + ".slopboss-board.lock"
    | _ => boardDir + "/.slopboss-board.lock"
  => res
}

acquireBoardLockScoped = (boardDir: String) => effect (unscoped) {
  pathService <- Path.Path
  fsService <- FileSystem.FileSystem

  lockPath = pathService.join(boardDir, ".slopboss-board.lock")
  lockExists <- fsService.exists(lockPath)

  _ <- match lockExists
    | false => Effect.void
    | true =>
      effect {
        readAttempt <- fsService.readFileString(lockPath) |> Effect.option
        _ <- match readAttempt
          | None =>
            effect {
              _ <- Console.log("[COORDINATION] Corrupted lock file detected at " + lockPath + ". Recovering lock.")
              _ <- fsService.remove(lockPath)
              => Unit
            }
          | Some(raw) =>
            effect {
              parseAttempt <- Effect.try(() => globalThis.JSON.parse(raw)) |> Effect.option
              _ <- match parseAttempt
                | None =>
                  effect {
                    _ <- Console.log("[COORDINATION] Corrupted lock file detected at " + lockPath + ". Recovering lock.")
                    _ <- fsService.remove(lockPath)
                    => Unit
                  }
                | Some(parsed) =>
                  decodedLock = Schema.decodeUnknownOption(BoardLock)(parsed)
                  match decodedLock
                    | Some(lock) =>
                      match
                        | lock.pid > 0 =>
                          alive = isPidAlive(lock.pid)
                          match alive
                            | true =>
                              Effect.fail(BoardLockedError({
                                message: "Board at " + boardDir + " is locked by active PID " + globalThis.String(lock.pid),
                                pid: lock.pid
                              }))
                            | false =>
                              effect {
                                _ <- Console.log("[COORDINATION] Stale lock detected for dead PID " + globalThis.String(lock.pid) + ". Recovering lock.")
                                _ <- fsService.remove(lockPath)
                                => Unit
                              }
                        | _ =>
                          effect {
                            _ <- Console.log("[COORDINATION] Corrupted lock file detected at " + lockPath + ". Recovering lock.")
                            _ <- fsService.remove(lockPath)
                            => Unit
                          }
                    | _ =>
                      effect {
                        _ <- Console.log("[COORDINATION] Corrupted lock file detected at " + lockPath + ". Recovering lock.")
                        _ <- fsService.remove(lockPath)
                        => Unit
                      }
              => Unit
            }
        => Unit
      }

  currentPid: Number = globalThis.process.pid
  currentTime <- Clock.currentTimeMillis

  lockData = globalThis.JSON.stringify({ pid: currentPid, timestamp: currentTime })
  _ <- fsService.writeFileString(lockPath, lockData)

  cleanupLock = effect {
    matchingExists <- fsService.exists(lockPath)
    _ <- match matchingExists
      | true =>
        effect {
          rawOption <- fsService.readFileString(lockPath) |> Effect.option
          _ <- match rawOption
            | Some(raw) =>
              effect {
                parseOption <- Effect.try(() => globalThis.JSON.parse(raw)) |> Effect.option
                _ <- match parseOption
                  | Some(parsed) =>
                    decodedLock = Schema.decodeUnknownOption(BoardLock)(parsed)
                    match decodedLock
                      | Some(lock) =>
                        match
                          | lock.pid #= currentPid and lock.timestamp #= currentTime =>
                            fsService.remove(lockPath) |> Effect.ignore
                          | _ => Effect.void
                      | _ => Effect.void
                  | _ => Effect.void
                => Unit
              }
            | _ => Effect.void
          => Unit
        }
      | false => Effect.void
    => Unit
  } |> Effect.ignore

  _ <- Effect.addFinalizer(() => effect {
    _ <- Console.log("[COORDINATION] Releasing board lock at " + lockPath)
    _ <- cleanupLock
    => Unit
  })

  => {
    pid: currentPid,
    timestamp: currentTime
  }
}

export acquireBoardLock = (boardDir: String) =>
  acquireBoardLockScoped(boardDir).pipe(Effect.provide(BunServices.layer))
