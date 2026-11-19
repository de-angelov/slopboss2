import { Array, Console, Duration, Effect, Option, Queue, Ref, Schema, String } from "effect"
import { archiveTask, BoardStore, loadBoardStoreSync, moveTask, parseBacklogTasks, persistBoardStoreSync, TaskBlock, TasksDocument } from "../domain/boardstore.js"
import { findReadyTasks, TaskNode } from "../domain/dag.js"
import { acquireBoardLock } from "../services/coordination.js"
import { buildDevAgentPrompt } from "../services/prompt.js"
import { runMockAgentSession, SessionResult } from "../services/runner.js"
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
  sections = match Option.fromNullishOr(archiveDoc)
    | Some(doc) => match Option.fromNullishOr(doc.sections)
      | Some(s) => s
      | _ => []
    | _ => []
  res = sections |> Array.flatMap((sec) => {
    tasks = match Option.fromNullishOr(sec.tasks)
      | Some(t) => t
      | _ => []
    initAcc: Array<String> = []
    => tasks |> Array.reduce(initAcc, (acc, t) =>
      match Option.fromNullishOr(t.id)
        | Some(id) => match (id #! "")
          | true => acc |> Array.append(id)
          | _ => acc
        | _ => acc
    )
  })
  => res
}

getContentCompletedIds = (archiveContent: String): Array<String> => {
  content = match Option.fromNullishOr(archiveContent)
    | Some(c) => c
    | _ => ""
  when (content #= "") => []

  bulletRx = globalThis.RegExp("- \\[x\\]\\s+([A-Za-z0-9_-]+):", "gi")
  taskRx = globalThis.RegExp("Task ID:\\s*([A-Za-z0-9_-]+)", "gi")

  matches1 = globalThis.Array.from(content.matchAll(bulletRx))
  initIds1: Array<String> = []
  ids1 = matches1 |> Array.reduce(initIds1, (acc, m) =>
    match m[1]
      | Some(id) => acc |> Array.append(id)
      | _ => acc
  )

  matches2 = globalThis.Array.from(content.matchAll(taskRx))
  initIds2: Array<String> = []
  ids2 = matches2 |> Array.reduce(initIds2, (acc, m) =>
    match m[1]
      | Some(id) => acc |> Array.append(id)
      | _ => acc
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
  initPairs: Array<PairItem> = []
  res = indices |> Array.reduce(initPairs, (acc, i) => {
    aOpt = agents[i]
    tOpt = tasks[i]
    match aOpt
      | Some(a) => match tOpt
        | Some(t) => acc |> Array.append({ idle: a, taskToAssign: t })
        | _ => acc
      | _ => acc
  })
  => res
}

processPairs = (pairList: Array<PairItem>, currentSessions: Array<RunningSession>, currentTokens: TokenCounter, boardDir: String, baseBranch: String, store: BoardStore, config: ReconcilerConfig): Effect.Effect<AssignmentResult, Any, Any> => effect {
  headOpt = Array.head(pairList)
  res <- match headOpt
    | Some(headItem) => effect {
      tail = pairList |> Array.drop(1)
      idle: IdleAgent = headItem.idle
      taskToAssign: TaskBlock = headItem.taskToAssign

      branchName: String = match Option.fromNullishOr(taskToAssign.branch)
        | Some(b) =>
          trimmed = b |> String.trim
          match (trimmed #= "")
            | true => "agent/" + globalThis.String(idle.agentIndex) + "/" + (taskToAssign.id |> String.toLowerCase)
            | _ => b
        | _ => "agent/" + globalThis.String(idle.agentIndex) + "/" + (taskToAssign.id |> String.toLowerCase)

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

      workspacePath = boardDir + "/workspaces/repo-agent-" + globalThis.String(idle.agentIndex)

      prompt: String = buildDevAgentPrompt(boardDir, taskAssigned, idle.agentId)

      runRes <- match Option.fromNullishOr(config.runnerFn)
        | Some(runner) => effect {
          runnerAny: Any = runner
          runnerCall: (a: String, b: String, c: String) => Effect.Effect<Unknown, Any, Any> = runnerAny
          resEffect = runnerCall(idle.agentId, taskAssigned.id, prompt)
          rawRes <- resEffect
          sessionRes = decodeSessionResult(rawRes)
          => sessionRes
        }
        | _ => runMockAgentSession(idle.agentId, taskAssigned.id)

      usedTokens: Number = match Option.fromNullishOr(runRes.totalTokens)
        | Some(tot) => tot
        | _ => 1420

      inTokens = globalThis.Math.floor(usedTokens * 0.7)
      outTokens = globalThis.Math.ceil(usedTokens * 0.3)

      updatedTokens: TokenCounter = {
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
            | Some(queue) => effect {
              q: Any = queue
              _ <- enqueueMergeRequest(q, mergeReq)
              => Unit
            }
            | _ => effect {
              _ <- landMergeRequest(mergeReq, baseBranch)
              => Unit
            }

          _archiveRes: Unknown = archiveTask(store, taskAssigned.id)
          _persistRes2: Unknown = persistBoardStoreSync(store)

          => currentSessions
        }
        | _ => effect {
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
    | _ => Effect.succeed({ sessions: currentSessions, tokens: currentTokens })
  => res
}

export reconcileTick = (config: ReconcilerConfig, state: ReconcilerState): Effect.Effect<ReconcilerState, Any, Any> => effect {
  nextTick = state.tickCount + 1
  boardDir = config.boardDir
  baseBranch = match Option.fromNullishOr(config.baseBranch)
    | Some(b) => b
    | _ => "main"
  devAgentCount = match (config.devAgentCount > 0)
    | true => config.devAgentCount
    | _ => 2

  // 1. Load board store
  store = loadBoardStoreSync(boardDir)

  // 2. Discover completed task IDs
  completedIds = getCompletedTaskIds(store)

  // 3. Collect backlog tasks
  rawBacklog = match Option.fromNullishOr(store.backlogContent)
    | Some(c) => c
    | _ => ""
  backlogTasks = parseBacklogTasks(rawBacklog)

  extraTasks = match Option.fromNullishOr(store.tasksDoc)
    | Some(doc) => match Option.fromNullishOr(doc.sections)
      | Some(sections) =>
        backlogSec = sections |> Array.findFirst((s) => {
          title = match Option.fromNullishOr(s.title)
            | Some(t) => t
            | _ => ""
          low = title |> String.toLowerCase
          => low |> String.includes("backlog")
        })
        match backlogSec
          | Some(sec) => match Option.fromNullishOr(sec.tasks)
            | Some(tasks) =>
              tasks |> Array.filter((t) =>
                not (backlogTasks |> Array.some((b) => b.id #= t.id))
              )
            | _ => []
          | _ => []
      | _ => []
    | _ => []

  allBacklog = backlogTasks |> Array.appendAll(extraTasks)

  // 4. DAG dependency resolution: filter pending and compute unblocked tasks
  activeTaskIds = state.activeSessions |> Array.map((s) => s.taskId)
  pendingBacklog = allBacklog |> Array.filter((t) =>
    (not (completedIds |> Array.contains(t.id))) and (not (activeTaskIds |> Array.contains(t.id)))
  )

  dagNodes = pendingBacklog |> Array.map((t) => {
    deps = match Option.fromNullishOr(t.dependencies)
      | Some(d) => d
      | _ => []
    node: TaskNode = { id: t.id, dependsOn: deps }
    => node
  })

  readyIds = findReadyTasks(dagNodes, completedIds)
  unblockedTasks = pendingBacklog |> Array.filter((t) => readyIds |> Array.contains(t.id))

  // 5. Detect idle lanes
  agentIndices = Array.range(1, devAgentCount)
  initIdle: Array<IdleAgent> = []
  idleAgents = agentIndices |> Array.reduce(initIdle, (acc, i) => {
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
              | _ => ""
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
                    | _ => ""
                  stLow = st |> String.toLowerCase
                  => stLow #= "in progress"
                })
              | _ => false
            | _ => false
        | _ => false
      | _ => false

    isIdle = (not isSessionRunning) and (not hasActiveTaskInLane)
    match isIdle
      | true => acc |> Array.append({ agentId: agentId, laneTitle: laneTitle, agentIndex: i })
      | _ => acc
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

  resState: ReconcilerState = {
    tickCount: nextTick,
    activeSessions: assignRes.sessions,
    tokenCounter: assignRes.tokens
  }
  => resState
}

drainMergeQueue = (queue: Any, baseBranch: String): Effect.Effect<Unit, Any, Any> => effect {
  item <- Queue.poll(queue)
  _ <- match item
    | Some(rawReq) => effect {
      req: MergeRequest = decodeMergeRequest(rawReq)
      _ <- landMergeRequest(req, baseBranch)
      _ <- drainMergeQueue(queue, baseBranch)
      => Unit
    }
    | _ => Effect.void
  => Unit
}

export runReconcilerLoop = (config: ReconcilerConfig) => effect {
  _ <- acquireBoardLock(config.boardDir)

  hasExternalQueue = Option.isSome(Option.fromNullishOr(config.mergeQueue))
  internalQueue <- createMergeTrain(100)
  resolvedQueue = match Option.fromNullishOr(config.mergeQueue)
    | Some(q) => q
    | _ => internalQueue

  resolvedConfig: ReconcilerConfig = {
    ...config,
    mergeQueue: Option.some(resolvedQueue)
  }

  agentCount = match (config.devAgentCount > 0)
    | true => config.devAgentCount
    | _ => 2

  initialState: ReconcilerState = initialReconcilerState(agentCount)
  stateRef <- Ref.make(initialState)

  maxIterations = match (config.maxIterations > 0)
    | true => config.maxIterations
    | _ => globalThis.Infinity

  baseBranch = match Option.fromNullishOr(config.baseBranch)
    | Some(b) => b
    | _ => "main"

  loopStep = (): Effect.Effect<ReconcilerState, Any, Any> => effect {
    currentState <- Ref.get(stateRef)
    res <- match (currentState.tickCount < maxIterations)
      | true => effect {
        nextState <- reconcileTick(resolvedConfig, currentState)
        _ <- Ref.set(stateRef, nextState)

        _ <- match (not hasExternalQueue)
          | true => drainMergeQueue(resolvedQueue, baseBranch)
          | _ => Effect.void

        _ <- match (nextState.tickCount < maxIterations and config.pollIntervalMs > 0)
          | true => Effect.sleep(Duration.millis(config.pollIntervalMs))
          | _ => Effect.void

        rec <- loopStep()
        => rec
      }
      | _ => Effect.succeed(currentState)
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
