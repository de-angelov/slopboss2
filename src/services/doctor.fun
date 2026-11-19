import { Array, Effect, Option, Schema, String } from "effect"
import { FileSystem, Path } from "effect"
import { BunServices } from "@effect/platform-bun"
import { safeSpawnSync, SyncServices } from "./platform.js"

export schema CheckResult = {
  name: String
  ok: Boolean
  message: String
  required: Boolean
}

export schema CheckResultTs = CheckResult

export schema DoctorReport = {
  isHealthy: Boolean
  checks: Array<CheckResult>
}

export schema DoctorReportTs = DoctorReport

export checkGitInstalledWorkflow = (gitCmd: String) => effect {
  res = safeSpawnSync([gitCmd, "--version"])
  outText = res.stdout |> String.trim
  successMsg = match outText #= ""
    | true => "Git is installed"
    | false => outText
  when (res.ok) => {
    name: "git",
    ok: true,
    message: successMsg,
    required: true
  }
  threwMsg = match res.stderr #= ""
    | true => "git executable not found in PATH"
    | false => res.stderr
  when (res.threw) => {
    name: "git",
    ok: false,
    message: threwMsg,
    required: true
  }
  defaultErr = match res.stdout #= ""
    | true => "git command exited with code " + globalThis.String(res.exitCode)
    | false => res.stdout
  err = match res.stderr #= ""
    | true => defaultErr
    | false => res.stderr
  => {
    name: "git",
    ok: false,
    message: err,
    required: true
  }
}

export checkGitInstalledSync = (gitCmd: String = "git") => Effect.runSync(checkGitInstalledWorkflow(gitCmd))

export checkGitInstalled = () => effect {
  res <- checkGitInstalledWorkflow("git")
  => res
}

export checkGitInstalledWith = (gitCmd: String) => effect {
  res <- checkGitInstalledWorkflow(gitCmd)
  => res
}

export checkBunInstalledWorkflow = (bunCmd: String) => effect {
  res = safeSpawnSync([bunCmd, "--version"])
  outText = res.stdout |> String.trim
  successMsg = match outText #= ""
    | true => "Bun is installed"
    | false => "bun " + outText
  when (res.ok) => {
    name: "bun",
    ok: true,
    message: successMsg,
    required: true
  }
  threwMsg = match res.stderr #= ""
    | true => "bun executable not found in PATH"
    | false => res.stderr
  when (res.threw) => {
    name: "bun",
    ok: false,
    message: threwMsg,
    required: true
  }
  defaultErr = match res.stdout #= ""
    | true => "bun command exited with code " + globalThis.String(res.exitCode)
    | false => res.stdout
  err = match res.stderr #= ""
    | true => defaultErr
    | false => res.stderr
  => {
    name: "bun",
    ok: false,
    message: err,
    required: true
  }
}

export checkBunInstalledSync = (bunCmd: String = "bun") => Effect.runSync(checkBunInstalledWorkflow(bunCmd))

export checkBunInstalled = () => effect {
  res <- checkBunInstalledWorkflow("bun")
  => res
}

export checkBunInstalledWith = (bunCmd: String) => effect {
  res <- checkBunInstalledWorkflow(bunCmd)
  => res
}

export checkProviderInstalledWorkflow = (providers: Array<String>) => effect {
  listToCheck = match providers.length #= 0
    | true => ["agy", "gemini"]
    | false => providers

  mut found = Option.none()
  _ = listToCheck |> Array.forEach((p) => {
    when (Option.isSome(found)) => true
    res = safeSpawnSync([p, "--version"])
    when (res.ok) {
      ver = res.stdout |> String.trim
      label = match p
        | "agy" => "Antigravity CLI (agy)"
        | "gemini" => "Gemini CLI"
        | _ => p
      verSuffix = match ver #= ""
        | true => ""
        | false => " (v" + ver + ")"
      found = Option.some({
        name: "provider",
        ok: true,
        message: label + " available" + verSuffix,
        required: true
      })
    }
    => true
  })

  defaultProviderRes = {
    name: "provider",
    ok: false,
    message: "Neither 'agy' nor 'gemini' CLI executable found in PATH",
    required: true
  }

  res = match found
    | Some(c) => c
    | None => defaultProviderRes
  => res
}

export checkProviderInstalledSync = (providers: Array<String> = []) => Effect.runSync(checkProviderInstalledWorkflow(providers))

export checkProviderInstalled = () => effect {
  res <- checkProviderInstalledWorkflow([])
  => res
}

export checkProviderInstalledWith = (providers: Array<String>) => effect {
  res <- checkProviderInstalledWorkflow(providers)
  => res
}

