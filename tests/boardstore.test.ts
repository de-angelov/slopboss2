import { afterEach, beforeEach, describe, expect, it } from "bun:test";
import { Effect, Option } from "effect";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import {
  appendTask,
  atomicWriteFileSync,
  createBoardStore,
  findTask,
  formatTasksDocument,
  loadBoardStore,
  loadBoardStoreSync,
  moveTask,
  parseTasksDocument,
  persistBoardStore,
  updateTaskStatus,
  type MarkdownSection,
  type TaskBlock,
  type TasksDocument,
} from "../src/domain/boardstore.js";

const SAMPLE_TASKS_MD = `# TASKS

Active work board for slopboss2 rewrite.

## Dev Agent 1 In Progress

### Full Markdown Board Store & Task File Synchronizer

Task ID: SB2-11
Category: Core Service
Owner: Dev Agent 1
Branch: agent/1/sb2-11-boardstore
Status: In Progress
Dependencies: none
Blocking tasks: none

Objective:
Implement a full markdown board parser, serializer, and transactional file synchronizer in \`src/domain/boardstore.fun\` that parses \`TASKS.md\`, \`BACKLOG.md\`, and \`ARCHIVE.md\`, supports section-level task mutations (move, update status, append, archive), and guarantees atomic multi-file persistence.

Scope:
- Model \`MarkdownSection\` and full \`TaskBlock\` with fields: \`id\`, \`category\`, \`owner\`, \`branch\`, \`status\`, \`dependencies\`, \`objective\`, \`scope\`, \`acceptanceCriteria\`, and \`rawBody\`.
- Implement \`parseTasksDocument(content: String)\`: splits document into header, agent lanes, and structured task blocks.
- Implement \`formatTasksDocument(...)\`: serializes structured sections back to clean Markdown without formatting drift.
- Implement \`moveTask(store, taskId, targetSection)\`: moves a task atomically (e.g. from Lane to Archive).
- Add unit tests in \`tests/boardstore.test.ts\`.

Acceptance Criteria:
- Parses \`TASKS.md\` containing multiple agent lanes into typed task blocks.
- Formats document cleanly preserving Markdown headers and bullets.
- \`moveTask\` atomically moves a task block between sections.
- \`bun test tests/boardstore.test.ts\` passes.

## Dev Agent 2 In Progress

*Idle - Ready for next backlog assignment.*
`;

const SAMPLE_MULTI_TASK_MD = `# TASKS

Active work board.

## Dev Agent 1 In Progress

### Task One

Task ID: SB2-01
Category: Core
Owner: Dev Agent 1
Branch: agent/1/sb2-01
Status: In Progress
Dependencies: none

Objective:
First objective.

Scope:
First scope.

Acceptance Criteria:
First AC.

## Dev Agent 2 In Progress

### Task Two

Task ID: SB2-02
Category: Core
Owner: Dev Agent 2
Branch: agent/2/sb2-02
Status: In Progress
Dependencies: SB2-01

Objective:
Second objective.

Scope:
Second scope.

Acceptance Criteria:
Second AC.
`;

