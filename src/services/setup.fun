import { Array, Console, Effect, Option, Schema, String } from "effect"

ts {
  import * as fs from "node:fs";
  import * as path from "node:path";
  import {
    DEFAULT_AGENTS_GUIDELINES,
    DEFAULT_DEV_AGENT_GUIDELINES,
    DEFAULT_TEAM_LEAD_GUIDELINES,
  } from "./prompt.js";
  import { runDoctorSync, type DoctorReportTs } from "./doctor.js";

  export interface WorkspaceInfoTs {
    name: string;
    path: string;
    exists: boolean;
    isGitRepo: boolean;
    currentBranch: string;
    isClean: boolean;
  }

  export interface WorkspacesReadyReportTs {
    name: string;
    ok: boolean;
    message: string;
    required: boolean;
    devAgentCount: number;
    workspacesDir: string;
    workspaces: WorkspaceInfoTs[];
  }

  export interface BoardInitResultTs {
    ok: boolean;
    boardDir: string;
    repoUrl: string;
    devAgentCount: number;
    filesCreated: string[];
    workspacesCreated: string[];
    message: string;
  }

  export interface GitCommandResult {
    exitCode: number;
    stdout: string;
    stderr: string;
  }

  export function runGitCommand(args: string[], cwd?: string): GitCommandResult {
    try {
      const proc = Bun.spawnSync(["git", ...args], {
        cwd: cwd || undefined,
        env: {
          ...process.env,
          GIT_TERMINAL_PROMPT: "0",
          GIT_AUTHOR_NAME: process.env.GIT_AUTHOR_NAME || "Slopboss",
          GIT_AUTHOR_EMAIL: process.env.GIT_AUTHOR_EMAIL || "slopboss@local",
          GIT_COMMITTER_NAME: process.env.GIT_COMMITTER_NAME || "Slopboss",
          GIT_COMMITTER_EMAIL: process.env.GIT_COMMITTER_EMAIL || "slopboss@local",
        },
      });
      return {
        exitCode: proc.exitCode ?? 1,
        stdout: proc.stdout.toString().trim(),
        stderr: proc.stderr.toString().trim(),
      };
    } catch (err: any) {
      return {
        exitCode: 1,
        stdout: "",
        stderr: err?.message || String(err),
      };
    }
  }

  export function generateTasksMarkdown(devAgentCount: number = 2): string {
    const count = Math.max(1, devAgentCount || 2);
    let md = "# TASKS\n\nActive work board for slopboss2.\n\n";
    for (let i = 1; i <= count; i++) {
      md += `## Dev Agent ${i} In Progress\n\n`;
    }
    return md;
  }

  export function generateBacklogMarkdown(): string {
    return "# BACKLOG\n\nPending unassigned work for slopboss2.\n";
  }

  export function generateArchiveMarkdown(): string {
    return "# ARCHIVE\n\nCompleted tasks for slopboss2.\n";
  }

  export function scaffoldBoardMarkdownSync(
    boardDir: string,
    devAgentCount: number = 2
  ): string[] {
    if (!fs.existsSync(boardDir)) {
      fs.mkdirSync(boardDir, { recursive: true });
    }

    const filesToScaffold: Record<string, string> = {
      "TASKS.md": generateTasksMarkdown(devAgentCount),
      "BACKLOG.md": generateBacklogMarkdown(),
      "ARCHIVE.md": generateArchiveMarkdown(),
      "AGENTS.md": DEFAULT_AGENTS_GUIDELINES,
      "DEV_AGENT.md": DEFAULT_DEV_AGENT_GUIDELINES,
      "TEAM_LEAD_AGENT.md": DEFAULT_TEAM_LEAD_GUIDELINES,
    };

    const filesCreated: string[] = [];

    for (const [filename, content] of Object.entries(filesToScaffold)) {
      const filePath = path.join(boardDir, filename);
      if (!fs.existsSync(filePath)) {
        fs.writeFileSync(filePath, content, "utf-8");
        filesCreated.push(filename);
      }
    }

    return filesCreated;
  }

  export function ensureCleanGitMain(wsPath: string): { ok: boolean; message: string } {
    const isGit = runGitCommand(["rev-parse", "--is-inside-work-tree"], wsPath);
    if (isGit.exitCode !== 0 || isGit.stdout !== "true") {
      return { ok: false, message: `Not a git repository: ${wsPath}` };
    }

    const status = runGitCommand(["status", "--porcelain"], wsPath);
    const isClean = status.exitCode === 0 && status.stdout === "";

    const branchRes = runGitCommand(["rev-parse", "--abbrev-ref", "HEAD"], wsPath);
    const currentBranch = branchRes.exitCode === 0 ? branchRes.stdout : "";

    if (currentBranch === "main") {
      return { ok: isClean, message: isClean ? "Clean on main" : "Uncommitted changes on main" };
    }

    if (isClean) {
      const hasMain = runGitCommand(["rev-parse", "--verify", "main"], wsPath);
      if (hasMain.exitCode === 0) {
        const checkoutRes = runGitCommand(["checkout", "main"], wsPath);
        if (checkoutRes.exitCode === 0) {
          return { ok: true, message: "Checked out main" };
        }
      } else {
        const createBranchRes = runGitCommand(["checkout", "-b", "main"], wsPath);
        if (createBranchRes.exitCode === 0) {
          return { ok: true, message: "Created and checked out main" };
        }
      }
    }

    return {
      ok: false,
      message: `On branch ${currentBranch || "unknown"} (clean: ${isClean})`,
    };
  }

  export function initWorkspaceRepoSync(
    wsPath: string,
    repoUrl: string,
    fallbackBaseRepo?: string
  ): { ok: boolean; path: string; method: string; message: string } {
    if (fs.existsSync(wsPath)) {
      const gitCheck = runGitCommand(["rev-parse", "--is-inside-work-tree"], wsPath);
      if (gitCheck.exitCode === 0 && gitCheck.stdout === "true") {
        ensureCleanGitMain(wsPath);
        return {
          ok: true,
          path: wsPath,
          method: "existing",
          message: "Existing git repository preserved",
        };
      }

      runGitCommand(["init", "-b", "main"], wsPath);
      const headCheck = runGitCommand(["rev-parse", "HEAD"], wsPath);
      if (headCheck.exitCode !== 0) {
        fs.writeFileSync(
          path.join(wsPath, "README.md"),
          "# Slopboss Workspace\n",
          "utf-8"
        );
        runGitCommand(["add", "-A"], wsPath);
        runGitCommand(["commit", "-m", "Initial commit on main"], wsPath);
      }
      return {
        ok: true,
        path: wsPath,
        method: "init",
        message: "Initialized git in existing directory",
      };
    }

    fs.mkdirSync(path.dirname(wsPath), { recursive: true });

    if (repoUrl && repoUrl.trim() !== "") {
      const cloneWithBranch = runGitCommand([
        "clone",
        "--branch",
        "main",
        repoUrl,
        wsPath,
      ]);
      if (cloneWithBranch.exitCode === 0) {
        ensureCleanGitMain(wsPath);
        return {
          ok: true,
          path: wsPath,
          method: "clone",
          message: `Cloned from ${repoUrl}`,
        };
      }

      const cloneDefault = runGitCommand(["clone", repoUrl, wsPath]);
      if (cloneDefault.exitCode === 0) {
        ensureCleanGitMain(wsPath);
        return {
          ok: true,
          path: wsPath,
          method: "clone",
          message: `Cloned from ${repoUrl}`,
        };
      }
    }

    if (
      fallbackBaseRepo &&
      fallbackBaseRepo !== wsPath &&
      fs.existsSync(fallbackBaseRepo)
    ) {
      const cloneFromFallback = runGitCommand([
        "clone",
        fallbackBaseRepo,
        wsPath,
      ]);
      if (cloneFromFallback.exitCode === 0) {
        ensureCleanGitMain(wsPath);
        return {
          ok: true,
          path: wsPath,
          method: "clone-fallback",
          message: `Cloned from fallback workspace ${fallbackBaseRepo}`,
        };
      }
    }

    fs.mkdirSync(wsPath, { recursive: true });
    runGitCommand(["init", "-b", "main"], wsPath);
    fs.writeFileSync(
      path.join(wsPath, "README.md"),
      "# Slopboss Workspace\n",
      "utf-8"
    );
    runGitCommand(["add", "-A"], wsPath);
    runGitCommand(["commit", "-m", "Initial commit on main"], wsPath);
    return {
      ok: true,
      path: wsPath,
      method: "init",
      message: "Initialized local git repository on main",
    };
  }

  export function createWorktreeWorkspaceSync(
    baseRepoPath: string,
    worktreePath: string,
    branch: string = "main"
  ): { ok: boolean; path: string; message: string } {
    if (!fs.existsSync(baseRepoPath)) {
      return {
        ok: false,
        path: worktreePath,
        message: `Base repository does not exist: ${baseRepoPath}`,
      };
    }

    if (fs.existsSync(worktreePath)) {
      return {
        ok: true,
        path: worktreePath,
        message: "Worktree path already exists",
      };
    }

    fs.mkdirSync(path.dirname(worktreePath), { recursive: true });

    const addRes = runGitCommand(
      ["worktree", "add", worktreePath, branch],
      baseRepoPath
    );
    if (addRes.exitCode === 0) {
      return {
        ok: true,
        path: worktreePath,
        message: `Added worktree on branch ${branch}`,
      };
    }

    const addNewBranchRes = runGitCommand(
      ["worktree", "add", "-b", branch, worktreePath, "HEAD"],
      baseRepoPath
    );
    if (addNewBranchRes.exitCode === 0) {
      return {
        ok: true,
        path: worktreePath,
        message: `Added worktree on new branch ${branch}`,
      };
    }

    return {
      ok: false,
      path: worktreePath,
      message: `Failed to create worktree: ${addNewBranchRes.stderr || addRes.stderr}`,
    };
  }

  export function provisionWorkspacesSync(
    boardDir: string,
    repoUrl: string,
    devAgentCount: number = 2
  ): string[] {
    const workspacesDir = path.join(boardDir, "workspaces");
    if (!fs.existsSync(workspacesDir)) {
      fs.mkdirSync(workspacesDir, { recursive: true });
    }

    const count = Math.max(1, devAgentCount || 2);
    const workspacesCreated: string[] = [];

    const repoTlPath = path.join(workspacesDir, "repo-tl");
    const existedTl = fs.existsSync(repoTlPath);
    initWorkspaceRepoSync(repoTlPath, repoUrl);
    if (!existedTl) {
      workspacesCreated.push("repo-tl");
    }

    for (let i = 1; i <= count; i++) {
      const agentWsName = `repo-agent-${i}`;
      const agentWsPath = path.join(workspacesDir, agentWsName);
      const existed = fs.existsSync(agentWsPath);
      initWorkspaceRepoSync(agentWsPath, repoUrl, repoTlPath);
      if (!existed) {
        workspacesCreated.push(agentWsName);
      }
    }

    return workspacesCreated;
  }

  export function verifyWorkspacesReadySync(
    boardDir: string,
    devAgentCount: number = 2
  ): WorkspacesReadyReportTs {
    const count = Math.max(1, devAgentCount || 2);
    const workspacesDir = path.join(boardDir, "workspaces");

    if (!fs.existsSync(boardDir) || !fs.statSync(boardDir).isDirectory()) {
      return {
        name: "workspaces",
        ok: false,
        required: true,
        devAgentCount: count,
        workspacesDir,
        workspaces: [],
        message: `Board directory does not exist: ${boardDir}`,
      };
    }

    if (!fs.existsSync(workspacesDir) || !fs.statSync(workspacesDir).isDirectory()) {
      return {
        name: "workspaces",
        ok: false,
        required: true,
        devAgentCount: count,
        workspacesDir,
        workspaces: [],
        message: `Workspaces directory does not exist: ${workspacesDir}`,
      };
    }

    const workspaceNames = ["repo-tl"];
    for (let i = 1; i <= count; i++) {
      workspaceNames.push(`repo-agent-${i}`);
    }

    const workspaces: WorkspaceInfoTs[] = [];
    const failures: string[] = [];

    for (const name of workspaceNames) {
      const wsPath = path.join(workspacesDir, name);
      const exists = fs.existsSync(wsPath) && fs.statSync(wsPath).isDirectory();

      if (!exists) {
        workspaces.push({
          name,
          path: wsPath,
          exists: false,
          isGitRepo: false,
          currentBranch: "",
          isClean: false,
        });
        failures.push(`${name} does not exist`);
        continue;
      }

      const gitCheck = runGitCommand(["rev-parse", "--is-inside-work-tree"], wsPath);
      const isGitRepo = gitCheck.exitCode === 0 && gitCheck.stdout === "true";

      if (!isGitRepo) {
        workspaces.push({
          name,
          path: wsPath,
          exists: true,
          isGitRepo: false,
          currentBranch: "",
          isClean: false,
        });
        failures.push(`${name} is not a git repository`);
        continue;
      }

      const branchRes = runGitCommand(["rev-parse", "--abbrev-ref", "HEAD"], wsPath);
      const currentBranch = branchRes.exitCode === 0 ? branchRes.stdout : "";

      const statusRes = runGitCommand(["status", "--porcelain"], wsPath);
      const isClean = statusRes.exitCode === 0 && statusRes.stdout === "";

      workspaces.push({
        name,
        path: wsPath,
        exists: true,
        isGitRepo: true,
        currentBranch,
        isClean,
      });

      if (currentBranch !== "main") {
        failures.push(`${name} is on branch '${currentBranch}' (expected 'main')`);
      }
      if (!isClean) {
        failures.push(`${name} has uncommitted changes`);
      }
    }

    const ok = failures.length === 0;
    const message = ok
      ? `All ${workspaces.length} workspaces are ready on main branch`
      : `Workspace verification failed: ${failures.join("; ")}`;

    return {
      name: "workspaces",
      ok,
      required: true,
      devAgentCount: count,
      workspacesDir,
      workspaces,
      message,
    };
  }

  export function initBoardStructureSync(
    boardDir: string,
    repoUrl: string = "",
    devAgentCount: number = 2
  ): BoardInitResultTs {
    const count = Math.max(1, devAgentCount || 2);

    const filesCreated = scaffoldBoardMarkdownSync(boardDir, count);
    const workspacesCreated = provisionWorkspacesSync(boardDir, repoUrl, count);
    const verification = verifyWorkspacesReadySync(boardDir, count);

    const ok = verification.ok;
    const message = ok
      ? `Board initialized successfully at ${boardDir} with ${workspacesCreated.length} workspaces created.`
      : `Board scaffolding created with workspace warnings: ${verification.message}`;

    return {
      ok,
      boardDir,
      repoUrl,
      devAgentCount: count,
      filesCreated,
      workspacesCreated,
      message,
    };
  }
}

