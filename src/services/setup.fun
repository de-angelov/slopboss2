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

export defaultRuntimeConfig = (): RuntimeConfig => ({
  repository: "",
  originUrl: "",
  baseBranch: "main",
  provider: "agy",
  devAgentCount: 2
})

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
  lanes = Array.range(1, count) |> map((i) => "## Dev Agent " + i + " In Progress\n\n") |> join("")
  => header + lanes

export generateBacklogMarkdown = () => "# BACKLOG\n\nPending unassigned work for slopboss2.\n"

export generateArchiveMarkdown = () => "# ARCHIVE\n\nCompleted tasks for slopboss2.\n"

export scaffoldBoardMarkdownWorkflow = (boardDir: String, devAgentCount: Number = 2) => effect {
  fs <- FileSystem.FileSystem
  path <- Path.Path

  count = Math.max(1, devAgentCount)

  dirEx <- fs.exists(boardDir)
  _ <- match (not dirEx)
    | true => fs.makeDirectory(boardDir, { recursive: true })
    | false => Effect.void

  tasksMd = generateTasksMarkdown(count)
  backlogMd = generateBacklogMarkdown()
  archiveMd = generateArchiveMarkdown()

  fileList = [
    { name: "TASKS.md", content: tasksMd },
    { name: "BACKLOG.md", content: backlogMd },
    { name: "ARCHIVE.md", content: archiveMd },
    { name: "AGENTS.md", content: DEFAULT_AGENTS_GUIDELINES },
    { name: "DEV_AGENT.md", content: DEFAULT_DEV_AGENT_GUIDELINES },
    { name: "TEAM_LEAD_AGENT.md", content: DEFAULT_TEAM_LEAD_GUIDELINES }
  ]

  results <- fileList |> Effect.forEach((item) => effect {
    filePath = path.join(boardDir, item.name)
    ex <- fs.exists(filePath)
    when (ex) => Option.none()
    _ <- fs.writeFileString(filePath, item.content)
    => Option.some(item.name)
  })

  filesCreated = results |> Array.getSomes
  => filesCreated
}

export scaffoldBoardMarkdown = (boardDir: String, devAgentCount: Number = 2) => effect {
  res <- scaffoldBoardMarkdownWorkflow(boardDir, devAgentCount) |> provide(BunServices.layer)
  => res
}

export scaffoldBoardMarkdownSync = (boardDir: String, devAgentCount: Number = 2) => Effect.runSync(scaffoldBoardMarkdownWorkflow(boardDir, devAgentCount) |> provide(SyncServices.layer))

export checkoutMainBranch = (wsPath: String) =>
  hasMain = runGitCommand(["rev-parse", "--verify", "main"], wsPath)
  checkoutRes = match hasMain.exitCode #= 0
    | true => runGitCommand(["checkout", "main"], wsPath)
    | false => runGitCommand(["checkout", "-b", "main"], wsPath)
  when (checkoutRes.exitCode #= 0) => {
    ok: true,
    message: match hasMain.exitCode #= 0
      | true => "Checked out main"
      | false => "Created and checked out main"
  }
  => {
    ok: false,
    message: "Failed to checkout main"
  }

export ensureCleanGitMain = (wsPath: String) =>
  isGit = runGitCommand(["rev-parse", "--is-inside-work-tree"], wsPath)
  when (isGit.exitCode #! 0 or isGit.stdout #! "true") => {
    ok: false,
    message: "Not a git repository: " + wsPath
  }

  status = runGitCommand(["status", "--porcelain"], wsPath)
  isClean = status.exitCode #= 0 and status.stdout #= ""

  branchRes = runGitCommand(["rev-parse", "--abbrev-ref", "HEAD"], wsPath)
  currentBranch = match branchRes.exitCode #= 0
    | true => branchRes.stdout
    | false => ""

  cleanMsg = match isClean
    | true => "Clean on main"
    | false => "Uncommitted changes on main"

  when (currentBranch #= "main") => {
    ok: isClean,
    message: cleanMsg
  }

  when (isClean) => checkoutMainBranch(wsPath)

  branchLabel = match currentBranch #= ""
    | true => "unknown"
    | false => currentBranch
  cleanStr = "false"

  => {
    ok: false,
    message: "On branch " + branchLabel + " (clean: " + cleanStr + ")"
  }

