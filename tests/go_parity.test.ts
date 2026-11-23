import { afterEach, beforeEach, describe, expect, it } from "bun:test";
import { Effect, Option } from "effect";
import { execFileSync } from "node:child_process";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import { landMergeRequest, type MergeRequest } from "../src/orchestrator/mergetrain.js";
import { initialReconcilerState, reconcileTick } from "../src/orchestrator/dispatcher.js";

// These are behavior contracts against real local processes and Git, not mocks.
describe("Go implementation parity", () => {
  let root: string;
  let remote: string;
  let workspace: string;
  let originalPath: string | undefined;

  const git = (cwd: string, ...args: string[]) =>
    execFileSync("git", args, { cwd, encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] }).trim();

  beforeEach(() => {
    root = fs.mkdtempSync(path.join(os.tmpdir(), "slopboss-parity-"));
    remote = path.join(root, "remote.git");
    workspace = path.join(root, "workspace");
    originalPath = process.env.PATH;
    git(root, "init", "--bare", "-b", "main", remote);
    git(root, "clone", remote, workspace);
    git(workspace, "config", "user.name", "Parity Test");
    git(workspace, "config", "user.email", "parity@example.com");
    fs.writeFileSync(path.join(workspace, "initial.txt"), "initial\n");
    git(workspace, "add", ".");
    git(workspace, "commit", "-m", "initial");
    git(workspace, "push", "origin", "main");
    git(workspace, "checkout", "-b", "agent/1/parity");
    fs.writeFileSync(path.join(workspace, "feature.txt"), "feature\n");
    git(workspace, "add", ".");
    git(workspace, "commit", "-m", "PARITY-1: feature");
    git(workspace, "push", "origin", "agent/1/parity");
  });

  afterEach(() => {
    process.env.PATH = originalPath;
    fs.rmSync(root, { recursive: true, force: true });
  });

  const request = (command: string): MergeRequest => ({
    taskId: "PARITY-1", branch: "agent/1/parity", workspace,
    isZeroCommit: false, verificationCmd: Option.some(command),
  });

  it("runs verification and pushes the actual change to the integration branch", async () => {
    const result = await Effect.runPromise(landMergeRequest(request("test -f feature.txt && touch verification-ran"), "main"));
    expect(result.success).toBe(true);
    expect(fs.existsSync(path.join(workspace, "verification-ran"))).toBe(true);
    expect(git(root, "--git-dir", remote, "show", "main:feature.txt")).toBe("feature");
    const head = git(root, "--git-dir", remote, "rev-parse", "main");
    expect(result.commitHash).toEqual(Option.some(head));
  });

  it("does not push when verification fails", async () => {
    const before = git(root, "--git-dir", remote, "rev-parse", "main");
    const result = await Effect.runPromise(landMergeRequest(request("false"), "main"));
    expect(result.success).toBe(false);
    expect(git(root, "--git-dir", remote, "rev-parse", "main")).toBe(before);
  });

  it("does not report a successful landing when the remote rejects pushes", async () => {
    const hook = path.join(remote, "hooks", "pre-receive");
    fs.writeFileSync(hook, "#!/bin/sh\nexit 1\n", { mode: 0o755 });
    const before = git(root, "--git-dir", remote, "rev-parse", "main");
    const result = await Effect.runPromise(landMergeRequest(request("true"), "main"));
    expect(result.success).toBe(false);
    expect(git(root, "--git-dir", remote, "rev-parse", "main")).toBe(before);
  });

  it("runs the configured agent instead of silently completing with a mock", async () => {
    const bin = path.join(root, "bin");
    fs.mkdirSync(bin);
    const marker = path.join(root, "agent-ran");
    fs.writeFileSync(path.join(bin, "agy"), `#!/bin/sh\ntouch '${marker}'\nexit 1\n`, { mode: 0o755 });
    process.env.PATH = bin + path.delimiter + originalPath;
    fs.mkdirSync(path.join(root, "workspaces"), { recursive: true });
    git(root, "clone", remote, path.join(root, "workspaces", "repo-agent-1"));
    fs.writeFileSync(path.join(root, "BACKLOG.md"), "# BACKLOG\n\n### Parity task\nTask ID: PARITY-1\nCategory: AFK\nOwner: Dev Agent 1\nBranch: agent/1/parity\nStatus: Backlog\nDependencies: none\n\nObjective: test\n");
    fs.writeFileSync(path.join(root, "TASKS.md"), "# TASKS\n\n## Dev Agent 1 In Progress\n\n*Idle*\n");
    fs.writeFileSync(path.join(root, "ARCHIVE.md"), "# ARCHIVE\n\n## Done\n");
    await Effect.runPromise(reconcileTick({ boardDir: root, pollIntervalMs: 0, maxIterations: 1, devAgentCount: 1, provider: path.join(bin, "agy") }, initialReconcilerState(1)));
    expect(fs.existsSync(marker)).toBe(true);
    expect(fs.readFileSync(path.join(root, "ARCHIVE.md"), "utf8")).not.toContain("PARITY-1");
  });
});
