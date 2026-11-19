import { Effect, FileSystem, Layer, Path } from "effect";
import * as PlatformError from "effect/PlatformError";
import * as nodeFs from "node:fs";

export const handleFsError = (method: string, path: string) => (err: any) => {
  let reason = "Unknown";
  switch (err?.code) {
    case "ENOENT":
      reason = "NotFound";
      break;
    case "EACCES":
    case "EPERM":
      reason = "PermissionDenied";
      break;
    case "EEXIST":
      reason = "AlreadyExists";
      break;
    case "EISDIR":
    case "ENOTDIR":
    case "ELOOP":
      reason = "BadResource";
      break;
    case "EBUSY":
      reason = "Busy";
      break;
  }
  return PlatformError.systemError({
    _tag: reason as any,
    module: "FileSystem",
    method,
    pathOrDescriptor: path,
    syscall: err?.syscall || method,
    cause: err,
  });
};

export const SyncFileSystem = FileSystem.make({
  access: (p, opt) =>
    Effect.try({
      try: () => {
        let mode = nodeFs.constants.F_OK;
        if (opt?.readable) mode |= nodeFs.constants.R_OK;
        if (opt?.writable) mode |= nodeFs.constants.W_OK;
        return nodeFs.accessSync(p, mode);
      },
      catch: handleFsError("access", p),
    }),
  copy: (from, to, opt) =>
    Effect.try({
      try: () => nodeFs.cpSync(from, to, { recursive: true, force: opt?.overwrite }),
      catch: handleFsError("copy", from),
    }),
  copyFile: (from, to) =>
    Effect.try({
      try: () => nodeFs.copyFileSync(from, to),
      catch: handleFsError("copyFile", from),
    }),
  chmod: (p, m) =>
    Effect.try({
      try: () => nodeFs.chmodSync(p, m),
      catch: handleFsError("chmod", p),
    }),
  chown: (p, u, g) =>
    Effect.try({
      try: () => nodeFs.chownSync(p, u, g),
      catch: handleFsError("chown", p),
    }),
  link: (from, to) =>
    Effect.try({
      try: () => nodeFs.linkSync(from, to),
      catch: handleFsError("link", from),
    }),
  lstat: (p) =>
    Effect.try({
      try: () => {
        const s = nodeFs.lstatSync(p);
        return {
          type: s.isDirectory() ? "Directory" : s.isFile() ? "File" : "Unknown",
          size: BigInt(s.size),
        } as any;
      },
      catch: handleFsError("lstat", p),
    }),
  makeDirectory: (p, opt) =>
    Effect.try({
      try: () => nodeFs.mkdirSync(p, { recursive: opt?.recursive }),
      catch: handleFsError("makeDirectory", p),
    }),
  makeTempDirectory: (opt) =>
    Effect.try({
      try: () => nodeFs.mkdtempSync(opt?.prefix || "/tmp/"),
      catch: handleFsError("makeTempDirectory", "/tmp"),
    }),
  makeTempDirectoryScoped: () => Effect.die("makeTempDirectoryScoped not implemented in SyncFileSystem"),
  makeTempFile: () => Effect.die("makeTempFile not implemented in SyncFileSystem"),
  makeTempFileScoped: () => Effect.die("makeTempFileScoped not implemented in SyncFileSystem"),
  open: () => Effect.die("open not implemented in SyncFileSystem"),
  readDirectory: (p) =>
    Effect.try({
      try: () => nodeFs.readdirSync(p),
      catch: handleFsError("readDirectory", p),
    }),
  readFile: (p) =>
    Effect.try({
      try: () => nodeFs.readFileSync(p),
      catch: handleFsError("readFile", p),
    }),
  readLink: (p) =>
    Effect.try({
      try: () => nodeFs.readlinkSync(p),
      catch: handleFsError("readLink", p),
    }),
  realPath: (p) =>
    Effect.try({
      try: () => nodeFs.realpathSync(p),
      catch: handleFsError("realPath", p),
    }),
  remove: (p, opt) =>
    Effect.try({
      try: () => nodeFs.rmSync(p, { recursive: opt?.recursive, force: true }),
      catch: handleFsError("remove", p),
    }),
  rename: (oldP, newP) =>
    Effect.try({
      try: () => nodeFs.renameSync(oldP, newP),
      catch: handleFsError("rename", oldP),
    }),
  stat: (p) =>
    Effect.try({
      try: () => {
        const s = nodeFs.statSync(p);
        return {
          type: s.isDirectory() ? "Directory" : s.isFile() ? "File" : "Unknown",
          size: BigInt(s.size),
        } as any;
      },
      catch: handleFsError("stat", p),
    }),
  symlink: (from, to) =>
    Effect.try({
      try: () => nodeFs.symlinkSync(from, to),
      catch: handleFsError("symlink", from),
    }),
  truncate: (p, len) =>
    Effect.try({
      try: () => nodeFs.truncateSync(p, len),
      catch: handleFsError("truncate", p),
    }),
  utimes: (p, a, m) =>
    Effect.try({
      try: () => nodeFs.utimesSync(p, a, m),
      catch: handleFsError("utimes", p),
    }),
  watch: () => Effect.die("watch not implemented in SyncFileSystem"),
  writeFile: (p, data) =>
    Effect.try({
      try: () => nodeFs.writeFileSync(p, data),
      catch: handleFsError("writeFile", p),
    }),
});

export const SyncServices = {
  layer: Layer.merge(Layer.succeed(FileSystem.FileSystem, SyncFileSystem), Path.layer),
};

export interface SafeSpawnResult {
  exitCode: number;
  stdout: string;
  stderr: string;
  ok: boolean;
  threw: boolean;
}

export function safeSpawnSync(
  cmd: string[],
  env?: Record<string, string>,
  cwd?: string
): SafeSpawnResult {
  try {
    const proc = Bun.spawnSync(cmd, {
      cwd: cwd || undefined,
      env: env ? { ...process.env, ...env } : undefined,
    });
    return {
      exitCode: proc.exitCode ?? 1,
      stdout: proc.stdout.toString().trim(),
      stderr: proc.stderr.toString().trim(),
      ok: proc.exitCode === 0,
      threw: false,
    };
  } catch (err: any) {
    return {
      exitCode: 1,
      stdout: "",
      stderr: err?.message || String(err),
      ok: false,
      threw: true,
    };
  }
}

export function runGitCommandSync(
  args: string[],
  cwd?: string
): { exitCode: number; stdout: string; stderr: string } {
  const res = safeSpawnSync(
    ["git", ...args],
    {
      GIT_TERMINAL_PROMPT: "0",
      GIT_AUTHOR_NAME: process.env.GIT_AUTHOR_NAME || "Slopboss",
      GIT_AUTHOR_EMAIL: process.env.GIT_AUTHOR_EMAIL || "slopboss@local",
      GIT_COMMITTER_NAME: process.env.GIT_COMMITTER_NAME || "Slopboss",
      GIT_COMMITTER_EMAIL: process.env.GIT_COMMITTER_EMAIL || "slopboss@local",
    },
    cwd
  );
  return {
    exitCode: res.exitCode,
    stdout: res.stdout,
    stderr: res.stderr,
  };
}
