import { Array, DateTime, Effect, FileSystem, Layer, Option, Path, Record, Schema, String } from "effect"
import * as fs from "node:fs"

export schema TaskBlock = {
  id: String
  title: String
  category: String
  owner: String
  branch: String
  status: String
  dependencies: Array<String>
  objective: String
  scope: String
  acceptanceCriteria: String
  rawBody: String
}

export schema MarkdownSection = {
  title: String
  name: String
  tasks: Array<TaskBlock>
  rawContent: String
}

export schema TasksDocument = {
  header: String
  lanes: Array<MarkdownSection>
  sections: Array<MarkdownSection>
}

export schema BoardStore = {
  boardDir: Option<String>
  tasksDoc: TasksDocument
  backlogContent: String
  archiveContent: String
  archiveDoc: TasksDocument
}

BunFileSystem = FileSystem.makeNoop({
  exists: (p: String) => Effect.try(() => fs.existsSync(p)) |> orDie,
  readFileString: (p: String) => Effect.try(() => fs.readFileSync(p, "utf-8")) |> orDie,
  writeFileString: (p: String, data: String) => Effect.try(() => fs.writeFileSync(p, data, "utf-8")) |> asVoid |> orDie,
  makeDirectory: (p: String) => Effect.try(() => fs.mkdirSync(p, { recursive: true })) |> asVoid |> orDie,
  rename: (oldP: String, newP: String) => Effect.try(() => fs.renameSync(oldP, newP)) |> asVoid |> orDie,
  remove: (p: String) => Effect.try(() => fs.rmSync(p, { recursive: true, force: true })) |> asVoid |> orDie
})

export BunServices = {
  layer: Layer.merge(Path.layer, Layer.succeed(FileSystem.FileSystem, BunFileSystem))
}

assignStore = (target: Any, source: Any) => {
  keys: Array<String> = Record.keys(source)
  _ = keys |> map((k) => {
    v: Unknown = Reflect.get(source, k)
    _ = Reflect.set(target, k, v)
    => true
  })
  => target
}

export atomicWriteFileEffect = (filePath: String, content: String) => effect {
  fsService <- FileSystem.FileSystem
  pathService <- Path.Path
  dir = pathService.dirname(filePath)
  base = pathService.basename(filePath)
  _ <- fsService.makeDirectory(dir)
  tempPath = pathService.join(dir, "." + base + ".tmp." + process.pid + "." + DateTime.toEpochMillis(DateTime.nowUnsafe()))
  _ <- fsService.writeFileString(tempPath, content)
  _ <- fsService.rename(tempPath, filePath)
  => true
}

export atomicWriteFile = (filePath: String, content: String) => atomicWriteFileEffect(filePath, content) |> provide(BunServices.layer)