export createWorktreeWorkspaceWorkflow = (baseRepoPath: String, worktreePath: String, branch: String = "main") => effect {
  fs <- FileSystem.FileSystem
  path <- Path.Path

  baseExists <- fs.exists(baseRepoPath)
  when (not baseExists) => {
    ok: false,
    path: worktreePath,
    message: "Base repository does not exist: " + baseRepoPath
  }

  wtExists <- fs.exists(worktreePath)
  when (wtExists) => {
    ok: true,
    path: worktreePath,
    message: "Worktree path already exists"
  }

  parentDir = path.dirname(worktreePath)
  parentEx <- fs.exists(parentDir)
  _ <- match (not parentEx)
    | true => fs.makeDirectory(parentDir, { recursive: true })
    | false => Effect.void

  addRes = runGitCommand(["worktree", "add", worktreePath, branch], baseRepoPath)
  when (addRes.exitCode #= 0) => {
    ok: true,
    path: worktreePath,
    message: "Added worktree on branch " + branch
  }

  addNewBranchRes = runGitCommand(["worktree", "add", "-b", branch, worktreePath, "HEAD"], baseRepoPath)
  when (addNewBranchRes.exitCode #= 0) => {
    ok: true,
    path: worktreePath,
    message: "Added worktree on new branch " + branch
  }

  failErr = match addNewBranchRes.stderr #= ""
    | true => addRes.stderr
    | false => addNewBranchRes.stderr

  => {
    ok: false,
    path: worktreePath,
    message: "Failed to create worktree: " + failErr
  }
}

export createWorktreeWorkspaceSync = (baseRepoPath: String, worktreePath: String, branch: String = "main") => Effect.runSync(createWorktreeWorkspaceWorkflow(baseRepoPath, worktreePath, branch) |> provide(SyncServices.layer))

