import { Array, Console, Effect, Option, Schema, String } from "effect"
import { FileSystem, Path } from "effect"
import { BunServices } from "@effect/platform-bun"
import { DEFAULT_AGENTS_GUIDELINES, DEFAULT_DEV_AGENT_GUIDELINES, DEFAULT_TEAM_LEAD_GUIDELINES } from "./prompt.js"
import { runGitCommandSync, SyncServices } from "./sys.js"

export schema WorkspaceInfo = {
  name: String
  path: String
  exists: Boolean
  isGitRepo: Boolean
  currentBranch: String
  isClean: Boolean
}

export schema WorkspaceInfoTs = WorkspaceInfo

export schema WorkspacesReadyReport = {
  name: String
  ok: Boolean
  message: String
  required: Boolean
  devAgentCount: Number
  workspacesDir: String
  workspaces: Array<WorkspaceInfo>
}

export schema WorkspacesReadyReportTs = WorkspacesReadyReport

export schema BoardInitResult = {
  ok: Boolean
  boardDir: String
  repoUrl: String
  devAgentCount: Number
  filesCreated: Array<String>
  workspacesCreated: Array<String>
  message: String
}

export schema BoardInitResultTs = BoardInitResult

export schema SetupResult = BoardInitResult
export schema SetupResultTs = SetupResult

export schema RuntimeConfig = {
  repository: String
  originUrl: String
  baseBranch: String
  provider: String
  devAgentCount: Number
}

export defaultRuntimeConfig = (): RuntimeConfig => {
  repository: ""
  originUrl: ""
  baseBranch: "main"
  provider: "agy"
  devAgentCount: 2
}

readRuntimeConfigWorkflow = (boardDir: String) => effect {
  fs <- FileSystem.FileSystem
  raw <- fs.readFileString(boardDir + "/.slopboss.json") |> option
  parsed = Option.flatMap(raw, (s) => Schema.decodeUnknownOption(Schema.fromJsonString(RuntimeConfig))(s))
  => Option.getOrElse(parsed, defaultRuntimeConfig)
}

export readRuntimeConfig = (boardDir: String) => readRuntimeConfigWorkflow(boardDir) |> provide(BunServices.layer)

export readRuntimeConfigSync = (boardDir: String): RuntimeConfig => Effect.runSync(readRuntimeConfigWorkflow(boardDir) |> provide(SyncServices.layer))

export schema GitCommandResult = {
  exitCode: Number
  stdout: String
  stderr: String
}

export runGitCommand = (args: Array<String>, cwd: String = "") => runGitCommandSync(args, cwd)

export generateTasksMarkdown = (devAgentCount: Number = 2) =>
  count = Math.max(1, devAgentCount)
  header = "# TASKS\n\nActive work board for slopboss2.\n\n"
  lanes =
    Array.range(1, count)
    |> map((i) => "## Dev Agent " + i + " In Progress\n\n")
    |> join("")
  => header + lanes

export generateBacklogMarkdown = () => "# BACKLOG\n\nPending unassigned work for slopboss2.\n"

export generateArchiveMarkdown = () => "# ARCHIVE\n\nCompleted tasks for slopboss2.\n"

