import { Array, Console, Duration, Effect, Option, Predicate, Queue, Ref, Schema, String } from "effect"
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

export initialReconcilerState = (devAgentCount: Number = 2): ReconcilerState =>
  emptySessions: Array<RunningSession> = []
  => {
    tickCount: 0
    activeSessions: emptySessions
    tokenCounter: {
      inputTokens: 0
      outputTokens: 0
      totalTokens: 0
    }
  }

export initialReconcilerStateFun = (devAgentCount: Number = 2) =>
  initialReconcilerState(devAgentCount)

getDocCompletedIds = (archiveDoc: TasksDocument): Array<String> =>
  docOpt = Option.fromNullishOr(archiveDoc)
  sectionsOpt = Option.flatMap(docOpt, (doc) => Option.fromNullishOr(doc.sections))
  res =
    sectionsOpt
    |> Option.map((sections) =>
      sections
      |> Array.flatMap((sec: MarkdownSection) =>
        Option.fromNullishOr(sec.tasks)
        |> Option.getOrElse(() => [])
        |> Array.map((t: TaskBlock) => Option.getOrElse(Option.fromNullishOr(t.id), () => ""))
        |> Array.filter((id: String) => id #! "")
      )
    )
    |> Option.getOrElse(() => [])
  => res

getContentCompletedIds = (archiveContent: String): Array<String> =>
  content = Option.getOrElse(Option.fromNullishOr(archiveContent), () => "")
  match content #= ""
    | true => []
    | false =>
        bulletRx = RegExp("- \\[x\\]\\s+([A-Za-z0-9_-]+):", "gi")
        taskRx = RegExp("Task ID:\\s*([A-Za-z0-9_-]+)", "gi")

        matches1 = Array.fromIterable(content.matchAll(bulletRx))
        initIds1: Array<String> = []
        ids1 =
          matches1
          |> reduce(initIds1, (acc, m) =>
            rawId = Option.getOrElse(Option.fromNullishOr(Reflect.get(m, 1)), () => "")
            match rawId #= ""
              | true => acc
              | false => acc |> Array.append("" + rawId)
          )

        matches2 = Array.fromIterable(content.matchAll(taskRx))
        initIds2: Array<String> = []
        ids2 =
          matches2
          |> reduce(initIds2, (acc, m) =>
            rawId = Option.getOrElse(Option.fromNullishOr(Reflect.get(m, 1)), () => "")
            match rawId #= ""
              | true => acc
              | false => acc |> Array.append("" + rawId)
          )

        => ids1 |> Array.appendAll(ids2)

getCompletedTaskIds = (store: BoardStore): Array<String> =>
  docIds = getDocCompletedIds(store.archiveDoc)
  contentIds = getContentCompletedIds(store.archiveContent)
  allIds = docIds |> Array.appendAll(contentIds)
  => Array.dedupe(allIds)

zipIdleAndTasks = (agents: Array<IdleAgent>, tasks: Array<TaskBlock>): Array<PairItem> =>
  minLen = Math.min(agents.length, tasks.length)
  match minLen <= 0
    | true => []
    | false =>
        indices = Array.range(0, minLen - 1)
        initPairs: Array<PairItem> = []
        =>
          indices
          |> reduce(initPairs, (acc, i) => {
            aOpt = agents[i]
            tOpt = tasks[i]
            pairOpt = Option.flatMap(aOpt, (a) => Option.map(tOpt, (t) => acc |> Array.append({ idle: a, taskToAssign: t })))
            => Option.getOrElse(pairOpt, () => acc)
          })

resolveBranchName = (rawBranch: Option.Option<String>, agentIndex: Number, taskId: String): String =>
  defaultBranch = "agent/" + agentIndex + "/" + String.toLowerCase(taskId)
  b = Option.getOrElse(rawBranch, () => defaultBranch)
  trimmed = String.trim(b)
  match trimmed #= ""
    | true => defaultBranch
    | false => b

runGitInWorkspace = (args: Array<String>, workspace: String) =>
  proc = Bun.spawnSync(["git"] |> Array.appendAll(args), {
    cwd: workspace
    stdout: "pipe"
    stderr: "pipe"
  })
  => {
    code: proc.exitCode
    out: proc.stdout.toString() |> trim
  }

checkoutWorkspaceBranch = (workspace: String, branch: String): Boolean =>
  exists = runGitInWorkspace(["show-ref", "--verify", "--quiet", "refs/heads/" + branch], workspace)
  checkoutArgs =
    match exists.code #= 0
      | true => ["checkout", branch]
      | false => ["checkout", "-b", branch]
  checkout = runGitInWorkspace(checkoutArgs, workspace)
  => checkout.code #= 0

prepareWorkspace = (workspace: String, branch: String) => effect {
  _status = runGitInWorkspace(["status", "--porcelain"], workspace)
  branchRes = runGitInWorkspace(["branch", "--show-current"], workspace)
  branchFailed = branchRes.code #! 0
  onBranch = branchRes.out #= branch
  res =
    match
      | branchFailed => false
      | onBranch => true
      | _ => checkoutWorkspaceBranch(workspace, branch)
  => res
}

FnSchema = Schema.declare(Predicate.isFunction)
EffectSchema = Schema.declare(Effect.isEffect)
QueueSchema = Schema.declare(Queue.isQueue)
OptSchema = Schema.declare(Option.isOption)

unwrapOptBool = (val: Unknown, fallback: Boolean): Boolean =>
  optOpt = Schema.decodeUnknownOption(OptSchema)(val)
  boolOpt = Schema.decodeUnknownOption(Schema.Boolean)(val)
  res =
    optOpt
    |> Option.flatMap((o) => Option.flatMap(o, Schema.decodeUnknownOption(Schema.Boolean)))
    |> Option.orElse(() => boolOpt)
    |> Option.getOrElse(() => fallback)
  => res

unwrapOptUnknown = (val: Unknown): Option.Option<Unknown> =>
  optOpt = Schema.decodeUnknownOption(OptSchema)(val)
  res =
    optOpt
    |> Option.flatMap((o) => o)
    |> Option.orElse(() => Option.fromNullishOr(val))
  => res

unwrapOptStr = (val: Unknown, fallback: String): String =>
  optOpt = Schema.decodeUnknownOption(OptSchema)(val)
  strOpt = Schema.decodeUnknownOption(Schema.String)(val)
  res =
    optOpt
    |> Option.flatMap((o) => Option.flatMap(o, Schema.decodeUnknownOption(Schema.String)))
    |> Option.orElse(() => strOpt)
    |> Option.getOrElse(() => fallback)
  => res

runInjectedRunner = (runnerOpt: Option.Option<Unknown>, agentId: String, taskId: String, prompt: String, workspace: String) => effect {
  fOpt = Option.flatMap(runnerOpt, (r) => Schema.decodeUnknownOption(FnSchema)(r))
  effOpt = Option.flatMap(fOpt, (f) => Schema.decodeUnknownOption(EffectSchema)(Reflect.apply(f, Void, [agentId, taskId, prompt, workspace])))
  rawRes <- match effOpt
    | Some(eff) => eff
    | None => Effect.succeed({
      exitCode: 1
      totalTokens: 0
      completed: false
    })
  => decodeSessionResult(rawRes)
}

executeRunner = (runnerOpt: Option.Option<Unknown>, useMock: Boolean, agentId: String, taskId: String, prompt: String, workspace: String, provider: String) =>
  match useMock
    | true => runMockAgentSession(agentId, taskId)
    | false when Option.isNone(runnerOpt) => runConfiguredAgentSession(prompt, workspace, provider)
    | false => runInjectedRunner(runnerOpt, agentId, taskId, prompt, workspace)

resolveUsedTokens = (tokensOpt: Option.Option<Number>): Number =>
  Option.getOrElse(tokensOpt, () => 1420)

submitMergeRequest = (queueOpt: Option.Option<Unknown>, mergeReq: MergeRequest, baseBranch: String) =>
  qOpt = Option.flatMap(queueOpt, (q) => Schema.decodeUnknownOption(QueueSchema)(q))
  => match qOpt
    | None => effect {
      _ <- landMergeRequest(mergeReq, baseBranch)
      => Void
    }
    | Some(q) => effect {
      _ <- Queue.offer(q, mergeReq)
      => Void
    }

createFailedSession = (idle: IdleAgent, taskAssigned: TaskBlock, branchName: String, workspacePath: String): RunningSession => {
  agentId: idle.agentId
  taskId: taskAssigned.id
  branch: branchName
  workspace: workspacePath
  status: "Running"
}

landAndArchiveSession = (idle: IdleAgent, taskAssigned: TaskBlock, branchName: String, workspacePath: String, currentSessions: Array<RunningSession>, store: BoardStore, baseBranch: String) => effect {
  mergeReq: MergeRequest = {
    taskId: taskAssigned.id
    branch: branchName
    workspace: workspacePath
    isZeroCommit: false
    verificationCmd: Option.none()
  }

  landing <- landMergeRequest(mergeReq, baseBranch)
  resSessions <- match landing.success
    | false => Effect.succeed(currentSessions
    |> Array.append(createFailedSession(idle, taskAssigned, branchName, workspacePath)))
    | true => effect {
      _archiveRes: Unknown = archiveTask(store, taskAssigned.id)
      _persistRes2: Unknown = persistBoardStoreSync(store)
      => currentSessions
    }

  => resSessions
}

handleSessionCompletion = (isDone: Boolean, idle: IdleAgent, taskAssigned: TaskBlock, branchName: String, workspacePath: String, currentSessions: Array<RunningSession>, store: BoardStore, baseBranch: String, mergeQueueOpt: Option.Option<Unknown>) =>
  match isDone
    | false => Effect.succeed(currentSessions
    |> Array.append(createFailedSession(idle, taskAssigned, branchName, workspacePath)))
    | true => landAndArchiveSession(idle, taskAssigned, branchName, workspacePath, currentSessions, store, baseBranch)

prepareAndExecuteRunner = (useMock: Boolean, hasInjectedRunner: Boolean, runnerOpt: Option.Option<Unknown>, provider: String, idle: IdleAgent, taskAssigned: TaskBlock, prompt: String, workspacePath: String, branchName: String) => effect {
  prepared <- match useMock or hasInjectedRunner
    | true => Effect.succeed(true)
    | false => prepareWorkspace(workspacePath, branchName)
  runRes <- match prepared
    | true => executeRunner(runnerOpt, useMock, idle.agentId, taskAssigned.id, prompt, workspacePath, provider)
    | false => Effect.succeed({
      exitCode: 1
      totalTokens: 0
      completed: false
    })
  => runRes
}

processPairs = (pairList: Array<PairItem>, currentSessions: Array<RunningSession>, currentTokens: TokenCounter, boardDir: String, baseBranch: String, store: BoardStore, config: ReconcilerConfig): Effect.Effect<AssignmentResult, Unknown, Unknown> =>
  match Array.head(pairList)
    | None => Effect.succeed({ sessions: currentSessions, tokens: currentTokens })
    | Some(headItem) => effect {
      tail = pairList |> Array.drop(1)
      idle: IdleAgent = headItem.idle
      taskToAssign: TaskBlock = headItem.taskToAssign

      branchName = resolveBranchName(Option.fromNullishOr(taskToAssign.branch), idle.agentIndex, taskToAssign.id)

      taskAssigned: TaskBlock = {
        id: taskToAssign.id
        title: taskToAssign.title
        category: taskToAssign.category
        owner: idle.agentId
        branch: branchName
        status: "In Progress"
        dependencies: taskToAssign.dependencies
        objective: taskToAssign.objective
        scope: taskToAssign.scope
        acceptanceCriteria: taskToAssign.acceptanceCriteria
        rawBody: taskToAssign.rawBody
      }

      _moveRes: Unknown = moveTask(store, taskAssigned.id, idle.laneTitle)
      _persistRes1: Unknown = persistBoardStoreSync(store)

      workspacePath = boardDir + "/workspaces/repo-agent-" + idle.agentIndex
      prompt: String = "" + buildDevAgentPrompt(boardDir, taskAssigned, idle.agentId)

      useMock = unwrapOptBool(config.mockRunner, false)
      runnerOpt = unwrapOptUnknown(config.runnerFn)
      hasInjectedRunner = Option.isSome(runnerOpt)
      runRes <- prepareAndExecuteRunner(useMock, hasInjectedRunner, runnerOpt, unwrapOptStr(config.provider, "agy"), idle, taskAssigned, prompt, workspacePath, branchName)

      usedTokens = resolveUsedTokens(Option.fromNullishOr(runRes.totalTokens))
      inTokens = Math.floor(usedTokens * 0.7)
      outTokens = Math.ceil(usedTokens * 0.3)

      updatedTokens: TokenCounter = {
        inputTokens: currentTokens.inputTokens + inTokens
        outputTokens: currentTokens.outputTokens + outTokens
        totalTokens: currentTokens.totalTokens + usedTokens
      }

      isDone = runRes.completed and runRes.exitCode #= 0

      updatedSessions <- handleSessionCompletion(isDone, idle, taskAssigned, branchName, workspacePath, currentSessions, store, baseBranch, config.mergeQueue)

      nextResult <- processPairs(tail, updatedSessions, updatedTokens, boardDir, baseBranch, store, config)
      => nextResult
    }

resolveBaseBranch = (branchOpt: Option.Option<String>): String =>
  Option.getOrElse(branchOpt, () => "main")

resolveDevAgentCount = (count: Number): Number =>
  match count > 0
    | true => count
    | false => 2

resolveRawContent = (contentOpt: Option.Option<String>): String =>
  Option.getOrElse(contentOpt, () => "")

getExtraTasks = (tasksDoc: TasksDocument, existingTasks: Array<TaskBlock>): Array<TaskBlock> =>
  docOpt = Option.fromNullishOr(tasksDoc)
  sectionsOpt = Option.flatMap(docOpt, (doc) => Option.fromNullishOr(doc.sections))
  backlogSecOpt = Option.flatMap(sectionsOpt, (sections) =>
    sections
    |> Array.findFirst((s: MarkdownSection) => {
      title = Option.getOrElse(Option.fromNullishOr(s.title), () => "")
      low = title |> toLowerCase
      => low |> includes("backlog")
    })
  )
  tasksOpt = Option.flatMap(backlogSecOpt, (sec) => Option.fromNullishOr(sec.tasks))
  res =
    tasksOpt
    |> Option.map((tasks) =>
      tasks
      |> Array.filter((t: TaskBlock) =>
        not (existingTasks |> Array.some((b: TaskBlock) => b.id #= t.id))
      )
    )
    |> Option.getOrElse(() => [])
  => res

getTaskDependencies = (t: TaskBlock): Array<String> =>
  Option.getOrElse(Option.fromNullishOr(t.dependencies), () => [])

toTaskNode = (t: TaskBlock): TaskNode => {
  id: t.id
  dependsOn: getTaskDependencies(t)
}

isLaneActiveInDoc = (tasksDoc: TasksDocument, agentId: String): Boolean =>
  docOpt = Option.fromNullishOr(tasksDoc)
  sectionsOpt = Option.flatMap(docOpt, (doc) => Option.fromNullishOr(doc.sections))
  agentIdLow = agentId |> toLowerCase
  laneSecOpt = Option.flatMap(sectionsOpt, (sections) =>
    sections
    |> Array.findFirst((s: MarkdownSection) => {
      title = Option.getOrElse(Option.fromNullishOr(s.title), () => "")
      low = title |> toLowerCase
      => low |> includes(agentIdLow)
    })
  )
  tasksOpt = Option.flatMap(laneSecOpt, (sec) => Option.fromNullishOr(sec.tasks))
  => match tasksOpt
    | None => false
    | Some(tasks) =>
        tasks
        |> Array.some((t: TaskBlock) => {
          st = Option.getOrElse(Option.fromNullishOr(t.status), () => "")
          stLow = st |> toLowerCase
          => stLow #= "in progress"
        })

export reconcileTick = (config: ReconcilerConfig, state: ReconcilerState) => effect {
  nextTick = state.tickCount + 1
  boardDir = config.boardDir
  baseBranch = unwrapOptStr(config.baseBranch, "main")
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
  activeTaskIds = state.activeSessions |> Array.map((s) => s.taskId)
  pendingBacklog =
    allBacklog
    |> Array.filter((t) =>
      not (completedIds |> Array.contains(t.id)) and not (activeTaskIds |> Array.contains(t.id))
    )

  dagNodes = pendingBacklog |> Array.map(toTaskNode)

  readyIds = findReadyTasks(dagNodes, completedIds)
  unblockedTasks = pendingBacklog |> Array.filter((t) => readyIds |> Array.contains(t.id))

  // 5. Detect idle lanes
  agentIndices = Array.range(1, devAgentCount)
  initIdle: Array<IdleAgent> = []
  idleAgents =
    agentIndices
    |> reduce(initIdle, (acc, i) => {
      agentId = "Dev Agent " + i
      laneTitle = "Dev Agent " + i + " In Progress"

      isSessionRunning =
        state.activeSessions
        |> Array.some((s) =>
          s.agentId #= agentId and s.status #= "Running"
        )
      hasActiveTaskInLane = isLaneActiveInDoc(store.tasksDoc, agentId)
      isIdle = not isSessionRunning and not hasActiveTaskInLane
      => match isIdle
        | true =>
            acc
            |> Array.append({
              agentId: agentId
              laneTitle: laneTitle
              agentIndex: i
            })
        | false => acc
    })

  // 6. Assign ready tasks to idle lanes and execute sequentially
  pairs = zipIdleAndTasks(idleAgents, unblockedTasks)
  runningSessions = state.activeSessions |> Array.filter((s) => s.status #= "Running")

  assignRes <- processPairs(pairs, runningSessions, state.tokenCounter, boardDir, baseBranch, store, config)

  resState: ReconcilerState = {
    tickCount: nextTick
    activeSessions: assignRes.sessions
    tokenCounter: assignRes.tokens
  }
  => resState
}

DequeueSchema = Schema.declare(Queue.isDequeue)

drainMergeQueue = (queue: Unknown, baseBranch: String): Effect.Effect<Void> => effect {
  qOpt = Schema.decodeUnknownOption(DequeueSchema)(queue)
  item <- match qOpt
    | None => Effect.succeed(Option.none())
    | Some(q) => Queue.poll(q)
  _ <- match item
    | None => Effect.void
    | Some(rawReq) => effect {
      req: MergeRequest = decodeMergeRequest(rawReq)
      _ <- landMergeRequest(req, baseBranch)
      _ <- drainMergeQueue(queue, baseBranch)
      => Void
    }

  => Void
}

resolveMergeQueue = (queueOpt: Option.Option<Unknown>, fallbackQueue: Unknown): Unknown =>
  Option.getOrElse(queueOpt, () => fallbackQueue)

resolveMaxIterations = (max: Number): Number =>
  match max > 0
    | true => max
    | false => Infinity

maybeDrainQueue = (hasExternalQueue: Boolean, queue: Unknown, baseBranch: String) =>
  match hasExternalQueue
    | true => Effect.void
    | false => drainMergeQueue(queue, baseBranch)

maybeSleep = (nextTick: Number, maxTicks: Number, intervalMs: Number) =>
  match nextTick >= maxTicks or intervalMs <= 0
    | true => Effect.void
    | false => Effect.sleep(Duration.millis(intervalMs))

export runReconcilerLoop = (config: ReconcilerConfig) => effect {
  _ <- acquireBoardLock(config.boardDir)

  safeMergeQueue =
    match Boolean(config.mergeQueue)
      | true => config.mergeQueue
      | false => Option.none()
  hasExternalQueue = Option.isSome(safeMergeQueue)
  internalQueue <- createMergeTrain(100)
  resolvedQueue = resolveMergeQueue(safeMergeQueue, internalQueue)

  resolvedConfig: ReconcilerConfig = {
    ...config
    mergeQueue: Option.some(resolvedQueue)
  }

  agentCount = resolveDevAgentCount(config.devAgentCount)
  initialState: ReconcilerState = initialReconcilerState(agentCount)
  stateRef <- Ref.make(initialState)

  maxIterations = resolveMaxIterations(config.maxIterations)
  baseBranch = unwrapOptStr(config.baseBranch, "main")

  loopStep = (): Effect.Effect<ReconcilerState, Unknown, Unknown> => effect {
    currentState <- Ref.get(stateRef)
    rec <- match currentState.tickCount >= maxIterations
      | true => Effect.succeed(currentState)
      | false => effect {
        nextState <- reconcileTick(resolvedConfig, currentState)
        _ <- Ref.update(stateRef, () => nextState)
        _ <- maybeDrainQueue(hasExternalQueue, resolvedQueue, baseBranch)
        _ <- maybeSleep(nextState.tickCount, maxIterations, config.pollIntervalMs)

        r <- loopStep()
        => r
      }

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
