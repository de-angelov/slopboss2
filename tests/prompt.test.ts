import { describe, expect, it } from "bun:test";
import { Effect } from "effect";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import type { TaskBlock } from "../src/domain/boardstore.js";
import {
  buildDevAgentPrompt,
  buildDevAgentPromptEffect,
  buildDevAgentPromptFun,
  buildTeamLeadPrompt,
  buildTeamLeadPromptEffect,
  buildTeamLeadPromptFun,
  DEFAULT_AGENTS_GUIDELINES,
  DEFAULT_DEV_AGENT_GUIDELINES,
  DEFAULT_TEAM_LEAD_GUIDELINES,
  readOptionalFile,
} from "../src/services/prompt.js";

const sampleDevTask: TaskBlock = {
  id: "SB2-99",
  title: "Implement Test Runner Feature",
  category: "Core Service",
  owner: "Dev Agent 2",
  branch: "agent/2/sb2-99-runner",
  status: "In Progress",
  dependencies: ["SB2-01", "SB2-02"],
  objective: "Implement a robust test runner service that executes targeted tests.",
  scope: "- Add runner service\n- Support timeout handling\n- Add unit tests",
  acceptanceCriteria: "- All tests pass cleanly with `bun test`\n- Timeout triggers cleanup",
  rawBody: "",
};

