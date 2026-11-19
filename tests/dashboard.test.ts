import { describe, expect, it } from "bun:test";
import { Option } from "effect";
import {
  renderDashboard,
  renderLane,
  renderTokenSection,
  renderLogsSection,
  type DashboardState,
  type AgentLane,
  type TokenUsage,
} from "../src/ui/dashboard.js";

describe("Terminal UI Live View & Dashboard", () => {
  const mockTokens: TokenUsage = {
    inputTokens: 12500,
    outputTokens: 3400,
    totalTokens: 15900,
  };

  const mockLanes: AgentLane[] = [
    {
      id: "Dev Agent 1",
      status: "In Progress",
      task: Option.some("SB2-07"),
      branch: Option.some("agent/1/sb2-07-terminal-dashboard"),
    },
    {
      id: "Dev Agent 2",
      status: "Idle",
      task: Option.none(),
      branch: Option.none(),
    },
  ];

  const mockState: DashboardState = {
    boardDir: "/home/dangelov/slopboss2-board",
    lanes: mockLanes,
    tokens: mockTokens,
    recentLogs: [
      "[MERGE TRAIN] Task SB2-06 landed cleanly.",
      "[DISPATCH] Dev Agent 1 claimed SB2-07.",
    ],
  };

  it("renders individual lane with colored status, task, and branch", () => {
    const rendered = renderLane(mockLanes[0]);
    expect(rendered).toContain("Dev Agent 1");
    expect(rendered).toContain("In Progress");
    expect(rendered).toContain("Task: SB2-07");
    expect(rendered).toContain("Branch: agent/1/sb2-07-terminal-dashboard");

    const idleRendered = renderLane(mockLanes[1]);
    expect(idleRendered).toContain("Dev Agent 2");
    expect(idleRendered).toContain("Task: (idle)");
  });

  it("renders token usage summary correctly", () => {
    const rendered = renderTokenSection(mockTokens);
    expect(rendered).toContain("in=12500");
    expect(rendered).toContain("out=3400");
    expect(rendered).toContain("total=15900");
  });

  it("renders recent event logs", () => {
    const rendered = renderLogsSection(mockState.recentLogs);
    expect(rendered).toContain("[MERGE TRAIN] Task SB2-06 landed cleanly.");
    expect(rendered).toContain("[DISPATCH] Dev Agent 1 claimed SB2-07.");
  });

  it("renders full dashboard containing all lanes and board directory", () => {
    const dashboard = renderDashboard(mockState, false);
    expect(dashboard).toContain("SLOPBOSS2 LIVE AGENT DASHBOARD");
    expect(dashboard).toContain("/home/dangelov/slopboss2-board");
    expect(dashboard).toContain("Dev Agent 1");
    expect(dashboard).toContain("Dev Agent 2");
    expect(dashboard).toContain("total=15900");
    expect(dashboard).toContain("[DISPATCH] Dev Agent 1 claimed SB2-07.");
    expect(dashboard.startsWith("\u001b[2J\u001b[H")).toBe(false);
  });

  it("prepends ANSI clear-screen escape codes when clearScreen=true", () => {
    const dashboard = renderDashboard(mockState, true);
    expect(dashboard.startsWith("\u001b[2J\u001b[H")).toBe(true);
  });
});