export scaffoldBoardMarkdownWorkflow = (boardDir: String, devAgentCount: Number = 2) => effect {
  fs <- FileSystem.FileSystem
  path <- Path.Path

  count = Math.max(1, devAgentCount)

  dirEx <- fs.exists(boardDir)
  _ <- match not dirEx
    | true => fs.makeDirectory(boardDir, { recursive: true })
    | false => Effect.void

  tasksMd = generateTasksMarkdown(count)
  backlogMd = generateBacklogMarkdown()
  archiveMd = generateArchiveMarkdown()

  fileList = [
    { name: "TASKS.md", content: tasksMd },
    { name: "BACKLOG.md", content: backlogMd },
    { name: "ARCHIVE.md", content: archiveMd },
    {
      name: "AGENTS.md"
      content: DEFAULT_AGENTS_GUIDELINES
    },
    {
      name: "DEV_AGENT.md"
      content: DEFAULT_DEV_AGENT_GUIDELINES
    },
    {
      name: "TEAM_LEAD_AGENT.md"
      content: DEFAULT_TEAM_LEAD_GUIDELINES
    }
  ]

  results <- fileList
  |> Effect.forEach((item) => effect {
    filePath = path.join(boardDir, item.name)
    ex <- fs.exists(filePath)
    resOpt <- match ex
      | true => Effect.succeed(Option.none())
      | false => effect {
        _ <- fs.writeFileString(filePath, item.content)
        => Option.some(item.name)
      }

    => resOpt
  })

  filesCreated = results |> Array.getSomes
  => filesCreated
}

export scaffoldBoardMarkdown = (boardDir: String, devAgentCount: Number = 2) => effect {
  res <- scaffoldBoardMarkdownWorkflow(boardDir, devAgentCount)
  |> provide(BunServices.layer)
  => res
}

export scaffoldBoardMarkdownSync = (boardDir: String, devAgentCount: Number = 2) => Effect.runSync(scaffoldBoardMarkdownWorkflow(boardDir, devAgentCount)
|> provide(SyncServices.layer))

export checkoutMainBranch = (wsPath: String) =>
  hasMain = runGitCommand(["rev-parse", "--verify", "main"], wsPath)
  checkoutRes =
    match hasMain.exitCode #= 0
      | true => runGitCommand(["checkout", "main"], wsPath)
      | false => runGitCommand(["checkout", "-b", "main"], wsPath)
  checkoutMsg =
    match hasMain.exitCode #= 0
      | true => "Checked out main"
      | false => "Created and checked out main"
  => match checkoutRes.exitCode #= 0
    | true => {
      ok: true
      message: checkoutMsg
    }
    | false => {
      ok: false
      message: "Failed to checkout main"
    }

formatNonMainStatus = (wsPath: String, isClean: Boolean, currentBranch: String) =>
  branchLabel =
    match currentBranch #= ""
      | true => "unknown"
      | false => currentBranch
  => match isClean
    | true => checkoutMainBranch(wsPath)
    | false => {
      ok: false
      message: "On branch " + branchLabel + " (clean: false)"
    }

checkCleanGitMain = (wsPath: String) =>
  status = runGitCommand(["status", "--porcelain"], wsPath)
  isClean = status.exitCode #= 0 and status.stdout #= ""
  branchRes = runGitCommand(["rev-parse", "--abbrev-ref", "HEAD"], wsPath)
  currentBranch =
    match branchRes.exitCode #= 0
      | true => branchRes.stdout
      | false => ""
  cleanMsg =
    match isClean
      | true => "Clean on main"
      | false => "Uncommitted changes on main"
  => match currentBranch #= "main"
    | true => {
      ok: isClean
      message: cleanMsg
    }
    | false => formatNonMainStatus(wsPath, isClean, currentBranch)

export ensureCleanGitMain = (wsPath: String) =>
  isGit = runGitCommand(["rev-parse", "--is-inside-work-tree"], wsPath)
  => match isGit.exitCode #! 0 or isGit.stdout #! "true"
    | true => {
      ok: false
      message: "Not a git repository: " + wsPath
    }
    | false => checkCleanGitMain(wsPath)

addWorktreeBranch = (baseRepoPath: String, worktreePath: String, branch: String) =>
  addRes = runGitCommand(["worktree", "add", worktreePath, branch], baseRepoPath)
  addNewBranchRes = runGitCommand(["worktree", "add", "-b", branch, worktreePath, "HEAD"], baseRepoPath)
  failErr =
    match addNewBranchRes.stderr #= ""
      | true => addRes.stderr
      | false => addNewBranchRes.stderr
  => match
    | addRes.exitCode #= 0 => {
      ok: true
      path: worktreePath
      message: "Added worktree on branch " + branch
    }
    | addNewBranchRes.exitCode #= 0 => {
      ok: true
      path: worktreePath
      message: "Added worktree on new branch " + branch
    }
    | _ => {
      ok: false
      path: worktreePath
      message: "Failed to create worktree: " + failErr
    }

