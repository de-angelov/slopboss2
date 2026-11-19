import { describe, expect, it } from "bun:test";
import { Effect, Option, Queue } from "effect";
import {
  landMergeRequest,
  createMergeTrain,
  enqueueMerge,
  processNextMerge,
  type MergeRequest,
} from "../src/orchestrator/mergetrain.js";

describe("Linearized Merge Train Queue & Automatic Landing", () => {
  it("lands zero-commit audit task cleanly without requiring git commit", async () => {
    const req: MergeRequest = {
      taskId: "SB2-AUDIT-01",
      branch: "agent/1/audit-task",
      workspace: "/tmp/workspace",
      isZeroCommit: true,
      verificationCmd: Option.some("npm test"),
    };

    const result = await Effect.runPromise(landMergeRequest(req, "main"));
    expect(result.taskId).toBe("SB2-AUDIT-01");
    expect(result.success).toBe(true);
    expect(result.commitHash).toEqual(Option.none());
    expect(result.error).toEqual(Option.none());
  });

  it("lands standard code branch with squash commit and verification", async () => {
    const req: MergeRequest = {
      taskId: "SB2-03",
      branch: "agent/1/sb2-03-runner",
      workspace: "/tmp/workspace",
      isZeroCommit: false,
      verificationCmd: Option.some("bun test tests/runner.test.ts"),
    };

    const result = await Effect.runPromise(landMergeRequest(req, "main"));
    expect(result.taskId).toBe("SB2-03");
    expect(result.success).toBe(true);
    expect(result.commitHash).toEqual(Option.some("f1a2b3c4d5e6"));
    expect(result.error).toEqual(Option.none());
  });

  it("processes concurrent merge requests strictly sequentially through Effect Queue", async () => {
    const queue = await Effect.runPromise(createMergeTrain(10));

    const req1: MergeRequest = {
      taskId: "SB2-01",
      branch: "agent/1/sb2-01-provider",
      workspace: "/tmp/ws1",
      isZeroCommit: false,
      verificationCmd: Option.none(),
    };

    const req2: MergeRequest = {
      taskId: "SB2-02",
      branch: "agent/2/sb2-02-git",
      workspace: "/tmp/ws2",
      isZeroCommit: false,
      verificationCmd: Option.none(),
    };

    // Enqueue concurrently
    await Effect.runPromise(
      Effect.all([
        enqueueMerge(queue, req1),
        enqueueMerge(queue, req2),
      ])
    );

    // Dequeue sequentially
    const res1 = await Effect.runPromise(processNextMerge(queue, "main"));
    const res2 = await Effect.runPromise(processNextMerge(queue, "main"));

    expect(res1.taskId).toBe("SB2-01");
    expect(res1.success).toBe(true);
    expect(res2.taskId).toBe("SB2-02");
    expect(res2.success).toBe(true);
  });
});
