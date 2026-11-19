#!/usr/bin/env bun
import { Effect } from "effect"
import { BunServices } from "@effect/platform-bun"
import { runCli } from "./index.js"

program = runCli() |> Effect.provide(BunServices.layer)
export main = () => {
  p: Promise<Unknown> = Reflect.apply(Effect.runPromise, Effect, [program])
  => p.catch((_err: Unknown) => process.exit(1))
}

res: Unknown = main()