export schema WorkspaceInfo = {
  name: String
  path: String
  exists: Boolean
  isGitRepo: Boolean
  currentBranch: String
  isClean: Boolean
}

export schema WorkspacesReadyReport = {
  name: String
  ok: Boolean
  message: String
  required: Boolean
  devAgentCount: Number
  workspacesDir: String
  workspaces: Array<WorkspaceInfo>
}

export schema BoardInitResult = {
  ok: Boolean
  boardDir: String
  repoUrl: String
  devAgentCount: Number
  filesCreated: Array<String>
  workspacesCreated: Array<String>
  message: String
}

export initBoardStructure = (boardDir: String, repoUrl: String, devAgentCount: Number) => effect
  => initBoardStructureSync(boardDir, repoUrl, devAgentCount)

export verifyWorkspacesReady = (boardDir: String, devAgentCount: Number) => effect
  => verifyWorkspacesReadySync(boardDir, devAgentCount)

export scaffoldBoardMarkdown = (boardDir: String, devAgentCount: Number) => effect
  => scaffoldBoardMarkdownSync(boardDir, devAgentCount)

export provisionWorkspaces = (boardDir: String, repoUrl: String, devAgentCount: Number) => effect
  => provisionWorkspacesSync(boardDir, repoUrl, devAgentCount)
