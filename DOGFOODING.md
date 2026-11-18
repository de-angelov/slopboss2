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
