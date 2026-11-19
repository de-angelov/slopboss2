import { Array, Deferred, Duration, Effect, FileSystem, Option, Path, Predicate, Ref, Schedule, Schema, String } from "effect"
import { BoardStore, MarkdownSection, TaskBlock, BunServices, loadBoardStoreSync } from "../domain/boardstore.js"
import { AgentLane, DashboardState, renderFullDashboard, TokenUsage } from "../ui/dashboard.js"

export schema LiveViewOptions = {
  stdin?: Unknown
  stdout?: Unknown
  maxTicks?: Number
  signal?: Unknown
  onTick?: Unknown
}

safeInvoke = (target: Unknown, method: String, args: Array<Unknown>) => {
  res = Effect.try(() => {
    obj: Any = target
    fnObj: Any = Reflect.get(obj, method)
    isFn = Predicate.isFunction(fnObj)
    match isFn
      | true => Reflect.apply(fnObj, target, args)
      | false => Option.none()
      | _ => Option.none()
    => true
  }) |> Effect.catch((_) => Effect.succeed(false)) |> Effect.runSync
  => res
}

readLanesAndStoreLogs = (boardDir: String) => {
  storeRes: Option<BoardStore> = Effect.try(() => loadBoardStoreSync(boardDir)) |> Effect.option |> Effect.runSync
  match storeRes
    | Some(store) =>
        sections = store.tasksDoc.sections
        laneLogs: Array<String> = sections |> Array.flatMap((sec: MarkdownSection) => {
          laneIdRaw = sec.name |> String.replace(RegExp("\\s+In Progress$", "i"), "") |> String.trim
          laneId = match laneIdRaw
            | "" => sec.name
            | id => id
          tasks = sec.tasks
          activeTaskOpt: Option<TaskBlock> = tasks |> Array.findFirst((t: TaskBlock) => t.status #= "In Progress")
          activeTask: Option<TaskBlock> = match activeTaskOpt
            | Some(t) => Option.some(t)
            | None => tasks |> Array.head
          res: Array<String> = match activeTask
            | Some(t) =>
                match (t.id #! "")
                  | true => ["[TASK] " + laneId + " working on " + t.id + " (" + t.title + ")"]
                  | false => []
                  | _ => []
            | _ => []
          => res
        })

        lanes: Array<AgentLane> = sections |> Array.map((sec: MarkdownSection) => {
          laneIdRaw = sec.name |> String.replace(RegExp("\\s+In Progress$", "i"), "") |> String.trim
          laneId = match laneIdRaw
            | "" => sec.name
            | id => id
          tasks = sec.tasks
          activeTaskOpt: Option<TaskBlock> = tasks |> Array.findFirst((t: TaskBlock) => t.status #= "In Progress")
          activeTask: Option<TaskBlock> = match activeTaskOpt
            | Some(t) => Option.some(t)
            | None => tasks |> Array.head
          res: AgentLane = match activeTask
            | Some(t) =>
                statusVal = match t.status
                  | "" => "In Progress"
                  | s => s
                branchVal = match t.branch
                  | "" => Option.none()
                  | b => Option.some(b)
                {
                  id: laneId,
                  status: statusVal,
                  task: Option.some(t.id),
                  branch: branchVal
                }
            | _ =>
                {
                  id: laneId,
                  status: "Idle",
                  task: Option.none(),
                  branch: Option.none()
                }
          => res
        })

        archiveSections = store.archiveDoc.sections
        archiveLogs: Array<String> = archiveSections |> Array.flatMap((sec: MarkdownSection) => {
          tasks = sec.tasks
          res: Array<String> = tasks |> Array.takeRight(3) |> Array.flatMap((t: TaskBlock) => match t.id
            | "" => []
            | id => ["[MERGE TRAIN] Task " + id + " landed cleanly."]
          )
          => res
        })

        allLogs: Array<String> = Array.appendAll(laneLogs, archiveLogs)
        { lanes: lanes, logs: allLogs }
    | None =>
        emptyLanes: Array<AgentLane> = []
        emptyLogs: Array<String> = []
        { lanes: emptyLanes, logs: emptyLogs }
}

readTokensSync = (boardDir: String): TokenUsage => {
  readEffect = effect {
    fsService <- FileSystem.FileSystem
    pathService <- Path.Path
    tokenPath = pathService.join(boardDir, ".tokens.json")
    altTokenPath = pathService.join(boardDir, "tokens.json")
    hasPrimary <- fsService.exists(tokenPath)
    hasAlt <- match hasPrimary
      | true => Effect.succeed(false)
      | false => fsService.exists(altTokenPath)
      | _ => Effect.succeed(false)
    targetPath = match hasPrimary
      | true => Option.some(tokenPath)
      | false => match hasAlt
        | true => Option.some(altTokenPath)
        | false => Option.none()
        | _ => Option.none()
      | _ => Option.none()

    rawOpt <- match targetPath
      | Some(p) => fsService.readFileString(p) |> Effect.option
      | None => Effect.succeed(Option.none())

    tokens: TokenUsage = match rawOpt
      | Some(raw) =>
          parsedOpt: Option<TokenUsage> = Schema.decodeUnknownOption(Schema.fromJsonString(TokenUsage))(raw)
          match parsedOpt
            | Some(tok) => tok
            | None => { inputTokens: 0, outputTokens: 0, totalTokens: 0 }
            | _ => { inputTokens: 0, outputTokens: 0, totalTokens: 0 }
      | None => { inputTokens: 0, outputTokens: 0, totalTokens: 0 }
      | _ => { inputTokens: 0, outputTokens: 0, totalTokens: 0 }

    => tokens
  }

  fallbackTokenUsage: TokenUsage = { inputTokens: 0, outputTokens: 0, totalTokens: 0 }
  res: TokenUsage = readEffect |> Effect.provide(BunServices.layer) |> Effect.catch((_) => Effect.succeed(fallbackTokenUsage)) |> Effect.runSync
  => res
}

readRecentLogsSync = (boardDir: String, initialLogs: Array<String>): Array<String> => {
  readEffect = effect {
    fsService <- FileSystem.FileSystem
    pathService <- Path.Path
    logPath = pathService.join(boardDir, ".slopboss.log")
    hasLog <- fsService.exists(logPath)
    rawOpt <- match hasLog
      | true => fsService.readFileString(logPath) |> Effect.option
      | false => Effect.succeed(Option.none())
      | _ => Effect.succeed(Option.none())

    logs = match rawOpt
      | Some(raw) =>
          lines = raw |> String.split("\n") |> Array.filter((l: String) => (l |> String.trim) #! "")
          recentLines = lines |> Array.takeRight(10)
          Array.appendAll(initialLogs, recentLines)
      | None => initialLogs
      | _ => initialLogs

    => logs
  }

  logsFromFs: Array<String> = readEffect |> Effect.provide(BunServices.layer) |> Effect.catch((_) => Effect.succeed(initialLogs)) |> Effect.runSync
  res: Array<String> = match (logsFromFs |> Array.length)
    | 0 => ["[SYSTEM] Live dashboard active. Waiting for orchestrator events..."]
    | _ => logsFromFs
  => res
}

export readDashboardState = (boardDir: String): DashboardState => {
  boardData = readLanesAndStoreLogs(boardDir)
  fallbackLanes: Array<AgentLane> = [
    { id: "Dev Agent 1", status: "Idle", task: Option.none(), branch: Option.none() },
    { id: "Dev Agent 2", status: "Idle", task: Option.none(), branch: Option.none() }
  ]
  lanes = match (boardData.lanes |> Array.length)
    | 0 => fallbackLanes
    | _ => boardData.lanes

  tokens = readTokensSync(boardDir)
  recentLogs = readRecentLogsSync(boardDir, boardData.logs)

  => {
    boardDir: boardDir,
    lanes: lanes,
    tokens: tokens,
    recentLogs: recentLogs
  }
}

extractOption = (opt: Option<Unknown>, fallback: Unknown): Unknown =>
  match opt
    | Some(v) => v
    | None => fallback
    | rawVal when Predicate.isNotNullish(rawVal) => rawVal
    | _ => fallback

extractMaxTicks = (opt: Option<Number>): Number =>
  match opt
    | Some(v) => match (v > 0)
        | true => v
        | false => Infinity
        | _ => Infinity
    | None => Infinity
    | rawVal when Predicate.isNotNullish(rawVal) =>
        num = Number(rawVal)
        match (num > 0)
          | true => num
          | false => Infinity
          | _ => Infinity
    | _ => Infinity

runLiveViewScoped = (boardDir: String, pollMs: Number, options: LiveViewOptions) => effect (unscoped) {
  stdin: Unknown = extractOption(options.stdin, process.stdin)
  stdout: Unknown = extractOption(options.stdout, process.stdout)
  maxTicks: Number = extractMaxTicks(options.maxTicks)

  intervalMs = Math.max(pollMs, 10)

  doneDeferred <- Deferred.make()
  tickCountRef <- Ref.make(0)

  onSigint = () => {
    _ = Deferred.succeed(doneDeferred, true) |> Effect.runSync
    => true
  }

  ctrlC = Buffer.from([3]).toString()
  onData = (chunk: Unknown) => {
    str = "" + chunk
    isExitKey = str #= "q" or str #= "Q" or str #= ctrlC
    match isExitKey
      | true => Deferred.succeed(doneDeferred, true) |> Effect.runSync
      | false => false
      | _ => false
    => true
  }

  _f <- Effect.addFinalizer(() => Effect.sync(() => {
    _1: Unknown = safeInvoke(stdin, "setRawMode", [false])
    _2: Unknown = safeInvoke(stdin, "pause", [])
    _3: Unknown = safeInvoke(stdin, "removeListener", ["data", onData])
    _4: Unknown = safeInvoke(process, "removeListener", ["SIGINT", onSigint])
    _5: Unknown = safeInvoke(stdout, "write", ["\u001b[?25h\nLive view closed.\n"])
    => true
  }))

  _s1: Unknown = safeInvoke(process, "on", ["SIGINT", onSigint])
  _s2: Unknown = safeInvoke(stdin, "setRawMode", [true])
  _s3: Unknown = safeInvoke(stdin, "resume", [])
  _s4: Unknown = safeInvoke(stdin, "setEncoding", ["utf8"])
  _s5: Unknown = safeInvoke(stdin, "on", ["data", onData])

  sigVal = extractOption(options.signal, Option.none())
  _sig: Unknown = match Predicate.isNotNullish(sigVal)
    | true =>
        sigObj: Any = sigVal
        abortedVal: Any = Reflect.get(sigObj, "aborted")
        aborted = Boolean(abortedVal)
        match aborted
          | true =>
              _ = Deferred.succeed(doneDeferred, true) |> Effect.runSync
              true
          | false =>
              abortListener = () => {
                _ = Deferred.succeed(doneDeferred, true) |> Effect.runSync
                => true
              }
              safeInvoke(sigVal, "addEventListener", ["abort", abortListener, { once: true }])
          | _ => true
    | false => true
    | _ => true

  tick = effect {
    cnt <- Ref.updateAndGet(tickCountRef, (n: Number) => n + 1)
    cntNum: Number = cnt
    state = readDashboardState(boardDir)
    output = renderFullDashboard(state)
    _w: Unknown = safeInvoke(stdout, "write", [output])
    onTickVal = extractOption(options.onTick, Option.none())
    _t: Unknown = match Predicate.isFunction(onTickVal)
      | true => safeInvoke(onTickVal, "call", [Option.none(), state, output])
      | false => true
      | _ => true
    _d <- match (cntNum >= maxTicks)
      | true => Deferred.succeed(doneDeferred, true)
      | false => Effect.void
      | _ => Effect.void
    => true
  }

  tickLoop = effect {
    _tk <- tick
    _sl <- Effect.sleep(Duration.millis(intervalMs))
    => true
  } |> Effect.repeat(Schedule.forever)

  _fk <- Effect.forkScoped(tickLoop)

  res <- Deferred.await(doneDeferred)
  => res
}

export defaultLiveViewOptions: LiveViewOptions = {
  stdin: Option.none(),
  stdout: Option.none(),
  maxTicks: Option.none(),
  signal: Option.none(),
  onTick: Option.none()
}

export runLiveView = (boardDir: String, pollMs: Number = 1000, options: LiveViewOptions = defaultLiveViewOptions) =>
  runLiveViewScoped(boardDir, pollMs, options) |> Effect.scoped

export runLiveViewAsync = (boardDir: String, pollMs: Number = 1000, options: LiveViewOptions = defaultLiveViewOptions) =>
  Effect.runPromise(runLiveView(boardDir, pollMs, options))

export runLiveViewFun = (boardDir: String, pollMs: Number = 1000) =>
  runLiveView(boardDir, pollMs, defaultLiveViewOptions)

export main = () => runLiveViewFun(".")
