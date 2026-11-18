import { Effect, Option, Ref, Schema } from "effect"

export schema TokenUsage = {
  inputTokens: Number
  outputTokens: Number
  totalTokens: Number
}

export schema CooldownState = {
  inCooldown: Boolean
  untilMs: Number
  backoffMs: Number
  reason?: String
}

export emptyTokenUsage = () => {
  inputTokens: 0,
  outputTokens: 0,
  totalTokens: 0
}

export createTokenCounter = () => effect
  counterRef <- Ref.make(emptyTokenUsage())
  => counterRef

export createCooldownState = () => effect
  cdRef <- Ref.make({
    inCooldown: false,
    untilMs: 0,
    backoffMs: 1000
  })
  => cdRef

export recordUsage = (counterRef: Ref.Ref<TokenUsage>, usage: TokenUsage) => effect
  _ <- Ref.update(counterRef, (current) => {
    inputTokens: current.inputTokens + usage.inputTokens,
    outputTokens: current.outputTokens + usage.outputTokens,
    totalTokens: current.totalTokens + usage.totalTokens
  })
  latest <- Ref.get(counterRef)
  => latest

export triggerCooldown = (cdRef: Ref.Ref<CooldownState>, currentTimeMs: Number, customBackoffMs: Option<Number>, reason: String) => effect
  state <- Ref.get(cdRef)
  nextBackoff = match customBackoffMs
    | Some(b) => b
    | None => state.backoffMs * 2

  untilTime = currentTimeMs + nextBackoff
  newState = {
    inCooldown: true,
    untilMs: untilTime,
    backoffMs: nextBackoff,
    reason: reason
  }
  _ <- Ref.set(cdRef, newState)
  => newState

export clearCooldown = (cdRef: Ref.Ref<CooldownState>) => effect
  _ <- Ref.update(cdRef, (current) => {
    inCooldown: false,
    untilMs: 0,
    backoffMs: current.backoffMs,
    reason: current.reason
  })
  => true

export resetCooldown = (cdRef: Ref.Ref<CooldownState>) => effect
  _ <- Ref.set(cdRef, {
    inCooldown: false,
    untilMs: 0,
    backoffMs: 1000
  })
  => true

export checkCooldown = (cdRef: Ref.Ref<CooldownState>, currentTimeMs: Number) => effect
  state <- Ref.get(cdRef)
  isExpired = match state.inCooldown
    | true => match (currentTimeMs >= state.untilMs)
      | true => true
      | false => false
    | false => true

  _ <- match (state.inCooldown and isExpired)
    | true => clearCooldown(cdRef)
    | false => Effect.succeed(true)

  active = match isExpired
    | true => false
    | false => true
  => active
