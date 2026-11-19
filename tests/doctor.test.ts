import { afterEach, beforeEach, describe, expect, it } from "bun:test";
import { Effect } from "effect";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import {
  checkBoardDirectory,
  checkBoardDirectorySync,
  checkBunInstalled,
  checkBunInstalledSync,
  checkBunInstalledWith,
  checkGitInstalled,
  checkGitInstalledSync,
  checkGitInstalledWith,
  checkProviderInstalled,
  checkProviderInstalledSync,
  checkProviderInstalledWith,
  checkWorkspaces,
  checkWorkspacesSync,
  runDoctor,
  runDoctorSync,
} from "../src/services/doctor.js";

describe("System Health Doctor Service", () => {
  let tempDir: string;

  beforeEach(() => {
    tempDir = fs.mkdtempSync(path.join(os.tmpdir(), "slopboss-doctor-test-"));
  });

  afterEach(() => {
    if (fs.existsSync(tempDir)) {
      fs.rmSync(tempDir, { recursive: true, force: true });
    }
  });

  describe("checkGitInstalled", () => {
    it("detects installed git and returns version info via Effect", async () => {
      const result = await Effect.runPromise(checkGitInstalled());
      expect(result.name).toBe("git");
      expect(result.ok).toBe(true);
      expect(result.required).toBe(true);
      expect(result.message).toContain("git version");
    });

    it("detects installed git synchronously", () => {
      const result = checkGitInstalledSync();
      expect(result.name).toBe("git");
      expect(result.ok).toBe(true);
      expect(result.required).toBe(true);
      expect(result.message).toContain("git version");
    });

    it("reports failure when git binary is missing or invalid", async () => {
      const result = await Effect.runPromise(
        checkGitInstalledWith("nonexistent_git_binary_xyz_123")
      );
      expect(result.name).toBe("git");
      expect(result.ok).toBe(false);
      expect(result.required).toBe(true);
      expect(result.message).toBeTruthy();
    });
  });

  describe("checkBunInstalled", () => {
    it("detects installed bun runtime via Effect", async () => {
      const result = await Effect.runPromise(checkBunInstalled());
      expect(result.name).toBe("bun");
      expect(result.ok).toBe(true);
      expect(result.required).toBe(true);
      expect(result.message).toContain("bun");
    });

    it("detects installed bun runtime synchronously", () => {
      const result = checkBunInstalledSync();
      expect(result.name).toBe("bun");
      expect(result.ok).toBe(true);
      expect(result.required).toBe(true);
    });

    it("reports failure when bun executable is missing", async () => {
      const result = await Effect.runPromise(
        checkBunInstalledWith("nonexistent_bun_binary_xyz_123")
      );
      expect(result.name).toBe("bun");
      expect(result.ok).toBe(false);
      expect(result.required).toBe(true);
      expect(result.message).toBeTruthy();
    });
  });

  describe("checkProviderInstalled", () => {
    it("detects installed provider (agy or gemini) via Effect", async () => {
      const result = await Effect.runPromise(checkProviderInstalled());
      expect(result.name).toBe("provider");
      expect(result.ok).toBe(true);
      expect(result.required).toBe(true);
      expect(result.message.length).toBeGreaterThan(0);
    });

    it("detects provider synchronously", () => {
      const result = checkProviderInstalledSync();
      expect(result.name).toBe("provider");
      expect(result.ok).toBe(true);
      expect(result.required).toBe(true);
    });

    it("reports failure when no supported provider executable is found", async () => {
      const result = await Effect.runPromise(
        checkProviderInstalledWith(["nonexistent_provider_abc", "fake_cli_xyz"])
      );
      expect(result.name).toBe("provider");
      expect(result.ok).toBe(false);
      expect(result.required).toBe(true);
      expect(result.message).toContain("Neither 'agy' nor 'gemini'");
    });
  });

  describe("checkBoardDirectory", () => {
    it("reports error when board directory does not exist", async () => {
      const nonexistent = path.join(tempDir, "does-not-exist");
      const result = await Effect.runPromise(checkBoardDirectory(nonexistent));
      expect(result.name).toBe("board");
      expect(result.ok).toBe(false);
      expect(result.required).toBe(true);
      expect(result.message).toContain("does not exist");
    });

    it("reports error when board directory path is a file", async () => {
      const filePath = path.join(tempDir, "regular-file.txt");
      fs.writeFileSync(filePath, "test");
      const result = await Effect.runPromise(checkBoardDirectory(filePath));
      expect(result.name).toBe("board");
      expect(result.ok).toBe(false);
      expect(result.message).toContain("not a directory");
    });

    it("reports missing required board files (TASKS.md, ARCHIVE.md, AGENTS.md)", async () => {
      // Empty directory
      const result = await Effect.runPromise(checkBoardDirectory(tempDir));
      expect(result.name).toBe("board");
      expect(result.ok).toBe(false);
      expect(result.message).toContain("TASKS.md");
      expect(result.message).toContain("ARCHIVE.md");
      expect(result.message).toContain("AGENTS.md");

      // Only one file present
      fs.writeFileSync(path.join(tempDir, "TASKS.md"), "# Tasks");
      const partialResult = await Effect.runPromise(checkBoardDirectory(tempDir));
      expect(partialResult.ok).toBe(false);
      expect(partialResult.message).toContain("ARCHIVE.md");
      expect(partialResult.message).toContain("AGENTS.md");
    });

    it("succeeds when all required board files are present", async () => {
      fs.writeFileSync(path.join(tempDir, "TASKS.md"), "# Tasks");
      fs.writeFileSync(path.join(tempDir, "ARCHIVE.md"), "# Archive");
      fs.writeFileSync(path.join(tempDir, "AGENTS.md"), "# Agents");

      const result = await Effect.runPromise(checkBoardDirectory(tempDir));
      expect(result.name).toBe("board");
      expect(result.ok).toBe(true);
      expect(result.required).toBe(true);
      expect(result.message).toContain("all required files");
    });

    it("supports synchronous checkBoardDirectorySync", () => {
      fs.writeFileSync(path.join(tempDir, "TASKS.md"), "# Tasks");
      fs.writeFileSync(path.join(tempDir, "ARCHIVE.md"), "# Archive");
      fs.writeFileSync(path.join(tempDir, "AGENTS.md"), "# Agents");

      const result = checkBoardDirectorySync(tempDir);
      expect(result.ok).toBe(true);
    });
  });

  describe("checkWorkspaces", () => {
    it("reports error when board directory does not exist", async () => {
      const result = await Effect.runPromise(
        checkWorkspaces(path.join(tempDir, "missing"))
      );
      expect(result.name).toBe("workspaces");
      expect(result.ok).toBe(false);
      expect(result.message).toContain("does not exist");
    });

    it("reports error when workspaces directory does not exist in board directory", async () => {
      const result = await Effect.runPromise(checkWorkspaces(tempDir));
      expect(result.name).toBe("workspaces");
      expect(result.ok).toBe(false);
      expect(result.message).toContain("Workspaces directory does not exist");
    });

    it("reports error when workspaces path is a file", async () => {
      fs.writeFileSync(path.join(tempDir, "workspaces"), "not a dir");
      const result = await Effect.runPromise(checkWorkspaces(tempDir));
      expect(result.name).toBe("workspaces");
      expect(result.ok).toBe(false);
      expect(result.message).toContain("not a directory");
    });

    it("succeeds when workspaces directory exists and is accessible", async () => {
      fs.mkdirSync(path.join(tempDir, "workspaces"), { recursive: true });
      const result = await Effect.runPromise(checkWorkspaces(tempDir));
      expect(result.name).toBe("workspaces");
      expect(result.ok).toBe(true);
      expect(result.required).toBe(true);
      expect(result.message).toContain("read/write access");
    });

    it("supports synchronous checkWorkspacesSync", () => {
      fs.mkdirSync(path.join(tempDir, "workspaces"), { recursive: true });
      const result = checkWorkspacesSync(tempDir);
      expect(result.ok).toBe(true);
    });
  });

  describe("runDoctor", () => {
    it("aggregates all checks and reports isHealthy=true in a valid environment", async () => {
      // Set up required files and workspaces
      fs.writeFileSync(path.join(tempDir, "TASKS.md"), "# Tasks");
      fs.writeFileSync(path.join(tempDir, "ARCHIVE.md"), "# Archive");
      fs.writeFileSync(path.join(tempDir, "AGENTS.md"), "# Agents");
      fs.mkdirSync(path.join(tempDir, "workspaces"), { recursive: true });

      const report = await Effect.runPromise(runDoctor(tempDir));
      expect(report.isHealthy).toBe(true);
      expect(report.checks.length).toBe(5);

      const checkNames = report.checks.map((c) => c.name);
      expect(checkNames).toContain("git");
      expect(checkNames).toContain("bun");
      expect(checkNames).toContain("provider");
      expect(checkNames).toContain("board");
      expect(checkNames).toContain("workspaces");

      expect(report.checks.every((c) => c.ok)).toBe(true);
    });

    it("reports isHealthy=false when board files or workspaces are missing", async () => {
      // Empty directory without files or workspaces
      const report = await Effect.runPromise(runDoctor(tempDir));
      expect(report.isHealthy).toBe(false);
      expect(report.checks.length).toBe(5);

      const boardCheck = report.checks.find((c) => c.name === "board");
      const workspacesCheck = report.checks.find((c) => c.name === "workspaces");
      expect(boardCheck?.ok).toBe(false);
      expect(workspacesCheck?.ok).toBe(false);
    });

    it("supports synchronous runDoctorSync", () => {
      fs.writeFileSync(path.join(tempDir, "TASKS.md"), "# Tasks");
      fs.writeFileSync(path.join(tempDir, "ARCHIVE.md"), "# Archive");
      fs.writeFileSync(path.join(tempDir, "AGENTS.md"), "# Agents");
      fs.mkdirSync(path.join(tempDir, "workspaces"), { recursive: true });

      const report = runDoctorSync(tempDir);
      expect(report.isHealthy).toBe(true);
      expect(report.checks.length).toBe(5);
    });
  });
});
