import { Array, Console, Duration, Effect, Option, Queue, Ref, Schema, String } from "effect"
import { archiveTask, BoardStore, loadBoardStoreSync, moveTask, parseBacklogTasks, persistBoardStoreSync, TaskBlock, TasksDocument } from "../domain/boardstore.js"
import { findReadyTasks, TaskNode } from "../domain/dag.js"
import { acquireBoardLock } from "../services/coordination.js"
import { buildDevAgentPrompt } from "../services/prompt.js"
import { runMockAgentSession } from "../services/runner.js"
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

export initialReconcilerState = (devAgentCount: Number = 2) => {
  tickCount: 0,
  activeSessions: [],
  tokenCounter: {
    inputTokens: 0,
    outputTokens: 0,
    totalTokens: 0
  }
}

export initialReconcilerStateFun = (devAgentCount: Number = 2) =>
  initialReconcilerState(devAgentCount)

getDocCompletedIds = (archiveDoc: TasksDocument): Array<String> => {
  sections = match Option.fromNullishOr(archiveDoc)
    | Some(doc) => match Option.fromNullishOr(doc.sections)
      | Some(s) => s
      | None => []
    | None => []
  res = sections |> Array.flatMap((sec) => {
    tasks = match Option.fromNullishOr(sec.tasks)
      | Some(t) => t
      | None => []
    => tasks |> Array.reduce([], (acc, t) =>
      match Option.fromNullishOr(t.id)
        | Some(id) => match (id #! "")
          | true => acc |> Array.append(id)
          | false => acc
        | None => acc
    )
  })
  => res
}

getContentCompletedIds = (archiveContent: String): Array<String> => {
  content = match Option.fromNullishOr(archiveContent)
    | Some(c) => c
    | None => ""
  when (content #= "") => []

  bulletRx = globalThis.RegExp("- \\[x\\]\\s+([A-Za-z0-9_-]+):", "gi")
  taskRx = globalThis.RegExp("Task ID:\\s*([A-Za-z0-9_-]+)", "gi")

  matches1 = globalThis.Array.from(content.matchAll(bulletRx))
  ids1 = matches1 |> Array.reduce([], (acc, m) =>
    match m[1]
      | Some(id) => acc |> Array.append(id)
      | None => acc
  )

  matches2 = globalThis.Array.from(content.matchAll(taskRx))
  ids2 = matches2 |> Array.reduce([], (acc, m) =>
    match m[1]
      | Some(id) => acc |> Array.append(id)
      | None => acc
  )

  => ids1 |> Array.appendAll(ids2)
}

getCompletedTaskIds = (store: BoardStore): Array<String> => {
  docIds = getDocCompletedIds(store.archiveDoc)
  contentIds = getContentCompletedIds(store.archiveContent)
  allIds = docIds |> Array.appendAll(contentIds)
  => Array.dedupe(allIds)
}

zipIdleAndTasks = (agents: Array<IdleAgent>, tasks: Array<TaskBlock>): Array<PairItem> => {
  minLen = globalThis.Math.min(agents.length, tasks.length)
  when (minLen <= 0) => []
  indices = Array.range(0, minLen - 1)
  res = indices |> Array.reduce([], (acc, i) => {
    aOpt = agents[i]
    tOpt = tasks[i]
    match aOpt
      | Some(a) => match tOpt
        | Some(t) => acc |> Array.append({ idle: a, taskToAssign: t })
        | None => acc
      | None => acc
  })
  => res
}

processPairs = (pairList: Array<PairItem>, currentSessions: Array<RunningSession>, currentTokens: TokenCounter, boardDir: String, baseBranch: String, store: BoardStore, config: ReconcilerConfig): Effect.Effect<AssignmentResult> => effect {
  res <- match pairList
    | [] => Effect.succeed({ sessions: currentSessions, tokens: currentTokens })
    | [head, ...tail] => effect {
      idle = head.idle
      taskToAssign = head.taskToAssign

      branchName = match Option.fromNullishOr(taskToAssign.branch)
        | Some(b) =>
          trimmed = b |> String.trim
          match (trimmed #= "")
            | true => "agent/" + globalThis.String(idle.agentIndex) + "/" + (taskToAssign.id |> String.toLowerCase)
            | false => b
        | None => "agent/" + globalThis.String(idle.agentIndex) + "/" + (taskToAssign.id |> String.toLowerCase)

      taskAssigned = {
        ...taskToAssign,
        owner: idle.agentId,
        status: "In Progress",
        branch: branchName
      }

      _moveRes = moveTask(store, taskAssigned.id, idle.laneTitle)
      _persistRes1 = persistBoardStoreSync(store)

      workspacePath = boardDir + "/workspaces/repo-agent-" + globalThis.String(idle.agentIndex)

      prompt = buildDevAgentPrompt(boardDir, taskAssigned, idle.agentId)

      runRes <- match Option.fromNullishOr(config.runnerFn)
        | Some(runner) => runner(idle.agentId, taskAssigned.id, prompt)
        | None => runMockAgentSession(idle.agentId, taskAssigned.id)

      usedTokens = match Option.fromNullishOr(runRes.totalTokens)
        | Some(tot) => tot
        | None => 1420

      inTokens = globalThis.Math.floor(usedTokens * 0.7)
      outTokens = globalThis.Math.ceil(usedTokens * 0.3)

      updatedTokens = {
        inputTokens: currentTokens.inputTokens + inTokens,
        outputTokens: currentTokens.outputTokens + outTokens,
        totalTokens: currentTokens.totalTokens + usedTokens
      }

      isDone = runRes.completed or runRes.exitCode #= 0

      updatedSessions <- match isDone
        | true => effect {
          mergeReq: MergeRequest = {
            taskId: taskAssigned.id,
            branch: branchName,
            workspace: workspacePath,
            isZeroCommit: false,
            verificationCmd: Option.none()
          }

          _ <- match Option.fromNullishOr(config.mergeQueue)
            | Some(queue) => enqueueMergeRequest(queue, mergeReq)
            | None => landMergeRequest(mergeReq, baseBranch)

          _archiveRes = archiveTask(store, taskAssigned.id)
          _persistRes2 = persistBoardStoreSync(store)

          => currentSessions
        }
        | false => effect {
          failedSession: RunningSession = {
            agentId: idle.agentId,
            taskId: taskAssigned.id,
            branch: branchName,
            workspace: workspacePath,
            status: "Running"
          }
          => currentSessions |> Array.append(failedSession)
        }

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
  => res
}

export reconcileTick = (config: ReconcilerConfig, state: ReconcilerState): Effect.Effect<ReconcilerState> => effect {
  nextTick = state.tickCount + 1
  boardDir = config.boardDir
  baseBranch = match Option.fromNullishOr(config.baseBranch)
    | Some(b) => b
    | None => "main"
  devAgentCount = match (config.devAgentCount > 0)
    | true => config.devAgentCount
    | false => 2

  // 1. Load board store
  store = loadBoardStoreSync(boardDir)

  // 2. Discover completed task IDs
  completedIds = getCompletedTaskIds(store)

  // 3. Collect backlog tasks
  rawBacklog = match Option.fromNullishOr(store.backlogContent)
    | Some(c) => c
    | None => ""
  backlogTasks = parseBacklogTasks(rawBacklog)

  extraTasks = match Option.fromNullishOr(store.tasksDoc)
    | Some(doc) => match Option.fromNullishOr(doc.sections)
      | Some(sections) =>
        backlogSec = sections |> Array.findFirst((s) => {
          title = match Option.fromNullishOr(s.title)
            | Some(t) => t
            | None => ""
          low = title |> String.toLowerCase
          => low |> String.includes("backlog")
        })
        match backlogSec
          | Some(sec) => match Option.fromNullishOr(sec.tasks)
            | Some(tasks) =>
              tasks |> Array.filter((t) =>
                not (backlogTasks |> Array.some((b) => b.id #= t.id))
              )
            | None => []
          | None => []
      | None => []
    | None => []

  allBacklog = backlogTasks |> Array.appendAll(extraTasks)

  // 4. DAG dependency resolution: filter pending and compute unblocked tasks
  activeTaskIds = state.activeSessions |> Array.map((s) => s.taskId)
  pendingBacklog = allBacklog |> Array.filter((t) =>
    (not (completedIds |> Array.contains(t.id))) and (not (activeTaskIds |> Array.contains(t.id)))
  )

  dagNodes = pendingBacklog |> Array.map((t) => {
    deps = match Option.fromNullishOr(t.dependencies)
      | Some(d) => d
      | None => []
    node: TaskNode = { id: t.id, dependsOn: deps }
    => node
  })

  readyIds = findReadyTasks(dagNodes, completedIds)
  unblockedTasks = pendingBacklog |> Array.filter((t) => readyIds |> Array.contains(t.id))

  // 5. Detect idle lanes
  agentIndices = Array.range(1, devAgentCount)
  idleAgents = agentIndices |> Array.reduce([], (acc, i) => {
    agentId = "Dev Agent " + globalThis.String(i)
    laneTitle = "Dev Agent " + globalThis.String(i) + " In Progress"

    isSessionRunning = state.activeSessions |> Array.some((s) =>
      s.agentId #= agentId and s.status #= "Running"
    )

    hasActiveTaskInLane = match Option.fromNullishOr(store.tasksDoc)
      | Some(doc) => match Option.fromNullishOr(doc.sections)
        | Some(sections) =>
          laneSec = sections |> Array.findFirst((s) => {
            title = match Option.fromNullishOr(s.title)
              | Some(t) => t
              | None => ""
            low = title |> String.toLowerCase
            agentIdLow = agentId |> String.toLowerCase
            => low |> String.includes(agentIdLow)
          })
          match laneSec
            | Some(sec) => match Option.fromNullishOr(sec.tasks)
              | Some(tasks) =>
                tasks |> Array.some((t) => {
                  st = match Option.fromNullishOr(t.status)
                    | Some(s) => s
                    | None => ""
                  stLow = st |> String.toLowerCase
                  => stLow #= "in progress"
                })
              | None => false
            | None => false
        | None => false
      | None => false

    isIdle = (not isSessionRunning) and (not hasActiveTaskInLane)
    match isIdle
      | true => acc |> Array.append({ agentId: agentId, laneTitle: laneTitle, agentIndex: i })
      | false => acc
  })

  // 6. Assign ready tasks to idle lanes and execute sequentially
  pairs = zipIdleAndTasks(idleAgents, unblockedTasks)
  runningSessions = state.activeSessions |> Array.filter((s) => s.status #= "Running")

  assignRes <- processPairs(
    pairs,
    runningSessions,
    state.tokenCounter,
    boardDir,
    baseBranch,
    store,
    config
  )

  => {
    tickCount: nextTick,
    activeSessions: assignRes.sessions,
    tokenCounter: assignRes.tokens
  }
}

drainMergeQueue = (queue: Queue.Queue<MergeRequest>, baseBranch: String): Effect.Effect<Unit> => effect {
  item <- Queue.poll(queue)
  _ <- match item
    | Some(req) => effect {
      _ <- landMergeRequest(req, baseBranch)
      _ <- drainMergeQueue(queue, baseBranch)
      => Unit
    }
    | None => Effect.void
  => Unit
}

export runReconcilerLoop = (config: ReconcilerConfig) => effect {
  _ <- acquireBoardLock(config.boardDir)

  hasExternalQueue = Option.isSome(Option.fromNullishOr(config.mergeQueue))
  internalQueue <- createMergeTrain(100)
  resolvedQueue = match Option.fromNullishOr(config.mergeQueue)
    | Some(q) => q
    | None => internalQueue

  resolvedConfig: ReconcilerConfig = {
    ...config,
    mergeQueue: resolvedQueue
  }

  agentCount = match (config.devAgentCount > 0)
    | true => config.devAgentCount
    | false => 2

  initialState = initialReconcilerState(agentCount)
  stateRef <- Ref.make(initialState)

  maxIterations = match (config.maxIterations > 0)
    | true => config.maxIterations
    | false => globalThis.Infinity

  baseBranch = match Option.fromNullishOr(config.baseBranch)
    | Some(b) => b
    | None => "main"

  loopStep = (): Effect.Effect<ReconcilerState> => effect {
    currentState <- Ref.get(stateRef)
    res <- match (currentState.tickCount < maxIterations)
      | false => Effect.succeed(currentState)
      | true => effect {
        nextState <- reconcileTick(resolvedConfig, currentState)
        _ <- Ref.set(stateRef, nextState)

        _ <- match (not hasExternalQueue)
          | true => drainMergeQueue(resolvedQueue, baseBranch)
          | false => Effect.void

        _ <- match (nextState.tickCount < maxIterations and config.pollIntervalMs > 0)
          | true => Effect.sleep(Duration.millis(config.pollIntervalMs))
          | false => Effect.void

        rec <- loopStep()
        => rec
      }
    => res
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