describe("Full Markdown Board Store & Task File Synchronizer", () => {
  let tempDir: string;

  beforeEach(() => {
    tempDir = fs.mkdtempSync(path.join(os.tmpdir(), "sb2-boardstore-test-"));
  });

  afterEach(() => {
    if (fs.existsSync(tempDir)) {
      fs.rmSync(tempDir, { recursive: true, force: true });
    }
  });

  describe("parseTasksDocument", () => {
    it("parses TASKS.md containing multiple agent lanes into typed task blocks", () => {
      const doc = parseTasksDocument(SAMPLE_TASKS_MD);

      expect(doc.header).toBe("# TASKS\n\nActive work board for slopboss2 rewrite.");
      expect(doc.sections.length).toBe(2);
      expect(doc.lanes.length).toBe(2);

      // Lane 1: Dev Agent 1 In Progress
      const lane1 = doc.sections[0];
      expect(lane1.title).toBe("Dev Agent 1 In Progress");
      expect(lane1.name).toBe("Dev Agent 1 In Progress");
      expect(lane1.tasks.length).toBe(1);

      const task = lane1.tasks[0];
      expect(task.id).toBe("SB2-11");
      expect(task.title).toBe("Full Markdown Board Store & Task File Synchronizer");
      expect(task.category).toBe("Core Service");
      expect(task.owner).toBe("Dev Agent 1");
      expect(task.branch).toBe("agent/1/sb2-11-boardstore");
      expect(task.status).toBe("In Progress");
      expect(task.dependencies).toEqual([]);
      expect(task.objective).toContain("Implement a full markdown board parser");
      expect(task.scope).toContain("Model `MarkdownSection` and full `TaskBlock`");
      expect(task.acceptanceCriteria).toContain("`bun test tests/boardstore.test.ts` passes.");
      expect(task.rawBody).toContain("### Full Markdown Board Store & Task File Synchronizer");

      // Lane 2: Dev Agent 2 In Progress (Idle)
      const lane2 = doc.sections[1];
      expect(lane2.title).toBe("Dev Agent 2 In Progress");
      expect(lane2.tasks.length).toBe(0);
      expect(lane2.rawContent).toBe("*Idle - Ready for next backlog assignment.*");
    });

    it("parses dependencies list cleanly", () => {
      const doc = parseTasksDocument(SAMPLE_MULTI_TASK_MD);
      expect(doc.sections[0].tasks[0].dependencies).toEqual([]);
      expect(doc.sections[1].tasks[0].dependencies).toEqual(["SB2-01"]);
    });
  });

  describe("formatTasksDocument", () => {
    it("formats document cleanly preserving Markdown headers and bullets without drift", () => {
      const doc = parseTasksDocument(SAMPLE_TASKS_MD);
      const formatted = formatTasksDocument(doc);
      expect(formatted.trim()).toBe(SAMPLE_TASKS_MD.trim());
    });

    it("formats sections array directly when passed without wrapper object", () => {
      const doc = parseTasksDocument(SAMPLE_TASKS_MD);
      const formatted = formatTasksDocument(doc.sections, doc.header);
      expect(formatted.trim()).toBe(SAMPLE_TASKS_MD.trim());
    });
  });

  describe("moveTask in-memory", () => {
    it("atomically moves a task block between sections and updates owner and placeholder", () => {
      const doc = parseTasksDocument(SAMPLE_TASKS_MD);
      expect(doc.sections[0].tasks.length).toBe(1);
      expect(doc.sections[1].tasks.length).toBe(0);

      const updated = moveTask(doc, "SB2-11", "Dev Agent 2 In Progress");

      // Dev Agent 1 is now empty with idle placeholder
      expect(updated.sections[0].tasks.length).toBe(0);
      expect(updated.sections[0].rawContent).toBe("*Idle - Ready for next backlog assignment.*");

      // Dev Agent 2 now has the task with owner updated
      expect(updated.sections[1].tasks.length).toBe(1);
      const movedTask = updated.sections[1].tasks[0];
      expect(movedTask.id).toBe("SB2-11");
      expect(movedTask.owner).toBe("Dev Agent 2");
      expect(movedTask.status).toBe("In Progress");

      // Serializes back cleanly
      const formatted = formatTasksDocument(updated);
      expect(formatted).toContain("## Dev Agent 1 In Progress\n\n*Idle - Ready for next backlog assignment.*");
      expect(formatted).toContain("## Dev Agent 2 In Progress\n\n### Full Markdown Board Store");
      expect(formatted).toContain("Owner: Dev Agent 2");
    });

    it("creates a new section if target section does not exist", () => {
      const doc = parseTasksDocument(SAMPLE_TASKS_MD);
      const updated = moveTask(doc, "SB2-11", "Review Queue");

      expect(updated.sections.length).toBe(3);
      const reviewQueue = updated.sections[2];
      expect(reviewQueue.title).toBe("Review Queue");
      expect(reviewQueue.tasks.length).toBe(1);
      expect(reviewQueue.tasks[0].id).toBe("SB2-11");
    });
  });

  describe("Task queries and mutations", () => {
    it("finds task by ID with Option", () => {
      const doc = parseTasksDocument(SAMPLE_TASKS_MD);
      const found = findTask(doc, "SB2-11");
      expect(Option.isSome(found)).toBe(true);
      if (Option.isSome(found)) {
        expect(found.value.id).toBe("SB2-11");
      }

      const notFound = findTask(doc, "NON-EXISTENT");
      expect(Option.isNone(notFound)).toBe(true);
    });

    it("updates task status in place", () => {
      const doc = parseTasksDocument(SAMPLE_TASKS_MD);
      updateTaskStatus(doc, "SB2-11", "Blocked");

      const task = doc.sections[0].tasks[0];
      expect(task.status).toBe("Blocked");
      expect(task.rawBody).toContain("Status: Blocked");
    });

    it("appends new task block to target section", () => {
      const doc = parseTasksDocument(SAMPLE_TASKS_MD);
      const newTask: TaskBlock = {
        id: "SB2-99",
        title: "Experimental Task",
        category: "Experiment",
        owner: "Dev Agent 2",
        branch: "agent/2/exp",
        status: "Todo",
        dependencies: [],
        objective: "Test appending",
        scope: "Small",
        acceptanceCriteria: "Passes",
        rawBody: "",
      };

      appendTask(doc, "Dev Agent 2 In Progress", newTask);
      expect(doc.sections[1].tasks.length).toBe(1);
      expect(doc.sections[1].tasks[0].id).toBe("SB2-99");
    });
  });

  describe("Transactional BoardStore & Atomic Multi-File Persistence", () => {
    it("loads board store from disk directory and moves task to Archive atomically", () => {
      const tasksFile = path.join(tempDir, "TASKS.md");
      const backlogFile = path.join(tempDir, "BACKLOG.md");
      const archiveFile = path.join(tempDir, "ARCHIVE.md");

      fs.writeFileSync(tasksFile, SAMPLE_TASKS_MD, "utf-8");
      fs.writeFileSync(backlogFile, "# BACKLOG\n\n- [ ] SB2-12: Diagnostics\n", "utf-8");
      fs.writeFileSync(
        archiveFile,
        "# ARCHIVE\n\nCompleted tasks for slopboss2.\n\n- [x] SB2-01: Antigravity Provider\n\n## Done\n\n### Antigravity Provider\n\nTask ID: SB2-01\nStatus: Done\n",
        "utf-8"
      );

      const store = loadBoardStoreSync(tempDir);
      expect(Option.isSome(store.boardDir)).toBe(true);
      expect(store.tasksDoc.sections[0].tasks.length).toBe(1);

      // Move task to Archive / Done
      moveTask(store, "SB2-11", "Done");

      // In-memory checks
      expect(store.tasksDoc.sections[0].tasks.length).toBe(0);
      const archivedTask = store.archiveDoc.sections
        .find((s) => s.title === "Done")
        ?.tasks.find((t) => t.id === "SB2-11");
      expect(archivedTask).toBeDefined();
      expect(archivedTask?.status).toBe("Done");

      // Disk checks - persistence happened automatically and atomically
      const diskTasks = fs.readFileSync(tasksFile, "utf-8");
      const diskArchive = fs.readFileSync(archiveFile, "utf-8");

      expect(diskTasks.includes("SB2-11")).toBe(false);
      expect(diskTasks.includes("*Idle - Ready for next backlog assignment.*")).toBe(true);
      expect(diskArchive.includes("SB2-11")).toBe(true);
      expect(diskArchive.includes("Status: Done")).toBe(true);
      expect(diskArchive.includes("Completed:")).toBe(true);
    });

    it("supports Effect-based loadBoardStore and persistBoardStore", async () => {
      const tasksFile = path.join(tempDir, "TASKS.md");
      fs.writeFileSync(tasksFile, SAMPLE_TASKS_MD, "utf-8");

      const store = await Effect.runPromise(loadBoardStore(tempDir));
      expect(store.tasksDoc.sections.length).toBe(2);

      updateTaskStatus(store, "SB2-11", "Blocked");
      await Effect.runPromise(persistBoardStore(store));

      const diskTasks = fs.readFileSync(tasksFile, "utf-8");
      expect(diskTasks.includes("Status: Blocked")).toBe(true);
    });

    it("atomicWriteFileSync overwrites cleanly without leaving temp files", () => {
      const targetFile = path.join(tempDir, "atomic-test.md");
      atomicWriteFileSync(targetFile, "Initial Content");
      expect(fs.readFileSync(targetFile, "utf-8")).toBe("Initial Content");

      atomicWriteFileSync(targetFile, "Overwritten Content");
      expect(fs.readFileSync(targetFile, "utf-8")).toBe("Overwritten Content");

      // Verify no temporary files left in directory
      const files = fs.readdirSync(tempDir);
      expect(files).toEqual(["atomic-test.md"]);
    });
  });
});
