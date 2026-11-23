import { Array, Console, Duration, Effect, Option, Queue, Ref, Schema, String } from "effect"
import { archiveTask, BoardStore, loadBoardStoreSync, MarkdownSection, moveTask, parseBacklogTasks, persistBoardStoreSync, TaskBlock, TasksDocument } from "../domain/boardstore.js"
import { findReadyTasks, TaskNode } from "../domain/dag.js"
import { acquireBoardLock } from "../services/coordination.js"
import { buildDevAgentPrompt } from "../services/prompt.js"
import { runConfiguredAgentSession, runMockAgentSession, SessionResult } from "../services/runner.js"
import { createMergeTrain, enqueueMergeRequest, landMergeRequest, MergeRequest } from "./mergetrain.js"

export schema ActiveAgentSession = {
  agentId: String
  taskId: String
  branch: String
  workspace: String
  status: String
}

export schema RunningSession = {
  agentId: String
  taskId: String
  branch: String
  workspace: String
  status: String
}

export schema TokenCounter = {
  inputTokens: Number
  outputTokens: Number
  totalTokens: Number
}

export schema DispatcherConfig = {
  boardDir: String
  pollIntervalMs: Number
  maxIterations: Number
  devAgentCount: Number
  baseBranch?: String
  provider?: String
  mockRunner?: Boolean
  runnerFn?: Unknown
  mergeQueue?: Unknown
}

export schema ReconcilerConfig = {
  boardDir: String
  pollIntervalMs: Number
  maxIterations: Number
  devAgentCount: Number
  baseBranch?: String
  provider?: String
  mockRunner?: Boolean
  runnerFn?: Unknown
  mergeQueue?: Unknown
}

export schema ReconcilerState = {
  tickCount: Number
  activeSessions: Array<RunningSession>
  tokenCounter: TokenCounter
}

export schema DispatcherResult = {
  tickCount: Number
  activeSessions: Array<ActiveAgentSession>
  tokenCounter: TokenCounter
}

export schema AssignmentResult = {
  sessions: Array<RunningSession>
  tokens: TokenCounter
}

export schema IdleAgent = {
  agentId: String
  laneTitle: String
  agentIndex: Number
}

export schema PairItem = {
  idle: IdleAgent
  taskToAssign: TaskBlock
}

decodeSessionResult = Schema.decodeUnknownSync(SessionResult)
decodePairItem = Schema.decodeUnknownSync(PairItem)
decodeMergeRequest = Schema.decodeUnknownSync(MergeRequest)

export initialReconcilerState = (devAgentCount: Number = 2): ReconcilerState => {
  emptySessions: Array<RunningSession> = []
  => {
    tickCount: 0,
    activeSessions: emptySessions,
    tokenCounter: {
      inputTokens: 0,
      outputTokens: 0,
      totalTokens: 0
    }
  }
}

export initialReconcilerStateFun = (devAgentCount: Number = 2) =>
  initialReconcilerState(devAgentCount)

