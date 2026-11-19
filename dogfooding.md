# Slopboss 2: FunScript Dogfooding Findings

Dogfooding observations, compiler feedback, and architectural invariants from migrating **Slopboss 2**—a fully autonomous multi-agent dev loop with Effect Platform, Bun runtime, TUI live dashboard, and task reconciler—to 100% pure FunScript.

---

## 1. Executive Summary

- **Target Codebase**: `slopboss2` (`/home/dangelov/slopboss2`)
- **Compiler Version**: `funscript-0.2.3.tgz` (development build with shebang lexer support)
- **Runtime**: Bun 1.2+ with `@effect/platform-bun`
- **Orchestration**: Self-hosted autonomous dev loop (`slopboss run --detach --dir slopboss2-board`) with Team Lead Agent + 2 Dev Agents operating in parallel.
- **Purity Status**: Reached 100% pure FunScript implementation across core orchestrator, CLI, TUI view, and task dispatcher; final 3 legacy `.ts` service/launcher files in active migration.

---

## 2. Working: Pure FunScript Architecture

The complete Slopboss 2 application layer compiles cleanly and executes under native FunScript without ambient TypeScript bridges:

1. **CLI Commands & Subcommand Dispatcher (`src/cli/index.fun`)**:
   - Pure FunScript argument parser and command dispatcher using Effect CLI abstractions.
   - Deleted legacy `cli_core.ts` (646 lines removed in commit `14bdf04`).
2. **Terminal Live View (`src/cli/view.fun`)**:
   - TUI dashboard rendering ANSI escape sequences, live task tables, agent rosters, and log previews.
   - Migrated completely to pure FunScript and Effect Platform (deleted `view_core.ts`, 283 lines removed in commit `f6fd9e2`).
3. **Reconciler & Task Dispatcher Loop (`src/orchestrator/dispatcher.fun`)**:
   - Autonomous dev loop handling task transitions (`Backlog` -> `Doing` -> `Review` -> `Done`), git worktree branch management, and fiber lifecycle.
   - Pure FunScript implementation using `Effect.sleep`, `Fiber.fork`, and `Ref` state machines (deleted `dispatcher_core.ts`, 315 lines removed in commit `8791645`).
4. **Coordination & Locking (`src/services/coordination.fun`)**:
   - Atomic process lockfile handling (`acquireBoardLock`, `isPidAlive`, `getLockPath`) implemented natively in FunScript with Effect `FileSystem`.
5. **CLI Schemas & Arguments (`src/cli/index.fun`)**:
   - CLI option definitions, help text generation, and validation schema using `@effect/schema` in native FunScript (commit `d8c6223`).

---

## 3. Compiler Feedback & Bugs Resolved

### 3.1 Shebang / Executable CLI Scripts (`docs/syntax.md §1.1`)
- **Finding**: Executable scripts like `src/cli/bin.ts` start with `#!/usr/bin/env bun`. While `docs/syntax.md §1.1` defines shebang support on the first line, `funscript` previously failed with:
  ```
  CompilerError: Unexpected character '#' at line 1, column 1
  ```
  because the lexer matched `#!` as `TokenType.VALUE_NEQ` (`#`).
- **Fix in FunScript (`src/lexer/lexer.ts` & `src/compiler.ts`)**:
  - Added shebang detection when `offset === 0 && char === '#' && nextChar === '!'`. The lexer consumes until `\n`.
  - Updated `compiler.ts` `compileString` to preserve the shebang line verbatim at the top of the generated JavaScript output.
  - Repacked and installed `funscript-0.2.3.tgz`. Direct CLI execution via `bun ./src/cli/bin.fun` now works seamlessly.

### 3.2 FunScript Config Files & Comment Syntax
- **Finding**: Creating `funscript.config.fun` with shell/Python style comments (`#`) triggered:
  ```
  CompilerError: Unexpected character '#' at line ...
  ```
- **Convention**: FunScript adheres to JavaScript/C-style syntax (`//` and `/* ... */`). `#` is exclusively reserved for the line 1 shebang `#!`. `funscript.config.fun` must use `//` for comments.

### 3.4 Eliminating `globalThis` in Favor of the Effect Ecosystem
- **Finding**: During early migration from TypeScript, agents introduced `globalThis.Boolean(...)`, `globalThis.process.env`, `globalThis.Bun.spawnSync`, and `globalThis.Object.assign` as ad-hoc shims.
- **FunScript Policy Support**: FunScript provides a built-in compiler rule `noGlobalThis: true` in `funscript.config.fun` (and `--no-global-this` CLI flag), which automatically detects and rejects `globalThis` accesses with:
  ```
  error: globalThis is disabled by project policy; use explicit FunScript imports and interop
  ```
