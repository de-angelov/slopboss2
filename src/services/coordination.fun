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

// --- Helpers ---

BoardLockJson = Schema.fromJsonString(BoardLock)

tryParseLockFile = (raw: String) =>
  Schema.decodeUnknownOption(BoardLockJson)(raw)

logAndRemoveLock = (fsService: FileSystem.FileSystem, lockPath: String, reason: String) => effect {
  _ <- Console.log("[COORDINATION] " + reason + " at " + lockPath + ". Recovering lock.")
  _ <- fsService.remove(lockPath)
  => Unit
}

handleValidLock = (fsService: FileSystem.FileSystem, lockPath: String, boardDir: String, lock: BoardLock) => {
  res = match
    | lock.pid > 0 =>
      alive = isPidAlive(lock.pid)
      match alive
        | true =>
          Effect.fail(BoardLockedError({
            message: "Board at " + boardDir + " is locked by active PID " + globalThis.String(lock.pid),
            pid: lock.pid
          }))
        | false =>
          logAndRemoveLock(fsService, lockPath, "Stale lock detected for dead PID " + globalThis.String(lock.pid))
    | _ =>
      logAndRemoveLock(fsService, lockPath, "Corrupted lock file detected")
  => res
}

handleExistingLock = (fsService: FileSystem.FileSystem, lockPath: String, boardDir: String) => effect {
  readAttempt <- fsService.readFileString(lockPath) |> Effect.option
  _ <- match readAttempt
    | None =>
      logAndRemoveLock(fsService, lockPath, "Corrupted lock file detected")
    | Some(raw) =>
      parsed = tryParseLockFile(raw)
      match parsed
        | Some(lock) => handleValidLock(fsService, lockPath, boardDir, lock)
        | None => logAndRemoveLock(fsService, lockPath, "Corrupted lock file detected")
  => Unit
}

releaseOwnLock = (fsService: FileSystem.FileSystem, lockPath: String, currentPid: Number, currentTime: Number) => effect {
  lockExists <- fsService.exists(lockPath)
  _ <- match lockExists
    | false => Effect.void
    | true =>
      effect {
        rawOption <- fsService.readFileString(lockPath) |> Effect.option
        _ <- match rawOption
          | Some(raw) =>
            parsed = tryParseLockFile(raw)
            match parsed
              | Some(lock) =>
                match
                  | lock.pid #= currentPid and lock.timestamp #= currentTime =>
                    fsService.remove(lockPath) |> Effect.ignore
                  | _ => Effect.void
              | _ => Effect.void
          | _ => Effect.void
        => Unit
      }
  => Unit
} |> Effect.ignore

// --- Main lock acquisition ---

acquireBoardLockScoped = (boardDir: String) => effect (unscoped) {
  pathService <- Path.Path
  fsService <- FileSystem.FileSystem

  lockPath = pathService.join(boardDir, ".slopboss-board.lock")
  lockExists <- fsService.exists(lockPath)

  _ <- match lockExists
    | false => Effect.void
    | true => handleExistingLock(fsService, lockPath, boardDir)

  currentPid: Number = globalThis.process.pid
  currentTime <- Clock.currentTimeMillis

  lockData: String = Schema.encodeSync(BoardLockJson)({ pid: currentPid, timestamp: currentTime })
  _ <- fsService.writeFileString(lockPath, lockData)

  _ <- Effect.addFinalizer(() => effect {
    _ <- Console.log("[COORDINATION] Releasing board lock at " + lockPath)
    _ <- releaseOwnLock(fsService, lockPath, currentPid, currentTime)
    => Unit
  })

  => {
    pid: currentPid,
    timestamp: currentTime
  }
}

export acquireBoardLock = (boardDir: String) =>
  acquireBoardLockScoped(boardDir).pipe(Effect.provide(BunServices.layer))
