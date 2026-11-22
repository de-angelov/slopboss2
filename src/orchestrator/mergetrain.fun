import { Array, Effect, Option, Queue, Schema, String } from "effect"
import { GitSubprocessResult, SafeSpawnResult, runGitCommandSync, safeSpawnSync } from "../services/sys.js"

export schema MergeRequest = {
  taskId: String
  branch: String
  workspace: String
  isZeroCommit: Boolean
  verificationCmd: Option<String>
}

export schema MergeResult = {
  taskId: String
  success: Boolean
  commitHash: Option<String>
  error: Option<String>
}

git = (args: Array<String>, cwd: String) => runGitCommandSync(args, cwd)
messageOf = (result: GitSubprocessResult) => {
  => match result.stderr |> isEmpty
    | true => result.stdout
    | false => result.stderr
}
runVerification = (cmd: String, cwd: String) => safeSpawnSync(["bash", "-lc", cmd], Option.none(), cwd)

export landMergeRequest = (req: MergeRequest, baseBranch: String) => effect {
  isZero = Option.fromNullishOr(req.isZeroCommit) |> Option.getOrElse(() => false)
  verification = Option.fromNullishOr(req.verificationCmd)
  verificationRes: SafeSpawnResult = match verification
    | Some(cmd) => runVerification(cmd, req.workspace)
    | None => { exitCode: 0, stdout: "", stderr: "", ok: true, threw: false }
  when (not verificationRes.ok) => {
    taskId: req.taskId, success: false, commitHash: Option.none(),
    error: Option.some("Verification failed: " + verificationRes.stdout + " " + verificationRes.stderr)
  }
  when (isZero) => {
    taskId: req.taskId, success: true, commitHash: Option.none(), error: Option.none()
  }

  remoteRes = git(["remote", "get-url", "origin"], req.workspace)
  when (not (remoteRes.exitCode #= 0)) => {
    taskId: req.taskId, success: false, commitHash: Option.none(), error: Option.some("Cannot resolve origin: " + messageOf(remoteRes))
  }
  remote = remoteRes.stdout
  tempRes = Bun.spawnSync(["mktemp", "-d"], { stdout: "pipe", stderr: "pipe" })
  tempDir = tempRes.stdout.toString() |> trim
  cloneRes = git(["clone", "--quiet", remote, tempDir], req.workspace)
  when (not (cloneRes.exitCode #= 0)) => {
    taskId: req.taskId, success: false, commitHash: Option.none(), error: Option.some("Cannot create isolated landing repository: " + messageOf(cloneRes))
  }
  fetchRes = git(["fetch", "origin", baseBranch, req.branch], tempDir)
  when (not (fetchRes.exitCode #= 0)) => {
    taskId: req.taskId, success: false, commitHash: Option.none(), error: Option.some("Branch or base validation failed: " + messageOf(fetchRes))
  }
  baseCheck = git(["show-ref", "--verify", "--quiet", "refs/remotes/origin/" + baseBranch], tempDir)
  branchCheck = git(["show-ref", "--verify", "--quiet", "refs/remotes/origin/" + req.branch], tempDir)
  when (not (baseCheck.exitCode #= 0) or not (branchCheck.exitCode #= 0)) => {
    taskId: req.taskId, success: false, commitHash: Option.none(), error: Option.some("Configured base branch or task branch does not exist on origin")
  }
  // A prior attempt may have pushed successfully and then failed while the
  // caller persisted board archival. Treat the task-specific landing commit as
  // evidence that this request already landed, so retrying is idempotent.
  landedRes = git(["log", "refs/remotes/origin/" + baseBranch, "--format=%H", "--grep=^" + req.taskId + ": landed$"], tempDir)
  when (landedRes.exitCode #= 0 and not (landedRes.stdout |> String.trim |> String.isEmpty)) => {
    taskId: req.taskId, success: true, commitHash: Option.some(landedRes.stdout |> trim |> split("\n") |> head |> getOrElse(() => "")), error: Option.none()
  }
  checkoutRes = git(["checkout", "--quiet", "-B", baseBranch, "refs/remotes/origin/" + baseBranch], tempDir)
  when (not (checkoutRes.exitCode #= 0)) => {
    taskId: req.taskId, success: false, commitHash: Option.none(), error: Option.some("Cannot check out base branch: " + messageOf(checkoutRes))
  }
  mergeRes = git(["merge", "--squash", "refs/remotes/origin/" + req.branch], tempDir)
  when (not (mergeRes.exitCode #= 0)) => {
    taskId: req.taskId, success: false, commitHash: Option.none(), error: Option.some("Squash merge conflict; recovery workspace: " + tempDir + ". " + messageOf(mergeRes))
  }
  commitRes = git(["commit", "-m", "" + req.taskId + ": landed"], tempDir)
  when (not (commitRes.exitCode #= 0)) => {
    taskId: req.taskId, success: false, commitHash: Option.none(), error: Option.some("Landing commit failed; recovery workspace: " + tempDir + ". " + messageOf(commitRes))
  }
  hashRes = git(["rev-parse", "HEAD"], tempDir)
  latestBaseRes = git(["fetch", "origin", baseBranch], tempDir)
  when (not (latestBaseRes.exitCode #= 0)) => {
    taskId: req.taskId, success: false, commitHash: Option.none(), error: Option.some("Cannot refresh base before push; recovery commit " + hashRes.stdout + " retained at " + tempDir + ". " + messageOf(latestBaseRes))
  }
  baseHeadRes = git(["rev-parse", "refs/remotes/origin/" + baseBranch], tempDir)
  parentRes = git(["rev-parse", "HEAD^"], tempDir)
  when (not (baseHeadRes.exitCode #= 0) or not (parentRes.exitCode #= 0) or not (baseHeadRes.stdout #= parentRes.stdout)) => {
    taskId: req.taskId, success: false, commitHash: Option.none(), error: Option.some("Base advanced during landing; recovery commit " + hashRes.stdout + " retained at " + tempDir)
  }
  pushRes = git(["push", "origin", "HEAD:refs/heads/" + baseBranch], tempDir)
  when (not (pushRes.exitCode #= 0)) => {
    taskId: req.taskId, success: false, commitHash: Option.none(), error: Option.some("Push failed; recovery commit " + hashRes.stdout + " retained at " + tempDir + ". " + messageOf(pushRes))
  }
  => { taskId: req.taskId, success: true, commitHash: Option.some(hashRes.stdout), error: Option.none() }
}

export createMergeTrain = (capacity: Number) => effect {
  queue <- Queue.bounded(capacity)
  => queue
}

export enqueueMerge = (queue: Queue.Queue<MergeRequest>, req: MergeRequest) => effect {
  _ <- Queue.offer(queue, req)
  => true
}

export enqueueMergeRequest = (queue: Queue.Queue<MergeRequest>, req: MergeRequest) => enqueueMerge(queue, req)

export processNextMerge = (queue: Queue.Queue<MergeRequest>, baseBranch: String) => effect {
  req <- Queue.take(queue)
  res <- landMergeRequest(req, baseBranch)
  => res
}
