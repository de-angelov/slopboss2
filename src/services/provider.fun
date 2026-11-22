import { Array, Option, Schema, String } from "effect"

export schema TokenBreakdown = {
  inputTokens: Number
  outputTokens: Number
  totalTokens: Number
}

export schema AgyEvent =
  | TokenUpdate(tokens: TokenBreakdown)
  | AssistantMessage(text: String)
  | UsageLimitReached
  | SessionCompleted

export buildAgyCommand = (model: Option<String>) =>
  baseArgs = ["--output-format", "stream-json", "--dangerously-skip-permissions"]
  args = match model
    | Some(m) => baseArgs |> appendAll(["--model", m])
    | None => baseArgs
  => ["agy"] |> appendAll(args)

export buildInteractiveCommand = (model: Option<String>, prompt: String) =>
  baseArgs = ["--dangerously-skip-permissions", "-i", prompt]
  args = match model
    | Some(m) => baseArgs |> appendAll(["--model", m])
    | None => baseArgs
  => ["agy"] |> appendAll(args)

// Completion contract for the configured agy stream-json provider: accept a
// valid JSON event with done: true or status: "completed". Assistant text and
// a zero process exit are not completion evidence. The runner independently
// rejects any session that also reports a usage limit or exits nonzero.
export parseAgyLine = (line: String) =>
  trimmed = line |> trim
  completionEvidence = Schema.Union([
    Schema.Struct({ done: Schema.Literal(true) }),
    Schema.Struct({ status: Schema.Literal("completed") })
  ])
  hasCompletionEvidence = Schema.decodeUnknownOption(Schema.fromJsonString(completionEvidence))(trimmed) |> Option.isSome
  fallbackEvent = match trimmed
    | l when l |> includes("rate_limit") => Option.some(UsageLimitReached)
    | l when l |> includes("usage_limit") => Option.some(UsageLimitReached)
    | l when l |> includes("\"type\":\"assistant\"") => Option.some(AssistantMessage(l))
    | l when l |> includes("\"content\"") => Option.some(AssistantMessage(l))
    | l when l |> includes("\"total_tokens\"") => Option.some(TokenUpdate({ inputTokens: 0, outputTokens: 0, totalTokens: 0 }))
    | _ => Option.none()
  evt = match hasCompletionEvidence
    | true => Option.some(SessionCompleted)
    | false => fallbackEvent
  => evt
