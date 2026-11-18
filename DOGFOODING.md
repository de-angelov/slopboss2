# Dogfooding Journal: Rewriting Slopboss in Bun + FunScript

This document records architectural comparisons, observed shortcomings in the original Go implementation of `slopboss`, and friction points/enhancement opportunities discovered in `funscript` while dogfooding it on a complex, real-world autonomous multi-agent orchestrator.

---

## 1. Shortcomings in Original Golang `slopboss`

### 1.1 Unstructured Concurrency & Goroutine Leaks
- **Goroutine Sprawl**: The Go orchestrator launches long-running background tasks via bare `go func()` (e.g., `reconcileDone`, `watcherDone`, `session.Run`, line-by-line output monitors).
- **No Hierarchical Supervision**: If the main orchestrator encounters an unrecoverable failure or receives `SIGTERM`, child goroutines must be manually coordinated via `context.Context` and `chan struct{}` close signals. A missed select case or unread channel can leave orphaned goroutines executing indefinitely in the background.
- **Panic Isolation**: An uncaught panic in any spawned goroutine (such as during unexpected JSON log formatting or nil pointer in a monitor) crashes the entire Go process immediately, killing all running agent sessions without a chance to persist controller state.

### 1.2 Mutex Contention & Global Mutable State
- **Global Variables**: Configuration and runtime state are largely stored as package-level globals in `config` and `orchestrator` (`sessionProvider`, `controllerStateStore`, `DevAgentCount`, `lastTeamLeadActivity`, `mu sync.Mutex`). This prevents running multiple isolated controller instances in tests.
- **Mixed Lock Scopes**: The global mutex `mu` is held across mixed operations, including file I/O writes (`controller-state.json`) and git operations, leading to latency spikes and potential lock contention during active agent reconciliation.
- **Process Group Termination Brittle**: Killing child agents relies on POSIX process groups via `syscall.Kill(-pgid, syscall.SIGTERM)`. If a child agent launcher drops its process group or spawns child daemons, orphan processes are left behind on Linux systems.

### 1.3 Polling-Only Architecture
- The controller relies on fixed-interval ticker loops (`time.NewTicker(config.PollInterval)`) to read `BACKLOG.md` and `TASKS.md`. There is no reactive file system event integration (e.g. `inotify`), causing unnecessary disk I/O when idle and up to 5-second latency before responding to human edits.

### 1.4 Historical Production Failure Modes in Go `slopboss` & How `slopboss2` Solves Them

Real-world agent runs in the original Go repository surfaced 5 major failure modes that frequently stalled or broke autonomous development:

1. **Concurrent Git Push Collisions**:
   - **Problem & Failure**: When Dev Agent 1 and Dev Agent 2 completed task branches simultaneously, both raced to squash-merge and push to `origin/main`. The second push was rejected as non-fast-forward, causing the second agent's completed task to be marked as `Failed`, discarding working code and requiring manual rollback.
   - **Go Patch (`34f48cd`)**: Wrapped git operations in a 3-attempt retry loop with exponential sleep backoff and `git reset --hard origin/main`.
   - **`slopboss2` Solution**: Handled fundamentally via a linearized Effect `Queue` for the merge train. Merges and pushes execute sequentially in a single supervised fiber, eliminating push races by design.

2. **Zero-Commit & Audit Task Rejection**:
   - **Problem & Failure**: The Go merge train validated branches via `ahead, err := git.CommitsAheadOfBase(...)`. If `ahead == 0`, it aborted with `no commits found on branch ahead of origin/main (ahead=0)`. This caused audit, characterization, or investigation tasks (which analyze code without producing git diffs) to fail and block board progression.
   - **Go Patch (`34f48cd`)**: Added an ad-hoc bypass for zero-commit tasks to run verification without requiring a git commit.
   - **`slopboss2` Solution**: Distinct task categories (`Audit`, `Investigation`, `Feature`) are modeled in the typed domain schema (`slopboss2/src/domain/board.fun`), cleanly routing non-code audit tasks past the git merge train.

3. **Redundant Team Lead Session Thrashing**:
   - **Problem & Failure**: Unstable synthetic task keys for follow-up sessions caused the scheduler to immediately spawn another Team Lead session whenever any agent completed or blocked. This spun back-to-back LLM sessions in a tight loop, burning thousands of LLM tokens before dev agents could claim work.
   - **Go Patch (`9c2e8fa`)**: Hashed task dependencies (`sha256(blockedTasks)`) and cached durable controller leases to debounce invocations.
   - **`slopboss2` Solution**: Managed natively with Effect's `Schedule.spaced` with jitter and atomic state transitions over `Ref<OrchestratorState>`, preventing thrashing.

