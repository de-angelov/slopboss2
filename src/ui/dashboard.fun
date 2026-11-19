import { Array, Option, Schema, String } from "effect"

export schema AgentLane = {
  id: String
  status: String
  task: Option<String>
  branch: Option<String>
}

export schema TokenUsage = {
  inputTokens: Number
  outputTokens: Number
  totalTokens: Number
}

export schema DashboardState = {
  boardDir: String
  lanes: Array<AgentLane>
  tokens: TokenUsage
  recentLogs: Array<String>
}

export formatStatusColor = (status: String) =>
  res = match status
    | "In Progress" => "\u001b[33mIn Progress\u001b[0m"
    | "Completed" => "\u001b[32mCompleted\u001b[0m"
    | "Running" => "\u001b[36mRunning\u001b[0m"
    | "Failed" => "\u001b[31mFailed\u001b[0m"
    | other => "\u001b[90m" + other + "\u001b[0m"
  => res

export renderLane = (lane: AgentLane) =>
  taskInfo = match lane.task
    | Some(t) => " | Task: " + t
    | None => " | Task: (idle)"

  branchInfo = match lane.branch
    | Some(b) => " | Branch: " + b
    | None => ""

  statusColored = formatStatusColor(lane.status)
  => "  * " + lane.id + " [" + statusColored + "]" + taskInfo + branchInfo

export renderTokenSection = (tokens: TokenUsage) =>
  inp = globalThis.String(tokens.inputTokens)
  out = globalThis.String(tokens.outputTokens)
  tot = globalThis.String(tokens.totalTokens)
  => "Token Usage: in=" + inp + " | out=" + out + " | total=" + tot

export renderLogsSection = (logs: Array<String>) =>
  header = "Recent Events:\n"
  formattedLogs = logs |> Array.map((log) => "  > " + log) |> Array.join("\n")
  => header + formattedLogs

export renderDashboard = (state: DashboardState, clearScreen: Boolean) =>
  esc = globalThis.String.fromCharCode(27)
  clearPrefix = match clearScreen
    | true => esc + "[2J" + esc + "[H"
    | false => ""

  banner = "=========================================================\n"
  title = "           SLOPBOSS2 LIVE AGENT DASHBOARD\n"
  boardLine = "Board: " + state.boardDir + "\n"
  divider = "---------------------------------------------------------\n"

  lanesHeader = "Agent Lanes:\n"
  renderedLanes = state.lanes |> Array.map(renderLane) |> Array.join("\n")
  lanesSection = lanesHeader + renderedLanes + "\n"

  tokensLine = renderTokenSection(state.tokens) + "\n"
  logsSection = renderLogsSection(state.recentLogs) + "\n"

  => clearPrefix + banner + title + banner + boardLine + divider + lanesSection + divider + tokensLine + divider + logsSection + banner

export renderFullDashboard = (state: DashboardState) =>
  renderDashboard(state, true)
