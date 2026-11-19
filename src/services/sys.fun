import { Array, Effect, FileSystem, Layer, Option, Path, String } from "effect"
import * as PlatformError from "effect/PlatformError"
import * as nodeFs from "node:fs"

export schema SafeSpawnResult = {
  exitCode: Number
  stdout: String
  stderr: String
  ok: Boolean
  threw: Boolean
}

export safeSpawnSync = (cmd: Array<String>, envOpt: Any = Option.none(), cwd: String = ""): SafeSpawnResult => {
  eff = Effect.try({
    "try": () => {
      opts: Any = {}
      _cwd = match (cwd #! "")
        | true => globalThis.Object.assign(opts, { cwd: cwd })
        | false => 0
      _env = match (Option.isSome(envOpt))
        | true => globalThis.Object.assign(opts, { env: globalThis.Object.assign({}, globalThis.process.env, Option.getOrThrow(envOpt)) })
        | false => match (globalThis.Boolean(envOpt) and not Option.isNone(envOpt))
          | true => globalThis.Object.assign(opts, { env: globalThis.Object.assign({}, globalThis.process.env, envOpt) })
          | false => 0
      proc = globalThis.Bun.spawnSync(cmd, opts)
      rawOut = match (globalThis.Boolean(proc.stdout))
        | true => proc.stdout.toString()
        | false => ""
      outStr = rawOut |> String.trim
      rawErr = match (globalThis.Boolean(proc.stderr))
        | true => proc.stderr.toString()
        | false => ""
      errStr = rawErr |> String.trim
      code = match (proc.exitCode #= 0)
        | true => 0
        | false => match (globalThis.Boolean(proc.exitCode))
          | true => proc.exitCode
          | false => 1
      => {
        exitCode: code,
        stdout: outStr,
        stderr: errStr,
        ok: code #= 0,
        threw: false
      }
    },
    "catch": (err: Any) => {
      errMsg = match (globalThis.Boolean(err) and globalThis.Boolean(err.message))
        | true => globalThis.String(err.message)
        | false => globalThis.String(err)
      => {
        exitCode: 1,
        stdout: "",
        stderr: errMsg,
        ok: false,
        threw: true
      }
    }
  }) |> Effect.catch((recovered) => Effect.succeed(recovered))
  => Effect.runSync(eff)
}

export schema GitSubprocessResult = {
  exitCode: Number
  stdout: String
  stderr: String
}

export runGitCommandSync = (args: Array<String>, cwd: String = ""): GitSubprocessResult => {
  gitCmd = ["git"] |> Array.appendAll(args)
  authorName = match (globalThis.Boolean(globalThis.process.env.GIT_AUTHOR_NAME))
    | true => globalThis.process.env.GIT_AUTHOR_NAME
    | false => "Slopboss"
  authorEmail = match (globalThis.Boolean(globalThis.process.env.GIT_AUTHOR_EMAIL))
    | true => globalThis.process.env.GIT_AUTHOR_EMAIL
    | false => "slopboss@local"
  committerName = match (globalThis.Boolean(globalThis.process.env.GIT_COMMITTER_NAME))
    | true => globalThis.process.env.GIT_COMMITTER_NAME
    | false => "Slopboss"
  committerEmail = match (globalThis.Boolean(globalThis.process.env.GIT_COMMITTER_EMAIL))
    | true => globalThis.process.env.GIT_COMMITTER_EMAIL
    | false => "slopboss@local"
  envObj = {
    GIT_TERMINAL_PROMPT: "0",
    GIT_AUTHOR_NAME: authorName,
    GIT_AUTHOR_EMAIL: authorEmail,
    GIT_COMMITTER_NAME: committerName,
    GIT_COMMITTER_EMAIL: committerEmail
  }
  res = safeSpawnSync(gitCmd, envObj, cwd)
  => {
    exitCode: res.exitCode,
    stdout: res.stdout,
    stderr: res.stderr
  }
}

handleFsError = (method: String, p: String) => (err: Any) => {
  errCode = match (globalThis.Boolean(err) and globalThis.Boolean(err.code))
    | true => err.code
    | false => ""
  reason = match errCode
    | "ENOENT" => "NotFound"
    | "EACCES" => "PermissionDenied"
    | "EPERM" => "PermissionDenied"
    | "EEXIST" => "AlreadyExists"
    | "EISDIR" => "BadResource"
    | "ENOTDIR" => "BadResource"
    | "ELOOP" => "BadResource"
    | "EBUSY" => "Busy"
    | _ => "Unknown"
  syscallStr = match (globalThis.Boolean(err) and globalThis.Boolean(err.syscall))
    | true => err.syscall
    | false => method
  => PlatformError.systemError({
    _tag: reason,
    module: "FileSystem",
    method: method,
    pathOrDescriptor: p,
    syscall: syscallStr,
    cause: err
  })
}

calcAccessMode = (opt: Any): Number => {
  r = match (globalThis.Boolean(opt) and globalThis.Boolean(opt.readable))
    | true => nodeFs.constants.R_OK
    | false => 0
  w = match (globalThis.Boolean(opt) and globalThis.Boolean(opt.writable))
    | true => nodeFs.constants.W_OK
    | false => 0
  => r + w
}

export SyncFileSystem = FileSystem.make({
  access: (p: String, opt: Any) => Effect.try({
    "try": () => nodeFs.accessSync(p, calcAccessMode(opt)),
    "catch": handleFsError("access", p)
  }),
  copy: (srcPath: String, destPath: String, opt: Any) => Effect.try({
    "try": () => {
      forceVal = match (globalThis.Boolean(opt) and globalThis.Boolean(opt.overwrite))
        | true => true
        | false => false
      => nodeFs.cpSync(srcPath, destPath, { recursive: true, force: forceVal })
    },
    "catch": handleFsError("copy", srcPath)
  }),
  copyFile: (srcPath: String, destPath: String) => Effect.try({
    "try": () => nodeFs.copyFileSync(srcPath, destPath),
    "catch": handleFsError("copyFile", srcPath)
  }),
  chmod: (p: String, m: Number) => Effect.try({
    "try": () => nodeFs.chmodSync(p, m),
    "catch": handleFsError("chmod", p)
  }),
  chown: (p: String, u: Number, g: Number) => Effect.try({
    "try": () => nodeFs.chownSync(p, u, g),
    "catch": handleFsError("chown", p)
  }),
  link: (srcPath: String, destPath: String) => Effect.try({
    "try": () => nodeFs.linkSync(srcPath, destPath),
    "catch": handleFsError("link", srcPath)
  }),
  lstat: (p: String) => Effect.try({
    "try": () => {
      s = nodeFs.lstatSync(p)
      t = match s.isDirectory()
        | true => "Directory"
        | false => match s.isFile()
          | true => "File"
          | false => "Unknown"
      => {
        type: t,
        size: globalThis.BigInt(s.size)
      }
    },
    "catch": handleFsError("lstat", p)
  }),
  makeDirectory: (p: String, opt: Any) => Effect.try({
    "try": () => {
      isRec = match (globalThis.Boolean(opt) and globalThis.Boolean(opt.recursive))
        | true => true
        | false => false
      => nodeFs.mkdirSync(p, { recursive: isRec })
    },
    "catch": handleFsError("makeDirectory", p)
  }),
  makeTempDirectory: (opt: Any) => Effect.try({
    "try": () => {
      prefix = match (globalThis.Boolean(opt) and globalThis.Boolean(opt.prefix))
        | true => opt.prefix
        | false => "/tmp/"
      => nodeFs.mkdtempSync(prefix)
    },
    "catch": handleFsError("makeTempDirectory", "/tmp")
  }),
  makeTempDirectoryScoped: () => Effect.die("makeTempDirectoryScoped not implemented in SyncFileSystem"),
  makeTempFile: () => Effect.die("makeTempFile not implemented in SyncFileSystem"),
  makeTempFileScoped: () => Effect.die("makeTempFileScoped not implemented in SyncFileSystem"),
  open: () => Effect.die("open not implemented in SyncFileSystem"),
  readDirectory: (p: String) => Effect.try({
    "try": () => nodeFs.readdirSync(p),
    "catch": handleFsError("readDirectory", p)
  }),
  readFile: (p: String) => Effect.try({
    "try": () => nodeFs.readFileSync(p),
    "catch": handleFsError("readFile", p)
  }),
  readLink: (p: String) => Effect.try({
    "try": () => nodeFs.readlinkSync(p),
    "catch": handleFsError("readLink", p)
  }),
  realPath: (p: String) => Effect.try({
    "try": () => nodeFs.realpathSync(p),
    "catch": handleFsError("realPath", p)
  }),
  remove: (p: String, opt: Any) => Effect.try({
    "try": () => {
      isRec = match (globalThis.Boolean(opt) and globalThis.Boolean(opt.recursive))
        | true => true
        | false => false
      => nodeFs.rmSync(p, { recursive: isRec, force: true })
    },
    "catch": handleFsError("remove", p)
  }),
  rename: (oldP: String, newP: String) => Effect.try({
    "try": () => nodeFs.renameSync(oldP, newP),
    "catch": handleFsError("rename", oldP)
  }),
  stat: (p: String) => Effect.try({
    "try": () => {
      s = nodeFs.statSync(p)
      t = match s.isDirectory()
        | true => "Directory"
        | false => match s.isFile()
          | true => "File"
          | false => "Unknown"
      => {
        type: t,
        size: globalThis.BigInt(s.size)
      }
    },
    "catch": handleFsError("stat", p)
  }),
  symlink: (srcPath: String, destPath: String) => Effect.try({
    "try": () => nodeFs.symlinkSync(srcPath, destPath),
    "catch": handleFsError("symlink", srcPath)
  }),
  truncate: (p: String, len: Number) => Effect.try({
    "try": () => nodeFs.truncateSync(p, len),
    "catch": handleFsError("truncate", p)
  }),
  utimes: (p: String, a: Any, m: Any) => Effect.try({
    "try": () => nodeFs.utimesSync(p, a, m),
    "catch": handleFsError("utimes", p)
  }),
  watch: () => Effect.die("watch not implemented in SyncFileSystem"),
  writeFile: (p: String, data: Any) => Effect.try({
    "try": () => nodeFs.writeFileSync(p, data),
    "catch": handleFsError("writeFile", p)
  })
})

export SyncServices = {
  layer: Layer.merge(Layer.succeed(FileSystem.FileSystem, SyncFileSystem), Path.layer)
}

export runSyncWithPlatform = (effectVal: Any): Any => {
  => Effect.runSync(effectVal |> Effect.provide(SyncServices.layer))
}
