import { Array, Effect, Option, Schema, String } from "effect"
import { FileSystem, Path } from "effect"
import { BunServices } from "@effect/platform-bun"
import { SyncServices, runSyncWithPlatform } from "./sys.js"

export schema TaskBlock = {
  id: String
  title: String
  category: String
  owner: String
  branch: String
  status: String
  dependencies: Array<String>
  objective: String
  scope: String
  acceptanceCriteria: String
  rawBody: String
}

export DEFAULT_AGENTS_GUIDELINES = "# AI Development Workflow (Fallback Rules)\n\n## General Principles\n- Work within your designated workspace and branch.\n- Keep changes focused on the assigned task.\n- Follow the board lifecycle: BACKLOG.md -> TASKS.md -> ARCHIVE.md.\n- Ensure all work is test-backed and independently verifiable."

export DEFAULT_DEV_AGENT_GUIDELINES = "# Dev Agent Role Instructions (Fallback Rules)\n\n## Responsibilities\n- Execute the assigned task autonomously to completion.\n- Write or update focused tests covering changes.\n- Verify changes with test suite before marking task complete.\n- Follow atomic commit hygiene and squash-merge completed branches."

export DEFAULT_TEAM_LEAD_GUIDELINES = "# Team Lead Agent Role Instructions (Fallback Rules)\n\n## Responsibilities\n- Review backlog items and prioritize work according to dependencies.\n- Groom tasks with clear Task ID, Category, Owner, Branch, Status, Objective, Scope, and Acceptance Criteria.\n- Assign ready tasks to available idle Dev Agent execution lanes.\n- Coordinate dependencies and avoid overlapping file ownership across lanes."

