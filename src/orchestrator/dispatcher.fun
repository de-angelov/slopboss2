import { Effect, Option, Schema } from "effect"
import * as core from "./dispatcher_core.js"

export schema RunningSession = {
  agentId: String
  taskId: String
  branch: String
  workspace: String
  status: String
}

export schema TokenCounter = {
  inputTokens: Number
  outputTokens: Number
  totalTokens: Number
}

export schema ReconcilerConfig = {
  boardDir: String
  pollIntervalMs: Number
  maxIterations: Number
  devAgentCount: Number
}

export schema ReconcilerState = {
  tickCount: Number
  activeSessions: Array<RunningSession>
  tokenCounter: TokenCounter
}

export initialReconcilerState = (devAgentCount: Number) => core.initialReconcilerState(devAgentCount)

export initialReconcilerStateFun = (devAgentCount: Number) => core.initialReconcilerState(devAgentCount)

export reconcileTick = (config: ts { any }, state: ts { any }) => core.reconcileTick(config, state)

export reconcileTickFun = (config: ts { any }, state: ts { any }) => core.reconcileTick(config, state)

export runReconcilerLoop = (config: ts { any }) => core.runReconcilerLoop(config)

export runReconcilerLoopFun = (config: ts { any }) => core.runReconcilerLoop(config)