describe("Dynamic Agent Prompt Builder Service", () => {
  describe("buildDevAgentPrompt", () => {
    it("generates complete dev prompt containing task objective and acceptance criteria", () => {
      const prompt = buildDevAgentPrompt("/non/existent/dir", sampleDevTask, "Dev Agent 2");

      // Role and metadata
      expect(prompt).toContain("Active role: Dev Agent 2");
      expect(prompt).toContain("Assigned branch: agent/2/sb2-99-runner");
      expect(prompt).toContain("Task ID: SB2-99");
      expect(prompt).toContain("Implement Test Runner Feature");
      expect(prompt).toContain("Category: Core Service");
      expect(prompt).toContain("Status: In Progress");
      expect(prompt).toContain("Dependencies: SB2-01, SB2-02");

      // Task body details
      expect(prompt).toContain("Objective:");
      expect(prompt).toContain("Implement a robust test runner service that executes targeted tests.");
      expect(prompt).toContain("Scope:");
      expect(prompt).toContain("- Add runner service");
      expect(prompt).toContain("Acceptance Criteria:");
      expect(prompt).toContain("- All tests pass cleanly with `bun test`");

      // Instructions
      expect(prompt).toContain("bun test");
      expect(prompt).toContain("atomic commit");
      expect(prompt).toContain("agent/2/sb2-99-runner");
      expect(prompt).toContain("squash-merge");
    });

    it("reads AGENTS.md and DEV_AGENT.md from disk when available", () => {
      const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), "slopboss-prompt-test-"));
      try {
        fs.writeFileSync(path.join(tempDir, "AGENTS.md"), "# Custom Agents Guidelines\nFollow custom rule 123.", "utf-8");
        fs.writeFileSync(path.join(tempDir, "DEV_AGENT.md"), "# Custom Dev Guidelines\nAlways write tests first.", "utf-8");
        fs.writeFileSync(path.join(tempDir, "TECH.md"), "# Tech Guidelines\nBun 1.4 runtime required.", "utf-8");

        const prompt = buildDevAgentPrompt(tempDir, sampleDevTask, "Dev Agent 1");

        expect(prompt).toContain("Custom Agents Guidelines");
        expect(prompt).toContain("Follow custom rule 123.");
        expect(prompt).toContain("Custom Dev Guidelines");
        expect(prompt).toContain("Always write tests first.");
        expect(prompt).toContain("Bun 1.4 runtime required.");
      } finally {
        fs.rmSync(tempDir, { recursive: true, force: true });
      }
    });

    it("handles missing optional files gracefully with sensible fallbacks", () => {
      const nonExistentDir = path.join(os.tmpdir(), "does-not-exist-" + Date.now());
      const prompt = buildDevAgentPrompt(nonExistentDir, sampleDevTask, "Dev Agent 2");

      expect(prompt).toContain(DEFAULT_AGENTS_GUIDELINES);
      expect(prompt).toContain(DEFAULT_DEV_AGENT_GUIDELINES);
      expect(prompt).toContain("Objective:");
      expect(prompt).toContain(sampleDevTask.objective);
    });

    it("supports Effect wrapper buildDevAgentPromptEffect", async () => {
      const prompt = await Effect.runPromise(
        buildDevAgentPromptEffect("/tmp", sampleDevTask, "Dev Agent 1")
      );
      expect(prompt).toContain("Task ID: SB2-99");
      expect(prompt).toContain("Acceptance Criteria:");
    });

    it("supports FunScript export buildDevAgentPromptFun", () => {
      const prompt = buildDevAgentPromptFun("/tmp", sampleDevTask, "Dev Agent 2");
      expect(prompt).toContain("Task ID: SB2-99");
      expect(prompt).toContain("Active role: Dev Agent 2");
    });
  });

  describe("buildTeamLeadPrompt", () => {
    const activeTasks: TaskBlock[] = [
      {
        id: "SB2-10",
        title: "Locking Service",
        category: "Core Service",
        owner: "Dev Agent 1",
        branch: "agent/1/sb2-10-lock",
        status: "In Progress",
        dependencies: [],
        objective: "Add advisory lock.",
        scope: "Implement file lock.",
        acceptanceCriteria: "Tests pass.",
        rawBody: "",
      },
      {
        id: "SB2-13",
        title: "Prompt Builder",
        category: "Core Service",
        owner: "Dev Agent 2",
        branch: "agent/2/sb2-13-prompt",
        status: "In Progress",
        dependencies: ["SB2-11"],
        objective: "Dynamic prompt generator.",
        scope: "Add prompt.fun.",
        acceptanceCriteria: "Unit tests pass.",
        rawBody: "",
      },
    ];

    it("generates team lead prompt containing backlog and current lanes", () => {
      const backlog = "# BACKLOG\n\n- [ ] SB2-15: Notification Service\n- [ ] SB2-16: Metrics Dashboard";
      const prompt = buildTeamLeadPrompt("/tmp", backlog, activeTasks);

      // Role and headers
      expect(prompt).toContain("Active role: Team Lead Agent");
      expect(prompt).toContain("================ CURRENT BACKLOG ================");
      expect(prompt).toContain("SB2-15: Notification Service");
      expect(prompt).toContain("SB2-16: Metrics Dashboard");

      // Active lanes
      expect(prompt).toContain("================ ACTIVE LANES & TASKS ================");
      expect(prompt).toContain("Lane 1 (Dev Agent 1):");
      expect(prompt).toContain("Task ID: SB2-10");
      expect(prompt).toContain("Locking Service");
      expect(prompt).toContain("agent/1/sb2-10-lock");

      expect(prompt).toContain("Lane 2 (Dev Agent 2):");
      expect(prompt).toContain("Task ID: SB2-13");
      expect(prompt).toContain("Prompt Builder");
      expect(prompt).toContain("Dependencies: SB2-11");

      // Grooming instructions
      expect(prompt).toContain("================ GROOMING & ASSIGNMENT INSTRUCTIONS ================");
      expect(prompt).toContain("Review prioritized tasks in BACKLOG.md");
      expect(prompt).toContain("Format task specifications for TASKS.md");
      expect(prompt).toContain("Write groomed task allocations to TASKS.md");
    });

    it("reads TEAM_LEAD_AGENT.md from disk when available", () => {
      const tempDir = fs.mkdtempSync(path.join(os.tmpdir(), "slopboss-tl-prompt-test-"));
      try {
        fs.writeFileSync(path.join(tempDir, "TEAM_LEAD_AGENT.md"), "# Custom Team Lead Rules\nTurn approved goals into tasks.", "utf-8");
        const prompt = buildTeamLeadPrompt(tempDir, "# Backlog", []);

        expect(prompt).toContain("Custom Team Lead Rules");
        expect(prompt).toContain("Turn approved goals into tasks.");
      } finally {
        fs.rmSync(tempDir, { recursive: true, force: true });
      }
    });

    it("handles idle lanes and missing optional files gracefully", () => {
      const nonExistentDir = path.join(os.tmpdir(), "does-not-exist-" + Date.now());
      const prompt = buildTeamLeadPrompt(nonExistentDir, "", []);

      expect(prompt).toContain(DEFAULT_TEAM_LEAD_GUIDELINES);
      expect(prompt).toContain(DEFAULT_AGENTS_GUIDELINES);
      expect(prompt).toContain("No pending backlog items");
      expect(prompt).toContain("All lanes are idle and ready for assignment");
    });

    it("supports Effect wrapper buildTeamLeadPromptEffect", async () => {
      const prompt = await Effect.runPromise(
        buildTeamLeadPromptEffect("/tmp", "- [ ] Task 1", activeTasks)
      );
      expect(prompt).toContain("Active role: Team Lead Agent");
      expect(prompt).toContain("Task 1");
    });

    it("supports FunScript export buildTeamLeadPromptFun", () => {
      const prompt = buildTeamLeadPromptFun("/tmp", "- [ ] Backlog Task", activeTasks);
      expect(prompt).toContain("Active role: Team Lead Agent");
      expect(prompt).toContain("Backlog Task");
    });
  });

  describe("readOptionalFile helper", () => {
    it("returns file content when file exists and is non-empty", () => {
      const tempFile = path.join(os.tmpdir(), `test-read-${Date.now()}.txt`);
      fs.writeFileSync(tempFile, "Hello World", "utf-8");
      try {
        expect(readOptionalFile(tempFile, "fallback")).toBe("Hello World");
      } finally {
        fs.rmSync(tempFile, { force: true });
      }
    });

    it("returns fallback when file does not exist", () => {
      expect(readOptionalFile("/no/such/file.txt", "my-fallback")).toBe("my-fallback");
    });

    it("returns fallback when file is empty", () => {
      const tempFile = path.join(os.tmpdir(), `test-empty-${Date.now()}.txt`);
      fs.writeFileSync(tempFile, "   \n\n  ", "utf-8");
      try {
        expect(readOptionalFile(tempFile, "fallback-empty")).toBe("fallback-empty");
      } finally {
        fs.rmSync(tempFile, { force: true });
      }
    });
  });
});
