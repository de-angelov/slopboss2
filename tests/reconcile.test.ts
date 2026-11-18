import { describe, expect, it } from "bun:test";
import { Effect, Ref } from "effect";
import {
  initialOrchestratorState,
  reconcileTick,
  startReconcileLoop,
} from "../src/orchestrator/reconcile.js";

describe("Orchestrator Reconciliation Engine", () => {
  it("initializes orchestrator state with 2 dev agents", () => {
    const state = initialOrchestratorState();
    expect(state.tickCount).toBe(0);
    expect(state.agents.length).toBe(2);
    expect(state.agents[0].id).toBe("Dev Agent 1");
    expect(state.agents[1].id).toBe("Dev Agent 2");
  });

  it("advances tickCount on each reconcileTick", async () => {
    const stateRef = await Effect.runPromise(Ref.make(initialOrchestratorState()));
    const tick1 = await Effect.runPromise(reconcileTick(stateRef, "/tmp/board"));
    expect(tick1).toBe(1);
    const tick2 = await Effect.runPromise(reconcileTick(stateRef, "/tmp/board"));
    expect(tick2).toBe(2);
    const current = await Effect.runPromise(Ref.get(stateRef));
    expect(current.tickCount).toBe(2);
  });

  it("executes multi-tick scheduled loop cleanly", async () => {
    const res = await Effect.runPromise(startReconcileLoop("/tmp/board", 2));
    expect(res).toBeDefined();
  });
});
