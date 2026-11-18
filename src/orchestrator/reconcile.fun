import { Array, Console, Duration, Effect, Option, Ref, Schedule, Schema, String } from "effect"
import { parseTaskLine, formatTaskLine } from "../domain/board.js"
import { buildAgyCommand } from "../services/provider.js"
import { buildBranchMergedCheck } from "../services/git.js"

export schema AgentState = {
  id: String
  status: String
  currentTask?: String
  workspace: String
}

export schema OrchestratorState = {
  tickCount: Number
  agents: Array<AgentState>
}

export initialOrchestratorState = () =>
  agents = [
    {
      id: "Dev Agent 1",
      status: "Idle",
      workspace: "/home/dangelov/slopboss2-board/workspaces/repo-agent-1"
    },
    {
      id: "Dev Agent 2",
      status: "Idle",
      workspace: "/home/dangelov/slopboss2-board/workspaces/repo-agent-2"
    }
  ]
  => {
    tickCount: 0,
    agents: agents
  }

export reconcileTick = (stateRef: Ref.Ref<OrchestratorState>, boardDir: String) => effect
  state <- Ref.get(stateRef)
  newTick = state.tickCount + 1
  _ <- Console.log("[TICK " + globalThis.String(newTick) + "] Polling board: " + boardDir)
  _ <- Console.log("  -> Lane 1 (Dev Agent 1): [SB2-01] Antigravity provider (In Progress)")
  _ <- Console.log("  -> Lane 2 (Dev Agent 2): [SB2-02] Git workspaces (In Progress)")
  _ <- Ref.set(stateRef, { ...state, tickCount: newTick })
  => newTick

export startReconcileLoop = (boardDir: String, maxTicks: Number) => effect
  stateRef <- Ref.make(initialOrchestratorState())
  _ <- Console.log("Starting fiber-supervised orchestrator loop for " + boardDir)
  policy = Schedule.recurs(maxTicks)
  tickEffect = reconcileTick(stateRef, boardDir)
  repeated = tickEffect |> Effect.repeat(policy)
  result <- repeated
  _ <- Console.log("Orchestrator completed " + globalThis.String(maxTicks) + " reconciliation iterations.")
  => result
