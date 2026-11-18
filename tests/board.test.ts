import { describe, expect, it } from "bun:test";
import { parseTaskLine, formatTaskLine, Done, InProgress, Todo } from "../src/domain/board.js";
import { Option } from "effect";

describe("Board domain parser & formatter", () => {
  it("parses completed task line", () => {
    const task = parseTaskLine("- [x] Ship release v0.2.0");
    expect(task.status._tag).toBe("Done");
    expect(task.title).toBe("Ship release v0.2.0");
  });

  it("parses in-progress task line", () => {
    const task = parseTaskLine("- [/] Build CLI orchestrator");
    expect(task.status._tag).toBe("InProgress");
    expect(task.title).toBe("Build CLI orchestrator");
  });

  it("parses todo task line", () => {
    const task = parseTaskLine("- [ ] Write integration tests");
    expect(task.status._tag).toBe("Todo");
    expect(task.title).toBe("Write integration tests");
  });

  it("formats task back to Markdown bullet", () => {
    const formatted = formatTaskLine({
      id: "TODO-001",
      title: "Write integration tests",
      description: "Write integration tests",
      status: Todo,
      assignee: Option.some("Dev Agent 1"),
      branch: Option.none(),
      dependsOn: [],
    });
    expect(formatted).toBe("- [ ] TODO-001: Write integration tests [assigned: Dev Agent 1]");
  });
});