getDocCompletedIds = (archiveDoc: TasksDocument): Array<String> => {
  docOpt = Option.fromNullishOr(archiveDoc)
  when (Option.isNone(docOpt)) => []
  doc: TasksDocument = archiveDoc
  sectionsOpt = Option.fromNullishOr(doc.sections)
  when (Option.isNone(sectionsOpt)) => []
  sections: Array<MarkdownSection> = doc.sections
  res = sections |> flatMap((sec: MarkdownSection) => {
    tasksOpt = Option.fromNullishOr(sec.tasks)
    when (Option.isNone(tasksOpt)) => []
    tasks: Array<TaskBlock> = sec.tasks
    initAcc: Array<String> = []
    => tasks |> reduce(initAcc, (acc, t: TaskBlock) => {
      id = Option.getOrElse(Option.fromNullishOr(t.id), () => "")
      when (id #= "") => acc
      => acc |> Array.append(id)
    })
  })
  => res
}

getContentCompletedIds = (archiveContent: String): Array<String> => {
  content = Option.getOrElse(Option.fromNullishOr(archiveContent), () => "")
  when (content #= "") => []

  bulletRx = RegExp("- \\[x\\]\\s+([A-Za-z0-9_-]+):", "gi")
  taskRx = RegExp("Task ID:\\s*([A-Za-z0-9_-]+)", "gi")

  matches1 = Array.fromIterable(content.matchAll(bulletRx))
  initIds1: Array<String> = []
  ids1 = matches1 |> reduce(initIds1, (acc, m) => {
    rawId = Option.getOrElse(Option.fromNullishOr(Reflect.get(m, 1)), () => "")
    when (rawId #= "") => acc
    => acc |> Array.append("" + rawId)
  })

  matches2 = Array.fromIterable(content.matchAll(taskRx))
  initIds2: Array<String> = []
  ids2 = matches2 |> reduce(initIds2, (acc, m) => {
    rawId = Option.getOrElse(Option.fromNullishOr(Reflect.get(m, 1)), () => "")
    when (rawId #= "") => acc
    => acc |> Array.append("" + rawId)
  })

  => ids1 |> Array.appendAll(ids2)
}

getCompletedTaskIds = (store: BoardStore): Array<String> => {
  docIds = getDocCompletedIds(store.archiveDoc)
  contentIds = getContentCompletedIds(store.archiveContent)
  allIds = docIds |> Array.appendAll(contentIds)
  => Array.dedupe(allIds)
}

zipIdleAndTasks = (agents: Array<IdleAgent>, tasks: Array<TaskBlock>): Array<PairItem> => {
  minLen = Math.min(agents.length, tasks.length)
  when (minLen <= 0) => []
  indices = Array.range(0, minLen - 1)
  emptyIdle: IdleAgent = { agentId: "", laneTitle: "", agentIndex: 0 }
  emptyTask: TaskBlock = { id: "", title: "", category: "", owner: "", branch: "", status: "", dependencies: [], objective: "", scope: "", acceptanceCriteria: "", rawBody: "" }
  initPairs: Array<PairItem> = []
  res = indices |> reduce(initPairs, (acc, i) => {
    aOpt = agents[i]
    tOpt = tasks[i]
    when (Option.isNone(aOpt) or Option.isNone(tOpt)) => acc
    a = aOpt |> Option.getOrElse(() => emptyIdle)
    t = tOpt |> Option.getOrElse(() => emptyTask)
    => acc |> Array.append({ idle: a, taskToAssign: t })
  })
  => res
}

resolveBranchName = (rawBranch: Option.Option<String>, agentIndex: Number, taskId: String): String => {
  defaultBranch = "agent/" + agentIndex + "/" + String.toLowerCase(taskId)
  b = Option.getOrElse(rawBranch, () => defaultBranch)
  trimmed = String.trim(b)
  when (trimmed #= "") => defaultBranch
  => b
}

runGitInWorkspace = (args: Array<String>, workspace: String) => {
  proc = Bun.spawnSync(["git"] |> Array.appendAll(args), { cwd: workspace, stdout: "pipe", stderr: "pipe" })
  => { code: proc.exitCode, out: proc.stdout.toString() |> trim }
}

prepareWorkspace = (workspace: String, branch: String): Effect.Effect<Boolean, Any, Any> => effect {
  status = runGitInWorkspace(["status", "--porcelain"], workspace)
  branchRes = runGitInWorkspace(["branch", "--show-current"], workspace)
  when (branchRes.code #! 0) => false
  when (branchRes.out #= branch) => true
  exists = runGitInWorkspace(["show-ref", "--verify", "--quiet", "refs/heads/" + branch], workspace)
  checkoutArgs = match exists.code #= 0
    | true => ["checkout", branch]
    | false => ["checkout", "-b", branch]
  // Git may refuse a checkout that would overwrite local changes. That preserves
  // the user's workspace data and leaves this task available for recovery.
  checkout = runGitInWorkspace(checkoutArgs, workspace)
  _ = status
  => checkout.code #= 0
}

executeRunner = (runnerOpt: Option.Option<Unknown>, useMock: Boolean, agentId: String, taskId: String, prompt: String, workspace: String, provider: String): Effect.Effect<SessionResult, Any, Any> =>
  match useMock
    | true => runMockAgentSession(agentId, taskId)
    | false when Option.isNone(runnerOpt) => runConfiguredAgentSession(prompt, workspace, provider)
    | false => {
        runnerAny: Any = Option.getOrElse(runnerOpt, () => "")
        runnerCall: (a: String, b: String, c: String, d: String) => Effect.Effect<Unknown, Any, Any> = runnerAny
        => effect {
          rawRes <- runnerCall(agentId, taskId, prompt, workspace)
          => decodeSessionResult(rawRes)
        }
    }

resolveUsedTokens = (tokensOpt: Option.Option<Number>): Number =>
  Option.getOrElse(tokensOpt, () => 1420)

submitMergeRequest = (queueOpt: Option.Option<Unknown>, mergeReq: MergeRequest, baseBranch: String): Effect.Effect<Unit, Any, Any> => {
  when (Option.isNone(queueOpt)) => effect {
    _ <- landMergeRequest(mergeReq, baseBranch)
    => Unit
  }
  q: Any = Option.getOrElse(queueOpt, () => "")
  => effect {
    _ <- enqueueMergeRequest(q, mergeReq)
    => Unit
  }
}

createFailedSession = (idle: IdleAgent, taskAssigned: TaskBlock, branchName: String, workspacePath: String): RunningSession => {
  agentId: idle.agentId,
  taskId: taskAssigned.id,
  branch: branchName,
  workspace: workspacePath,
  status: "Running"
}

handleSessionCompletion = (isDone: Boolean, idle: IdleAgent, taskAssigned: TaskBlock, branchName: String, workspacePath: String, currentSessions: Array<RunningSession>, store: BoardStore, baseBranch: String, mergeQueueOpt: Option.Option<Unknown>): Effect.Effect<Array<RunningSession>, Any, Any> => {
  when (not isDone) => Effect.succeed(currentSessions |> append(createFailedSession(idle, taskAssigned, branchName, workspacePath)))

  => effect {
    mergeReq: MergeRequest = {
      taskId: taskAssigned.id,
      branch: branchName,
      workspace: workspacePath,
      isZeroCommit: false,
      verificationCmd: Option.none()
    }

    landing <- landMergeRequest(mergeReq, baseBranch)
    when (not landing.success) => currentSessions |> append(createFailedSession(idle, taskAssigned, branchName, workspacePath))
    _archiveRes: Unknown = archiveTask(store, taskAssigned.id)
    _persistRes2: Unknown = persistBoardStoreSync(store)
    => currentSessions
  }
}

processPairs = (pairList: Array<PairItem>, currentSessions: Array<RunningSession>, currentTokens: TokenCounter, boardDir: String, baseBranch: String, store: BoardStore, config: ReconcilerConfig): Effect.Effect<AssignmentResult, Any, Any> => effect {
  headOpt = Array.head(pairList)
  when (Option.isNone(headOpt)) => { sessions: currentSessions, tokens: currentTokens }
  emptyPair: PairItem = {
    idle: { agentId: "", laneTitle: "", agentIndex: 0 },
    taskToAssign: { id: "", title: "", category: "", owner: "", branch: "", status: "", dependencies: [], objective: "", scope: "", acceptanceCriteria: "", rawBody: "" }
  }
  headItem = headOpt |> Option.getOrElse(() => emptyPair)
  tail = pairList |> drop(1)
  idle: IdleAgent = headItem.idle
  taskToAssign: TaskBlock = headItem.taskToAssign

  branchName = resolveBranchName(Option.fromNullishOr(taskToAssign.branch), idle.agentIndex, taskToAssign.id)

  taskAssigned: TaskBlock = {
    id: taskToAssign.id,
    title: taskToAssign.title,
    category: taskToAssign.category,
    owner: idle.agentId,
    branch: branchName,
    status: "In Progress",
    dependencies: taskToAssign.dependencies,
    objective: taskToAssign.objective,
    scope: taskToAssign.scope,
    acceptanceCriteria: taskToAssign.acceptanceCriteria,
    rawBody: taskToAssign.rawBody
  }

  _moveRes: Unknown = moveTask(store, taskAssigned.id, idle.laneTitle)
  _persistRes1: Unknown = persistBoardStoreSync(store)

  workspacePath = boardDir + "/workspaces/repo-agent-" + idle.agentIndex
  prompt: String = buildDevAgentPrompt(boardDir, taskAssigned, idle.agentId)

  useMock = Option.getOrElse(Option.fromNullishOr(config.mockRunner), () => false)
  hasInjectedRunner = Option.isSome(Option.fromNullishOr(config.runnerFn))
  prepared <- match useMock or hasInjectedRunner
    | true => Effect.succeed(true)
    | false => prepareWorkspace(workspacePath, branchName)
  runRes <- match prepared
    | true => executeRunner(Option.fromNullishOr(config.runnerFn), useMock, idle.agentId, taskAssigned.id, prompt, workspacePath, Option.getOrElse(Option.fromNullishOr(config.provider), () => "agy"))
    | false => Effect.succeed({ exitCode: 1, totalTokens: 0, completed: false })

  usedTokens = resolveUsedTokens(Option.fromNullishOr(runRes.totalTokens))
  inTokens = Math.floor(usedTokens * 0.7)
  outTokens = Math.ceil(usedTokens * 0.3)

  updatedTokens: TokenCounter = {
    inputTokens: currentTokens.inputTokens + inTokens,
    outputTokens: currentTokens.outputTokens + outTokens,
    totalTokens: currentTokens.totalTokens + usedTokens
  }

  isDone = runRes.completed and runRes.exitCode #= 0

  updatedSessions <- handleSessionCompletion(
    isDone,
    idle,
    taskAssigned,
    branchName,
    workspacePath,
    currentSessions,
    store,
    baseBranch,
    Option.fromNullishOr(config.mergeQueue)
  )

  nextResult <- processPairs(
    tail,
    updatedSessions,
    updatedTokens,
    boardDir,
    baseBranch,
    store,
    config
  )
  => nextResult
}

resolveBaseBranch = (branchOpt: Option.Option<String>): String =>
  Option.getOrElse(branchOpt, () => "main")

resolveDevAgentCount = (count: Number): Number => {
  when (count > 0) => count
  => 2
}

resolveRawContent = (contentOpt: Option.Option<String>): String =>
  Option.getOrElse(contentOpt, () => "")

getExtraTasks = (tasksDoc: TasksDocument, existingTasks: Array<TaskBlock>): Array<TaskBlock> => {
  when (Option.isNone(Option.fromNullishOr(tasksDoc))) => []
  when (Option.isNone(Option.fromNullishOr(tasksDoc.sections))) => []
  sections: Array<MarkdownSection> = tasksDoc.sections

  backlogSec = sections |> findFirst((s: MarkdownSection) => {
    title = Option.getOrElse(Option.fromNullishOr(s.title), () => "")
    low = title |> toLowerCase
    => low |> includes("backlog")
  })
  when (Option.isNone(backlogSec)) => []
  emptySec: MarkdownSection = { title: "", name: "", tasks: [], rawContent: "" }
  sec = backlogSec |> getOrElse(() => emptySec)

  when (Option.isNone(Option.fromNullishOr(sec.tasks))) => []
  tasks: Array<TaskBlock> = sec.tasks

  => tasks |> filter((t: TaskBlock) =>
    not (existingTasks |> Array.some((b: TaskBlock) => b.id #= t.id))
  )
}

getTaskDependencies = (t: TaskBlock): Array<String> =>
  Option.getOrElse(Option.fromNullishOr(t.dependencies), () => [])

toTaskNode = (t: TaskBlock): TaskNode => {
  id: t.id,
  dependsOn: getTaskDependencies(t)
}

isLaneActiveInDoc = (tasksDoc: TasksDocument, agentId: String): Boolean => {
  when (Option.isNone(Option.fromNullishOr(tasksDoc))) => false
  when (Option.isNone(Option.fromNullishOr(tasksDoc.sections))) => false
  sections: Array<MarkdownSection> = tasksDoc.sections

  agentIdLow = agentId |> toLowerCase
  laneSec = sections |> findFirst((s: MarkdownSection) => {
    title = Option.getOrElse(Option.fromNullishOr(s.title), () => "")
    low = title |> toLowerCase
    => low |> includes(agentIdLow)
  })
  when (Option.isNone(laneSec)) => false
  emptySec: MarkdownSection = { title: "", name: "", tasks: [], rawContent: "" }
  sec = laneSec |> getOrElse(() => emptySec)

  when (Option.isNone(Option.fromNullishOr(sec.tasks))) => false
  tasks: Array<TaskBlock> = sec.tasks

  => tasks |> Array.some((t: TaskBlock) => {
    st = Option.getOrElse(Option.fromNullishOr(t.status), () => "")
    stLow = st |> toLowerCase
    => stLow #= "in progress"
  })
}

export reconcileTick = (config: ReconcilerConfig, state: ReconcilerState): Effect.Effect<ReconcilerState, Any, Any> => effect {
  nextTick = state.tickCount + 1
  boardDir = config.boardDir
  baseBranch = resolveBaseBranch(Option.fromNullishOr(config.baseBranch))
  devAgentCount = resolveDevAgentCount(config.devAgentCount)

  // 1. Load board store
  store = loadBoardStoreSync(boardDir)

  // 2. Discover completed task IDs
  completedIds = getCompletedTaskIds(store)

  // 3. Collect backlog tasks
  rawBacklog = resolveRawContent(Option.fromNullishOr(store.backlogContent))
  backlogTasks = parseBacklogTasks(rawBacklog)
  extraTasks = getExtraTasks(store.tasksDoc, backlogTasks)
  allBacklog = backlogTasks |> Array.appendAll(extraTasks)

  // 4. DAG dependency resolution: filter pending and compute unblocked tasks
  activeTaskIds = state.activeSessions |> map((s) => s.taskId)
  pendingBacklog = allBacklog |> Array.filter((t) =>
    (not (completedIds |> Array.contains(t.id))) and (not (activeTaskIds |> Array.contains(t.id)))
  )

  dagNodes = pendingBacklog |> map(toTaskNode)

  readyIds = findReadyTasks(dagNodes, completedIds)
  unblockedTasks = pendingBacklog |> filter((t) => readyIds |> Array.contains(t.id))

  // 5. Detect idle lanes
  agentIndices = Array.range(1, devAgentCount)
  initIdle: Array<IdleAgent> = []
  idleAgents = agentIndices |> reduce(initIdle, (acc, i) => {
    agentId = "Dev Agent " + i
    laneTitle = "Dev Agent " + i + " In Progress"

    isSessionRunning = state.activeSessions |> Array.some((s) =>
      s.agentId #= agentId and s.status #= "Running"
    )
    when (isSessionRunning) => acc

    hasActiveTaskInLane = isLaneActiveInDoc(store.tasksDoc, agentId)
    when (hasActiveTaskInLane) => acc

    => acc |> Array.append({ agentId: agentId, laneTitle: laneTitle, agentIndex: i })
  })

  // 6. Assign ready tasks to idle lanes and execute sequentially
  pairs = zipIdleAndTasks(idleAgents, unblockedTasks)
  runningSessions = state.activeSessions |> filter((s) => s.status #= "Running")

  assignRes <- processPairs(
    pairs,
    runningSessions,
    state.tokenCounter,
    boardDir,
    baseBranch,
    store,
    config
  )

  resState: ReconcilerState = {
    tickCount: nextTick,
    activeSessions: assignRes.sessions,
    tokenCounter: assignRes.tokens
  }
  => resState
}

drainMergeQueue = (queue: Any, baseBranch: String): Effect.Effect<Unit, Any, Any> => effect {
  item <- Queue.poll(queue)
  when (Option.isNone(item)) => Unit
  rawReq = Option.getOrElse(item, () => "")
  req: MergeRequest = decodeMergeRequest(rawReq)
  _ <- landMergeRequest(req, baseBranch)
  _ <- drainMergeQueue(queue, baseBranch)
  => Unit
}

resolveMergeQueue = (queueOpt: Option.Option<Unknown>, fallbackQueue: Unknown): Unknown =>
  Option.getOrElse(queueOpt, () => fallbackQueue)

resolveMaxIterations = (max: Number): Number => {
  when (max > 0) => max
  => Infinity
}

maybeDrainQueue = (hasExternalQueue: Boolean, queue: Any, baseBranch: String): Effect.Effect<Unit, Any, Any> => {
  when (hasExternalQueue) => Effect.void
  => drainMergeQueue(queue, baseBranch)
}

maybeSleep = (nextTick: Number, maxTicks: Number, intervalMs: Number): Effect.Effect<Unit, Any, Any> => {
  when (nextTick >= maxTicks or intervalMs <= 0) => Effect.void
  => Effect.sleep(Duration.millis(intervalMs))
}

export runReconcilerLoop = (config: ReconcilerConfig) => effect {
  _ <- acquireBoardLock(config.boardDir)

  hasExternalQueue = Option.isSome(Option.fromNullishOr(config.mergeQueue))
  internalQueue <- createMergeTrain(100)
  resolvedQueue = resolveMergeQueue(Option.fromNullishOr(config.mergeQueue), internalQueue)

  resolvedConfig: ReconcilerConfig = {
    ...config,
    mergeQueue: Option.some(resolvedQueue)
  }

  agentCount = resolveDevAgentCount(config.devAgentCount)
  initialState: ReconcilerState = initialReconcilerState(agentCount)
  stateRef <- Ref.make(initialState)

  maxIterations = resolveMaxIterations(config.maxIterations)
  baseBranch = resolveBaseBranch(Option.fromNullishOr(config.baseBranch))

  loopStep = (): Effect.Effect<ReconcilerState, Any, Any> => effect {
    currentState <- Ref.get(stateRef)
    when (currentState.tickCount >= maxIterations) => currentState

    nextState <- reconcileTick(resolvedConfig, currentState)
    _ <- Ref.update(stateRef, () => nextState)
    _ <- maybeDrainQueue(hasExternalQueue, resolvedQueue, baseBranch)
    _ <- maybeSleep(nextState.tickCount, maxIterations, config.pollIntervalMs)

    rec <- loopStep()
    => rec
  }

  finalState <- loopStep()
  => finalState
}

export reconcileTickFun = (config: ReconcilerConfig, state: ReconcilerState) => effect {
  res <- reconcileTick(config, state)
  => res
}

export runReconcilerLoopFun = (config: ReconcilerConfig) => effect {
  res <- runReconcilerLoop(config)
  => res
}