export initWorkspaceRepoWorkflow = (wsPath: String, repoUrl: String = "", fallbackBaseRepo: String = "") => effect {
  fs <- FileSystem.FileSystem
  path <- Path.Path

  wsExists <- fs.exists(wsPath)
  gitCheck = match wsExists
    | true => runGitCommand(["rev-parse", "--is-inside-work-tree"], wsPath)
    | false => { exitCode: 1, stdout: "", stderr: "" }

  isExisting = wsExists and gitCheck.exitCode #= 0 and gitCheck.stdout #= "true"
  _clean1 = match isExisting
    | true => ensureCleanGitMain(wsPath)
    | false => { ok: false, message: "" }

  when (isExisting) => {
    ok: true,
    path: wsPath,
    method: "existing",
    message: "Existing git repository preserved"
  }

  _init = match wsExists
    | true => runGitCommand(["init", "-b", "main"], wsPath)
    | false => { exitCode: 0, stdout: "", stderr: "" }

  headCheck = match wsExists
    | true => runGitCommand(["rev-parse", "HEAD"], wsPath)
    | false => { exitCode: 0, stdout: "", stderr: "" }

  _ <- match (wsExists and headCheck.exitCode #! 0)
    | true => fs.writeFileString(path.join(wsPath, "README.md"), "# Slopboss Workspace\n")
    | false => Effect.void

  _add = match (wsExists and headCheck.exitCode #! 0)
    | true => runGitCommand(["add", "-A"], wsPath)
    | false => { exitCode: 0, stdout: "", stderr: "" }

  _commit = match (wsExists and headCheck.exitCode #! 0)
    | true => runGitCommand(["commit", "-m", "Initial commit on main"], wsPath)
    | false => { exitCode: 0, stdout: "", stderr: "" }

  when (wsExists) => {
    ok: true,
    path: wsPath,
    method: "init",
    message: "Initialized git in existing directory"
  }

  parentDir = path.dirname(wsPath)
  parentEx <- fs.exists(parentDir)
  _ <- match (not parentEx)
    | true => fs.makeDirectory(parentDir, { recursive: true })
    | false => Effect.void

  cloneWithBranch = match (repoUrl #! "")
    | true => runGitCommand(["clone", "--branch", "main", repoUrl, wsPath])
    | false => { exitCode: 1, stdout: "", stderr: "" }

  isCloneWithBranch = repoUrl #! "" and cloneWithBranch.exitCode #= 0
  _cleanBranch = match isCloneWithBranch
    | true => ensureCleanGitMain(wsPath)
    | false => { ok: false, message: "" }

  when (isCloneWithBranch) => {
    ok: true,
    path: wsPath,
    method: "clone",
    message: "Cloned from " + repoUrl
  }

  cloneDefault = match (repoUrl #! "")
    | true => runGitCommand(["clone", repoUrl, wsPath])
    | false => { exitCode: 1, stdout: "", stderr: "" }

  isCloneDefault = repoUrl #! "" and cloneDefault.exitCode #= 0
  _cleanDefault = match isCloneDefault
    | true => ensureCleanGitMain(wsPath)
    | false => { ok: false, message: "" }

  when (isCloneDefault) => {
    ok: true,
    path: wsPath,
    method: "clone",
    message: "Cloned from " + repoUrl
  }

  hasFallback = fallbackBaseRepo #! "" and fallbackBaseRepo #! wsPath
  fallbackExists <- match hasFallback
    | true => fs.exists(fallbackBaseRepo)
    | false => Effect.succeed(false)

  cloneFromFallback = match (hasFallback and fallbackExists)
    | true => runGitCommand(["clone", fallbackBaseRepo, wsPath])
    | false => { exitCode: 1, stdout: "", stderr: "" }

  isFallbackClone = hasFallback and fallbackExists and cloneFromFallback.exitCode #= 0
  _clean2 = match isFallbackClone
    | true => ensureCleanGitMain(wsPath)
    | false => { ok: false, message: "" }

  when (isFallbackClone) => {
    ok: true,
    path: wsPath,
    method: "clone-fallback",
    message: "Cloned from fallback workspace " + fallbackBaseRepo
  }

  _ <- fs.makeDirectory(wsPath, { recursive: true })
  _dirInit = runGitCommand(["init", "-b", "main"], wsPath)
  readmeP = path.join(wsPath, "README.md")
  _ <- fs.writeFileString(readmeP, "# Slopboss Workspace\n")
  _dirAdd = runGitCommand(["add", "-A"], wsPath)
  _dirCommit = runGitCommand(["commit", "-m", "Initial commit on main"], wsPath)

  => {
    ok: true,
    path: wsPath,
    method: "init",
    message: "Initialized local git repository on main"
  }
}

export initWorkspaceRepoSync = (wsPath: String, repoUrl: String = "", fallbackBaseRepo: String = "") => Effect.runSync(initWorkspaceRepoWorkflow(wsPath, repoUrl, fallbackBaseRepo) |> provide(SyncServices.layer))

export provisionWorkspacesWorkflow = (boardDir: String, repoUrl: String, devAgentCount: Number = 2) => effect {
  fs <- FileSystem.FileSystem
  path <- Path.Path

  workspacesDir = path.join(boardDir, "workspaces")
  wsEx <- fs.exists(workspacesDir)
  _ <- match (not wsEx)
    | true => fs.makeDirectory(workspacesDir, { recursive: true })
    | false => Effect.void

  count = Math.max(1, devAgentCount)

  repoTlPath = path.join(workspacesDir, "repo-tl")
  exTl <- fs.exists(repoTlPath)
  _ <- initWorkspaceRepoWorkflow(repoTlPath, repoUrl, "")
  tlCreated = match (not exTl)
    | true => ["repo-tl"]
    | false => []

  agentIndices = Array.range(1, count)
  agentResults <- agentIndices |> Effect.forEach((i) => effect {
    agentWsName = "repo-agent-" + i
    agentWsPath = path.join(workspacesDir, agentWsName)
    exAgent <- fs.exists(agentWsPath)
    _ <- initWorkspaceRepoWorkflow(agentWsPath, repoUrl, repoTlPath)
    when (not exAgent) => Option.some(agentWsName)
    => Option.none()
  })

  created = tlCreated |> appendAll(agentResults |> Array.getSomes)
  => created
}

export provisionWorkspaces = (boardDir: String, repoUrl: String, devAgentCount: Number = 2) => effect {
  res <- provisionWorkspacesWorkflow(boardDir, repoUrl, devAgentCount) |> provide(BunServices.layer)
  => res
}

export provisionWorkspacesSync = (boardDir: String, repoUrl: String, devAgentCount: Number = 2) => Effect.runSync(provisionWorkspacesWorkflow(boardDir, repoUrl, devAgentCount) |> provide(SyncServices.layer))

export verifyWorkspacesReadyWorkflow = (boardDir: String, devAgentCount: Number = 2) => effect {
  fs <- FileSystem.FileSystem
  path <- Path.Path

  count = Math.max(1, devAgentCount)
  workspacesDir = path.join(boardDir, "workspaces")

  boardEx <- fs.exists(boardDir)
  when (not boardEx) => {
    name: "workspaces",
    ok: false,
    required: true,
    devAgentCount: count,
    workspacesDir: workspacesDir,
    workspaces: [],
    message: "Board directory does not exist: " + boardDir
  }

  boardStat <- fs.stat(boardDir) |> Effect.catch((_) => Effect.succeed({ type: "Unknown" }))
  when (boardStat.type #! "Directory") => {
    name: "workspaces",
    ok: false,
    required: true,
    devAgentCount: count,
    workspacesDir: workspacesDir,
    workspaces: [],
    message: "Board directory does not exist: " + boardDir
  }

  wsEx <- fs.exists(workspacesDir)
  when (not wsEx) => {
    name: "workspaces",
    ok: false,
    required: true,
    devAgentCount: count,
    workspacesDir: workspacesDir,
    workspaces: [],
    message: "Workspaces directory does not exist: " + workspacesDir
  }

  wsStat <- fs.stat(workspacesDir) |> Effect.catch((_) => Effect.succeed({ type: "Unknown" }))
  when (wsStat.type #! "Directory") => {
    name: "workspaces",
    ok: false,
    required: true,
    devAgentCount: count,
    workspacesDir: workspacesDir,
    workspaces: [],
    message: "Workspaces directory does not exist: " + workspacesDir
  }

  agentNames = Array.range(1, count) |> map((i) => "repo-agent-" + i)
  workspaceNames = ["repo-tl"] |> appendAll(agentNames)

  checkResults <- workspaceNames |> Effect.forEach((name) => effect {
    wsPath = path.join(workspacesDir, name)
    ex <- fs.exists(wsPath)
    statRes <- fs.stat(wsPath) |> Effect.catch((_) => Effect.succeed({ type: "Unknown" }))
    isDir = ex and statRes.type #= "Directory"

    when (not isDir) => {
      info: {
        name: name,
        path: wsPath,
        exists: false,
        isGitRepo: false,
        currentBranch: "",
        isClean: false
      },
      failures: [name + " does not exist"]
    }

    gitCheck = runGitCommand(["rev-parse", "--is-inside-work-tree"], wsPath)
    isGitRepo = gitCheck.exitCode #= 0 and gitCheck.stdout #= "true"

    when (not isGitRepo) => {
      info: {
        name: name,
        path: wsPath,
        exists: true,
        isGitRepo: false,
        currentBranch: "",
        isClean: false
      },
      failures: [name + " is not a git repository"]
    }

    branchRes = runGitCommand(["rev-parse", "--abbrev-ref", "HEAD"], wsPath)
    currentBranch = match branchRes.exitCode #= 0
      | true => branchRes.stdout
      | false => ""

    statusRes = runGitCommand(["status", "--porcelain"], wsPath)
    isClean = statusRes.exitCode #= 0 and statusRes.stdout #= ""

    branchFail = match (currentBranch #! "main")
      | true => [name + " is on branch '" + currentBranch + "' (expected 'main')"]
      | false => []

    cleanFail = match (not isClean)
      | true => [name + " has uncommitted changes"]
      | false => []

    allFails = branchFail |> appendAll(cleanFail)

    => {
      info: {
        name: name,
        path: wsPath,
        exists: true,
        isGitRepo: true,
        currentBranch: currentBranch,
        isClean: isClean
      },
      failures: allFails
    }
  })

  workspaces = checkResults |> Array.map((r) => r.info)
  failures = checkResults |> Array.flatMap((r) => r.failures)

  isOk = failures.length #= 0
  successMsg = "All " + workspaces.length + " workspaces are ready on main branch"
  failMsg = "Workspace verification failed: " + (failures |> Array.join("; "))
  msg = match isOk
    | true => successMsg
    | false => failMsg

  => {
    name: "workspaces",
    ok: isOk,
    required: true,
    devAgentCount: count,
    workspacesDir: workspacesDir,
    workspaces: workspaces,
    message: msg
  }
}

export verifyWorkspacesReady = (boardDir: String, devAgentCount: Number = 2) => effect {
  res <- verifyWorkspacesReadyWorkflow(boardDir, devAgentCount) |> provide(BunServices.layer)
  => res
}

export verifyWorkspacesReadySync = (boardDir: String, devAgentCount: Number = 2) => Effect.runSync(verifyWorkspacesReadyWorkflow(boardDir, devAgentCount) |> provide(SyncServices.layer))

export initBoardStructureWorkflow = (boardDir: String, repoUrl: String = "", devAgentCount: Number = 2, originUrl: String = "", baseBranch: String = "main", provider: String = "agy") => effect {
  count = Math.max(1, devAgentCount)

  filesCreated <- scaffoldBoardMarkdownWorkflow(boardDir, count)
  workspacesCreated <- provisionWorkspacesWorkflow(boardDir, repoUrl, count)
  verification <- verifyWorkspacesReadyWorkflow(boardDir, count)
  fs <- FileSystem.FileSystem
  config = Schema.encodeSync(Schema.fromJsonString(RuntimeConfig))({ repository: repoUrl, originUrl: originUrl, baseBranch: baseBranch, provider: provider, devAgentCount: count })
  _ <- fs.writeFileString(boardDir + "/.slopboss.json", config)

  isOk = verification.ok
  successMsg = "Board initialized successfully at " + boardDir + " with " + workspacesCreated.length + " workspaces created."
  warnMsg = "Board scaffolding created with workspace warnings: " + verification.message
  msg = match isOk
    | true => successMsg
    | false => warnMsg

  => {
    ok: isOk,
    boardDir: boardDir,
    repoUrl: repoUrl,
    devAgentCount: count,
    filesCreated: filesCreated,
    workspacesCreated: workspacesCreated,
    message: msg
  }
}

export initBoardStructure = (boardDir: String, repoUrl: String = "", devAgentCount: Number = 2, originUrl: String = "", baseBranch: String = "main", provider: String = "agy") => effect {
  res <- initBoardStructureWorkflow(boardDir, repoUrl, devAgentCount, originUrl, baseBranch, provider) |> provide(BunServices.layer)
  => res
}

export initBoardStructureSync = (boardDir: String, repoUrl: String = "", devAgentCount: Number = 2, originUrl: String = "", baseBranch: String = "main", provider: String = "agy") => Effect.runSync(initBoardStructureWorkflow(boardDir, repoUrl, devAgentCount, originUrl, baseBranch, provider) |> provide(SyncServices.layer))
