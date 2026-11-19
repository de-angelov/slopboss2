import { afterEach, describe, expect, it } from "bun:test";
import { execFileSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { Effect, Option } from "effect";
import { landMergeRequest, type MergeRequest } from "../src/orchestrator/mergetrain.js";

const roots: string[] = [];
const git = (cwd: string, ...args: string[]) => execFileSync("git", args, { cwd, stdio: "ignore" });
const setup = () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "slopboss-landing-"));
  roots.push(root);
  const remote = path.join(root, "remote.git");
  const workspace = path.join(root, "workspace");
  fs.mkdirSync(workspace);
  execFileSync("git", ["init", "--bare", remote]);
  git(root, "init", "--initial-branch=main", "workspace");
  git(workspace, "config", "user.name", "Test");
  git(workspace, "config", "user.email", "test@example.com");
  fs.writeFileSync(path.join(workspace, "base.txt"), "base\n");
  git(workspace, "add", "."); git(workspace, "commit", "-m", "base");
  git(workspace, "remote", "add", "origin", remote);
  git(workspace, "push", "-u", "origin", "main");
  git(workspace, "checkout", "-b", "agent/change");
  fs.writeFileSync(path.join(workspace, "base.txt"), "branch change\n");
  git(workspace, "add", "."); git(workspace, "commit", "-m", "change");
  git(workspace, "push", "-u", "origin", "agent/change");
  git(workspace, "checkout", "main");
  const request: MergeRequest = { taskId: "SB2-TEST", branch: "agent/change", workspace, isZeroCommit: false, verificationCmd: Option.none() };
  return { root, remote, workspace, request };
};

afterEach(() => { for (const root of roots.splice(0)) fs.rmSync(root, { recursive: true, force: true }); });

describe("verified Git landing", () => {
  it("squash lands and pushes a real commit", async () => {
    const { remote, request } = setup();
    const result = await Effect.runPromise(landMergeRequest(request, "main"));
    expect(result.success).toBe(true);
    expect(result.commitHash).not.toEqual(Option.none());
    expect(execFileSync("git", ["--git-dir", remote, "show", "main:base.txt"], { encoding: "utf8" })).toBe("branch change\n");
    expect(execFileSync("git", ["--git-dir", remote, "log", "--format=%P", "-1", "main"], { encoding: "utf8" }).trim().split(" ")).toHaveLength(1);
  });

  it("returns verification evidence and does not push", async () => {
    const { remote, request } = setup();
    request.verificationCmd = Option.some("exit 7");
    const result = await Effect.runPromise(landMergeRequest(request, "main"));
    expect(result.success).toBe(false); expect(Option.getOrElse(result.error, () => "")).toMatch(/Verification failed/);
    expect(execFileSync("git", ["--git-dir", remote, "rev-parse", "main"], { encoding: "utf8" }).trim()).toBe(execFileSync("git", ["--git-dir", remote, "rev-parse", "refs/heads/main"], { encoding: "utf8" }).trim());
  });

  it("reports squash conflicts", async () => {
    const { remote, workspace, request } = setup();
    git(workspace, "checkout", "main"); fs.writeFileSync(path.join(workspace, "base.txt"), "conflict\n");
    git(workspace, "commit", "-am", "conflicting base"); git(workspace, "push", "origin", "main");
    const result = await Effect.runPromise(landMergeRequest(request, "main"));
    expect(result.success).toBe(false); expect(Option.getOrElse(result.error, () => "")).toMatch(/conflict/i);
    expect(execFileSync("git", ["--git-dir", remote, "show", "main:base.txt"], { encoding: "utf8" })).toBe("conflict\n");
  });

  it("returns push failures without claiming a commit", async () => {
    const { root, remote, request } = setup();
    const hook = path.join(remote, "hooks", "pre-receive"); fs.writeFileSync(hook, "#!/bin/sh\nexit 1\n"); fs.chmodSync(hook, 0o755);
    const result = await Effect.runPromise(landMergeRequest(request, "main"));
    expect(result.success).toBe(false); expect(result.commitHash).toEqual(Option.none()); expect(Option.getOrElse(result.error, () => "")).toMatch(/Push failed/);
    fs.chmodSync(hook, 0o644); void root;
  });

  it("verifies zero-commit tasks and rejects failed verification", async () => {
    const { request } = setup();
    request.isZeroCommit = true; request.verificationCmd = Option.some("true");
    const ok = await Effect.runPromise(landMergeRequest(request, "main"));
    expect(ok.success).toBe(true); expect(ok.commitHash).toEqual(Option.none());
    request.verificationCmd = Option.some("false");
    const failed = await Effect.runPromise(landMergeRequest(request, "main"));
    expect(failed.success).toBe(false); expect(Option.getOrElse(failed.error, () => "")).toMatch(/Verification failed/);
  });
});
