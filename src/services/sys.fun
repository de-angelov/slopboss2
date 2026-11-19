import { Array, ByteSize, Effect, FileSystem, Layer, Option, Path, Schema, Stream, String } from "effect"
import * as PlatformError from "effect/PlatformError"
import * as nodeFs from "node:fs"

export schema SafeSpawnResult = {
  exitCode: Number
  stdout: String
  stderr: String
  ok: Boolean
  threw: Boolean
}

export schema NodeError = {
  code?: String
  syscall?: String
  message?: String
}

export safeSpawnSync = (cmd: Array<String>, envOpt: Unknown = Option.none(), cwd: String = ""): SafeSpawnResult => {
  eff = Effect.try({
    "try": () => {
      opts: Any = {}
      match cwd #! ""
        | true => globalThis.Object.assign(opts, { cwd: cwd })
        | false => 0
      match envOpt
        | Some(e) => globalThis.Object.assign(opts, { env: globalThis.Object.assign({}, globalThis.process.env, e) })
        | None => 0
        | _ => match Option.fromNullishOr(envOpt)
          | Some(e) => globalThis.Object.assign(opts, { env: globalThis.Object.assign({}, globalThis.process.env, e) })
          | None => 0
      cmdArray = globalThis.Array.from(cmd)
      proc = globalThis.Bun.spawnSync(cmdArray, opts)
      rawOut = match Option.fromNullishOr(proc.stdout)
        | Some(out) => out.toString()
        | None => ""
      outStr = rawOut |> String.trim
      rawErr = match Option.fromNullishOr(proc.stderr)
        | Some(err) => err.toString()
        | None => ""
      errStr = rawErr |> String.trim
      code = match Option.fromNullishOr(proc.exitCode)
        | Some(c) => c
        | None => 1
      => {
        exitCode: code,
        stdout: outStr,
        stderr: errStr,
        ok: code #= 0,
        threw: false
      }
    },
    "catch": (err: Unknown) => {
      errDecoded = Schema.decodeUnknownOption(NodeError)(err)
      errMsg = match errDecoded
        | Some(e) => match e.message
          | Some(m) => m
          | None => globalThis.String(err)
        | None => globalThis.String(err)
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
  authorName = match Option.fromNullishOr(globalThis.process.env.GIT_AUTHOR_NAME)
    | Some(name) => name
    | None => "Slopboss"
  authorEmail = match Option.fromNullishOr(globalThis.process.env.GIT_AUTHOR_EMAIL)
    | Some(email) => email
    | None => "slopboss@local"
  committerName = match Option.fromNullishOr(globalThis.process.env.GIT_COMMITTER_NAME)
    | Some(name) => name
    | None => "Slopboss"
  committerEmail = match Option.fromNullishOr(globalThis.process.env.GIT_COMMITTER_EMAIL)
    | Some(email) => email
    | None => "slopboss@local"
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

export schema CopyOptions = {
  overwrite?: Boolean
}

export schema MakeDirectoryOptions = {
  recursive?: Boolean
  mode?: Number
}

export schema MakeTempDirectoryOptions = {
  prefix?: String
  directory?: String
}

export schema RemoveOptions = {
  recursive?: Boolean
}

export schema AccessOptions = {
  readable?: Boolean
  writable?: Boolean
}

handleFsError = (method: String, p: String) => (err: Unknown) => {
  errDecoded = Schema.decodeUnknownOption(NodeError)(err)
  errCode = match errDecoded
    | Some(e) => match e.code
      | Some(c) => c
      | None => ""
    | None => ""
  syscallStr = match errDecoded
    | Some(e) => match e.syscall
      | Some(s) => s
      | None => method
    | None => method
  => match errCode
    | "ENOENT" => PlatformError.systemError({ _tag: "NotFound", module: "FileSystem", method: method, pathOrDescriptor: p, syscall: syscallStr, cause: err })
    | "EACCES" => PlatformError.systemError({ _tag: "PermissionDenied", module: "FileSystem", method: method, pathOrDescriptor: p, syscall: syscallStr, cause: err })
    | "EPERM" => PlatformError.systemError({ _tag: "PermissionDenied", module: "FileSystem", method: method, pathOrDescriptor: p, syscall: syscallStr, cause: err })
    | "EEXIST" => PlatformError.systemError({ _tag: "AlreadyExists", module: "FileSystem", method: method, pathOrDescriptor: p, syscall: syscallStr, cause: err })
    | "EISDIR" => PlatformError.systemError({ _tag: "BadResource", module: "FileSystem", method: method, pathOrDescriptor: p, syscall: syscallStr, cause: err })
    | "ENOTDIR" => PlatformError.systemError({ _tag: "BadResource", module: "FileSystem", method: method, pathOrDescriptor: p, syscall: syscallStr, cause: err })
    | "ELOOP" => PlatformError.systemError({ _tag: "BadResource", module: "FileSystem", method: method, pathOrDescriptor: p, syscall: syscallStr, cause: err })
    | "EBUSY" => PlatformError.systemError({ _tag: "Busy", module: "FileSystem", method: method, pathOrDescriptor: p, syscall: syscallStr, cause: err })
    | _ => PlatformError.systemError({ _tag: "Unknown", module: "FileSystem", method: method, pathOrDescriptor: p, syscall: syscallStr, cause: err })
}

calcAccessMode = (opt: Unknown = 0): Number => {
  optDecoded = Schema.decodeUnknownOption(AccessOptions)(opt)
  r = match optDecoded
    | Some(o) => match o.readable
      | Some(true) => nodeFs.constants.R_OK
      | _ => 0
    | None => 0
  w = match optDecoded
    | Some(o) => match o.writable
      | Some(true) => nodeFs.constants.W_OK
      | _ => 0
    | None => 0
  => r + w
}

makeBaseInfo = (t: ("Directory" | "File" | "Unknown"), sizeNum: Number) => ({
  type: t,
  mtime: Option.none(),
  atime: Option.none(),
  birthtime: Option.none(),
  dev: globalThis.BigInt(0),
  ino: Option.none(),
  mode: 0,
  nlink: Option.none(),
  uid: Option.none(),
  gid: Option.none(),
  rdev: Option.none(),
  size: ByteSize.bytes(sizeNum),
  blksize: Option.none(),
  blocks: Option.none()
})

makeDirInfo = (sizeNum: Number) => makeBaseInfo("Directory", sizeNum)
makeFileInfo = (sizeNum: Number) => makeBaseInfo("File", sizeNum)
makeUnknownInfo = (sizeNum: Number) => makeBaseInfo("Unknown", sizeNum)

makeFileStatInfo = (isDir: Boolean, isFile: Boolean, sizeNum: Number) => {
  when (isDir) => makeDirInfo(sizeNum)
  when (isFile) => makeFileInfo(sizeNum)
  => makeUnknownInfo(sizeNum)
}

makeDirEntry = (name: String, isDir: Boolean, isFile: Boolean) => {
  when (isDir) => { name: name, type: "Directory" }
  when (isFile) => { name: name, type: "File" }
  => { name: name, type: "Unknown" }
}

export SyncFileSystem = FileSystem.make({
  access: (p: String, opt: Unknown = 0) => Effect.try({
    "try": () => nodeFs.accessSync(p, calcAccessMode(opt)),
    "catch": handleFsError("access", p)
  }),
  copy: (srcPath: String, destPath: String, opt: Unknown = 0) => Effect.try({
    "try": () => {
      optDecoded = Schema.decodeUnknownOption(CopyOptions)(opt)
      forceVal = match optDecoded
        | Some(o) => match o.overwrite
          | Some(true) => true
          | _ => false
        | None => false
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
      => makeFileStatInfo(s.isDirectory(), s.isFile(), s.size)
    },
    "catch": handleFsError("lstat", p)
  }),
  makeDirectory: (p: String, opt: Unknown = 0) => Effect.try({
    "try": () => {
      optDecoded = Schema.decodeUnknownOption(MakeDirectoryOptions)(opt)
      isRec = match optDecoded
        | Some(o) => match o.recursive
          | Some(true) => true
          | _ => false
        | None => false
      => nodeFs.mkdirSync(p, { recursive: isRec })
    },
    "catch": handleFsError("makeDirectory", p)
  }),
  makeTempDirectory: (opt: Unknown = 0) => Effect.try({
    "try": () => {
      optDecoded = Schema.decodeUnknownOption(MakeTempDirectoryOptions)(opt)
      prefix = match optDecoded
        | Some(o) => match o.prefix
          | Some(pfx) => pfx
          | None => "/tmp/"
        | None => "/tmp/"
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
  readDirectoryEntries: (p: String) => Effect.try({
    "try": () => {
      entries = nodeFs.readdirSync(p, { withFileTypes: true })
      => entries |> Array.map((e) => makeDirEntry(e.name, e.isDirectory(), e.isFile()))
    },
    "catch": handleFsError("readDirectoryEntries", p)
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
  remove: (p: String, opt: Unknown = 0) => Effect.try({
    "try": () => {
      optDecoded = Schema.decodeUnknownOption(RemoveOptions)(opt)
      isRec = match optDecoded
        | Some(o) => match o.recursive
          | Some(true) => true
          | _ => false
        | None => false
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
      => makeFileStatInfo(s.isDirectory(), s.isFile(), s.size)
    },
    "catch": handleFsError("stat", p)
  }),
  symlink: (srcPath: String, destPath: String) => Effect.try({
    "try": () => nodeFs.symlinkSync(srcPath, destPath),
    "catch": handleFsError("symlink", srcPath)
  }),
  truncate: (p: String, len?: Number) => Effect.try({
    "try": () => nodeFs.truncateSync(p, len),
    "catch": handleFsError("truncate", p)
  }),
  utimes: (p: String, a: Date | Number, m: Date | Number) => Effect.try({
    "try": () => nodeFs.utimesSync(p, a, m),
    "catch": handleFsError("utimes", p)
  }),
  watch: (p: String, opt: Unknown = 0) => Stream.die("watch not implemented in SyncFileSystem"),
  writeFile: (p: String, data: Uint8Array) => Effect.try({
    "try": () => nodeFs.writeFileSync(p, data),
    "catch": handleFsError("writeFile", p)
  })
})

export SyncServices = {
  layer: Layer.merge(Layer.succeed(FileSystem.FileSystem, SyncFileSystem), Path.layer)
}

export runSyncWithPlatform = (effectVal: Effect.Effect<Any, Any, FileSystem.FileSystem | Path.Path>): Any => {
  provided = effectVal |> Effect.provide(SyncServices.layer)
  => Effect.runSync(provided)
}