export atomicWriteFileSync = (filePath: String, content: String) => {
  dir = filePath |> split("/") |> dropRight(1) |> join("/")
  dirSafe = match (dir #= "")
    | true => "."
    | false => dir
  fs.mkdirSync(dirSafe, { recursive: true })
  base = filePath |> split("/") |> last |> getOrElse(() => "file")
  tempPath = dirSafe + "/." + base + ".tmp." + process.pid + "." + DateTime.toEpochMillis(DateTime.nowUnsafe())
  fs.writeFileSync(tempPath, content, "utf-8")
  fs.renameSync(tempPath, filePath)
  => true
}

schema TaskBlockParseState = {
  title: String
  id: String
  category: String
  owner: String
  branch: String
  status: String
  dependencies: Array<String>
  objectiveLines: Array<String>
  scopeLines: Array<String>
  acceptanceLines: Array<String>
  currentSection: String
}

export parseTaskBlockText = (rawBlock: String): TaskBlock => {
  lines = rawBlock |> replaceAll("\r", "") |> split("\n")
  initialState: TaskBlockParseState = {
    title: "",
    id: "",
    category: "",
    owner: "",
    branch: "",
    status: "",
    dependencies: [],
    objectiveLines: [],
    scopeLines: [],
    acceptanceLines: [],
    currentSection: "none"
  }

  cleanRx = RegExp("^\\[|\\]$", "g")
  splitRx = RegExp("\\s+", "g")

  finalState = lines |> reduce(initialState, (state, line) => {
    trimmed = line |> trim
    lowerTrimmed = trimmed |> toLowerCase
    colonIndexOpt = trimmed |> indexOf(":")
    afterColon = match colonIndexOpt
      | Some(i) => trimmed |> substring(i + 1) |> trim
      | None => ""

    isOther = (lowerTrimmed |> startsWith("blocking tasks:")) or (lowerTrimmed |> startsWith("completed:")) or (lowerTrimmed |> startsWith("blocked by:")) or (lowerTrimmed |> startsWith("progress notes:")) or (lowerTrimmed |> startsWith("verification evidence:"))

    t = trimmed |> substring(3) |> trim
    deps = afterColon |> split(",") |> map((d: String) => d |> trim |> replace(cleanRx, "")) |> filter((d: String) => d #! "")
    linesValue = match (afterColon #= "")
      | true => []
      | false => [afterColon]
    normalizedDeps = match ((afterColon |> toLowerCase) #= "none" or afterColon #= "")
      | true => []
      | false => deps
    when (trimmed |> startsWith("###")) => { ...state, title: t }
    when (lowerTrimmed |> startsWith("task id:")) => { ...state, id: afterColon, currentSection: "none" }
    when (lowerTrimmed |> startsWith("category:")) => { ...state, category: afterColon, currentSection: "none" }
    when (lowerTrimmed |> startsWith("owner:")) => { ...state, owner: afterColon, currentSection: "none" }
    when (lowerTrimmed |> startsWith("branch:")) => { ...state, branch: afterColon, currentSection: "none" }
    when (lowerTrimmed |> startsWith("status:")) => { ...state, status: afterColon, currentSection: "none" }
    when (lowerTrimmed |> startsWith("dependencies:")) => { ...state, dependencies: normalizedDeps, currentSection: "none" }
    when (lowerTrimmed |> startsWith("objective:")) => { ...state, objectiveLines: linesValue, currentSection: "objective" }
    when (lowerTrimmed |> startsWith("scope:")) => { ...state, scopeLines: linesValue, currentSection: "scope" }
    when (lowerTrimmed |> startsWith("acceptance criteria:")) => { ...state, acceptanceLines: linesValue, currentSection: "acceptance" }
    when isOther => { ...state, currentSection: "other" }
    when (state.currentSection #= "objective") => { ...state, objectiveLines: state.objectiveLines |> Array.append(line) }
    when (state.currentSection #= "scope") => { ...state, scopeLines: state.scopeLines |> Array.append(line) }
    when (state.currentSection #= "acceptance") => { ...state, acceptanceLines: state.acceptanceLines |> Array.append(line) }
    => state
  })

  computedId = match (finalState.id #= "" and finalState.title #! "")
    | true => finalState.title |> String.replace(splitRx, "-") |> toUpperCase
    | false => finalState.id

  computedStatus = match (finalState.status #= "")
    | true => "Todo"
    | false => finalState.status

  => {
    id: computedId,
    title: finalState.title,
    category: finalState.category,
    owner: finalState.owner,
    branch: finalState.branch,
    status: computedStatus,
    dependencies: finalState.dependencies,
    objective: finalState.objectiveLines |> Array.join("\n") |> trim,
    scope: finalState.scopeLines |> Array.join("\n") |> trim,
    acceptanceCriteria: finalState.acceptanceLines |> Array.join("\n") |> trim,
    rawBody: rawBlock |> trim
  }
}

schema SectionParseState = {
  tasks: Array<TaskBlock>
  nonTaskLines: Array<String>
  currentTaskLines: Option<Array<String>>
}

parseSectionLines = (title: String, lines: Array<String>): MarkdownSection => {
  initialState: SectionParseState = {
    tasks: [],
    nonTaskLines: [],
    currentTaskLines: Option.none()
  }

  reduced = lines |> reduce(initialState, (state, line) => {
    trimmed = line |> trim
    currentLines = state.currentTaskLines |> Option.getOrElse(() => [])
    hasCurrentTask = Option.isSome(state.currentTaskLines)
    isTaskHeader = trimmed |> startsWith("### ")
    flushedTasks = state.tasks |> Array.appendAll(
      state.currentTaskLines |> Option.map((taskLines) => [parseTaskBlockText(taskLines |> Array.join("\n"))]) |> Option.getOrElse(() => [])
    )
    when (isTaskHeader) => { ...state, tasks: flushedTasks, currentTaskLines: Option.some([line]) }
    when (hasCurrentTask) => { ...state, currentTaskLines: Option.some(currentLines |> Array.append(line)) }
    => { ...state, nonTaskLines: state.nonTaskLines |> Array.append(line) }
  })

  allTasks = reduced.tasks |> Array.appendAll(
    reduced.currentTaskLines |> Option.map((tLines) => [parseTaskBlockText(tLines |> Array.join("\n"))]) |> Option.getOrElse(() => [])
  )

  rawContent = reduced.nonTaskLines |> Array.join("\n") |> trim

  => {
    title: title,
    name: title,
    tasks: allTasks,
    rawContent: rawContent
  }
}

schema DocParseState = {
  seenFirstSection: Boolean
  headerLines: Array<String>
  sections: Array<MarkdownSection>
  currentSectionTitle: String
  currentSectionLines: Array<String>
}

export parseTasksDocument = (content: String): TasksDocument => {
  lines = content |> replaceAll("\r", "") |> split("\n")
  initialState: DocParseState = {
    seenFirstSection: false,
    headerLines: [],
    sections: [],
    currentSectionTitle: "",
    currentSectionLines: []
  }

  reduced = lines |> reduce(initialState, (state, line) => {
    trimmed = line |> trim
    isSectionHeader = (trimmed |> startsWith("## ")) and not (trimmed |> startsWith("### "))
    secTitle = trimmed |> substring(2) |> trim
    flushedSec = parseSectionLines(state.currentSectionTitle, state.currentSectionLines)
    when (isSectionHeader and not state.seenFirstSection) => { ...state, seenFirstSection: true, currentSectionTitle: secTitle, currentSectionLines: [] }
    when isSectionHeader => { ...state, sections: state.sections |> Array.append(flushedSec), currentSectionTitle: secTitle, currentSectionLines: [] }
    when (not state.seenFirstSection) => { ...state, headerLines: state.headerLines |> Array.append(line) }
    => { ...state, currentSectionLines: state.currentSectionLines |> Array.append(line) }
  })

  lastSec = parseSectionLines(reduced.currentSectionTitle, reduced.currentSectionLines)
  allSections = match reduced.seenFirstSection
    | true => reduced.sections |> Array.append(lastSec)
    | false => reduced.sections

  header = reduced.headerLines |> Array.join("\n") |> trim

  => {
    header: header,
    lanes: allSections,
    sections: allSections
  }
}

export parseArchiveDocument = (content: String): TasksDocument => parseTasksDocument(content)

export parseBacklogTasks = (content: String): Array<TaskBlock> => {
  when (content #= "") => []
  lines = content |> replaceAll("\r", "") |> split("\n")

  initialState: SectionParseState = {
    tasks: [],
    nonTaskLines: [],
    currentTaskLines: Option.none()
  }

  reduced = lines |> reduce(initialState, (state, line) => {
    trimmed = line |> trim
    isTaskHeader = trimmed |> startsWith("### ")
    flushedTasks = state.tasks |> Array.appendAll(state.currentTaskLines |> Option.map((taskLines) => [parseTaskBlockText(taskLines |> Array.join("\n"))]) |> Option.getOrElse(() => []))
    currentLines = state.currentTaskLines |> Option.getOrElse(() => [])
    when isTaskHeader => { ...state, tasks: flushedTasks, currentTaskLines: Option.some([line]) }
    when (Option.isSome(state.currentTaskLines)) => { ...state, currentTaskLines: Option.some(currentLines |> Array.append(line)) }
    => state
  })

  allTasks = reduced.tasks |> Array.appendAll(reduced.currentTaskLines |> Option.map((taskLines) => [parseTaskBlockText(taskLines |> Array.join("\n"))]) |> Option.getOrElse(() => []))

  => allTasks
}

export formatTaskBlock = (task: TaskBlock): String => {
  trimmedRaw = task.rawBody |> trim
  statusRx = RegExp("(^|\\n)Status:\\s*[^\\n]+", "g")
  ownerRx = RegExp("(^|\\n)Owner:\\s*[^\\n]+", "g")
  branchRx = RegExp("(^|\\n)Branch:\\s*[^\\n]+", "g")

  b1 = trimmedRaw |> replace(statusRx, "$1Status: " + task.status)
  b2 = match (task.owner #! "") | true => b1 |> replace(ownerRx, "$1Owner: " + task.owner) | false => b1
  b3 = match (task.branch #! "") | true => b2 |> String.replace(branchRx, "$1Branch: " + task.branch) | false => b2
  depsStr = match (task.dependencies.length > 0) | true => task.dependencies |> join(", ") | false => "none"
  titleStr = match (task.title #! "") | true => task.title | false => task.id
  catStr = match (task.category #! "") | true => task.category | false => "Core Service"
  ownerStr = match (task.owner #! "") | true => task.owner | false => "Unassigned"
  branchStr = match (task.branch #! "") | true => task.branch | false => "main"
  statusStr = match (task.status #! "") | true => task.status | false => "Todo"
  baseParts = [
          "### " + titleStr,
          "",
          "Task ID: " + task.id,
          "Category: " + catStr,
          "Owner: " + ownerStr,
          "Branch: " + branchStr,
          "Status: " + statusStr,
          "Dependencies: " + depsStr,
          "Blocking tasks: none"
        ]

  p1 = match (task.objective #! "") | true => baseParts |> appendAll(["", "Objective:", task.objective]) | false => baseParts
  p2 = match (task.scope #! "") | true => p1 |> appendAll(["", "Scope:", task.scope]) | false => p1
  p3 = match (task.acceptanceCriteria #! "") | true => p2 |> appendAll(["", "Acceptance Criteria:", task.acceptanceCriteria]) | false => p2
  generated = p3 |> join("\n")
  => match (trimmedRaw #! "") | true => b3 | false => generated
}

formatSection = (section: MarkdownSection): String => {
  raw = section.rawContent |> trim
  emptyTasksPart = match (raw #! "") | true => raw + "\n" | false => "*Idle - Ready for next backlog assignment.*\n"
  tasksPart = match (section.tasks.length > 0)
    | true => (section.tasks |> map(formatTaskBlock) |> join("\n\n")) + "\n"
    | false => emptyTasksPart
  => "## " + section.title + "\n\n" + tasksPart
}

formatSectionsOnly = (sections: Array<MarkdownSection>, maybeHeader: Option<String>): String => {
  headerDefault = "# TASKS\n\nActive work board for slopboss2 rewrite."
  header = match maybeHeader
    | Some(h) => h
    | None => headerDefault
  sectionsPart = sections |> map(formatSection) |> join("\n")
  => (header |> trim) + "\n\n" + sectionsPart
}

formatDocumentOnly = (doc: TasksDocument): String => {
  headerDefault = "# TASKS\n\nActive work board for slopboss2 rewrite."
  header = match (Boolean(doc.header) and doc.header #! "")
    | true => doc.header
    | false => headerDefault
  sections = chooseDocumentSections(doc)
  sectionsPart = sections |> map(formatSection) |> join("\n")
  => (header |> trim) + "\n\n" + sectionsPart
}

export formatTasksDocument = (docOrSections: Any, maybeHeader?: String): String => {
  isArray = Array.isArray(docOrSections)
  res = match isArray
    | true => formatSectionsOnly(docOrSections, maybeHeader)
    | false => formatDocumentOnly(docOrSections)
  => res
}

export formatArchiveDocument = (doc: TasksDocument, summaryBullets?: String): String => {
  header = summaryBullets |> map((b: String) => b |> trim) |> filter((b: String) => b #! "") |> getOrElse(() => doc.header)
  => formatTasksDocument(doc, header)
}

chooseDocumentSections = (doc: TasksDocument): Array<MarkdownSection> => {
  when (Boolean(doc.sections)) => doc.sections
  when (Boolean(doc.lanes)) => doc.lanes
  => []
}

findTaskInTasksDocument = (doc: TasksDocument, taskId: String): Option.Option<TaskBlock> => doc.sections |> findFirst((sec: MarkdownSection) => sec.tasks |> Array.some((t: TaskBlock) => t.id #= taskId)) |> flatMap((sec: MarkdownSection) => sec.tasks |> findFirst((t: TaskBlock) => t.id #= taskId))

findTaskInBoardStore = (store: BoardStore, taskId: String): Option.Option<TaskBlock> => {
  inTasks = findTaskInTasksDocument(store.tasksDoc, taskId)
  inArchive = match Boolean(store.archiveDoc) | true => findTaskInTasksDocument(store.archiveDoc, taskId) | false => Option.none()
  backlogTasks = match (store.backlogContent #! "") | true => parseBacklogTasks(store.backlogContent) | false => []
  inBacklog = backlogTasks |> findFirst((t: TaskBlock) => t.id #= taskId)
  => inTasks |> orElse(() => inArchive) |> orElse(() => inBacklog)
}

export findTask = (store: Any, taskId: String): Option.Option<TaskBlock> => {
  isDoc = Record.has(store, "sections")
  res = match isDoc
    | true => findTaskInTasksDocument(store, taskId)
    | false => findTaskInBoardStore(store, taskId)
  => res
}

updateStatusInSections = (sections: Array<MarkdownSection>, taskId: String, newStatus: String): Array<MarkdownSection> => {
  statusRx = RegExp("(^|\\n)Status:\\s*[^\\n]+", "g")
  res = sections |> map((sec: MarkdownSection) => {
    updatedTasks = sec.tasks |> map((task: TaskBlock) => {
      hasRaw = task.rawBody #! ""
      isTarget = task.id #= taskId
      raw = match hasRaw
        | true => task.rawBody |> replace(statusRx, "$1Status: " + newStatus)
        | false => task.rawBody
      when isTarget => { ...task, status: newStatus, rawBody: raw }
      => task
    })
    => { ...sec, tasks: updatedTasks }
  })
  => res
}

addTaskToSections = (sections: Array<MarkdownSection>, targetTitle: String, task: TaskBlock, prepend: Boolean): Array<MarkdownSection> => {
  targetLower = targetTitle |> toLowerCase
  targetIndex = sections |> findFirstIndex((s: MarkdownSection) => (s.title |> toLowerCase) #= targetLower)

  updatedSections = match targetIndex
    | Some(idx) =>
        sections |> map((sec: MarkdownSection, i: Number) => {
          newTasks = match prepend
            | true => [task] |> appendAll(sec.tasks)
            | false => sec.tasks |> append(task)
          when (i #= idx) => { ...sec, tasks: newTasks, rawContent: "" }
          => sec
        })
    | None =>
        newSec: MarkdownSection = {
          title: targetTitle,
          name: targetTitle,
          tasks: [task],
          rawContent: ""
        }
        sections |> append(newSec)
  => updatedSections
}

schema RemoveResult = {
  updatedSections: Array<MarkdownSection>
  maybeTask: Option<TaskBlock>
}

removeTaskFromSections = (sections: Array<MarkdownSection>, taskId: String): RemoveResult => {
  foundTaskOpt = sections |> findFirst((sec: MarkdownSection) => sec.tasks |> Array.some((t: TaskBlock) => t.id #= taskId)) |> flatMap((sec: MarkdownSection) => sec.tasks |> findFirst((t: TaskBlock) => t.id #= taskId))

  updatedSections = match foundTaskOpt
    | Some(_) =>
        sections |> map((sec: MarkdownSection) => {
          filteredTasks = sec.tasks |> filter((t: TaskBlock) => t.id #! taskId)
          raw = match (sec.tasks.length > 0 and filteredTasks.length #= 0 and sec.rawContent #= "")
            | true => "*Idle - Ready for next backlog assignment.*"
            | false => sec.rawContent
          => { ...sec, tasks: filteredTasks, rawContent: raw }
        })
    | None => sections

  => { updatedSections: updatedSections, maybeTask: foundTaskOpt }
}

updateTaskStatusInBoardStore = (store: BoardStore, taskId: String, newStatus: String): BoardStore => {
  newSections = updateStatusInSections(store.tasksDoc.sections, taskId, newStatus)
  newDoc = { ...store.tasksDoc, sections: newSections, lanes: newSections }
  assignStore(store, { tasksDoc: newDoc })
  match Option.isSome(store.boardDir)
    | true => persistBoardStoreSync(store)
    | false => true
  => store
}

updateTaskStatusInTasksDocument = (doc: TasksDocument, taskId: String, newStatus: String): TasksDocument => {
  newSections = updateStatusInSections(doc.sections, taskId, newStatus)
  assignStore(doc, { sections: newSections, lanes: newSections })
  => doc
}

export updateTaskStatus = (store: Any, taskId: String, newStatus: String): Any => {
  isBoardStore = Record.has(store, "tasksDoc")
  res = match isBoardStore
    | true => updateTaskStatusInBoardStore(store, taskId, newStatus)
    | false => updateTaskStatusInTasksDocument(store, taskId, newStatus)
  => res
}

appendTaskInBoardStore = (store: BoardStore, targetSectionTitle: String, task: TaskBlock): BoardStore => {
  newSections = addTaskToSections(store.tasksDoc.sections, targetSectionTitle, task, false)
  newDoc = { ...store.tasksDoc, sections: newSections, lanes: newSections }
  assignStore(store, { tasksDoc: newDoc })
  match Option.isSome(store.boardDir)
    | true => persistBoardStoreSync(store)
    | false => true
  => store
}

appendTaskInTasksDocument = (doc: TasksDocument, targetSectionTitle: String, task: TaskBlock): TasksDocument => {
  newSections = addTaskToSections(doc.sections, targetSectionTitle, task, false)
  assignStore(doc, { sections: newSections, lanes: newSections })
  => doc
}

export appendTask = (store: Any, targetSectionTitle: String, task: TaskBlock): Any => {
  isBoardStore = Record.has(store, "tasksDoc")
  res = match isBoardStore
    | true => appendTaskInBoardStore(store, targetSectionTitle, task)
    | false => appendTaskInTasksDocument(store, targetSectionTitle, task)
  => res
}

export loadBoardStoreEffect = (boardDir: String) => effect {
  fsService <- FileSystem.FileSystem
  pathService <- Path.Path

  tasksPath = pathService.join(boardDir, "TASKS.md")
  backlogPath = pathService.join(boardDir, "BACKLOG.md")
  archivePath = pathService.join(boardDir, "ARCHIVE.md")

  tExists <- fsService.exists(tasksPath)
  tasksRaw <- match tExists
    | true => fsService.readFileString(tasksPath)
    | false => Effect.succeed("# TASKS\n")

  bExists <- fsService.exists(backlogPath)
  backlogRaw <- match bExists
    | true => fsService.readFileString(backlogPath)
    | false => Effect.succeed("# BACKLOG\n")

  aExists <- fsService.exists(archivePath)
  archiveRaw <- match aExists
    | true => fsService.readFileString(archivePath)
    | false => Effect.succeed("# ARCHIVE\n")

  tasksDoc = parseTasksDocument(tasksRaw)
  archiveDoc = parseTasksDocument(archiveRaw)

  store: BoardStore = {
    boardDir: Option.some(boardDir),
    tasksDoc: tasksDoc,
    backlogContent: backlogRaw,
    archiveContent: archiveRaw,
    archiveDoc: archiveDoc
  }
  => store
}

export loadBoardStore = (boardDir: String) => loadBoardStoreEffect(boardDir) |> provide(BunServices.layer)

export loadBoardStoreSync = (boardDir: String): BoardStore => {
  tasksPath = boardDir + "/TASKS.md"
  backlogPath = boardDir + "/BACKLOG.md"
  archivePath = boardDir + "/ARCHIVE.md"

  tasksRaw = match fs.existsSync(tasksPath)
    | true => fs.readFileSync(tasksPath, "utf-8")
    | false => "# TASKS\n"

  backlogRaw = match fs.existsSync(backlogPath)
    | true => fs.readFileSync(backlogPath, "utf-8")
    | false => "# BACKLOG\n"

  archiveRaw = match fs.existsSync(archivePath)
    | true => fs.readFileSync(archivePath, "utf-8")
    | false => "# ARCHIVE\n"

  tasksDoc = parseTasksDocument(tasksRaw)
  archiveDoc = parseTasksDocument(archiveRaw)

  => {
    boardDir: Option.some(boardDir),
    tasksDoc: tasksDoc,
    backlogContent: backlogRaw,
    archiveContent: archiveRaw,
    archiveDoc: archiveDoc
  }
}

export createBoardStore = (boardDir?: String): BoardStore => {
  res = match boardDir
    | Some(dir) => loadBoardStoreSync(dir)
    | None =>
        emptyDoc: TasksDocument = {
          header: "# TASKS\n\nActive work board for slopboss2 rewrite.",
          lanes: [],
          sections: []
        }
        emptyArchive: TasksDocument = {
          header: "# ARCHIVE\n\nCompleted tasks for slopboss2.",
          lanes: [],
          sections: []
        }
        {
          boardDir: Option.none(),
          tasksDoc: emptyDoc,
          backlogContent: "# BACKLOG\n",
          archiveContent: "# ARCHIVE\n",
          archiveDoc: emptyArchive
        }
  => res
}

export persistBoardStoreEffect = (store: BoardStore) => effect {
  pathService <- Path.Path

  dir = match store.boardDir
    | Some(d) => d
    | None => ""

  when (dir #= "") => true

  tasksPath = pathService.join(dir, "TASKS.md")
  archivePath = pathService.join(dir, "ARCHIVE.md")
  backlogPath = pathService.join(dir, "BACKLOG.md")

  _ <- atomicWriteFileEffect(tasksPath, formatTasksDocument(store.tasksDoc))
  _ <- atomicWriteFileEffect(archivePath, formatTasksDocument(store.archiveDoc, store.archiveContent))
  _ <- atomicWriteFileEffect(backlogPath, store.backlogContent)
  => true
}

export persistBoardStore = (store: BoardStore) => persistBoardStoreEffect(store) |> provide(BunServices.layer)

export persistBoardStoreSync = (store: BoardStore) => {
  dir = match store.boardDir
    | Some(d) => d
    | None => ""

  when (dir #= "") => true

  tasksPath = dir + "/TASKS.md"
  archivePath = dir + "/ARCHIVE.md"
  backlogPath = dir + "/BACKLOG.md"

  atomicWriteFileSync(tasksPath, formatTasksDocument(store.tasksDoc))
  atomicWriteFileSync(archivePath, formatTasksDocument(store.archiveDoc, store.archiveContent))
  atomicWriteFileSync(backlogPath, store.backlogContent)
  => true
}

moveTaskInTasksDocument = (doc: TasksDocument, taskId: String, targetSectionTitle: String): TasksDocument => {
  r = removeTaskFromSections(doc.sections, taskId)
  when (Option.isNone(r.maybeTask)) => doc

  emptyBlock = { id: "", title: "", category: "", owner: "", branch: "", status: "", dependencies: [], objective: "", scope: "", acceptanceCriteria: "", rawBody: "" }
  foundTask = r.maybeTask |> Option.getOrElse(() => emptyBlock)
  lowerTarget = targetSectionTitle |> toLowerCase
  isArchive = (lowerTarget |> includes("archive")) or (lowerTarget |> includes("done"))

  statusRx = RegExp("(^|\\n)Status:\\s*[^\\n]+", "g")
  statusDoneRx = RegExp("(^|\\n)Status:\\s*Done", "i")
  ownerRx = RegExp("(^|\\n)Owner:\\s*[^\\n]+", "g")
  today = DateTime.formatIsoDateUtc(DateTime.nowUnsafe())
  rawDone = foundTask.rawBody |> String.replace(statusRx, "$1Status: Done")
  doneNeedsDate = (rawDone #! "") and not (rawDone |> includes("Completed:"))
  rawDoneFinal = match doneNeedsDate
    | true => rawDone |> String.replace(statusDoneRx, "$1Status: Done\nCompleted: " + today)
    | false => rawDone
  owner1 = lowerTarget |> includes("dev agent 1")
  owner2 = lowerTarget |> includes("dev agent 2")
  targetIsAgent = owner1 or owner2
  targetIsBacklog = lowerTarget |> includes("backlog")
  owner1Value = match owner1 | true => Option.some("Dev Agent 1") | false => Option.none()
  owner2Value = match owner2 | true => Option.some("Dev Agent 2") | false => Option.none()
  newOwner = owner1Value |> orElse(() => owner2Value) |> getOrElse(() => foundTask.owner)
  agentStatus = match targetIsAgent | true => Option.some("In Progress") | false => Option.none()
  backlogStatus = match targetIsBacklog | true => Option.some("Backlog") | false => Option.none()
  newStatus = agentStatus |> orElse(() => backlogStatus) |> getOrElse(() => foundTask.status)
  rawUpdated = foundTask.rawBody |> String.replace(statusRx, "$1Status: " + newStatus)
  rawUpdatedOwner = match ((rawUpdated #! "") and (newOwner #! ""))
    | true => rawUpdated |> String.replace(ownerRx, "$1Owner: " + newOwner)
    | _ => rawUpdated
  finalTask = match isArchive
    | true => { ...foundTask, status: "Done", rawBody: rawDoneFinal }
    | false => { ...foundTask, owner: newOwner, status: newStatus, rawBody: rawUpdatedOwner }

  newSections = addTaskToSections(r.updatedSections, targetSectionTitle, finalTask, false)
  assignStore(doc, { sections: newSections, lanes: newSections })
  => doc
}

moveTaskInBoardStore = (store: BoardStore, taskId: String, targetSectionTitle: String): BoardStore => {
  emptyBlock = { id: "", title: "", category: "", owner: "", branch: "", status: "", dependencies: [], objective: "", scope: "", acceptanceCriteria: "", rawBody: "" }
  r1 = removeTaskFromSections(store.tasksDoc.sections, taskId)

  r2 = removeTaskFromSections(store.archiveDoc.sections, taskId)
  bTasks = parseBacklogTasks(store.backlogContent)
  foundBacklog = bTasks |> findFirst((t: TaskBlock) => t.id #= taskId)
  maybeTask = r1.maybeTask |> orElse(() => r2.maybeTask) |> orElse(() => foundBacklog)
  useTasks = Option.isSome(r1.maybeTask)
  useArchive = not useTasks and Option.isSome(r2.maybeTask)
  taskFromTasks = r1.maybeTask |> getOrElse(() => emptyBlock)
  taskFromArchive = r2.maybeTask |> getOrElse(() => emptyBlock)
  taskFromBacklog = foundBacklog |> getOrElse(() => emptyBlock)
  newTasksDoc = { ...store.tasksDoc, sections: r1.updatedSections, lanes: r1.updatedSections }
  newArchiveDoc = { ...store.archiveDoc, sections: r2.updatedSections, lanes: r2.updatedSections }
  hasBacklog = Option.isSome(foundBacklog)
  newBacklog = (store.backlogContent |> replace(taskFromBacklog.rawBody, "") |> trim) + "\n"
  fromTasks = match useTasks
    | true => Option.some({ store: { ...store, tasksDoc: newTasksDoc }, task: Option.some(taskFromTasks) })
    | false => Option.none()
  fromArchive = match useArchive
    | true => Option.some({ store: { ...store, archiveDoc: newArchiveDoc }, task: Option.some(taskFromArchive) })
    | false => Option.none()
  fromBacklog = match hasBacklog
    | true => Option.some({ store: { ...store, backlogContent: newBacklog }, task: Option.some(taskFromBacklog) })
    | false => Option.none()
  unchanged = { store: store, task: maybeTask }
  taskAndStore = fromTasks |> orElse(() => fromArchive) |> orElse(() => fromBacklog) |> getOrElse(() => unchanged)

  when (Option.isNone(taskAndStore.task)) => store

  foundTask = taskAndStore.task |> Option.getOrElse(() => emptyBlock)
  curStore = taskAndStore.store
  lowerTarget = targetSectionTitle |> toLowerCase
  isArchive = (lowerTarget |> includes("archive")) or (lowerTarget |> includes("done"))

  statusRx = RegExp("(^|\\n)Status:\\s*[^\\n]+", "g")
  statusDoneRx = RegExp("(^|\\n)Status:\\s*Done", "i")
  ownerRx = RegExp("(^|\\n)Owner:\\s*[^\\n]+", "g")
  today = DateTime.formatIsoDateUtc(DateTime.nowUnsafe())
  rawDone = foundTask.rawBody |> String.replace(statusRx, "$1Status: Done")
  doneNeedsDate = (rawDone #! "") and not (rawDone |> includes("Completed:"))
  rawDoneFinal = match doneNeedsDate
    | true => rawDone |> String.replace(statusDoneRx, "$1Status: Done\nCompleted: " + today)
    | false => rawDone
  owner1 = lowerTarget |> includes("dev agent 1")
  owner2 = lowerTarget |> includes("dev agent 2")
  targetIsAgent = owner1 or owner2
  targetIsBacklog = lowerTarget |> includes("backlog")
  owner1Value = match owner1 | true => Option.some("Dev Agent 1") | false => Option.none()
  owner2Value = match owner2 | true => Option.some("Dev Agent 2") | false => Option.none()
  newOwner = owner1Value |> orElse(() => owner2Value) |> getOrElse(() => foundTask.owner)
  agentStatus = match targetIsAgent | true => Option.some("In Progress") | false => Option.none()
  backlogStatus = match targetIsBacklog | true => Option.some("Backlog") | false => Option.none()
  newStatus = agentStatus |> orElse(() => backlogStatus) |> getOrElse(() => foundTask.status)
  rawUpdated = foundTask.rawBody |> String.replace(statusRx, "$1Status: " + newStatus)
  rawUpdatedOwner = match ((rawUpdated #! "") and (newOwner #! ""))
    | true => rawUpdated |> String.replace(ownerRx, "$1Owner: " + newOwner)
    | _ => rawUpdated
  archiveTask = { ...foundTask, status: "Done", rawBody: rawDoneFinal }
  archiveSections = addTaskToSections(curStore.archiveDoc.sections, "Done", archiveTask, true)
  archiveDoc = { ...curStore.archiveDoc, sections: archiveSections, lanes: archiveSections }
  bulletPattern = "- [x] " + archiveTask.id + ":"
  hasBullet = curStore.archiveContent |> includes(bulletPattern)
  bullet = "- [x] " + archiveTask.id + ": " + archiveTask.title + "\n"
  archiveRx = RegExp("(# ARCHIVE[^\\n]*\\n\\n[^\\n]*\\n\\n)")
  archiveContent = match hasBullet
    | true => curStore.archiveContent
    | false => curStore.archiveContent |> String.replace(archiveRx, "$1" + bullet)
  archiveStore = { ...curStore, archiveDoc: archiveDoc, archiveContent: archiveContent }
  regularTask = { ...foundTask, owner: newOwner, status: newStatus, rawBody: rawUpdatedOwner }
  taskSections = addTaskToSections(curStore.tasksDoc.sections, targetSectionTitle, regularTask, false)
  tasksDoc = { ...curStore.tasksDoc, sections: taskSections, lanes: taskSections }
  tasksStore = { ...curStore, tasksDoc: tasksDoc }
  finalStore = match isArchive
    | true => archiveStore
    | false => tasksStore
  assignStore(store, finalStore)
  persistResult = match Option.isSome(curStore.boardDir)
    | true => persistBoardStoreSync(store)
    | false => true

  => store
}

export moveTask = (store: Any, taskId: String, targetSectionTitle: String): Any => {
  isBoardStore = Record.has(store, "tasksDoc")
  res = match isBoardStore
    | true => moveTaskInBoardStore(store, taskId, targetSectionTitle)
    | false => moveTaskInTasksDocument(store, taskId, targetSectionTitle)
  => res
}

export archiveTask = (store: Any, taskId: String): Any => moveTask(store, taskId, "Done")
