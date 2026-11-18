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
    | Some(m) => baseArgs |> Array.appendAll(["--model", m])
    | None => baseArgs
  => ["agy"] |> Array.appendAll(args)

export buildInteractiveCommand = (model: Option<String>, prompt: String) =>
  baseArgs = ["--dangerously-skip-permissions", "-i", prompt]
  args = match model
    | Some(m) => baseArgs |> Array.appendAll(["--model", m])
    | None => baseArgs
  => ["agy"] |> Array.appendAll(args)

export parseAgyLine = (line: String) =>
  trimmed = line |> String.trim
  evt = match trimmed
    | l when l |> String.includes("rate_limit") =>
      Option.some(UsageLimitReached)
    | l when l |> String.includes("usage_limit") =>
      Option.some(UsageLimitReached)
    | l when l |> String.includes("\"type\":\"assistant\"") =>
      Option.some(AssistantMessage(l))
    | l when l |> String.includes("\"content\"") =>
      Option.some(AssistantMessage(l))
    | l when l |> String.includes("\"total_tokens\"") =>
      Option.some(TokenUpdate({ inputTokens: 0, outputTokens: 0, totalTokens: 0 }))
    | l when l |> String.includes("\"done\":true") =>
      Option.some(SessionCompleted)
    | l when l |> String.includes("\"status\":\"completed\"") =>
      Option.some(SessionCompleted)
    | _ =>
      Option.none()
  => evt
