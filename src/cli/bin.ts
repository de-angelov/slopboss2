#!/usr/bin/env bun
import { Effect } from "effect";
import { runCli } from "./index.js";

try {
  await Effect.runPromise(runCli());
} catch (_err) {
  process.exit(1);
}
