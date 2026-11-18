#!/usr/bin/env bun
import { Effect } from "effect";
import { runCli } from "./index.js";

await Effect.runPromise(runCli());
