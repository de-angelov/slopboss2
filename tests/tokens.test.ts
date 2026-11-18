import { describe, expect, it } from "bun:test";
import { Effect, Option } from "effect";
import {
  createTokenCounter,
  createCooldownState,
  recordUsage,
  triggerCooldown,
  checkCooldown,
  resetCooldown,
  emptyTokenUsage,
  type TokenUsage,
} from "../src/services/tokens.js";

describe("Token Accounting & Cooldown Manager", () => {
  it("initializes empty token counter at zero", async () => {
    const empty = emptyTokenUsage();
    expect(empty.inputTokens).toBe(0);
    expect(empty.outputTokens).toBe(0);
    expect(empty.totalTokens).toBe(0);
  });

  it("atomically records cumulative usage across multiple sessions", async () => {
    const program = Effect.gen(function* () {
      const counter = yield* createTokenCounter();
      yield* recordUsage(counter, { inputTokens: 500, outputTokens: 200, totalTokens: 700 });
      yield* recordUsage(counter, { inputTokens: 1200, outputTokens: 450, totalTokens: 1650 });
      const finalState = yield* recordUsage(counter, { inputTokens: 300, outputTokens: 100, totalTokens: 400 });
      return finalState;
    });

    const result = await Effect.runPromise(program);
    expect(result.inputTokens).toBe(2000);
    expect(result.outputTokens).toBe(750);
    expect(result.totalTokens).toBe(2750);
  });

  it("tracks cooldown activation and exponential backoff doubling", async () => {
    const program = Effect.gen(function* () {
      const cdRef = yield* createCooldownState();

      // Initially not in cooldown
      const initialActive = yield* checkCooldown(cdRef, 1000);
      expect(initialActive).toBe(false);

      // Trigger cooldown with default doubling (1000ms -> 2000ms)
      const state1 = yield* triggerCooldown(cdRef, 10000, Option.none(), "Rate limit 429");
      expect(state1.inCooldown).toBe(true);
      expect(state1.untilMs).toBe(12000);
      expect(state1.backoffMs).toBe(2000);

      // In active cooldown at 11000ms
      const midActive = yield* checkCooldown(cdRef, 11000);
      expect(midActive).toBe(true);

      // Cooldown expired at 12001ms
      const postActive = yield* checkCooldown(cdRef, 12001);
      expect(postActive).toBe(false);

      // Trigger second cooldown, should double again to 4000ms
      const state2 = yield* triggerCooldown(cdRef, 20000, Option.none(), "Rate limit 429");
      expect(state2.backoffMs).toBe(4000);
      expect(state2.untilMs).toBe(24000);

      // Reset cooldown
      yield* resetCooldown(cdRef);
      const afterReset = yield* checkCooldown(cdRef, 20000);
      expect(afterReset).toBe(false);

      return true;
    });

    await Effect.runPromise(program);
  });

  it("supports explicit custom backoff duration", async () => {
    const program = Effect.gen(function* () {
      const cdRef = yield* createCooldownState();
      const state = yield* triggerCooldown(cdRef, 50000, Option.some(15000), "Quota exhaustion");
      expect(state.backoffMs).toBe(15000);
      expect(state.untilMs).toBe(65000);

      const inCd = yield* checkCooldown(cdRef, 60000);
      expect(inCd).toBe(true);

      const outCd = yield* checkCooldown(cdRef, 65001);
      expect(outCd).toBe(false);

      return true;
    });

    await Effect.runPromise(program);
  });
});
