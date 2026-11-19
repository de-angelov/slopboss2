import { Console, Effect, Option } from "effect"

ts {
  import * as fs from "node:fs";
  import * as path from "node:path";
  import { Option } from "effect";

  export interface BoardLock {
    pid: number;
    timestamp: number;
  }

  export function getLockFilePath(boardDir: string): string {
    return path.join(boardDir, ".slopboss-board.lock");
  }

  export function checkPidAlive(pid: number): boolean {
    if (pid <= 0) return false;
    try {
      process.kill(pid, 0);
      return true;
    } catch {
      return false;
    }
  }

  export function readLockFile(lockPath: string): Option.Option<BoardLock> {
    try {
      if (!fs.existsSync(lockPath)) {
        return Option.none();
      }
      const raw = fs.readFileSync(lockPath, "utf-8");
      const parsed = JSON.parse(raw);
      if (typeof parsed.pid === "number") {
        return Option.some({
          pid: parsed.pid,
          timestamp: typeof parsed.timestamp === "number" ? parsed.timestamp : 0
        });
      }
      return Option.some({ pid: -1, timestamp: 0 });
    } catch {
      return Option.some({ pid: -1, timestamp: 0 });
    }
  }

  export function writeLockFile(lockPath: string, pid: number, timestamp: number): void {
    const data = JSON.stringify({ pid, timestamp }, null, 2);
    fs.writeFileSync(lockPath, data, "utf-8");
  }

  export function removeLockFile(lockPath: string): void {
    try {
      if (fs.existsSync(lockPath)) {
        fs.unlinkSync(lockPath);
      }
    } catch {}
  }

  export function removeLockFileIfMatching(lockPath: string, pid: number, timestamp: number): void {
    try {
      if (fs.existsSync(lockPath)) {
        const raw = fs.readFileSync(lockPath, "utf-8");
        const parsed = JSON.parse(raw);
        if (parsed.pid === pid && parsed.timestamp === timestamp) {
          fs.unlinkSync(lockPath);
        }
      }
    } catch {}
  }
}

export error BoardLockedError(message: String, pid: Number)

export schema BoardLock = {
  pid: Number,
  timestamp: Number
}

export isPidAlive = (pid: Number) =>
  checkPidAlive(pid)

export getLockPath = (boardDir: String) =>
  getLockFilePath(boardDir)

export acquireBoardLock = (boardDir: String) => effect (unscoped) {
  lockPath = getLockFilePath(boardDir)
  existing = readLockFile(lockPath)

  _ <- match existing
    | None => Effect.succeed(true)
    | Some(lock) when lock.pid > 0 =>
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
            _ = removeLockFile(lockPath)
            => true
          }
    | _ =>
      effect {
        _ <- Console.log("[COORDINATION] Corrupted lock file detected at " + lockPath + ". Recovering lock.")
        _ = removeLockFile(lockPath)
        => true
      }

  currentPid = ts { process.pid }
  currentTime = ts { Date.now() }

  _ = writeLockFile(lockPath, currentPid, currentTime)

  _ <- Effect.addFinalizer(() => effect {
    _ <- Console.log("[COORDINATION] Releasing board lock at " + lockPath)
    _ = removeLockFileIfMatching(lockPath, currentPid, currentTime)
    => true
  })

  => {
    pid: currentPid,
    timestamp: currentTime
  }
}