createMissingWorktree = (baseRepoPath: String, worktreePath: String, branch: String) => effect {
  fs <- FileSystem.FileSystem
  path <- Path.Path
  parentDir = path.dirname(worktreePath)
  parentEx <- fs.exists(parentDir)
  _ <- match not parentEx
    | true => fs.makeDirectory(parentDir, { recursive: true })
    | false => Effect.void
  => addWorktreeBranch(baseRepoPath, worktreePath, branch)
}

export createWorktreeWorkspaceWorkflow = (baseRepoPath: String, worktreePath: String, branch: String = "main") => effect {
  fs <- FileSystem.FileSystem

  baseExists <- fs.exists(baseRepoPath)
  wtExists <- fs.exists(worktreePath)
  res <- match
    | not baseExists => Effect.succeed({
      ok: false
      path: worktreePath
      message: "Base repository does not exist: " + baseRepoPath
    })
    | wtExists => Effect.succeed({
      ok: true
      path: worktreePath
      message: "Worktree path already exists"
    })
    | _ => createMissingWorktree(baseRepoPath, worktreePath, branch)
  => res
}

export createWorktreeWorkspaceSync = (baseRepoPath: String, worktreePath: String, branch: String = "main") => Effect.runSync(createWorktreeWorkspaceWorkflow(baseRepoPath, worktreePath, branch)
|> Effect.provide(SyncServices.layer))

initExistingDirRepo = (wsPath: String) => effect {
  fs <- FileSystem.FileSystem
  path <- Path.Path
  _init = runGitCommand(["init", "-b", "main"], wsPath)
  headCheck = runGitCommand(["rev-parse", "HEAD"], wsPath)
  _ <- match headCheck.exitCode #! 0
    | true => effect {
      _ <- fs.writeFileString(path.join(wsPath, "README.md"), "# Slopboss Workspace\n")
      _add = runGitCommand(["add", "-A"], wsPath)
      _commit = runGitCommand(["commit", "-m", "Initial commit on main"], wsPath)
      => Void
    }
    | false => Effect.void
  => {
    ok: true
    path: wsPath
    method: "init"
    message: "Initialized git in existing directory"
  }
}

