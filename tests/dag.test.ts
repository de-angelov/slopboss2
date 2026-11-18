import { describe, expect, it } from "bun:test";
import {
  topologicalSort,
  findReadyTasks,
  type TaskNode,
} from "../src/domain/dag.js";

describe("Task Dependency DAG & Topological Sort Engine", () => {
  it("linearizes independent and sequentially dependent tasks correctly", () => {
    const tasks: TaskNode[] = [
      { id: "SB2-03", dependsOn: ["SB2-01"] },
      { id: "SB2-01", dependsOn: [] },
      { id: "SB2-05", dependsOn: ["SB2-03"] },
      { id: "SB2-02", dependsOn: [] },
    ];

    const result = topologicalSort(tasks);
    expect(result.hasCycle).toBe(false);
    expect(result.cycleNodes).toEqual([]);

    // SB2-01 must come before SB2-03, and SB2-03 before SB2-05
    const idx01 = result.order.indexOf("SB2-01");
    const idx03 = result.order.indexOf("SB2-03");
    const idx05 = result.order.indexOf("SB2-05");

    expect(idx01).toBeGreaterThanOrEqual(0);
    expect(idx03).toBeGreaterThan(idx01);
    expect(idx05).toBeGreaterThan(idx03);
    expect(result.order.length).toBe(4);
  });

  it("detects circular dependencies cleanly and identifies cycle nodes", () => {
    const cyclicTasks: TaskNode[] = [
      { id: "TASK-A", dependsOn: ["TASK-B"] },
      { id: "TASK-B", dependsOn: ["TASK-C"] },
      { id: "TASK-C", dependsOn: ["TASK-A"] },
      { id: "TASK-INDEPENDENT", dependsOn: [] },
    ];

    const result = topologicalSort(cyclicTasks);
    expect(result.hasCycle).toBe(true);
    expect(result.order).toContain("TASK-INDEPENDENT");
    expect(result.cycleNodes).toContain("TASK-A");
    expect(result.cycleNodes).toContain("TASK-B");
    expect(result.cycleNodes).toContain("TASK-C");
    expect(result.cycleNodes).not.toContain("TASK-INDEPENDENT");
  });

  it("finds ready tasks based on completed dependencies", () => {
    const tasks: TaskNode[] = [
      { id: "SB2-01", dependsOn: [] },
      { id: "SB2-02", dependsOn: ["SB2-01"] },
      { id: "SB2-03", dependsOn: ["SB2-01", "SB2-02"] },
      { id: "SB2-04", dependsOn: ["SB2-UNFINISHED"] },
    ];

    // When none are completed, only SB2-01 is ready
    const ready0 = findReadyTasks(tasks, []);
    expect(ready0).toEqual(["SB2-01"]);

    // When SB2-01 is completed, SB2-02 is ready, SB2-01 is already completed
    const ready1 = findReadyTasks(tasks, ["SB2-01"]);
    expect(ready1).toEqual(["SB2-02"]);

    // When SB2-01 and SB2-02 are completed, SB2-03 becomes ready
    const ready2 = findReadyTasks(tasks, ["SB2-01", "SB2-02"]);
    expect(ready2).toEqual(["SB2-03"]);
  });
});
