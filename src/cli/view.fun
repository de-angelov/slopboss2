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

ObjSchema = Schema.declare(Predicate.isObject)
FnSchema = Schema.declare(Predicate.isFunction)
OptNumSchema = Schema.declare(Option.isOption)

safeInvoke = (target: Unknown, method: String, args: Array<Unknown>) =>
  res =
    Effect.try(() => {
      objOpt =
        Schema.decodeUnknownOption(ObjSchema)(target)
        |> Option.orElse(() => Schema.decodeUnknownOption(FnSchema)(target))
      fnOpt = Option.flatMap(objOpt, (obj) => Schema.decodeUnknownOption(FnSchema)(Reflect.get(obj, method)))
      _applied = Option.map(fnOpt, (f) => Reflect.apply(f, target, args))
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
  match laneIdRaw #! ""
    | true => laneIdRaw
    | false => name

resolveStatus = (status: String): String =>
  match status #= ""
    | true => "In Progress"
    | false => status

resolveBranch = (branch: String): Option<String> =>
  match branch #= ""
    | true => Option.none()
    | false => Option.some(branch)

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
            res =
              activeTask
              |> Option.filter((t: TaskBlock) => t.id #! "")
              |> Option.map((t: TaskBlock) => ["[TASK] " + laneId + " working on " + t.id + " (" + t.title + ")"])
              |> Option.getOrElse(() => [])
            => res
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
  match hasPrimary
    | true => primary
    | false => alt

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
  tokens <- match hasPrimary or hasAlt
    | false => Effect.succeed(fallbackTokenUsage)
    | true => effect {
      targetPath = resolveTargetPath(hasPrimary, tokenPath, altTokenPath)
      rawOpt <- fsService.readFileString(targetPath) |> option
      rawStr = Option.getOrElse(rawOpt, () => "")
      parsed =
        Option.some(rawStr)
        |> Option.filter((s) => s #! "")
        |> Option.flatMap(Schema.decodeUnknownOption(Schema.fromJsonString(TokenUsage)))
      => parsed |> Option.getOrElse(() => fallbackTokenUsage)
    }

  => tokens
}

readTokensSync = (boardDir: String): TokenUsage =>
  fallbackTokenUsage = {
    inputTokens: 0
    outputTokens: 0
    totalTokens: 0
  }
  res =
    readTokensWorkflow(boardDir)
    |> Effect.provide(BunServices.layer)
    |> Effect.catch((_) => Effect.succeed(fallbackTokenUsage))
    |> Effect.runSync
  => res

readRecentLogsWorkflow = (boardDir: String, initialLogs: Array<String>) => effect {
  fsService <- FileSystem.FileSystem
  pathService <- Path.Path
  logPath = pathService.join(boardDir, ".slopboss.log")
  hasLog <- fsService.exists(logPath)
  logs <- match hasLog
    | false => Effect.succeed(initialLogs)
    | true => effect {
      rawOpt <- fsService.readFileString(logPath) |> option
      raw = Option.getOrElse(rawOpt, () => "")
      recentLines =
        Option.some(raw)
        |> Option.filter((s) => s #! "")
        |> Option.map((s) =>
          s
          |> String.split("\n")
          |> Array.filter((l: String) => (l |> String.trim) #! "")
          |> Array.takeRight(10)
        )
        |> Option.getOrElse(() => [])
      => Array.appendAll(initialLogs, recentLines)
    }

  => logs
}

readRecentLogsSync = (boardDir: String, initialLogs: Array<String>): Array<String> =>
  logsFromFs =
    readRecentLogsWorkflow(boardDir, initialLogs)
    |> Effect.provide(BunServices.layer)
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

export extractOption = (opt: Unknown, fallback: Unknown): Unknown =>
  match
    | Option.isOption(opt) => Option.getOrElse(opt, () => fallback)
    | Predicate.isNotNullish(opt) => opt
    | _ => fallback

isPositiveNumber = (val: Unknown): Boolean =>
  num = Number.parse("" + val) |> Option.getOrElse(() => 0)
  match num > 0
    | true => true
    | false => false

export extractMaxTicks = (opt: Unknown): Number =>
  optNum = Schema.decodeUnknownOption(OptNumSchema)(opt)
  rawNum =
    match optNum
      | Some(innerOpt) => Number.parse("" + Option.getOrElse(innerOpt, () => 0))
      |> Option.getOrElse(() => 0)
      | None => Number.parse("" + opt) |> Option.getOrElse(() => 0)
  => match rawNum > 0
    | true => rawNum
    | false => Infinity

setupAbortSignal = (sigVal: Unknown, doneDeferred: Deferred.Deferred<Unknown>) =>
  sigObjOpt = Schema.decodeUnknownOption(ObjSchema)(sigVal)
  aborted =
    sigObjOpt
    |> Option.map((sigObj) => Boolean(Reflect.get(sigObj, "aborted")))
    |> Option.getOrElse(() => false)
  hasSig = Option.isSome(sigObjOpt)
  => match
    | not hasSig => true
    | aborted => Deferred.succeed(doneDeferred, true) |> Effect.runSync
    | _ =>
        abortListener = () =>
          Deferred.succeed(doneDeferred, true) |> Effect.runSync
          => true
        safeInvoke(sigVal, "addEventListener", ["abort", abortListener, { once: true }])
        => true

invokeOnTick = (onTickVal: Unknown, state: DashboardState, output: String) =>
  match Predicate.isFunction(onTickVal)
    | false => true
    | true =>
        safeInvoke(onTickVal, "call", [Option.none(), state, output])
        => true

checkMaxTicks = (cntNum: Number, maxTicks: Number, doneDeferred: Deferred.Deferred<Unknown>) =>
  match cntNum < maxTicks
    | true => false
    | false =>
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
    match isExitKey
      | true => Deferred.succeed(doneDeferred, true) |> Effect.runSync
      | false => Void
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