export checkBoardDirectoryWorkflow = (boardDir: String) => effect {
  when (boardDir #= "") => {
    name: "board",
    ok: false,
    message: "Board directory does not exist: " + boardDir,
    required: true
  }

  fs <- FileSystem.FileSystem
  path <- Path.Path

  exists <- fs.exists(boardDir)
  when (not exists) => {
    name: "board",
    ok: false,
    message: "Board directory does not exist: " + boardDir,
    required: true
  }

  statRes <- fs.stat(boardDir) |> Effect.catch((_) => Effect.succeed({ type: "Unknown" }))
  when (statRes.type #! "Directory") => {
    name: "board",
    ok: false,
    message: "Board path is not a directory: " + boardDir,
    required: true
  }

  requiredFiles = ["TASKS.md", "ARCHIVE.md", "AGENTS.md"]
  missingFiles <- requiredFiles |> Effect.filter((file) => effect {
    filePath = path.join(boardDir, file)
    fileEx <- fs.exists(filePath)
    => not fileEx
  })

  when (missingFiles.length > 0) => {
    name: "board",
    ok: false,
    message: "Missing required board files in " + boardDir + ": " + (missingFiles |> Array.join(", ")),
    required: true
  }

  => {
    name: "board",
    ok: true,
    message: "Board directory contains all required files (" + (requiredFiles |> Array.join(", ")) + ")",
    required: true
  }
}

export checkBoardDirectory = (boardDir: String) => effect {
  res <- checkBoardDirectoryWorkflow(boardDir) |> Effect.provide(BunServices.layer)
  => res
}

export checkBoardDirectorySync = (boardDir: String) => Effect.runSync(checkBoardDirectoryWorkflow(boardDir) |> Effect.provide(SyncServices.layer))

export checkWorkspacesWorkflow = (boardDir: String) => effect {
  when (boardDir #= "") => {
    name: "workspaces",
    ok: false,
    message: "Board directory does not exist: " + boardDir,
    required: true
  }

  fs <- FileSystem.FileSystem
  path <- Path.Path

  exists <- fs.exists(boardDir)
  when (not exists) => {
    name: "workspaces",
    ok: false,
    message: "Board directory does not exist: " + boardDir,
    required: true
  }

  workspacesPath = path.join(boardDir, "workspaces")
  wsExists <- fs.exists(workspacesPath)
  when (not wsExists) => {
    name: "workspaces",
    ok: false,
    message: "Workspaces directory does not exist at " + workspacesPath,
    required: true
  }

  statRes <- fs.stat(workspacesPath) |> Effect.catch((_) => Effect.succeed({ type: "Unknown" }))
  when (statRes.type #! "Directory") => {
    name: "workspaces",
    ok: false,
    message: "Workspaces path is not a directory: " + workspacesPath,
    required: true
  }

  accessEffect = fs.access(workspacesPath, { readable: true, writable: true }) |> Effect.as(true) |> Effect.catch((_) => Effect.succeed(false))
  accessRes <- accessEffect

  when (not accessRes) => {
    name: "workspaces",
    ok: false,
    message: "Workspaces directory lacks read/write permissions: " + workspacesPath,
    required: true
  }

  => {
    name: "workspaces",
    ok: true,
    message: "Workspaces directory exists with read/write access: " + workspacesPath,
    required: true
  }
}

export checkWorkspaces = (boardDir: String) => effect {
  res <- checkWorkspacesWorkflow(boardDir) |> Effect.provide(BunServices.layer)
  => res
}

export checkWorkspacesSync = (boardDir: String) => Effect.runSync(checkWorkspacesWorkflow(boardDir) |> Effect.provide(SyncServices.layer))

export runDoctorWorkflow = (boardDir: String) => effect {
  gitCheck <- checkGitInstalledWorkflow("git")
  bunCheck <- checkBunInstalledWorkflow("bun")
  providerCheck <- checkProviderInstalledWorkflow(["agy", "gemini"])
  boardCheck <- checkBoardDirectoryWorkflow(boardDir)
  workspacesCheck <- checkWorkspacesWorkflow(boardDir)

  allChecks = [gitCheck, bunCheck, providerCheck, boardCheck, workspacesCheck]
  healthy = allChecks |> Array.every((c) => match c.required
    | true => c.ok
    | false => true
  )

  => {
    isHealthy: healthy,
    checks: allChecks
  }
}

export runDoctor = (boardDir: String) => effect {
  res <- runDoctorWorkflow(boardDir) |> Effect.provide(BunServices.layer)
  => res
}

export runDoctorSync = (boardDir: String) => Effect.runSync(runDoctorWorkflow(boardDir) |> Effect.provide(SyncServices.layer))
