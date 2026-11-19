import { Array, Option, Schema, String, Effect } from "effect"
import { TaskBlock } from "../domain/boardstore.js"

ts {
  import * as fs from "node:fs";
  import * as path from "node:path";

  export function readOptionalFile(filePath: string, fallback: string): string {
    try {
      if (filePath && fs.existsSync(filePath)) {
        const content = fs.readFileSync(filePath, "utf-8").trim();
        if (content) return content;
      }
    } catch (_e) {
      // Graceful fallback on read or access failure
    }
    return fallback;
  }

  export const DEFAULT_AGENTS_GUIDELINES = `# AI Development Workflow (Fallback Rules)

## General Principles
- Work within your designated workspace and branch.
- Keep changes focused on the assigned task.
- Follow the board lifecycle: BACKLOG.md -> TASKS.md -> ARCHIVE.md.
- Ensure all work is test-backed and independently verifiable.`;

  export const DEFAULT_DEV_AGENT_GUIDELINES = `# Dev Agent Role Instructions (Fallback Rules)

## Responsibilities
- Execute the assigned task autonomously to completion.
- Write or update focused tests covering changes.
- Verify changes with test suite before marking task complete.
- Follow atomic commit hygiene and squash-merge completed branches.`;

  export const DEFAULT_TEAM_LEAD_GUIDELINES = `# Team Lead Agent Role Instructions (Fallback Rules)

## Responsibilities
- Review backlog items and prioritize work according to dependencies.
- Groom tasks with clear Task ID, Category, Owner, Branch, Status, Objective, Scope, and Acceptance Criteria.
- Assign ready tasks to available idle Dev Agent execution lanes.
- Coordinate dependencies and avoid overlapping file ownership across lanes.`;

  export function buildDevAgentPrompt(
    boardDir: string,
    task: TaskBlock,
    agentName: string
  ): string {
    const agentsPath = boardDir ? path.join(boardDir, "AGENTS.md") : "";
    const devPath = boardDir ? path.join(boardDir, "DEV_AGENT.md") : "";
    const techPath = boardDir ? path.join(boardDir, "TECH.md") : "";

    const agentsContent = readOptionalFile(agentsPath, DEFAULT_AGENTS_GUIDELINES);
    const devAgentContent = readOptionalFile(devPath, DEFAULT_DEV_AGENT_GUIDELINES);
    const techContent = readOptionalFile(techPath, "");

    const deps =
      task && task.dependencies && task.dependencies.length > 0
        ? task.dependencies.join(", ")
        : "none";

    const sections: string[] = [
      `You are running inside the multi-agent development workflow.`,
      `Active role: ${agentName || "Dev Agent"}`,
      `Board root: ${boardDir || "."}`,
      `Assigned branch: ${task ? task.branch : "agent/branch"}`,
      ``,
      `================ AGENTS.md COMMON RULES ================`,
      agentsContent,
      ``,
      `================ DEV_AGENT.md ROLE INSTRUCTIONS ================`,
      devAgentContent,
    ];

    if (techContent) {
      sections.push(
        ``,
        `================ TECH.md ================`,
        techContent
      );
    }

    sections.push(
      ``,
      `================ WORKFLOW & EXECUTION INSTRUCTIONS ================`,
      `- Test verification: Run \`bun test\` or targeted test suite (e.g. \`bun test tests/<target>.test.ts\`) during development and as the final merge gate.`,
      `- Atomic commits: Make focused, descriptive atomic commits (e.g. \`feat(...)\`, \`fix(...)\`, \`refactor(...)\`).`,
      `- Git branching: Work exclusively in the assigned branch \`${task ? task.branch : "agent/branch"}\`, verify zero uncommitted or unmerged changes, and squash-merge into product main upon completion.`,
      ``,
      `================ ACTIVE TASK ================`,
      `### ${task ? task.title : "Untitled Task"}`,
      ``,
      `Task ID: ${task ? task.id : "UNKNOWN"}`,
      `Category: ${task && task.category ? task.category : "Development"}`,
      `Owner: ${task && task.owner ? task.owner : agentName || "Dev Agent"}`,
      `Branch: ${task && task.branch ? task.branch : "unknown"}`,
      `Status: ${task && task.status ? task.status : "In Progress"}`,
      `Dependencies: ${deps}`,
      ``,
      `Objective:`,
      `${task && task.objective ? task.objective : "No objective provided."}`,
      ``,
      `Scope:`,
      `${task && task.scope ? task.scope : "No scope specified."}`,
      ``,
      `Acceptance Criteria:`,
      `${task && task.acceptanceCriteria ? task.acceptanceCriteria : "No acceptance criteria specified."}`
    );

    return sections.join("\n");
  }

  export function buildTeamLeadPrompt(
    boardDir: string,
    backlogContent: string,
    activeTasks: readonly TaskBlock[] = []
  ): string {
    const tlPath = boardDir ? path.join(boardDir, "TEAM_LEAD_AGENT.md") : "";
    const agentsPath = boardDir ? path.join(boardDir, "AGENTS.md") : "";

    const tlContent = readOptionalFile(tlPath, DEFAULT_TEAM_LEAD_GUIDELINES);
    const agentsContent = readOptionalFile(agentsPath, DEFAULT_AGENTS_GUIDELINES);

    let lanesSection: string;
    if (activeTasks && activeTasks.length > 0) {
      const taskLines = activeTasks.map((t, idx) => {
        const deps = t.dependencies && t.dependencies.length > 0 ? t.dependencies.join(", ") : "none";
        return [
          `Lane ${idx + 1} (${t.owner || "Unassigned"}):`,
          `  - Task ID: ${t.id}`,
          `  - Title: ${t.title || "Untitled"}`,
          `  - Branch: ${t.branch || "none"}`,
          `  - Status: ${t.status || "In Progress"}`,
          `  - Dependencies: ${deps}`,
          `  - Objective: ${t.objective ? t.objective.replace(/\n+/g, " ") : "N/A"}`
        ].join("\n");
      });
      lanesSection = taskLines.join("\n\n");
    } else {
      lanesSection = "No active tasks in progress across agent lanes. All lanes are idle and ready for assignment.";
    }

    const cleanBacklog = backlogContent && backlogContent.trim()
      ? backlogContent.trim()
      : "# BACKLOG\n\nNo pending backlog items.";

    const sections: string[] = [
      `You are running inside the multi-agent development workflow.`,
      `Active role: Team Lead Agent`,
      `Board root: ${boardDir || "."}`,
      ``,
      `================ TEAM_LEAD_AGENT.md ROLE INSTRUCTIONS ================`,
      tlContent,
      ``,
      `================ AGENTS.md COMMON RULES ================`,
      agentsContent,
      ``,
      `================ CURRENT BACKLOG ================`,
      cleanBacklog,
      ``,
      `================ ACTIVE LANES & TASKS ================`,
      lanesSection,
      ``,
      `================ GROOMING & ASSIGNMENT INSTRUCTIONS ================`,
      `1. Review prioritized tasks in BACKLOG.md and verify readiness and dependencies.`,
      `2. Format task specifications for TASKS.md including Task ID, Category, Owner, Branch, Status, Objective, Scope, and Acceptance Criteria.`,
      `3. Write groomed task allocations to TASKS.md and update BACKLOG.md.`,
      `4. Ensure non-overlapping scope and file ownership between active agents to prevent merge conflicts.`
    ];

    return sections.join("\n");
  }

  export function buildDevAgentPromptEffect(
    boardDir: string,
    task: TaskBlock,
    agentName: string
  ): Effect.Effect<string, never> {
    return Effect.sync(() => buildDevAgentPrompt(boardDir, task, agentName));
  }

  export function buildTeamLeadPromptEffect(
    boardDir: string,
    backlogContent: string,
    activeTasks: readonly TaskBlock[] = []
  ): Effect.Effect<string, never> {
    return Effect.sync(() => buildTeamLeadPrompt(boardDir, backlogContent, activeTasks));
  }
}

export buildDevAgentPromptFun = (boardDir: String, task: TaskBlock, agentName: String) =>
  buildDevAgentPrompt(boardDir, task, agentName)

export buildTeamLeadPromptFun = (boardDir: String, backlogContent: String, activeTasks: Array<TaskBlock>) =>
  buildTeamLeadPrompt(boardDir, backlogContent, activeTasks)
