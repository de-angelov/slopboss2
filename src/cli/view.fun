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

safeInvoke = (target: Unknown, method: String, args: Array<Unknown>) =>
  res =
    Effect.try(() => {
      obj: Any = target
      fnObj: Any = Reflect.get(obj, method)
      when (not Predicate.isFunction(fnObj)) => true
      Reflect.apply(fnObj, target, args)
      => true
    })
    |> Effect.catch((_) => Effect.succeed(false))
    |> Effect.runSync
  => res

resolveLaneId = (name: String): String =>
  laneIdRaw =
    name
    |> replace(RegExp("\\s+In Progress$", "i"), "")
    |> trim
  when (laneIdRaw #! "") => laneIdRaw
  => name

resolveStatus = (status: String): String =>
  when (status #= "") => "In Progress"
  => status

resolveBranch = (branch: String): Option<String> =>
  when (branch #= "") => Option.none()
  => Option.some(branch)

readLanesAndStoreLogs = (boardDir: String) =>
  storeRes =
    Effect.try(() => loadBoardStoreSync(boardDir))
    |> option
    |> Effect.runSync
  match storeRes
    | None => { lanes: [], logs: [] }
    | Some(store) =>
        sections = store.tasksDoc.sections

        laneLogs =
          sections
          |> Array.flatMap((sec: MarkdownSection) => {
            laneId = resolveLaneId(sec.name)
            tasks = sec.tasks
            activeTaskOpt =
              tasks
              |> Array.findFirst((t: TaskBlock) => t.status #= "In Progress")
            activeTask = activeTaskOpt |> orElse(() => tasks |> Array.head)
            match activeTask
              | None => []
              | Some(t) =>
                  when (t.id #= "") => []
                  => ["[TASK] " + laneId + " working on " + t.id + " (" + t.title + ")"]
          })

        lanes =
          sections
          |> Array.map((sec: MarkdownSection) => {
            laneId = resolveLaneId(sec.name)
            tasks = sec.tasks
            activeTaskOpt =
              tasks
              |> Array.findFirst((t: TaskBlock) => t.status #= "In Progress")
            activeTask = activeTaskOpt |> orElse(() => tasks |> Array.head)
            match activeTask
              | None => {
                id: laneId
                status: "Idle"
                task: Option.none()
                branch: Option.none()
              }
              | Some(t) => {
                id: laneId
                status: resolveStatus(t.status)
                task: Option.some(t.id)
                branch: resolveBranch(t.branch)
              }
          })

        => { lanes: lanes, logs: laneLogs }

resolveTargetPath = (hasPrimary: Boolean, primary: String, alt: String): String =>
  when (hasPrimary) => primary
  => alt

readTokensWorkflow = (boardDir: String) => effect {
  fallbackTokenUsage = {
    inputTokens: 0
    outputTokens: 0
    totalTokens: 0
  }
  fsService <- FileSystem.FileSystem
  pathService <- Path.Path
  tokenPath = pathService.join(boardDir, ".tokens.json")
  altTokenPath = pathService.join(boardDir, "tokens.json")

  hasPrimary <- fsService.exists(tokenPath)
  hasAlt <- fsService.exists(altTokenPath)
  when (not hasPrimary and not hasAlt) => fallbackTokenUsage

  targetPath = resolveTargetPath(hasPrimary, tokenPath, altTokenPath)
  rawOpt <- fsService.readFileString(targetPath) |> option
  rawStr = Option.getOrElse(rawOpt, () => "")
  when (rawStr #= "") => fallbackTokenUsage

  parsed = Schema.decodeUnknownOption(Schema.fromJsonString(TokenUsage))(rawStr)
  => parsed |> getOrElse(() => fallbackTokenUsage)
}

readTokensSync = (boardDir: String): TokenUsage =>
  fallbackTokenUsage = {
    inputTokens: 0
    outputTokens: 0
    totalTokens: 0
  }
  res =
    readTokensWorkflow(boardDir)
    |> provide(BunServices.layer)
    |> Effect.catch((_) => Effect.succeed(fallbackTokenUsage))
    |> Effect.runSync
  => res

readRecentLogsWorkflow = (boardDir: String, initialLogs: Array<String>) => effect {
  fsService <- FileSystem.FileSystem
  pathService <- Path.Path
  logPath = pathService.join(boardDir, ".slopboss.log")
  hasLog <- fsService.exists(logPath)
  when (not hasLog) => initialLogs

  rawOpt <- fsService.readFileString(logPath) |> option
  raw = Option.getOrElse(rawOpt, () => "")
  when (raw #= "") => initialLogs

  lines =
    raw
    |> split("\n")
    |> filter((l: String) => (l |> trim) #! "")
  recentLines = lines |> takeRight(10)
  => Array.appendAll(initialLogs, recentLines)
}

readRecentLogsSync = (boardDir: String, initialLogs: Array<String>): Array<String> =>
  logsFromFs =
    readRecentLogsWorkflow(boardDir, initialLogs)
    |> provide(BunServices.layer)
    |> Effect.catch((_) => Effect.succeed(initialLogs))
    |> Effect.runSync
  => logsFromFs

resolveLanes = (lanes: Array<AgentLane>): Array<AgentLane> =>
  lanes

export readDashboardState = (boardDir: String): DashboardState =>
  boardData = readLanesAndStoreLogs(boardDir)
  lanes = resolveLanes(boardData.lanes)
  tokens = readTokensSync(boardDir)
  recentLogs = readRecentLogsSync(boardDir, boardData.logs)

  => {
    boardDir: boardDir
    lanes: lanes
    tokens: tokens
    recentLogs: recentLogs
  }

export extractOption = (opt: Any, fallback: Unknown): Unknown =>
  when (Option.isOption(opt)) => Option.getOrElse(opt, () => fallback)
  when (Predicate.isNotNullish(opt)) => opt
  => fallback

isPositiveNumber = (val: Unknown): Boolean =>
  num = Number.parse("" + val) |> Option.getOrElse(() => 0)
  when (num > 0) => true
  => false

extractFromOption = (opt: Any): Number =>
  raw = Option.getOrElse(opt, () => 0)
  num = Number.parse("" + raw) |> Option.getOrElse(() => 0)
  when (num > 0) => num
  => Infinity

export extractMaxTicks = (opt: Any): Number =>
  when (Option.isOption(opt)) => extractFromOption(opt)
  when (Predicate.isNotNullish(opt) and isPositiveNumber(opt)) => Number.parse("" + opt) |> getOrElse(() => Infinity)
  => Infinity

setupAbortSignal = (sigVal: Unknown, doneDeferred: Any) =>
  when (not Predicate.isNotNullish(sigVal)) => true
  sigObj: Any = sigVal
  abortedVal: Any = Reflect.get(sigObj, "aborted")
  aborted = Boolean(abortedVal)
  when (aborted) => Deferred.succeed(doneDeferred, true) |> Effect.runSync
  abortListener = () =>
    Deferred.succeed(doneDeferred, true) |> Effect.runSync
    => true
  safeInvoke(sigVal, "addEventListener", ["abort", abortListener, { once: true }])
  => true

invokeOnTick = (onTickVal: Unknown, state: DashboardState, output: String) =>
  when (not Predicate.isFunction(onTickVal)) => true
  safeInvoke(onTickVal, "call", [Option.none(), state, output])
  => true

checkMaxTicks = (cntNum: Number, maxTicks: Number, doneDeferred: Any) =>
  when (cntNum < maxTicks) => false
  Deferred.succeed(doneDeferred, true) |> Effect.runSync
  => true

runLiveViewScoped = (boardDir: String, pollMs: Number, options: LiveViewOptions) => effect (unscoped) {
  stdin = extractOption(options.stdin, process.stdin)
  stdout = extractOption(options.stdout, process.stdout)
  maxTicks = extractMaxTicks(options.maxTicks)

  intervalMs = Math.max(pollMs, 10)

  doneDeferred <- Deferred.make()
  tickCountRef <- Ref.make(0)

  onSigint = () =>
    Deferred.succeed(doneDeferred, true) |> Effect.runSync
    => true
  ctrlC = Buffer.from([3]).toString()
  onData = (chunk: Unknown) =>
    str = "" + chunk
    isExitKey = str #= "q" or str #= "Q" or str #= ctrlC
    when (isExitKey) => Deferred.succeed(doneDeferred, true) |> Effect.runSync
    => true
  _f <- Effect.addFinalizer(() => Effect.sync(() => {
    _1 = safeInvoke(stdin, "setRawMode", [false])
    _2 = safeInvoke(stdin, "pause", [])
    _3 = safeInvoke(stdin, "removeListener", ["data", onData])
    _4 = safeInvoke(process, "removeListener", ["SIGINT", onSigint])
    _5 = safeInvoke(stdout, "write", ["\\u001b[?25h\nLive view closed.\n"])
    => true
  }))

  _s1 = safeInvoke(process, "on", ["SIGINT", onSigint])
  _s2 = safeInvoke(stdin, "setRawMode", [true])
  _s3 = safeInvoke(stdin, "resume", [])
  _s4 = safeInvoke(stdin, "setEncoding", ["utf8"])
  _s5 = safeInvoke(stdin, "on", ["data", onData])

  sigVal = extractOption(options.signal, Option.none())
  _sig = setupAbortSignal(sigVal, doneDeferred)

  tick =
    effect {
      cnt <- Ref.updateAndGet(tickCountRef, (n: Number) => n + 1)
      cntNum = cnt
      state = readDashboardState(boardDir)
      output = renderFullDashboard(state)
      _w = safeInvoke(stdout, "write", [output])
      onTickVal = extractOption(options.onTick, Option.none())
      _t = invokeOnTick(onTickVal, state, output)
      _chk = checkMaxTicks(cntNum, maxTicks, doneDeferred)
      => true
    }

  tickLoop =
    effect {
      _tk <- tick
      _sl <- Effect.sleep(Duration.millis(intervalMs))
      => true
    }
    |> repeat(Schedule.forever)

  _fk <- Effect.forkScoped(tickLoop)

  res <- Deferred.await(doneDeferred)
  => res
}

export defaultLiveViewOptions: LiveViewOptions = {
  stdin: Option.none()
  stdout: Option.none()
  maxTicks: Option.none()
  signal: Option.none()
  onTick: Option.none()
}

export runLiveView = (boardDir: String, pollMs: Number = 1000, options: LiveViewOptions = defaultLiveViewOptions) =>
  runLiveViewScoped(boardDir, pollMs, options) |> scoped

export runLiveViewAsync = (boardDir: String, pollMs: Number = 1000, options: LiveViewOptions = defaultLiveViewOptions) =>
  Effect.runPromise(runLiveView(boardDir, pollMs, options))

export runLiveViewFun = (boardDir: String, pollMs: Number = 1000) =>
  runLiveView(boardDir, pollMs, defaultLiveViewOptions)

export main = () => runLiveViewFun(".")
