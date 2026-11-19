import { pipe } from "effect";
import { match, P } from "ts-pattern";

import { Clock, Console, Effect, FileSystem, Option, Path, Schema, String } from "effect";

import { BunServices } from "@effect/platform-bun";

export class BoardLockedError$Class extends Schema.TaggedError<BoardLockedError$Class>()("BoardLockedError", {
  message: Schema.String,
  pid: Schema.Number
}) {}
export type BoardLockedError = InstanceType<typeof BoardLockedError$Class>;
export const BoardLockedError = (function(args: ConstructorParameters<typeof BoardLockedError$Class>[0]): BoardLockedError { return new BoardLockedError$Class(args); }) as { (args: ConstructorParameters<typeof BoardLockedError$Class>[0]): BoardLockedError; new (args: ConstructorParameters<typeof BoardLockedError$Class>[0]): BoardLockedError };

export const BoardLock = Schema.Struct({
  pid: Schema.Number,
  timestamp: Schema.Number
});
export type BoardLock = typeof BoardLock.Type;
export const BoardLockFromUnknown = (input: unknown): BoardLock => Schema.decodeUnknownSync(BoardLock)(input);

const runSyncEffect = <A,>(eff: Effect.Effect<A, never>): A => {
  const runner = Effect;
  const res: A = runner.runSync(eff);
  return (res);
};

export const isPidAlive = (pid: number) => {
  const res = ((pid <= 0) ? false : (() => {
  const eff = pipe(
  Effect.try(() => globalThis.process.kill(pid, 0)),
  Effect.map(() => true),
  Effect.orElseSucceed(() => false)
);
  return runSyncEffect(eff);
})());
  return (res);
};

export const getLockPath = (boardDir: string) => {
  const res = (pipe(
  boardDir,
  String.endsWith("/")
) ? (boardDir + ".slopboss-board.lock") : (boardDir + "/.slopboss-board.lock"));
  return (res);
};

const BoardLockJson = Schema.fromJsonString(BoardLock);

const tryParseLockFile = (raw: string) => {
  return Schema.decodeUnknownOption(BoardLockJson)(raw);
};

const logAndRemoveLock = (fsService: FileSystem.FileSystem, lockPath: string, reason: string) => Effect.scoped(Effect.gen(function* () {
    yield* Console.log((((("[COORDINATION] " + reason) + " at ") + lockPath) + ". Recovering lock."));
    yield* fsService.remove(lockPath);
    return;
  }));

const handleValidLock = (fsService: FileSystem.FileSystem, lockPath: string, boardDir: string, lock: BoardLock) => {
  const res = ((lock.pid > 0) ? (() => {
  const alive = isPidAlive(lock.pid);
  return match(alive)
  .with(true, () => {
  return Effect.fail(BoardLockedError({ message: ((("Board at " + boardDir) + " is locked by active PID ") + globalThis.String(lock.pid)), pid: lock.pid }));
})
  .otherwise(() => {
  return logAndRemoveLock(fsService, lockPath, ("Stale lock detected for dead PID " + globalThis.String(lock.pid)));
});
})() : (() => {
  return logAndRemoveLock(fsService, lockPath, "Corrupted lock file detected");
})());
  return (res);
};

const handleExistingLock = (fsService: FileSystem.FileSystem, lockPath: string, boardDir: string) => Effect.scoped(Effect.gen(function* () {
    const readAttempt = yield* pipe(
  fsService.readFileString(lockPath),
  Effect.option
);
    yield* match(readAttempt)
  .with({ _tag: "None" }, () => {
  return logAndRemoveLock(fsService, lockPath, "Corrupted lock file detected");
})
  .with({ _tag: "Some" }, ($matched) => {
    const { value: raw } = $matched as unknown as { value: typeof $matched extends import("effect").Option.Some<infer V> ? V : any };
  const parsed = tryParseLockFile(raw);
  return match(parsed)
  .with({ _tag: "Some" }, ($matched) => {
    const { value: lock } = $matched as unknown as { value: typeof $matched extends import("effect").Option.Some<infer V> ? V : any };
    return handleValidLock(fsService, lockPath, boardDir, lock);
  })
  .with({ _tag: "None" }, () => logAndRemoveLock(fsService, lockPath, "Corrupted lock file detected"))
  .exhaustive();
  })
  .exhaustive();
    return;
  }));

const releaseOwnLock = (fsService: FileSystem.FileSystem, lockPath: string, currentPid: number, currentTime: number) => pipe(
  Effect.scoped(Effect.gen(function* () {
    const lockExists = yield* fsService.exists(lockPath);
    yield* match(lockExists)
  .with(false, () => Effect.void)
  .otherwise(() => {
  return Effect.scoped(Effect.gen(function* () {
    const rawOption = yield* pipe(
  fsService.readFileString(lockPath),
  Effect.option
);
    yield* match(rawOption)
  .with({ _tag: "Some" }, ($matched) => {
    const { value: raw } = $matched as unknown as { value: typeof $matched extends import("effect").Option.Some<infer V> ? V : any };
  const parsed = tryParseLockFile(raw);
  return match(parsed)
  .with({ _tag: "Some" }, ($matched) => {
    const { value: lock } = $matched as unknown as { value: typeof $matched extends import("effect").Option.Some<infer V> ? V : any };
  return (((lock.pid === currentPid) && (lock.timestamp === currentTime)) ? (() => {
  return pipe(
  fsService.remove(lockPath),
  Effect.ignore
);
})() : Effect.void);
  })
  .otherwise(() => Effect.void);
  })
  .otherwise(() => Effect.void);
    return;
  }));
});
    return;
  })),
  Effect.ignore
);

const acquireBoardLockScoped = (boardDir: string) => Effect.gen(function* () {
    const pathService = yield* Path.Path;
    const fsService = yield* FileSystem.FileSystem;
    const lockPath = pathService.join(boardDir, ".slopboss-board.lock");
    const lockExists = yield* fsService.exists(lockPath);
    yield* match(lockExists)
  .with(false, () => Effect.void)
  .otherwise(() => handleExistingLock(fsService, lockPath, boardDir));
    const currentPid: number = globalThis.process.pid;
    const currentTime = yield* Clock.currentTimeMillis;
    const lockData: string = Schema.encodeSync(BoardLockJson)({ pid: currentPid, timestamp: currentTime });
    yield* fsService.writeFileString(lockPath, lockData);
    yield* Effect.addFinalizer(() => Effect.scoped(Effect.gen(function* () {
    yield* Console.log(("[COORDINATION] Releasing board lock at " + lockPath));
    yield* releaseOwnLock(fsService, lockPath, currentPid, currentTime);
    return;
  })));
    return { pid: currentPid, timestamp: currentTime };
  });

export const acquireBoardLock = (boardDir: string) => {
  return acquireBoardLockScoped(boardDir).pipe(Effect.provide(BunServices.layer));
};
