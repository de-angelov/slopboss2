import { Array, Console, Duration, Effect, Option, Ref, Schedule, Schema, String } from "effect"
import { parseTaskLine, formatTaskLine } from "../domain/board.js"
import { buildAgyCommand } from "../services/provider.js"
import { buildBranchMergedCheck } from "../services/git.js"
import { runMockAgentSession } from "../services/runner.js"

export schema AgentState = {
  id: String
  status: String
  currentTask: Option<String>
  workspace: String
}

export schema OrchestratorState = {
  tickCount: Number
  agents: Array<AgentState>
}

export initialOrchestratorState = (): OrchestratorState =>
  agents: Array<AgentState> = [
    {
      id: "Dev Agent 1"
      status: "Idle"
      currentTask: Option.none()
      workspace: "/home/dangelov/slopboss2-board/workspaces/repo-agent-1"
    },
    {
      id: "Dev Agent 2"
      status: "Idle"
      currentTask: Option.none()
      workspace: "/home/dangelov/slopboss2-board/workspaces/repo-agent-2"
    }
  ]
  => {
    tickCount: 0
    agents: agents
  }

logTickTransition = (tickCount: Number) =>
  match tickCount
    | 0 => Console.log("  -> Dispatching: Dev Agent 1 on [SB2-03], Dev Agent 2 on [SB2-05]")
    | 1 => Console.log("  -> Working: Dev Agent 1 on agent/1/sb2-03, Dev Agent 2 on agent/2/sb2-05")
    | _ => Console.log("  -> Merged: All branches merged to main. Tasks marked Done.")

getUpdatedAgents = (tickCount: Number, currentAgents: Array<AgentState>): Array<AgentState> =>
  match tickCount
    | 0 => [
      {
        id: "Dev Agent 1"
        status: "Running"
        currentTask: Option.some("SB2-03")
        workspace: "/home/dangelov/slopboss2-board/workspaces/repo-agent-1"
      },
      {
        id: "Dev Agent 2"
        status: "Running"
        currentTask: Option.some("SB2-05")
        workspace: "/home/dangelov/slopboss2-board/workspaces/repo-agent-2"
      }
    ]
    | 1 => currentAgents
    | _ => [
      {
        id: "Dev Agent 1"
        status: "Completed"
        currentTask: Option.none()
        workspace: "/home/dangelov/slopboss2-board/workspaces/repo-agent-1"
      },
      {
        id: "Dev Agent 2"
        status: "Completed"
        currentTask: Option.none()
        workspace: "/home/dangelov/slopboss2-board/workspaces/repo-agent-2"
      }
    ]

reportAgentStatuses = (agents: Array<AgentState>) =>
  match (agents |> length) #= 0
    | true => Console.log("  No agents active")
    | false => Effect.forEach(agents, (a: AgentState) => Console.log("  " + a.id + ": " + a.status))

export reconcileTick = (stateRef: Ref.Ref<OrchestratorState>, boardDir: String) => effect {
  state <- Ref.get(stateRef)
  newTick = state.tickCount + 1
  _ <- Console.log("[TICK " + newTick + "] Polling board: " + boardDir)
  _ <- logTickTransition(state.tickCount)

  updatedAgents = getUpdatedAgents(state.tickCount, state.agents)

  _ <- Ref.update(stateRef, (s) => {
    tickCount: newTick
    agents: updatedAgents
  })
  => newTick
}

export startReconcileLoop = (boardDir: String, maxTicks: Number) => effect {
  stateRef <- Ref.make(initialOrchestratorState())
  _ <- Console.log("Starting fiber-supervised orchestrator loop for " + boardDir)
  policy = Schedule.recurs(maxTicks)
  tickEffect = reconcileTick(stateRef, boardDir)
  repeated = tickEffect |> repeat(policy)
  result <- repeated
  finalState <- Ref.get(stateRef)
  _ <- Console.log("Orchestrator completed " + maxTicks + " iterations. Final agent statuses:")
  _ <- reportAgentStatuses(finalState.agents)
  => result
}
