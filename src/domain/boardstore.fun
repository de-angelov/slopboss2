import { Array, Option, Schema, String, Effect } from "effect"

ts {
  import * as fs from "node:fs";
  import * as path from "node:path";
  import { Option, Effect } from "effect";

  export interface TaskBlock {
    id: string;
    title: string;
    category: string;
    owner: string;
    branch: string;
    status: string;
    dependencies: string[];
    objective: string;
    scope: string;
    acceptanceCriteria: string;
    rawBody: string;
  }

  export interface MarkdownSection {
    title: string;
    name: string;
    tasks: TaskBlock[];
    rawContent: string;
  }

  export interface TasksDocument {
    header: string;
    lanes: MarkdownSection[];
    sections: MarkdownSection[];
  }

  export interface BoardStore {
    boardDir: Option.Option<string>;
    tasksDoc: TasksDocument;
    backlogContent: string;
    archiveContent: string;
    archiveDoc: TasksDocument;
  }

  export function atomicWriteFileSync(filePath: string, content: string): void {
    const dir = path.dirname(filePath);
    fs.mkdirSync(dir, { recursive: true });
    const tempPath = path.join(
      dir,
      `.${path.basename(filePath)}.tmp.${Date.now()}.${Math.random().toString(36).slice(2)}`
    );
    fs.writeFileSync(tempPath, content, "utf-8");
    fs.renameSync(tempPath, filePath);
  }

  export function parseTaskBlockText(rawBlock: string): TaskBlock {
    const lines = rawBlock.split(/\r?\n/);
    let title = "";
    let id = "";
    let category = "";
    let owner = "";
    let branch = "";
    let status = "";
    let dependencies: string[] = [];

    const objectiveLines: string[] = [];
    const scopeLines: string[] = [];
    const acceptanceLines: string[] = [];

    let currentSection: "none" | "objective" | "scope" | "acceptance" | "other" = "none";

    for (let i = 0; i < lines.length; i++) {
      const line = lines[i];
      const trimmed = line.trim();

      if (i === 0 && trimmed.startsWith("###")) {
        title = trimmed.replace(/^###\s*/, "").trim();
        continue;
      }

      if (/^Task ID:\s*/i.test(trimmed)) {
        id = trimmed.replace(/^Task ID:\s*/i, "").trim();
        currentSection = "none";
        continue;
      }
      if (/^Category:\s*/i.test(trimmed)) {
        category = trimmed.replace(/^Category:\s*/i, "").trim();
        currentSection = "none";
        continue;
      }
      if (/^Owner:\s*/i.test(trimmed)) {
        owner = trimmed.replace(/^Owner:\s*/i, "").trim();
        currentSection = "none";
        continue;
      }
      if (/^Branch:\s*/i.test(trimmed)) {
        branch = trimmed.replace(/^Branch:\s*/i, "").trim();
        currentSection = "none";
        continue;
      }
      if (/^Status:\s*/i.test(trimmed)) {
        status = trimmed.replace(/^Status:\s*/i, "").trim();
        currentSection = "none";
        continue;
      }
      if (/^Dependencies:\s*/i.test(trimmed)) {
        const rawDeps = trimmed.replace(/^Dependencies:\s*/i, "").trim();
        if (rawDeps.toLowerCase() === "none" || rawDeps === "") {
          dependencies = [];
        } else {
          dependencies = rawDeps
            .split(",")
            .map((d) => d.trim().replace(/^\[|\]$/g, ""))
            .filter(Boolean);
        }
        currentSection = "none";
        continue;
      }

      if (/^Objective:\s*/i.test(trimmed)) {
        currentSection = "objective";
        const after = trimmed.replace(/^Objective:\s*/i, "").trim();
        if (after) objectiveLines.push(after);
        continue;
      }
      if (/^Scope:\s*/i.test(trimmed)) {
        currentSection = "scope";
        const after = trimmed.replace(/^Scope:\s*/i, "").trim();
        if (after) scopeLines.push(after);
        continue;
      }
      if (/^Acceptance Criteria:\s*/i.test(trimmed)) {
        currentSection = "acceptance";
        const after = trimmed.replace(/^Acceptance Criteria:\s*/i, "").trim();
        if (after) acceptanceLines.push(after);
        continue;
      }

      if (
        /^Blocking tasks:\s*/i.test(trimmed) ||
        /^Completed:\s*/i.test(trimmed) ||
        /^Blocked by:\s*/i.test(trimmed) ||
        /^Progress Notes:\s*/i.test(trimmed) ||
        /^Verification Evidence:\s*/i.test(trimmed)
      ) {
        currentSection = "other";
        continue;
      }

      if (currentSection === "objective") {
        objectiveLines.push(line);
      } else if (currentSection === "scope") {
        scopeLines.push(line);
      } else if (currentSection === "acceptance") {
        acceptanceLines.push(line);
      }
    }

    if (!id && title) {
      id = title.replace(/\s+/g, "-").toUpperCase();
    }

    return {
      id,
      title,
      category,
      owner,
      branch,
      status: status || "Todo",
      dependencies,
      objective: objectiveLines.join("\n").trim(),
      scope: scopeLines.join("\n").trim(),
      acceptanceCriteria: acceptanceLines.join("\n").trim(),
      rawBody: rawBlock.trim(),
    };
  }

  export function parseTasksDocument(content: string): TasksDocument {
    const lines = content.split(/\r?\n/);
    const sections: MarkdownSection[] = [];
    const headerLines: string[] = [];

    let currentSectionTitle: string | null = null;
    let currentSectionLines: string[] = [];

    const flushSection = () => {
      if (currentSectionTitle === null) return;
      const tasks: TaskBlock[] = [];
      const nonTaskLines: string[] = [];

      let currentTaskLines: string[] | null = null;

      for (const line of currentSectionLines) {
        if (/^###\s+/.test(line.trim())) {
          if (currentTaskLines !== null) {
            tasks.push(parseTaskBlockText(currentTaskLines.join("\n")));
          }
          currentTaskLines = [line];
        } else if (currentTaskLines !== null) {
          currentTaskLines.push(line);
        } else {
          nonTaskLines.push(line);
        }
      }

      if (currentTaskLines !== null) {
        tasks.push(parseTaskBlockText(currentTaskLines.join("\n")));
      }

      const rawContent = nonTaskLines.join("\n").trim();
      const sec: MarkdownSection = {
        title: currentSectionTitle,
        name: currentSectionTitle,
        tasks,
        rawContent,
      };
      sections.push(sec);
    };

    let seenFirstSection = false;
    for (let i = 0; i < lines.length; i++) {
      const line = lines[i];
      const trimmed = line.trim();

      if (trimmed.startsWith("## ") && !trimmed.startsWith("### ")) {
        if (!seenFirstSection) {
          seenFirstSection = true;
        } else {
          flushSection();
        }
        currentSectionTitle = trimmed.replace(/^##\s+/, "").trim();
        currentSectionLines = [];
      } else {
        if (!seenFirstSection) {
          headerLines.push(line);
        } else {
          currentSectionLines.push(line);
        }
      }
    }

    if (seenFirstSection) {
      flushSection();
    }

    const header = headerLines.join("\n").trim();
    return {
      header,
      lanes: sections,
      sections,
    };
  }

  export function formatTaskBlock(task: TaskBlock): string {
    if (task.rawBody && task.rawBody.trim()) {
      let body = task.rawBody.trim();
      body = body.replace(/(^|\n)Status:\s*[^\n]+/g, `$1Status: ${task.status}`);
      if (task.owner) {
        body = body.replace(/(^|\n)Owner:\s*[^\n]+/g, `$1Owner: ${task.owner}`);
      }
      if (task.branch) {
        body = body.replace(/(^|\n)Branch:\s*[^\n]+/g, `$1Branch: ${task.branch}`);
      }
      return body;
    }

    const depsStr =
      task.dependencies && task.dependencies.length > 0
        ? task.dependencies.join(", ")
        : "none";

    const parts: string[] = [
      `### ${task.title || task.id}`,
      "",
      `Task ID: ${task.id}`,
      `Category: ${task.category || "Core Service"}`,
      `Owner: ${task.owner || "Unassigned"}`,
      `Branch: ${task.branch || "main"}`,
      `Status: ${task.status || "Todo"}`,
      `Dependencies: ${depsStr}`,
      `Blocking tasks: none`,
    ];

    if (task.objective) {
      parts.push("", "Objective:", task.objective);
    }
    if (task.scope) {
      parts.push("", "Scope:", task.scope);
    }
    if (task.acceptanceCriteria) {
      parts.push("", "Acceptance Criteria:", task.acceptanceCriteria);
    }

    return parts.join("\n");
  }

  export function formatTasksDocument(
    docOrSections: TasksDocument | MarkdownSection[],
    maybeHeader?: string
  ): string {
    let header = "# TASKS\n\nActive work board for slopboss2 rewrite.";
    let sections: MarkdownSection[] = [];

    if (Array.isArray(docOrSections)) {
      sections = docOrSections;
      if (typeof maybeHeader === "string") header = maybeHeader;
    } else if (docOrSections && typeof docOrSections === "object") {
      if (docOrSections.header) header = docOrSections.header;
      sections = docOrSections.sections || (docOrSections as any).lanes || [];
    }

    let out = header.trim() + "\n\n";

    for (let i = 0; i < sections.length; i++) {
      const section = sections[i];
      out += `## ${section.title}\n\n`;

      if (section.tasks && section.tasks.length > 0) {
        const taskStrs = section.tasks.map((task) => formatTaskBlock(task));
        out += taskStrs.join("\n\n") + "\n";
      } else {
        const raw =
          section.rawContent && section.rawContent.trim()
            ? section.rawContent.trim()
            : "*Idle - Ready for next backlog assignment.*";
        out += raw + "\n";
      }

      if (i < sections.length - 1) {
        out += "\n";
      }
    }

    return out;
  }

  export function parseArchiveDocument(content: string): TasksDocument {
    return parseTasksDocument(content);
  }

  export function formatArchiveDocument(doc: TasksDocument, summaryBullets?: string): string {
    let header = doc.header || "# ARCHIVE\n\nCompleted tasks for slopboss2.";
    if (summaryBullets && summaryBullets.trim()) {
      header = summaryBullets.trim();
    }
    return formatTasksDocument(doc, header);
  }

  export function findTask(store: TasksDocument | BoardStore, taskId: string): Option.Option<TaskBlock> {
    const sections: MarkdownSection[] =
      "sections" in store && Array.isArray(store.sections)
        ? store.sections
        : (store as BoardStore).tasksDoc?.sections || [];

    for (const sec of sections) {
      const found = sec.tasks.find((t) => t.id === taskId);
      if (found) return Option.some(found);
    }

    if ("archiveDoc" in store && (store as BoardStore).archiveDoc?.sections) {
      for (const sec of (store as BoardStore).archiveDoc.sections) {
        const found = sec.tasks.find((t) => t.id === taskId);
        if (found) return Option.some(found);
      }
    }

    return Option.none();
  }

  export function updateTaskStatus<T extends TasksDocument | BoardStore>(
    store: T,
    taskId: string,
    newStatus: string
  ): T {
    const tasksDoc: TasksDocument =
      "sections" in store && Array.isArray(store.sections)
        ? store
        : (store as any).tasksDoc;

    if (tasksDoc && tasksDoc.sections) {
      for (const sec of tasksDoc.sections) {
        const t = sec.tasks.find((task) => task.id === taskId);
        if (t) {
          t.status = newStatus;
          if (t.rawBody) {
            t.rawBody = t.rawBody.replace(/(^|\n)Status:\s*[^\n]+/g, `$1Status: ${newStatus}`);
          }
          break;
        }
      }
    }

    if ("boardDir" in store) {
      persistBoardStoreSync(store as any);
    }
    return store;
  }

  export function appendTask<T extends TasksDocument | BoardStore>(
    store: T,
    targetSectionTitle: string,
    task: TaskBlock
  ): T {
    const tasksDoc: TasksDocument =
      "sections" in store && Array.isArray(store.sections)
        ? store
        : (store as any).tasksDoc;

    let target = tasksDoc.sections.find(
      (s) => s.title.toLowerCase() === targetSectionTitle.toLowerCase()
    );
    if (!target) {
      target = {
        title: targetSectionTitle,
        name: targetSectionTitle,
        tasks: [],
        rawContent: "",
      };
      tasksDoc.sections.push(target);
    }

    target.tasks.push(task);
    target.rawContent = "";

    if ("boardDir" in store) {
      persistBoardStoreSync(store as any);
    }
    return store;
  }

  export function moveTask<T extends TasksDocument | BoardStore>(
    store: T,
    taskId: string,
    targetSectionTitle: string
  ): T {
    const isBoardStore = "tasksDoc" in store;
    const tasksDoc: TasksDocument = isBoardStore
      ? (store as any).tasksDoc
      : (store as TasksDocument);

    let movedTask: TaskBlock | null = null;

    // Search and remove from tasksDoc
    for (const sec of tasksDoc.sections) {
      const idx = sec.tasks.findIndex((t) => t.id === taskId);
      if (idx !== -1) {
        movedTask = sec.tasks[idx];
        sec.tasks.splice(idx, 1);
        if (sec.tasks.length === 0 && !sec.rawContent) {
          sec.rawContent = "*Idle - Ready for next backlog assignment.*";
        }
        break;
      }
    }

    if (!movedTask && isBoardStore && (store as any).archiveDoc?.sections) {
      for (const sec of (store as any).archiveDoc.sections) {
        const idx = sec.tasks.findIndex((t) => t.id === taskId);
        if (idx !== -1) {
          movedTask = sec.tasks[idx];
          sec.tasks.splice(idx, 1);
          break;
        }
      }
    }

    if (!movedTask) {
      return store;
    }

    const lowerTarget = targetSectionTitle.toLowerCase();
    const isArchive = lowerTarget.includes("archive") || lowerTarget.includes("done");

    if (isArchive) {
      movedTask.status = "Done";
      if (movedTask.rawBody) {
        movedTask.rawBody = movedTask.rawBody.replace(/(^|\n)Status:\s*[^\n]+/g, `$1Status: Done`);
        const today = new Date().toISOString().slice(0, 10);
        if (!/(^|\n)Completed:\s*[^\n]+/i.test(movedTask.rawBody)) {
          movedTask.rawBody = movedTask.rawBody.replace(
            /(^|\n)Status:\s*Done/i,
            `$1Status: Done\nCompleted: ${today}`
          );
        }
      }

      if (isBoardStore) {
        const archiveDoc: TasksDocument = (store as any).archiveDoc;
        let doneSec = archiveDoc.sections.find(
          (s) => s.title.toLowerCase() === "done" || s.title.toLowerCase() === targetSectionTitle.toLowerCase()
        );
        if (!doneSec) {
          doneSec = {
            title: "Done",
            name: "Done",
            tasks: [],
            rawContent: "",
          };
          archiveDoc.sections.push(doneSec);
        }
        doneSec.tasks.unshift(movedTask);

        // Also add bullet to archive content summary if not present
        const bulletPattern = new RegExp(`- \\[x\\]\\s+${movedTask.id}:`, "i");
        if ((store as any).archiveContent && !bulletPattern.test((store as any).archiveContent)) {
          const bullet = `- [x] ${movedTask.id}: ${movedTask.title}\n`;
          (store as any).archiveContent = (store as any).archiveContent.replace(
            /(# ARCHIVE[^\n]*\n\n[^\n]*\n\n)/,
            `$1${bullet}`
          );
        }
      } else {
        // In-memory document only
        let target = tasksDoc.sections.find(
          (s) => s.title.toLowerCase() === targetSectionTitle.toLowerCase()
        );
        if (!target) {
          target = {
            title: targetSectionTitle,
            name: targetSectionTitle,
            tasks: [],
            rawContent: "",
          };
          tasksDoc.sections.push(target);
        }
        target.tasks.push(movedTask);
      }
    } else {
      // Moving to another lane / section
      if (lowerTarget.includes("dev agent 1")) {
        movedTask.owner = "Dev Agent 1";
        movedTask.status = "In Progress";
      } else if (lowerTarget.includes("dev agent 2")) {
        movedTask.owner = "Dev Agent 2";
        movedTask.status = "In Progress";
      } else if (lowerTarget.includes("backlog")) {
        movedTask.status = "Backlog";
      }

      let target = tasksDoc.sections.find(
        (s) => s.title.toLowerCase() === targetSectionTitle.toLowerCase()
      );
      if (!target) {
        target = {
          title: targetSectionTitle,
          name: targetSectionTitle,
          tasks: [],
          rawContent: "",
        };
        tasksDoc.sections.push(target);
      }
      target.tasks.push(movedTask);
      target.rawContent = "";
    }

    if (isBoardStore && (store as any).boardDir) {
      persistBoardStoreSync(store as any);
    }

    return store;
  }

  export function archiveTask<T extends TasksDocument | BoardStore>(
    store: T,
    taskId: string
  ): T {
    return moveTask(store, taskId, "Done");
  }

  export function loadBoardStoreSync(boardDir: string): BoardStore {
    const tasksPath = path.join(boardDir, "TASKS.md");
    const backlogPath = path.join(boardDir, "BACKLOG.md");
    const archivePath = path.join(boardDir, "ARCHIVE.md");

    const tasksRaw = fs.existsSync(tasksPath) ? fs.readFileSync(tasksPath, "utf-8") : "# TASKS\n";
    const backlogRaw = fs.existsSync(backlogPath) ? fs.readFileSync(backlogPath, "utf-8") : "# BACKLOG\n";
    const archiveRaw = fs.existsSync(archivePath) ? fs.readFileSync(archivePath, "utf-8") : "# ARCHIVE\n";

    const tasksDoc = parseTasksDocument(tasksRaw);
    const archiveDoc = parseTasksDocument(archiveRaw);

    return {
      boardDir: Option.some(boardDir),
      tasksDoc,
      backlogContent: backlogRaw,
      archiveContent: archiveRaw,
      archiveDoc,
    };
  }

  export function createBoardStore(boardDir?: string): BoardStore {
    if (boardDir) {
      return loadBoardStoreSync(boardDir);
    }
    const emptyDoc: TasksDocument = {
      header: "# TASKS\n\nActive work board for slopboss2 rewrite.",
      lanes: [],
      sections: [],
    };
    return {
      boardDir: Option.none(),
      tasksDoc: emptyDoc,
      backlogContent: "# BACKLOG\n",
      archiveContent: "# ARCHIVE\n",
      archiveDoc: {
        header: "# ARCHIVE\n\nCompleted tasks for slopboss2.",
        lanes: [],
        sections: [],
      },
    };
  }

  export function persistBoardStoreSync(store: BoardStore): void {
    const dir = Option.isOption(store.boardDir)
      ? (Option.isSome(store.boardDir) ? store.boardDir.value : null)
      : (store.boardDir as any);
    if (!dir) return;

    if (store.tasksDoc) {
      const tasksPath = path.join(dir, "TASKS.md");
      atomicWriteFileSync(tasksPath, formatTasksDocument(store.tasksDoc));
    }
    if (store.archiveDoc) {
      const archivePath = path.join(dir, "ARCHIVE.md");
      atomicWriteFileSync(archivePath, formatTasksDocument(store.archiveDoc, store.archiveContent));
    }
    if (store.backlogContent) {
      const backlogPath = path.join(dir, "BACKLOG.md");
      atomicWriteFileSync(backlogPath, store.backlogContent);
    }
  }

  export function persistBoardStore(store: BoardStore): Effect.Effect<void, Error> {
    return Effect.try({
      try: () => persistBoardStoreSync(store),
      catch: (e) => (e instanceof Error ? e : new Error(String(e))),
    });
  }

  export function loadBoardStore(boardDir: string): Effect.Effect<BoardStore, Error> {
    return Effect.try({
      try: () => loadBoardStoreSync(boardDir),
      catch: (e) => (e instanceof Error ? e : new Error(String(e))),
    });
  }
}

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

export parseTasksDocumentFun = (content: String) =>
  parseTasksDocument(content)

export formatTasksDocumentFun = (doc: TasksDocument) =>
  formatTasksDocument(doc)
