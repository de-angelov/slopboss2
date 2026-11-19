import { afterEach, beforeEach, describe, expect, it } from "bun:test";
import { Effect, Exit, Fiber, Scope } from "effect";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import {
  BoardLockedError,
  acquireBoardLock,
  getLockPath,
  isPidAlive,
} from "../src/services/coordination.js";
import { readCoordinationReport, writeCoordinationReport } from "../src/services/coordination_report.js";

describe("Board File Lock & Stale Lease Recovery", () => {
  let tempDir: string;

  beforeEach(() => {
    tempDir = fs.mkdtempSync(path.join(os.tmpdir(), "slopboss-coord-test-"));
  });

  afterEach(() => {
    if (fs.existsSync(tempDir)) {
      fs.rmSync(tempDir, { recursive: true, force: true });
    }
  });

  it("validates and atomically persists only the current session's coordination report", async () => {
    const reportPath = path.join(tempDir, "session", "result.json");
    const invalid = await Effect.runPromise(Effect.flip(writeCoordinationReport(reportPath, { status: "later", summary: "no" })));
    expect(String(invalid)).toContain("status must be acted, idle, or blocked");
    expect(fs.existsSync(reportPath)).toBe(false);

    const expected = { status: "blocked", summary: "board command failed" };
    await Effect.runPromise(writeCoordinationReport(reportPath, expected));
    expect(JSON.parse(fs.readFileSync(reportPath, "utf8"))).toEqual(expected);
    expect(await Effect.runPromise(readCoordinationReport(reportPath))).toEqual(expected);
  });

  it("checks PID liveness correctly", () => {
    expect(isPidAlive(process.pid)).toBe(true);
    expect(isPidAlive(9999999)).toBe(false);
    expect(isPidAlive(-1)).toBe(false);
    expect(isPidAlive(0)).toBe(false);
  });

  it("single controller acquires lock cleanly and writes lock file", async () => {
    const lockPath = getLockPath(tempDir);
    expect(fs.existsSync(lockPath)).toBe(false);

    let acquiredPid = 0;
    let acquiredTimestamp = 0;

    await Effect.runPromise(
      Effect.scoped(
        Effect.gen(function* () {
          const lock = yield* acquireBoardLock(tempDir);
          acquiredPid = lock.pid;
          acquiredTimestamp = lock.timestamp;

          expect(lock.pid).toBe(process.pid);
          expect(lock.timestamp).toBeGreaterThan(0);
          expect(fs.existsSync(lockPath)).toBe(true);

          const raw = fs.readFileSync(lockPath, "utf-8");
          const parsed = JSON.parse(raw);
          expect(parsed.pid).toBe(process.pid);
          expect(parsed.timestamp).toBe(lock.timestamp);
        })
      )
    );

    expect(acquiredPid).toBe(process.pid);
    expect(acquiredTimestamp).toBeGreaterThan(0);
  });

  it("lock is automatically removed when Effect scope closes", async () => {
    const lockPath = getLockPath(tempDir);

    await Effect.runPromise(
      Effect.scoped(
        Effect.gen(function* () {
          yield* acquireBoardLock(tempDir);
          expect(fs.existsSync(lockPath)).toBe(true);
        })
      )
    );

    // After scope closes, lock file must be deleted by finalizer
    expect(fs.existsSync(lockPath)).toBe(false);
  });

  it("second controller on same board fails with BoardLockedError while first is active", async () => {
    const lockPath = getLockPath(tempDir);

    const testScope = await Effect.runPromise(Scope.make());

    try {
      // Controller 1 acquires lock within testScope
      const lock1 = await Effect.runPromise(
        Scope.provide(acquireBoardLock(tempDir), testScope)
      );
      expect(lock1.pid).toBe(process.pid);
      expect(fs.existsSync(lockPath)).toBe(true);

      // Controller 2 tries to acquire lock on the same board
      const controller2Effect = Effect.scoped(acquireBoardLock(tempDir));
      const err: any = await Effect.runPromise(Effect.flip(controller2Effect));

      expect(err._tag).toBe("BoardLockedError");
      expect(err.pid).toBe(process.pid);
      expect(err.message).toContain("locked");
    } finally {
      // Close Controller 1's scope
      await Effect.runPromise(Scope.close(testScope, Exit.void));
    }

    // After closing scope, lock is released
    expect(fs.existsSync(lockPath)).toBe(false);

    // Controller 2 can now acquire the lock cleanly
    const lock2 = await Effect.runPromise(
      Effect.scoped(acquireBoardLock(tempDir))
    );
    expect(lock2.pid).toBe(process.pid);
  });

  it("dead PID lock is recovered and acquired cleanly", async () => {
    const lockPath = getLockPath(tempDir);
    const deadPid = 9999999;

    // Simulate an orphaned stale lock from a dead process
    fs.writeFileSync(
      lockPath,
      JSON.stringify({ pid: deadPid, timestamp: Date.now() - 60000 }, null, 2),
      "utf-8"
    );
    expect(fs.existsSync(lockPath)).toBe(true);

    // acquireBoardLock should detect the dead PID, log recovery, and acquire cleanly
    await Effect.runPromise(
      Effect.scoped(
        Effect.gen(function* () {
          const lock = yield* acquireBoardLock(tempDir);
          expect(lock.pid).toBe(process.pid);

          const raw = fs.readFileSync(lockPath, "utf-8");
          const parsed = JSON.parse(raw);
          expect(parsed.pid).toBe(process.pid);
        })
      )
    );

    // After scope closes, lock is removed
    expect(fs.existsSync(lockPath)).toBe(false);
  });

  it("corrupted lock file is recovered and acquired cleanly", async () => {
    const lockPath = getLockPath(tempDir);

    // Simulate a corrupted/truncated lock file
    fs.writeFileSync(lockPath, "{ broken json ...", "utf-8");
    expect(fs.existsSync(lockPath)).toBe(true);

    await Effect.runPromise(
      Effect.scoped(
        Effect.gen(function* () {
          const lock = yield* acquireBoardLock(tempDir);
          expect(lock.pid).toBe(process.pid);

          const raw = fs.readFileSync(lockPath, "utf-8");
          const parsed = JSON.parse(raw);
          expect(parsed.pid).toBe(process.pid);
        })
      )
    );

    expect(fs.existsSync(lockPath)).toBe(false);
  });

  it("releases lock upon fiber interruption", async () => {
    const lockPath = getLockPath(tempDir);

    const fiber = Effect.runFork(
      Effect.scoped(
        Effect.gen(function* () {
          yield* acquireBoardLock(tempDir);
          yield* Effect.sleep("10 seconds");
        })
      )
    );

    // Yield to let the fiber start and acquire the lock
    await new Promise((resolve) => setTimeout(resolve, 50));
    expect(fs.existsSync(lockPath)).toBe(true);

    // Interrupt the fiber
    await Effect.runPromise(Fiber.interrupt(fiber));

    // Finalizer should have run and released the lock
    expect(fs.existsSync(lockPath)).toBe(false);
  });
});
