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

messageOf = (result: GitSubprocessResult) =>
  match result.stderr |> String.isEmpty
    | true => result.stdout
    | _ => result.stderr

runVerification = (cmd: String, cwd: String) => safeSpawnSync(["bash", "-lc", cmd], Option.none(), cwd)

failLanding = (taskId: String, msg: String): MergeResult => {
  taskId: taskId
  success: false
  commitHash: Option.none()
  "error": Option.some(msg)
}

succeedLanding = (taskId: String, hash: Option.Option<String>): MergeResult => {
  taskId: taskId
  success: true
  commitHash: hash
  "error": Option.none()
}

export landMergeRequest = (req: MergeRequest, baseBranch: String) => effect {
  isZero = Option.fromNullishOr(req.isZeroCommit) |> Option.getOrElse(() => false)
  verification = req.verificationCmd
  verificationRes: SafeSpawnResult =
    match verification
      | Some(cmd) => runVerification(cmd, req.workspace)
      | None => {
        exitCode: 0
        stdout: ""
        stderr: ""
        ok: true
        threw: false
      }

  workflow =
    effect {
      _ <- match verificationRes.ok
        | true => Effect.void
        | false => Effect.fail("Verification failed: " + verificationRes.stdout + " " + verificationRes.stderr)

      zeroSentinel = "__IS_ZERO__"
      _ <- match isZero
        | true => Effect.fail(zeroSentinel)
        | false => Effect.void

      remoteRes = git(["remote", "get-url", "origin"], req.workspace)
      _ <- match remoteRes.exitCode #= 0
        | true => Effect.void
        | false => Effect.fail("Cannot resolve origin: " + messageOf(remoteRes))

      remote = remoteRes.stdout
      tempRes = Bun.spawnSync(["mktemp", "-d"], { stdout: "pipe", stderr: "pipe" })
      tempDir = tempRes.stdout.toString() |> trim

      cloneRes = git(["clone", "--quiet", remote, tempDir], req.workspace)
      _ <- match cloneRes.exitCode #= 0
        | true => Effect.void
        | false => Effect.fail("Cannot create isolated landing repository: " + messageOf(cloneRes))

      fetchRes = git(["fetch", "origin", baseBranch, req.branch], tempDir)
      _ <- match fetchRes.exitCode #= 0
        | true => Effect.void
        | false => Effect.fail("Branch or base validation failed: " + messageOf(fetchRes))

      baseCheck = git(["show-ref", "--verify", "--quiet", "refs/remotes/origin/" + baseBranch], tempDir)
      branchCheck = git(["show-ref", "--verify", "--quiet", "refs/remotes/origin/" + req.branch], tempDir)
      missingBranchMsg = "Configured base branch or task branch does not exist on origin"
      _ <- match baseCheck.exitCode #= 0 and branchCheck.exitCode #= 0
        | true => Effect.void
        | false => Effect.fail(missingBranchMsg)

      landedRes = git([
        "log",
        "refs/remotes/origin/" + baseBranch,
        "--format=%H",
        "--grep=^" + req.taskId + ": landed$"
      ], tempDir)
      alreadyLanded = landedRes.exitCode #= 0 and not (landedRes.stdout
      |> trim
      |> isEmpty)
      _ <- match alreadyLanded
        | false => Effect.void
        | true =>
            firstHash =
              landedRes.stdout
              |> trim
              |> split("\n")
              |> head
              |> getOrElse(() => "")
            Effect.fail("__ALREADY_LANDED__:" + firstHash)

      checkoutRes = git(["checkout", "--quiet", "-B", baseBranch, "refs/remotes/origin/" + baseBranch], tempDir)
      _ <- match checkoutRes.exitCode #= 0
        | true => Effect.void
        | false => Effect.fail("Cannot check out base branch: " + messageOf(checkoutRes))

      mergeRes = git(["merge", "--squash", "refs/remotes/origin/" + req.branch], tempDir)
      _ <- match mergeRes.exitCode #= 0
        | true => Effect.void
        | false => Effect.fail("Squash merge conflict; recovery workspace: " + tempDir + ". " + messageOf(mergeRes))

      commitRes = git(["commit", "-m", "" + req.taskId + ": landed"], tempDir)
      _ <- match commitRes.exitCode #= 0
        | true => Effect.void
        | false => Effect.fail("Landing commit failed; recovery workspace: " + tempDir + ". " + messageOf(commitRes))

      hashRes = git(["rev-parse", "HEAD"], tempDir)
      latestBaseRes = git(["fetch", "origin", baseBranch], tempDir)
      _ <- match latestBaseRes.exitCode #= 0
        | true => Effect.void
        | false => Effect.fail("Cannot refresh base before push; recovery commit " + hashRes.stdout + " retained at " + tempDir + ". " + messageOf(latestBaseRes))

      baseHeadRes = git(["rev-parse", "refs/remotes/origin/" + baseBranch], tempDir)
      parentRes = git(["rev-parse", "HEAD^"], tempDir)
      baseAdvanced = not (baseHeadRes.exitCode #= 0) or not (parentRes.exitCode #= 0) or not (baseHeadRes.stdout #= parentRes.stdout)
      _ <- match baseAdvanced
        | false => Effect.void
        | true => Effect.fail("Base advanced during landing; recovery commit " + hashRes.stdout + " retained at " + tempDir)

      pushRes = git(["push", "origin", "HEAD:refs/heads/" + baseBranch], tempDir)
      _ <- match pushRes.exitCode #= 0
        | true => Effect.void
        | false => Effect.fail("Push failed; recovery commit " + hashRes.stdout + " retained at " + tempDir + ". " + messageOf(pushRes))

      => hashRes.stdout
    }

  handledWorkflow =
    workflow
    |> Effect.map((hash) => succeedLanding(req.taskId, Option.some(hash)))
    |> Effect.catch((err: String) => {
      isZeroErr = err #= "__IS_ZERO__"
      alreadyLanded = err |> String.startsWith("__ALREADY_LANDED__:")
      => match
        | isZeroErr => Effect.sync(() => succeedLanding(req.taskId, Option.none()))
        | alreadyLanded => Effect.sync(() => succeedLanding(req.taskId, Option.some(err |> String.substring(19))))
        | _ => Effect.sync(() => failLanding(req.taskId, err))
    })
  finalResult <- handledWorkflow
  => finalResult
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