- **Idiomatic Effect Replacements**:
  - `globalThis.process.env` -> `Config.string(...)` or `Option.fromNullishOr(process.env[...])`
  - `globalThis.Bun.spawn` / `spawnSync` -> `@effect/platform/Command` / `BunCommandExecutor`
  - `globalThis.Date.now()` -> `Clock.currentTimeMillis` / `DateTime.now`
  - `globalThis.Object.assign` -> Native FunScript record spread `{ ...a, ...b }`
  - `globalThis.Boolean(x)` -> FunScript pattern matching `match opt | Some(v) => ... | None => ...`
  - `globalThis.Error` -> `Data.TaggedError` / `PlatformError`

---

## 4. AST Purity Gates & Invariants

To avoid subtle regressions, Slopboss 2 implements a multi-tiered purity gate:

1. **Lexer/AST Purity Check (`scripts/check-purity.ts`)**:
   - Uses the official FunScript lexer to scan all files under `src/` for forbidden TypeScript escape hatch blocks (`ts { ... }`).
   - Ensures zero non-ambient TypeScript escape blocks exist in the codebase.
2. **File Extension Policy**:
   - Initial versions of `check-purity.ts` only scanned `*.fun` files, which allowed lingering `.ts` files (`platform.ts`, `coordination.ts`, `bin.ts`) to hide in plain sight.
   - Policy updated to enforce that `src/` must contain exclusively `.fun` files.
3. **Automated CI / Test Integration (`package.json`)**:
   - Configured `"test": "bun run scripts/check-purity.ts && bun test"`.
   - Wired into end-to-end self-hosted tests (`tests/e2e_self_hosted.test.ts`), guaranteeing that tests cannot pass if purity is violated.

---

## 5. Dogfooding Experience: Slopboss Building Slopboss

Running Slopboss 2 autonomously to migrate Slopboss 2 into pure FunScript has demonstrated high stability:
- **Parallel Worktrees**: Slopboss spins up isolated git worktrees (`repo-tl`, `repo-agent-1`, `repo-agent-2`) to avoid file collisions between agents.
- **Continuous Test Verification**: Dev agents execute `bun test` inside their respective worktrees before creating PR branches.
- **Autonomous Recovery**: Over 5 major refactoring tasks (SB2-23, SB2-27, SB2-28, SB2-29, SB2-30) were planned, executed, tested, and landed onto `main` by the autonomous loop with 178 passing unit and integration tests.

---

## 6. Migration Progress & Status

| Task ID | Component / Milestone | Status | Details |
| :--- | :--- | :--- | :--- |
| **SB2-27** | Reconciler Loop & Dispatcher | **Landed** (`8791645`) | Migrated to pure `dispatcher.fun`; removed `dispatcher_core.ts` (315 lines). |
| **SB2-29** | Terminal Live View (TUI) | **Landed** (`f6fd9e2`) | Migrated to pure `view.fun`; removed `view_core.ts` (283 lines). |
| **SB2-30** | CLI Argument Parsing & Schemas | **Landed** (`d8c6223`) | Migrated argument parsing to pure `index.fun`. |
| **SB2-28** | CLI Subcommands & Dispatcher | **Landed** (`14bdf04`) | Migrated commands to pure `index.fun`; removed `cli_core.ts` (646 lines). |
| **SB2-23** | Automated Purity Gate | **Landed** (`eaa2ffc`) | Wired `check-purity.ts` into test suite and CI lifecycle. |
| **SB2-31** | Eliminate `platform.ts` | **In Progress** | Dev Agent 1 refactoring `doctor.fun`, `prompt.fun`, `setup.fun` to native Effect platform. |
| **SB2-32** | Delete Redundant `coordination.ts` | **In Progress** | Dev Agent 2 removing obsolete `coordination.ts` duplicate of `coordination.fun`. |
| **SB2-33** | Pure `bin.fun` & Global `noTs` | **Queued** | Convert CLI launcher to pure `bin.fun` with `#!/usr/bin/env bun` and enforce 0 `.ts` files. |

---

## 7. Recommendations for FunScript Development

1. **Preserve Shebang in Build Tooling**: Ensure all downstream bundlers and packers preserve shebang lines emitted by `funscript.compileString`.
2. **Native Effect Platform Support**: Continue expanding first-class syntactic idioms for Effect services (`FileSystem`, `Path`, `Command`), as they fit FunScript's functional purity exceptionally well.
3. **Purity Linter Built into FunScript CLI**: Provide `funscript check --purity` out of the box to reject TypeScript escape hatches without requiring custom ad-hoc scripts.
