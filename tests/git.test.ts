import { describe, expect, it } from "bun:test";
import {
  buildCloneCommand,
  buildCheckoutCommand,
  buildBranchMergedCheck,
  buildCommitCommand,
  buildPushCommand,
} from "../src/services/git.js";

describe("Git Service Commands", () => {
  it("builds git clone command", () => {
    const cmd = buildCloneCommand("https://github.com/de-angelov/slopboss2.git", "workspaces/repo-agent-1", "main");
    expect(cmd).toEqual([
      "git",
      "clone",
      "--branch",
      "main",
      "https://github.com/de-angelov/slopboss2.git",
      "workspaces/repo-agent-1",
    ]);
  });

  it("builds checkout new branch command", () => {
    const cmd = buildCheckoutCommand("agent/1/task-1", true);
    expect(cmd).toEqual(["git", "checkout", "-b", "agent/1/task-1"]);
  });

  it("builds merge base check command", () => {
    const cmd = buildBranchMergedCheck("main", "agent/1/task-1");
    expect(cmd).toEqual(["git", "merge-base", "--is-ancestor", "agent/1/task-1", "origin/main"]);
  });

  it("builds commit and push commands", () => {
    expect(buildCommitCommand("fix: done")).toEqual(["git", "commit", "-m", "fix: done"]);
    expect(buildPushCommand("agent/1/task-1")).toEqual(["git", "push", "-u", "origin", "agent/1/task-1"]);
  });
});
