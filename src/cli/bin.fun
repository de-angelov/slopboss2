import { Effect } from "effect"
import { BunServices } from "@effect/platform-bun"
import { runCli } from "./index.js"

program = runCli() |> Effect.provide(BunServices.layer)
export main = () => Effect.runPromise(program).catch((_err: Unknown) => process.exit(1))

res = main()