tryCloneArgs = (wsPath: String, enabled: Boolean, gitArgs: Array<String>, method: String, msg: String) =>
  res =
    Option.some(enabled)
    |> Option.filter((ok) => ok)
    |> Option.map((_) => runGitCommand(gitArgs))
    |> Option.filter((r) => r.exitCode #= 0)
    |> Option.map((_) => {
      _clean = ensureCleanGitMain(wsPath)
      => {
        ok: true
        path: wsPath
        method: method
        message: msg
      }
    })
  => res

createFreshGitRepo = (wsPath: String) => effect {
  fs <- FileSystem.FileSystem
  path <- Path.Path
  _ <- fs.makeDirectory(wsPath, { recursive: true })
  _dirInit = runGitCommand(["init", "-b", "main"], wsPath)
  readmeP = path.join(wsPath, "README.md")
  _ <- fs.writeFileString(readmeP, "# Slopboss Workspace\n")
  _dirAdd = runGitCommand(["add", "-A"], wsPath)
  _dirCommit = runGitCommand(["commit", "-m", "Initial commit on main"], wsPath)
  => {
    ok: true
    path: wsPath
    method: "init"
    message: "Initialized local git repository on main"
  }
}

initNewWorkspaceRepo = (wsPath: String, repoUrl: String, fallbackBaseRepo: String) => effect {
  fs <- FileSystem.FileSystem
  path <- Path.Path
  parentDir = path.dirname(wsPath)
  parentEx <- fs.exists(parentDir)
  _ <- match not parentEx
    | true => fs.makeDirectory(parentDir, { recursive: true })
    | false => Effect.void

  hasRepo = repoUrl #! ""
  branchCloneRes = tryCloneArgs(wsPath, hasRepo, ["clone", "--branch", "main", repoUrl, wsPath], "clone", "Cloned from " + repoUrl)
  defaultCloneRes =
    branchCloneRes
    |> Option.orElse(() => tryCloneArgs(wsPath, hasRepo, ["clone", repoUrl, wsPath], "clone", "Cloned from " + repoUrl))

  hasFallback = fallbackBaseRepo #! "" and fallbackBaseRepo #! wsPath
  fallbackExists <- match hasFallback and Option.isNone(defaultCloneRes)
    | true => fs.exists(fallbackBaseRepo)
    | false => Effect.succeed(false)

  cloneOpt =
    defaultCloneRes
    |> Option.orElse(() => tryCloneArgs(wsPath, hasFallback and fallbackExists, ["clone", fallbackBaseRepo, wsPath], "clone-fallback", "Cloned from fallback workspace " + fallbackBaseRepo))

  finalInitRes <- match cloneOpt
    | Some(r) => Effect.succeed(r)
    | None => createFreshGitRepo(wsPath)
  => finalInitRes
}

export initWorkspaceRepoWorkflow = (wsPath: String, repoUrl: String = "", fallbackBaseRepo: String = "") => effect {
  fs <- FileSystem.FileSystem
  wsExists <- fs.exists(wsPath)
  gitCheck =
    match wsExists
      | true => runGitCommand(["rev-parse", "--is-inside-work-tree"], wsPath)
      | false => {
        exitCode: 1
        stdout: ""
        stderr: ""
      }

  isExisting = wsExists and gitCheck.exitCode #= 0 and gitCheck.stdout #= "true"

  res <- match
    | isExisting =>
        _clean1 = ensureCleanGitMain(wsPath)
        Effect.succeed({
          ok: true
          path: wsPath
          method: "existing"
          message: "Existing git repository preserved"
        })
    | wsExists => initExistingDirRepo(wsPath)
    | _ => initNewWorkspaceRepo(wsPath, repoUrl, fallbackBaseRepo)
  => res
}

export initWorkspaceRepoSync = (wsPath: String, repoUrl: String = "", fallbackBaseRepo: String = "") => Effect.runSync(initWorkspaceRepoWorkflow(wsPath, repoUrl, fallbackBaseRepo)
|> Effect.provide(SyncServices.layer))

export provisionWorkspacesWorkflow = (boardDir: String, repoUrl: String, devAgentCount: Number = 2) => effect {
  fs <- FileSystem.FileSystem
  path <- Path.Path

  workspacesDir = path.join(boardDir, "workspaces")
  wsEx <- fs.exists(workspacesDir)
  _ <- match not wsEx
    | true => fs.makeDirectory(workspacesDir, { recursive: true })
    | false => Effect.void

  count = Math.max(1, devAgentCount)

  repoTlPath = path.join(workspacesDir, "repo-tl")
  exTl <- fs.exists(repoTlPath)
  _ <- initWorkspaceRepoWorkflow(repoTlPath, repoUrl, "")
  tlCreated =
    match not exTl
      | true => ["repo-tl"]
      | false => []

  agentIndices = Array.range(1, count)
  agentResults <- agentIndices
  |> Effect.forEach((i) => effect {
    agentWsName = "repo-agent-" + i
    agentWsPath = path.join(workspacesDir, agentWsName)
    exAgent <- fs.exists(agentWsPath)
    _ <- initWorkspaceRepoWorkflow(agentWsPath, repoUrl, repoTlPath)
    => match exAgent
      | false => Option.some(agentWsName)
      | true => Option.none()
  })

  created = tlCreated |> Array.appendAll(agentResults |> Array.getSomes)
  => created
}

export provisionWorkspaces = (boardDir: String, repoUrl: String, devAgentCount: Number = 2) => effect {
  res <- provisionWorkspacesWorkflow(boardDir, repoUrl, devAgentCount)
  |> Effect.provide(BunServices.layer)
  => res
}

export provisionWorkspacesSync = (boardDir: String, repoUrl: String, devAgentCount: Number = 2) => Effect.runSync(provisionWorkspacesWorkflow(boardDir, repoUrl, devAgentCount)
|> Effect.provide(SyncServices.layer))

checkSingleWorkspaceGit = (name: String, wsPath: String) =>
  gitCheck = runGitCommand(["rev-parse", "--is-inside-work-tree"], wsPath)
  isGitRepo = gitCheck.exitCode #= 0 and gitCheck.stdout #= "true"
  branchRes = runGitCommand(["rev-parse", "--abbrev-ref", "HEAD"], wsPath)
  currentBranch =
    Option.some(branchRes.stdout)
    |> Option.filter((_) => branchRes.exitCode #= 0)
    |> Option.getOrElse(() => "")
  statusRes = runGitCommand(["status", "--porcelain"], wsPath)
  isClean = statusRes.exitCode #= 0 and statusRes.stdout #= ""
  branchFail =
    Option.some([name + " is on branch '" + currentBranch + "' (expected 'main')"])
    |> Option.filter((_) => currentBranch #! "main")
    |> Option.getOrElse(() => [])
  cleanFail =
    Option.some([name + " has uncommitted changes"])
    |> Option.filter((_) => not isClean)
    |> Option.getOrElse(() => [])
  allFails = branchFail |> Array.appendAll(cleanFail)
  => match isGitRepo
    | false => {
      info: {
        name: name
        path: wsPath
        exists: true
        isGitRepo: false
        currentBranch: ""
        isClean: false
      }
      failures: [name + " is not a git repository"]
    }
    | true => {
      info: {
        name: name
        path: wsPath
        exists: true
        isGitRepo: true
        currentBranch: currentBranch
        isClean: isClean
      }
      failures: allFails
    }

checkSingleWorkspace = (workspacesDir: String, name: String) => effect {
  fs <- FileSystem.FileSystem
  path <- Path.Path
  wsPath = path.join(workspacesDir, name)
  ex <- fs.exists(wsPath)
  statRes <- fs.stat(wsPath) |> Effect.catch((_) => Effect.succeed({ "type": "Unknown" }))
  isDir = ex and statRes.type #= "Directory"
  => match isDir
    | false => {
      info: {
        name: name
        path: wsPath
        exists: false
        isGitRepo: false
        currentBranch: ""
        isClean: false
      }
      failures: [name + " does not exist"]
    }
    | true => checkSingleWorkspaceGit(name, wsPath)
}

verifyWorkspacesContents = (workspacesDir: String, count: Number) => effect {
  agentNames = Array.range(1, count) |> Array.map((i) => "repo-agent-" + i)
  workspaceNames = ["repo-tl"] |> Array.appendAll(agentNames)

  checkResults <- workspaceNames
  |> Effect.forEach((name) => checkSingleWorkspace(workspacesDir, name))

  workspaces = checkResults |> Array.map((r) => r.info)
  failures = checkResults |> Array.flatMap((r) => r.failures)

  isOk = failures.length #= 0
  successMsg = "All " + workspaces.length + " workspaces are ready on main branch"
  failMsg = "Workspace verification failed: " + (failures |> Array.join("; "))
  msg =
    match isOk
      | true => successMsg
      | false => failMsg

  => {
    name: "workspaces"
    ok: isOk
    required: true
    devAgentCount: count
    workspacesDir: workspacesDir
    workspaces: workspaces
    message: msg
  }
}

export verifyWorkspacesReadyWorkflow = (boardDir: String, devAgentCount: Number = 2) => effect {
  fs <- FileSystem.FileSystem
  path <- Path.Path

  count = Math.max(1, devAgentCount)
  workspacesDir = path.join(boardDir, "workspaces")

  boardEx <- fs.exists(boardDir)
  boardStat <- fs.stat(boardDir)
  |> Effect.catch((_) => Effect.succeed({ "type": "Unknown" }))
  wsEx <- fs.exists(workspacesDir)
  wsStat <- fs.stat(workspacesDir)
  |> Effect.catch((_) => Effect.succeed({ "type": "Unknown" }))

  boardInvalid = not boardEx or boardStat.type #! "Directory"
  wsInvalid = not wsEx or wsStat.type #! "Directory"

  res <- match
    | boardInvalid => Effect.succeed({
      name: "workspaces"
      ok: false
      required: true
      devAgentCount: count
      workspacesDir: workspacesDir
      workspaces: []
      message: "Board directory does not exist: " + boardDir
    })
    | wsInvalid => Effect.succeed({
      name: "workspaces"
      ok: false
      required: true
      devAgentCount: count
      workspacesDir: workspacesDir
      workspaces: []
      message: "Workspaces directory does not exist: " + workspacesDir
    })
    | _ => verifyWorkspacesContents(workspacesDir, count)
  => res
}

export verifyWorkspacesReady = (boardDir: String, devAgentCount: Number = 2) => effect {
  res <- verifyWorkspacesReadyWorkflow(boardDir, devAgentCount)
  |> provide(BunServices.layer)
  => res
}

export verifyWorkspacesReadySync = (boardDir: String, devAgentCount: Number = 2) => Effect.runSync(verifyWorkspacesReadyWorkflow(boardDir, devAgentCount)
|> Effect.provide(SyncServices.layer))

export initBoardStructureWorkflow = (boardDir: String, repoUrl: String = "", devAgentCount: Number = 2, originUrl: String = "", baseBranch: String = "main", provider: String = "agy") => effect {
  count = Math.max(1, devAgentCount)

  filesCreated <- scaffoldBoardMarkdownWorkflow(boardDir, count)
  workspacesCreated <- provisionWorkspacesWorkflow(boardDir, repoUrl, count)
  verification <- verifyWorkspacesReadyWorkflow(boardDir, count)
  fs <- FileSystem.FileSystem
  config = Schema.encodeSync(Schema.fromJsonString(RuntimeConfig))({
    repository: repoUrl
    originUrl: originUrl
    baseBranch: baseBranch
    provider: provider
    devAgentCount: count
  })
  _ <- fs.writeFileString(boardDir + "/.slopboss.json", config)

  isOk = verification.ok
  successMsg = "Board initialized successfully at " + boardDir + " with " + workspacesCreated.length + " workspaces created."
  warnMsg = "Board scaffolding created with workspace warnings: " + verification.message
  msg =
    match isOk
      | true => successMsg
      | false => warnMsg

  => {
    ok: isOk
    boardDir: boardDir
    repoUrl: repoUrl
    devAgentCount: count
    filesCreated: filesCreated
    workspacesCreated: workspacesCreated
    message: msg
  }
}

export initBoardStructure = (boardDir: String, repoUrl: String = "", devAgentCount: Number = 2, originUrl: String = "", baseBranch: String = "main", provider: String = "agy") => effect {
  res <- initBoardStructureWorkflow(boardDir, repoUrl, devAgentCount, originUrl, baseBranch, provider)
  |> provide(BunServices.layer)
  => res
}

export initBoardStructureSync = (boardDir: String, repoUrl: String = "", devAgentCount: Number = 2, originUrl: String = "", baseBranch: String = "main", provider: String = "agy") => Effect.runSync(initBoardStructureWorkflow(boardDir, repoUrl, devAgentCount, originUrl, baseBranch, provider)
|> Effect.provide(SyncServices.layer))
