import { afterEach, beforeEach, describe, expect, it } from "bun:test";
import { Effect } from "effect";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import { runDoctor, runDoctorSync } from "../src/services/doctor.js";
import {
  createWorktreeWorkspaceSync,
  ensureCleanGitMain,
  initBoardStructure,
  initBoardStructureSync,
  provisionWorkspacesSync,
  readRuntimeConfigSync,
  runGitCommand,
  scaffoldBoardMarkdownSync,
  verifyWorkspacesReady,
  verifyWorkspacesReadySync,
} from "../src/services/setup.js";

describe("Workspace Auto-Provisioning & Board Scaffolding Service", () => {
  let tempDir: string;

  beforeEach(() => {
    tempDir = fs.mkdtempSync(path.join(os.tmpdir(), "slopboss-setup-test-"));
  });

  afterEach(() => {
    if (fs.existsSync(tempDir)) {
      fs.rmSync(tempDir, { recursive: true, force: true });
    }
  });

  describe("scaffoldBoardMarkdownSync", () => {
    it("creates all required board markdown files", () => {
      const filesCreated = scaffoldBoardMarkdownSync(tempDir, 2);

      expect(filesCreated).toContain("TASKS.md");
      expect(filesCreated).toContain("BACKLOG.md");
      expect(filesCreated).toContain("ARCHIVE.md");
      expect(filesCreated).toContain("AGENTS.md");
      expect(filesCreated).toContain("DEV_AGENT.md");
      expect(filesCreated).toContain("TEAM_LEAD_AGENT.md");

      const tasksContent = fs.readFileSync(path.join(tempDir, "TASKS.md"), "utf-8");
      expect(tasksContent).toContain("# TASKS");
      expect(tasksContent).toContain("## Dev Agent 1 In Progress");
      expect(tasksContent).toContain("## Dev Agent 2 In Progress");

      const backlogContent = fs.readFileSync(path.join(tempDir, "BACKLOG.md"), "utf-8");
      expect(backlogContent).toContain("# BACKLOG");

      const archiveContent = fs.readFileSync(path.join(tempDir, "ARCHIVE.md"), "utf-8");
      expect(archiveContent).toContain("# ARCHIVE");

      const agentsContent = fs.readFileSync(path.join(tempDir, "AGENTS.md"), "utf-8");
      expect(agentsContent).toContain("# AI Development Workflow");
    });

    it("scaffolds lanes dynamically for devAgentCount", () => {
      scaffoldBoardMarkdownSync(tempDir, 4);

      const tasksContent = fs.readFileSync(path.join(tempDir, "TASKS.md"), "utf-8");
      expect(tasksContent).toContain("## Dev Agent 1 In Progress");
      expect(tasksContent).toContain("## Dev Agent 2 In Progress");
      expect(tasksContent).toContain("## Dev Agent 3 In Progress");
      expect(tasksContent).toContain("## Dev Agent 4 In Progress");
    });

    it("preserves existing files safely without overwriting user data", () => {
      const existingTasksContent = "# TASKS\n\nCustom user task content that must be preserved.";
      fs.writeFileSync(path.join(tempDir, "TASKS.md"), existingTasksContent, "utf-8");

      const filesCreated = scaffoldBoardMarkdownSync(tempDir, 2);
      expect(filesCreated).not.toContain("TASKS.md");

      const readBack = fs.readFileSync(path.join(tempDir, "TASKS.md"), "utf-8");
      expect(readBack).toBe(existingTasksContent);
    });
  });

  describe("provisionWorkspacesSync and verifyWorkspacesReadySync", () => {
    it("provisions clean git repositories for repo-tl and dev agent workspaces", () => {
      const created = provisionWorkspacesSync(tempDir, "", 2);

      expect(created).toContain("repo-tl");
      expect(created).toContain("repo-agent-1");
      expect(created).toContain("repo-agent-2");

      const check = verifyWorkspacesReadySync(tempDir, 2);
      expect(check.ok).toBe(true);
      expect(check.workspaces.length).toBe(3);

      for (const ws of check.workspaces) {
        expect(ws.exists).toBe(true);
        expect(ws.isGitRepo).toBe(true);
        expect(ws.currentBranch).toBe("main");
        expect(ws.isClean).toBe(true);
      }
    });

    it("reports verification failure if a workspace is missing", () => {
      provisionWorkspacesSync(tempDir, "", 2);

      // Remove repo-agent-2
      const agent2Dir = path.join(tempDir, "workspaces", "repo-agent-2");
      fs.rmSync(agent2Dir, { recursive: true, force: true });

      const check = verifyWorkspacesReadySync(tempDir, 2);
      expect(check.ok).toBe(false);
      expect(check.message).toContain("repo-agent-2 does not exist");
    });

    it("reports verification failure if a workspace has uncommitted changes", () => {
      provisionWorkspacesSync(tempDir, "", 2);

      const agent1Dir = path.join(tempDir, "workspaces", "repo-agent-1");
      fs.writeFileSync(path.join(agent1Dir, "dirty.txt"), "uncommitted content");

      const check = verifyWorkspacesReadySync(tempDir, 2);
      expect(check.ok).toBe(false);
      expect(check.message).toContain("repo-agent-1 has uncommitted changes");
    });

    it("reports verification failure if a workspace is on another branch", () => {
      provisionWorkspacesSync(tempDir, "", 2);

      const agent1Dir = path.join(tempDir, "workspaces", "repo-agent-1");
      runGitCommand(["checkout", "-b", "feature/other"], agent1Dir);

      const check = verifyWorkspacesReadySync(tempDir, 2);
      expect(check.ok).toBe(false);
      expect(check.message).toContain("repo-agent-1 is on branch 'feature/other'");
    });

    it("verifies workspaces asynchronously via Effect", async () => {
      provisionWorkspacesSync(tempDir, "", 2);

      const check = await Effect.runPromise(verifyWorkspacesReady(tempDir, 2));
      expect(check.ok).toBe(true);
      expect(check.workspaces.length).toBe(3);
    });
  });

  describe("initBoardStructure", () => {
    it("initializes complete board structure and passes runDoctor", async () => {
      const initResult = await Effect.runPromise(initBoardStructure(tempDir, "", 2));

      expect(initResult.ok).toBe(true);
      expect(initResult.filesCreated.length).toBeGreaterThanOrEqual(6);
      expect(initResult.workspacesCreated.length).toBe(3);

      // Verify that doctor report passes
      const doctorReport = await Effect.runPromise(runDoctor(tempDir));
      expect(doctorReport.isHealthy).toBe(true);

      const boardCheck = doctorReport.checks.find((c) => c.name === "board");
      expect(boardCheck?.ok).toBe(true);

      const workspacesCheck = doctorReport.checks.find((c) => c.name === "workspaces");
      expect(workspacesCheck?.ok).toBe(true);
    });

    it("supports synchronous initBoardStructureSync", () => {
      const initResult = initBoardStructureSync(tempDir, "", 3);

      expect(initResult.ok).toBe(true);
      expect(initResult.devAgentCount).toBe(3);
      expect(initResult.workspacesCreated).toEqual(["repo-tl", "repo-agent-1", "repo-agent-2", "repo-agent-3"]);

      const readyReport = verifyWorkspacesReadySync(tempDir, 3);
      expect(readyReport.ok).toBe(true);
      expect(readyReport.workspaces.length).toBe(4);

      const doctorReport = runDoctorSync(tempDir);
      expect(doctorReport.isHealthy).toBe(true);
    });

    it("persists configured runtime values for the controller", () => {
      const result = initBoardStructureSync(tempDir, "file:///repo.git", 3, "file:///origin.git", "trunk", "gemini");
      expect(result.ok).toBe(true);
      expect(readRuntimeConfigSync(tempDir)).toEqual({
        repository: "file:///repo.git",
        originUrl: "file:///origin.git",
        baseBranch: "trunk",
        provider: "gemini",
        devAgentCount: 3,
      });
    });

    it("clones from a local git repository when repoUrl is provided", () => {
      // Create a bare origin repo to clone from
      const originDir = path.join(tempDir, "origin.git");
      fs.mkdirSync(originDir, { recursive: true });
      runGitCommand(["init", "--bare", "-b", "main"], originDir);

      // Seed bare repo with an initial commit via temporary workdir
      const seedDir = path.join(tempDir, "seed");
      fs.mkdirSync(seedDir, { recursive: true });
      runGitCommand(["init", "-b", "main"], seedDir);
      fs.writeFileSync(path.join(seedDir, "file.txt"), "hello world");
      runGitCommand(["add", "-A"], seedDir);
      runGitCommand(["commit", "-m", "init"], seedDir);
      runGitCommand(["remote", "add", "origin", originDir], seedDir);
      runGitCommand(["push", "origin", "main"], seedDir);

      const boardDir = path.join(tempDir, "board");
      const initResult = initBoardStructureSync(boardDir, originDir, 2);

      expect(initResult.ok).toBe(true);

      const agent1Dir = path.join(boardDir, "workspaces", "repo-agent-1");
      expect(fs.existsSync(path.join(agent1Dir, "file.txt"))).toBe(true);

      const readyReport = verifyWorkspacesReadySync(boardDir, 2);
      expect(readyReport.ok).toBe(true);
    });

    it("handles re-initialization safely without data loss", () => {
      // First initialization
      const firstInit = initBoardStructureSync(tempDir, "", 2);
      expect(firstInit.ok).toBe(true);

      // Modify a file in repo-agent-1 and add a task to TASKS.md
      const taskMd = path.join(tempDir, "TASKS.md");
      fs.appendFileSync(taskMd, "\n### My Important User Task\nTask ID: USER-01\n");

      const agent1File = path.join(tempDir, "workspaces", "repo-agent-1", "custom.txt");
      fs.writeFileSync(agent1File, "user data");
      runGitCommand(["add", "custom.txt"], path.dirname(agent1File));
      runGitCommand(["commit", "-m", "user commit"], path.dirname(agent1File));

      // Re-run initialization
      const secondInit = initBoardStructureSync(tempDir, "", 2);
      expect(secondInit.ok).toBe(true);
      expect(secondInit.filesCreated.length).toBe(0);
      expect(secondInit.workspacesCreated.length).toBe(0);

      // Ensure user modifications were preserved
      const taskContentAfter = fs.readFileSync(taskMd, "utf-8");
      expect(taskContentAfter).toContain("### My Important User Task");
      expect(fs.existsSync(agent1File)).toBe(true);
    });
  });

  describe("createWorktreeWorkspaceSync", () => {
    it("creates a git worktree on a new branch from a base repo", () => {
      const baseRepo = path.join(tempDir, "base-repo");
      fs.mkdirSync(baseRepo, { recursive: true });
      runGitCommand(["init", "-b", "main"], baseRepo);
      fs.writeFileSync(path.join(baseRepo, "README.md"), "# Base\n");
      runGitCommand(["add", "-A"], baseRepo);
      runGitCommand(["commit", "-m", "init"], baseRepo);

      const worktreePath = path.join(tempDir, "worktree-1");
      const res = createWorktreeWorkspaceSync(baseRepo, worktreePath, "feature/worktree");

      expect(res.ok).toBe(true);
      expect(fs.existsSync(worktreePath)).toBe(true);

      const branch = runGitCommand(["rev-parse", "--abbrev-ref", "HEAD"], worktreePath);
      expect(branch.stdout).toBe("feature/worktree");
    });
  });
});
