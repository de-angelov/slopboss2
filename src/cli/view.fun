import { Array, Deferred, Duration, Effect, FileSystem, Option, Path, Predicate, Ref, Schedule, Schema, String } from "effect"
import { BunServices, loadBoardStoreSync } from "../domain/boardstore.js"
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
    obj: Any = globalThis.Object(target)
    fnObj: Any = Reflect.get(obj, method)
    isFn = Predicate.isFunction(fnObj)
    match isFn
      | true => Reflect.apply(fnObj, target, args)
      | false => globalThis.undefined
    => true
  }) |> Effect.catch((_) => Effect.succeed(false)) |> Effect.runSync
  => res
}

readLanesAndStoreLogs = (boardDir: String) => {
  storeRes = Effect.try(() => loadBoardStoreSync(boardDir)) |> Effect.option |> Effect.runSync
  match storeRes
    | Some(store) =>
        storeVal: Any = store
        sections: Array<Any> = storeVal.tasksDoc.sections
        laneLogs: Array<String> = sections |> Array.flatMap((sec: Any) => {
          laneIdRaw = sec.name |> String.replace(globalThis.RegExp("\\s+In Progress$", "i"), "") |> String.trim
          laneId = match laneIdRaw
            | "" => sec.name
            | id => id
          tasks: Array<Any> = sec.tasks
          activeTaskOpt: Option<Any> = tasks |> Array.findFirst((t: Any) => t.status #= "In Progress")
          activeTask: Option<Any> = match activeTaskOpt
            | Some(t) => Option.some(t)
            | None => tasks |> Array.head
          res: Array<String> = match activeTask
            | Some(t) =>
                tVal: Any = t
                match (tVal.id #! "")
                  | true => ["[TASK] " + laneId + " working on " + tVal.id + " (" + tVal.title + ")"]
                  | false => []
            | _ => []
          => res
        })

        lanes: Array<AgentLane> = sections |> Array.map((sec: Any) => {
          laneIdRaw = sec.name |> String.replace(globalThis.RegExp("\\s+In Progress$", "i"), "") |> String.trim
          laneId = match laneIdRaw
            | "" => sec.name
            | id => id
          tasks: Array<Any> = sec.tasks
          activeTaskOpt: Option<Any> = tasks |> Array.findFirst((t: Any) => t.status #= "In Progress")
          activeTask: Option<Any> = match activeTaskOpt
            | Some(t) => Option.some(t)
            | None => tasks |> Array.head
          res: AgentLane = match activeTask
            | Some(t) =>
                tVal: Any = t
                statusVal = match tVal.status
                  | "" => "In Progress"
                  | s => s
                branchVal = match tVal.branch
                  | "" => Option.none()
                  | b => Option.some(b)
                {
                  id: laneId,
                  status: statusVal,
                  task: Option.some(tVal.id),
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

        archiveSections: Array<Any> = storeVal.archiveDoc.sections
        archiveLogs: Array<String> = archiveSections |> Array.flatMap((sec: Any) => {
          tasks: Array<Any> = sec.tasks
          res: Array<String> = tasks |> Array.takeRight(3) |> Array.flatMap((t: Any) => match t.id
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
    targetPath = match hasPrimary
      | true => Option.some(tokenPath)
      | false => match hasAlt
        | true => Option.some(altTokenPath)
        | false => Option.none()

    rawOpt <- match targetPath
      | Some(p) => fsService.readFileString(p) |> Effect.option
      | None => Effect.succeed(Option.none())

    tokens = match rawOpt
      | Some(raw) =>
          parsed: Any = globalThis.JSON.parse(raw)
          rawInp: Number = globalThis.Number(parsed.inputTokens)
          inp = match (rawInp > 0)
            | true => rawInp
            | false => 0
          rawOut: Number = globalThis.Number(parsed.outputTokens)
          out = match (rawOut > 0)
            | true => rawOut
            | false => 0
          rawTot: Number = globalThis.Number(parsed.totalTokens)
          tot = match (rawTot > 0)
            | true => rawTot
            | false => 0
          { inputTokens: inp, outputTokens: out, totalTokens: tot }
      | None =>
          { inputTokens: 0, outputTokens: 0, totalTokens: 0 }
    => tokens
  }

  res: TokenUsage = readEffect |> Effect.provide(BunServices.layer) |> Effect.catch((_) => Effect.succeed({ inputTokens: 0, outputTokens: 0, totalTokens: 0 })) |> Effect.runSync
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
    logs = match rawOpt
      | Some(raw) =>
          lines = raw |> String.split(globalThis.RegExp("\\r?\\n")) |> Array.filter((l) => (l |> String.trim) #! "")
          match lines |> Array.length
            | 0 => initialLogs
            | _ => lines |> Array.takeRight(5)
      | None => initialLogs
    => logs
  }

  logsFromFs: Array<String> = readEffect |> Effect.provide(BunServices.layer) |> Effect.catch((_) => Effect.succeed(initialLogs)) |> Effect.runSync

  withFallback: Array<String> = match (logsFromFs |> Array.length)
    | 0 => ["[IDLE] Waiting for next dispatch cycle..."]
    | _ => logsFromFs

  => withFallback |> Array.dedupe |> Array.takeRight(6)
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

runLiveViewScoped = (boardDir: String, pollMs: Number, options: LiveViewOptions) => effect {
  rawOpts: Any = options
  stdin: Unknown = match rawOpts.stdin
    | inStream when Predicate.isNotNullish(inStream) => inStream
    | _ => process.stdin

  stdout: Unknown = match rawOpts.stdout
    | outStream when Predicate.isNotNullish(outStream) => outStream
    | _ => process.stdout

  rawMax: Number = globalThis.Number(rawOpts.maxTicks)
  maxTicks: Number = match (rawMax > 0)
    | true => rawMax
    | false => globalThis.Infinity

  intervalMs = globalThis.Math.max(pollMs, 10)

  doneDeferred <- Deferred.make()
  tickCountRef <- Ref.make(0)

  onSigint = () => {
    _ = Deferred.succeed(doneDeferred, true) |> Effect.runSync
    => true
  }

  ctrlC = globalThis.String.fromCharCode(3)
  onData = (chunk: Unknown) => {
    str = "" + chunk
    isExitKey = str #= "q" or str #= "Q" or str #= ctrlC
    match isExitKey
      | true => Deferred.succeed(doneDeferred, true) |> Effect.runSync
      | false => false
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

  sig: Any = rawOpts.signal
  _sig: Unknown = match Predicate.isNotNullish(sig)
    | true =>
        aborted: Boolean = Reflect.get(globalThis.Object(sig), "aborted")
        match aborted
          | true =>
              _ = Deferred.succeed(doneDeferred, true) |> Effect.runSync
              true
          | false =>
              abortListener = () => {
                _ = Deferred.succeed(doneDeferred, true) |> Effect.runSync
                => true
              }
              safeInvoke(sig, "addEventListener", ["abort", abortListener, { once: true }])
    | false => true

  tick = effect {
    cnt <- Ref.updateAndGet(tickCountRef, (n: Number) => n + 1)
    cntNum: Number = cnt
    state = readDashboardState(boardDir)
    output = renderFullDashboard(state)
    _w: Unknown = safeInvoke(stdout, "write", [output])
    _t: Unknown = safeInvoke(rawOpts, "onTick", [state, output])
    _d <- match (cntNum >= maxTicks)
      | true => Deferred.succeed(doneDeferred, true)
      | false => Effect.void
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

export runLiveView = (boardDir: String, pollMs: Number = 1000, options: LiveViewOptions = {}) =>
  runLiveViewScoped(boardDir, pollMs, options) |> Effect.scoped

export runLiveViewAsync = (boardDir: String, pollMs: Number = 1000, options: LiveViewOptions = {}) =>
  Effect.runPromise(runLiveView(boardDir, pollMs, options))

export runLiveViewFun = (boardDir: String, pollMs: Number = 1000) =>
  runLiveView(boardDir, pollMs, {})
