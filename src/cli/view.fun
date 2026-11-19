import { Effect, Option, Schema } from "effect"
import * as core from "./view_core.js"

export schema LiveViewOptions = {
  maxTicks: Option<Number>
}

export readDashboardState = (boardDir: String) => core.readDashboardState(boardDir)

export runLiveView = (boardDir: String, pollMs: Number, options: ts { any }) => core.runLiveView(boardDir, pollMs, options)

export runLiveViewAsync = (boardDir: String, pollMs: Number, options: ts { any }) => core.runLiveViewAsync(boardDir, pollMs, options)

export runLiveViewFun = (boardDir: String, pollMs: Number) => core.runLiveView(boardDir, pollMs)
