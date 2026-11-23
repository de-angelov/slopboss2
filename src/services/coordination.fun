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
  when (pid <= 0) => false
  eff = Effect.try(() => process.kill(pid, 0)) |> map(() => true) |> orElseSucceed(() => false)
  => runSyncEffect(eff)
}

export getLockPath = (boardDir: String) => {
  when (boardDir |> endsWith("/")) => boardDir + ".slopboss-board.lock"
  => boardDir + "/.slopboss-board.lock"
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
  when (lock.pid <= 0) => logAndRemoveLock(fsService, lockPath, "Corrupted lock file detected")
  when (not isPidAlive(lock.pid)) => logAndRemoveLock(fsService, lockPath, "Stale lock detected for dead PID " + lock.pid)
  => Effect.fail(BoardLockedError({
    message: "Board at " + boardDir + " is locked by active PID " + lock.pid,
    pid: lock.pid
  }))
}

handleExistingLock = (fsService: FileSystem.FileSystem, lockPath: String, boardDir: String) => effect {
  readAttempt <- fsService.readFileString(lockPath) |> option
  parsed = readAttempt |> flatMap(tryParseLockFile)
  _ <- match parsed
    | Some(lock) => handleValidLock(fsService, lockPath, boardDir, lock)
    | None => logAndRemoveLock(fsService, lockPath, "Corrupted lock file detected")
  => Unit
}

removeLockIfOwned = (fsService: FileSystem.FileSystem, lockPath: String, parsed: Option<BoardLock>, lock: BoardLock, currentPid: Number, currentTime: Number) =>
  match (Option.isSome(parsed) and lock.pid #= currentPid and lock.timestamp #= currentTime)
    | true => fsService.remove(lockPath) |> ignore
    | false => Effect.void

releaseOwnLock = (fsService: FileSystem.FileSystem, lockPath: String, currentPid: Number, currentTime: Number) => effect {
  lockExists <- fsService.exists(lockPath)
  _ <- match lockExists
    | false => Effect.void
    | true => effect {
      rawOption <- fsService.readFileString(lockPath) |> option
      parsed = rawOption |> flatMap(tryParseLockFile)
      lock = parsed |> getOrElse(() => ({ pid: 0, timestamp: 0 }))
      _ <- removeLockIfOwned(fsService, lockPath, parsed, lock, currentPid, currentTime)
      => Unit
    }
  => Unit
} |> ignore

// --- Main lock acquisition ---

acquireBoardLockScoped = (boardDir: String) => effect (unscoped) {
  pathService <- Path.Path
  fsService <- FileSystem.FileSystem

  lockPath = pathService.join(boardDir, ".slopboss-board.lock")
  lockExists <- fsService.exists(lockPath)

  _ <- match lockExists
    | false => Effect.void
    | true => handleExistingLock(fsService, lockPath, boardDir)

  currentPid: Number = process.pid
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