export readOptionalFileWorkflow = (filePath: String, fallback: String) => effect {
  when (not filePath or filePath #= "") => fallback
  fs <- FileSystem.FileSystem
  exists <- fs.exists(filePath) |> Effect.catch((_) => Effect.succeed(false))
  when (not exists) => fallback
  content <- fs.readFileString(filePath) |> Effect.catch((_) => Effect.succeed(""))
  trimmed = content |> String.trim
  when (trimmed #= "") => fallback
  => trimmed
}

export readOptionalFileEffect = (filePath: String, fallback: String) => {
  => readOptionalFileWorkflow(filePath, fallback) |> Effect.provide(BunServices.layer)
}

export readOptionalFile = (filePath: String, fallback: String) => {
  => runSyncWithPlatform(readOptionalFileWorkflow(filePath, fallback))
}

export buildDevAgentPromptWorkflow = (boardDir: String, task: TaskBlock, agentName: String) => effect {
  pathService <- Path.Path

  agentsPath = match (not boardDir or boardDir #= "")
    | true => ""
    | false => pathService.join(boardDir, "AGENTS.md")

  devPath = match (not boardDir or boardDir #= "")
    | true => ""
    | false => pathService.join(boardDir, "DEV_AGENT.md")

  techPath = match (not boardDir or boardDir #= "")
    | true => ""
    | false => pathService.join(boardDir, "TECH.md")

  agentsContent <- readOptionalFileWorkflow(agentsPath, DEFAULT_AGENTS_GUIDELINES)
  devAgentContent <- readOptionalFileWorkflow(devPath, DEFAULT_DEV_AGENT_GUIDELINES)
  techContent <- readOptionalFileWorkflow(techPath, "")

  role = match (not agentName or agentName #= "")
    | true => "Dev Agent"
    | false => agentName

  boardRoot = match (not boardDir or boardDir #= "")
    | true => "."
    | false => boardDir

  taskBranch = match (not task or not task.branch or task.branch #= "")
    | true => "agent/branch"
    | false => task.branch

  taskTitle = match (not task or not task.title or task.title #= "")
    | true => "Untitled Task"
    | false => task.title

  taskId = match (not task or not task.id or task.id #= "")
    | true => "UNKNOWN"
    | false => task.id

  taskCategory = match (not task or not task.category or task.category #= "")
    | true => "Development"
    | false => task.category

  taskOwner = match (not task or not task.owner or task.owner #= "")
    | true => role
    | false => task.owner

  taskStatus = match (not task or not task.status or task.status #= "")
    | true => "In Progress"
    | false => task.status

  deps = match (not task or not task.dependencies or task.dependencies.length #= 0)
    | true => "none"
    | false => task.dependencies |> Array.join(", ")

  taskObjective = match (not task or not task.objective or task.objective #= "")
    | true => "No objective provided."
    | false => task.objective

  taskScope = match (not task or not task.scope or task.scope #= "")
    | true => "No scope specified."
    | false => task.scope

  taskAcceptanceCriteria = match (not task or not task.acceptanceCriteria or task.acceptanceCriteria #= "")
    | true => "No acceptance criteria specified."
    | false => task.acceptanceCriteria

  baseSections = [
    "You are running inside the multi-agent development workflow.",
    "Active role: " + role,
    "Board root: " + boardRoot,
    "Assigned branch: " + taskBranch,
    "",
    "================ AGENTS.md COMMON RULES ================",
    agentsContent,
    "",
    "================ DEV_AGENT.md ROLE INSTRUCTIONS ================",
    devAgentContent
  ]

  techSections = match (techContent #= "")
    | true => []
    | false => [
        "",
        "================ TECH.md ================",
        techContent
      ]

  tailSections = [
    "",
    "================ WORKFLOW & EXECUTION INSTRUCTIONS ================",
    "- Test verification: Run `bun test` or targeted test suite (e.g. `bun test tests/<target>.test.ts`) during development and as the final merge gate.",
    "- Atomic commits: Make focused, descriptive atomic commits (e.g. `feat(...)`, `fix(...)`, `refactor(...)`).",
    "- Git branching: Work exclusively in the assigned branch `" + taskBranch + "`, verify zero uncommitted or unmerged changes, and squash-merge into product main upon completion.",
    "",
    "================ ACTIVE TASK ================",
    "### " + taskTitle,
    "",
    "Task ID: " + taskId,
    "Category: " + taskCategory,
    "Owner: " + taskOwner,
    "Branch: " + taskBranch,
    "Status: " + taskStatus,
    "Dependencies: " + deps,
    "",
    "Objective:",
    taskObjective,
    "",
    "Scope:",
    taskScope,
    "",
    "Acceptance Criteria:",
    taskAcceptanceCriteria
  ]

  allSections = baseSections |> Array.appendAll(techSections) |> Array.appendAll(tailSections)
  => allSections |> Array.join("\n")
}

export buildDevAgentPromptEffect = (boardDir: String, task: TaskBlock, agentName: String) => {
  => buildDevAgentPromptWorkflow(boardDir, task, agentName) |> Effect.provide(BunServices.layer)
}

export buildDevAgentPrompt = (boardDir: String, task: TaskBlock, agentName: String) => {
  => runSyncWithPlatform(buildDevAgentPromptWorkflow(boardDir, task, agentName))
}

export buildDevAgentPromptFun = (boardDir: String, task: TaskBlock, agentName: String) => {
  => buildDevAgentPrompt(boardDir, task, agentName)
}

formatActiveTasks = (activeTasks: Array<TaskBlock>) => {
  pattern = RegExp("\\n+", "g")
  taskLines = activeTasks |> Array.map((t: TaskBlock, idx: Number) => {
    owner = match (not t.owner or t.owner #= "")
      | true => "Unassigned"
      | false => t.owner

    title = match (not t.title or t.title #= "")
      | true => "Untitled"
      | false => t.title

    branch = match (not t.branch or t.branch #= "")
      | true => "none"
      | false => t.branch

    status = match (not t.status or t.status #= "")
      | true => "In Progress"
      | false => t.status

    deps = match (not t.dependencies or t.dependencies.length #= 0)
      | true => "none"
      | false => t.dependencies |> Array.join(", ")

    cleanObj = match (not t.objective or t.objective #= "")
      | true => "N/A"
      | false => t.objective |> String.replace(pattern, " ")

    laneNum = "" + (idx + 1)
    lines = [
      "Lane " + laneNum + " (" + owner + "):",
      "  - Task ID: " + t.id,
      "  - Title: " + title,
      "  - Branch: " + branch,
      "  - Status: " + status,
      "  - Dependencies: " + deps,
      "  - Objective: " + cleanObj
    ]
    => lines |> Array.join("\n")
  })
  => taskLines |> Array.join("\n\n")
}

export buildTeamLeadPromptWorkflow = (boardDir: String, backlogContent: String, activeTasks: Array<TaskBlock> = []) => effect {
  pathService <- Path.Path

  tlPath = match (not boardDir or boardDir #= "")
    | true => ""
    | false => pathService.join(boardDir, "TEAM_LEAD_AGENT.md")

  agentsPath = match (not boardDir or boardDir #= "")
    | true => ""
    | false => pathService.join(boardDir, "AGENTS.md")

  tlContent <- readOptionalFileWorkflow(tlPath, DEFAULT_TEAM_LEAD_GUIDELINES)
  agentsContent <- readOptionalFileWorkflow(agentsPath, DEFAULT_AGENTS_GUIDELINES)

  lanesSection = match (not activeTasks or activeTasks.length #= 0)
    | true => "No active tasks in progress across agent lanes. All lanes are idle and ready for assignment."
    | false => formatActiveTasks(activeTasks)

  trimmedBacklog = match (not backlogContent or backlogContent #= "")
    | true => ""
    | false => backlogContent |> String.trim

  cleanBacklog = match (trimmedBacklog #= "")
    | true => "# BACKLOG\n\nNo pending backlog items."
    | false => trimmedBacklog

  boardRoot = match (not boardDir or boardDir #= "")
    | true => "."
    | false => boardDir

  sections = [
    "You are running inside the multi-agent development workflow.",
    "Active role: Team Lead Agent",
    "Board root: " + boardRoot,
    "",
    "================ TEAM_LEAD_AGENT.md ROLE INSTRUCTIONS ================",
    tlContent,
    "",
    "================ AGENTS.md COMMON RULES ================",
    agentsContent,
    "",
    "================ CURRENT BACKLOG ================",
    cleanBacklog,
    "",
    "================ ACTIVE LANES & TASKS ================",
    lanesSection,
    "",
    "================ GROOMING & ASSIGNMENT INSTRUCTIONS ================",
    "1. Review prioritized tasks in BACKLOG.md and verify readiness and dependencies.",
    "2. Format task specifications for TASKS.md including Task ID, Category, Owner, Branch, Status, Objective, Scope, and Acceptance Criteria.",
    "3. Write groomed task allocations to TASKS.md and update BACKLOG.md.",
    "4. Ensure non-overlapping scope and file ownership between active agents to prevent merge conflicts."
  ]

  => sections |> Array.join("\n")
}

export buildTeamLeadPromptEffect = (boardDir: String, backlogContent: String, activeTasks: Array<TaskBlock> = []) => {
  => buildTeamLeadPromptWorkflow(boardDir, backlogContent, activeTasks) |> Effect.provide(BunServices.layer)
}

export buildTeamLeadPrompt = (boardDir: String, backlogContent: String, activeTasks: Array<TaskBlock> = []) => {
  => runSyncWithPlatform(buildTeamLeadPromptWorkflow(boardDir, backlogContent, activeTasks))
}

export buildTeamLeadPromptFun = (boardDir: String, backlogContent: String, activeTasks: Array<TaskBlock> = []) => {
  => buildTeamLeadPrompt(boardDir, backlogContent, activeTasks)
}