4. **Trailing Prose Breaking Verification Commands**:
   - **Problem & Failure**: LLMs frequently appended explanations to generated verification blocks (e.g. `## Verification\nnpm test tests/parser.test.ts. Verify that all 12 tests pass.`). Passing this raw string into `bash -c` caused syntax errors on the trailing English prose.
   - **Go Patch (`e21346a`)**: Added regex heuristics to strip trailing sentences matching `(?:\.\s+[A-Z][a-zA-Z]+.*$)`.
   - **`slopboss2` Solution**: Sanitized during markdown parsing in `slopboss2/src/domain/board.fun` by strictly extracting fenced code blocks rather than raw text.

5. **Zombie Processes & Detached Subprocesses**:
   - **Problem & Failure**: Go relied on `syscall.Kill(-pgid, SIGTERM)` to terminate agent sessions. If child CLI tools (compilers, vitest, git) spawned independent process groups or ignored `SIGTERM`, orphan background processes survived indefinitely, consuming CPU and holding locks on git repositories.
   - **`slopboss2` Solution**: Effect's `Scope.addFinalizer` hooks into fiber termination, closing all stdio stream sinks and escalating from `SIGTERM` to `SIGKILL` if the child process does not exit promptly.

---

## 2. Shortcomings & Friction Points in FunScript

### 2.1 Lack of Standard Subprocess / Process Companions
- **Observation**: FunScript excels at data modeling (`schema`), pure functional logic, and Effect workflows, but orchestrating external CLI tools (`agy`, `git`, `tmux`) requires dropping into `js` blocks or using `@effect/platform` / `child_process`.
- **Opportunity**: A native FunScript `Process` or `Command` companion (backed by Bun/Node subprocesses) would allow declarative command execution without raw `js` escapes:
  ```funscript
  # Proposed ideal FunScript subprocess syntax:
  result <- Process.spawn("agy", ["--output-format", "stream-json"])
  ```

### 2.2 Direct Bun Loader Plugin (`bun-plugin-funscript`)
- **Observation**: Currently, `.fun` files must be compiled ahead of time via `funscript build --outDir dist` before Bun can execute them (`bun run dist/cli/index.js`).
- **Opportunity**: Implementing a custom Bun plugin using `Bun.plugin` would allow running `.fun` files directly without manual compilation:
  ```bash
  bun run src/cli/index.fun
  ```

### 2.3 Streaming & Line Decoding Ergonomics
- **Observation**: Processing stdout streams from `agy` line-by-line requires Effect `Stream` splitting combinators (`Stream.splitLines`), which require careful handling of text decoders and trailing newlines across chunk boundaries.

---

## 3. How `slopboss2` Solves Concurrency via Effect + Bun

| Concern | Go `slopboss` | FunScript + Bun `slopboss2` |
| --- | --- | --- |
| **Concurrency Model** | Unstructured `go func()` | Supervised `Effect.forkScoped` fibers |
| **State Synchronization** | `sync.Mutex` & global variables | Atomic lock-free `Ref` and `SynchronizedRef` |
| **Process Lifecycle** | `syscall.Kill(-pgid)` | Effect `Scope.addFinalizer` with graceful SIGTERM/SIGKILL |
| **Log Streaming** | Goroutines pumping `io.Reader` | Reactive backpressured Effect `Stream` |
| **Compute Heavy Work** | Goroutine pools | Bun Workers + AssemblyScript SIMD Wasm (`as { ... }`) |
| **Error Handling** | `if err != nil` (manual checks) | Typed `Effect<A, E, R>` error channels |

---

## 4. Compiler & Toolchain Bugs Discovered & Resolved in FunScript

During the `slopboss2` dogfooding loop, three distinct bugs were caught, root-caused, and fixed in the `funscript` compiler:

1. **Missing `esbuild` dependency in `package.json`**:
   - `funscript` CLI commands used `transformSync` from `esbuild`, which was only transitively present in development. When installed as an npm package in `slopboss2`, `bunx funscript` threw `ERR_MODULE_NOT_FOUND: Cannot find package 'esbuild'`.
   - **Fix**: Added `"esbuild": "^0.21.5"` to `dependencies` in `funscript/package.json` and repacked.

2. **Wildcard rest-pattern destructuring syntax error (`[c, ..._]`)**:
   - In pattern matches like `[c, ..._] => c`, `emitBindingTarget` was emitting `const [c, ...] = $matched;`, producing invalid JavaScript syntax because the discarded rest identifier was empty.
   - **Fix**: Updated `src/emitter/emitter.ts` to omit wildcard rest bindings when target argument is empty.

3. **`ts-pattern` variable unpacking in pattern-arm guards vs handlers**:
   - When matching with `when` guards on scalar variables (`| l when l |> ... =>`), `ts-pattern` passes the raw value to the guard function, but passes a selection dictionary `{ [varName]: value }` to the arm handler. The compiler was attempting to unpack `{ _tag: _, ...__fields }` in both, corrupting scalar strings.
   - **Fix**: Updated `src/emitter/match.ts` to assign `$matched` directly in guards and `{ [name] }` in handlers for `VariablePattern`.

