import { Array, Option, Schema, String } from "effect"

export schema GitStatus = {
  branch: String
  clean: Boolean
}

export buildCloneCommand = (repoUrl: String, destPath: String, branch: String) =>
  ["git", "clone", "--branch", branch, repoUrl, destPath]

export buildCheckoutCommand = (branch: String, createNew: Boolean) =>
  match createNew
    | true => ["git", "checkout", "-b", branch]
    | false => ["git", "checkout", branch]

export buildBranchMergedCheck = (baseBranch: String, taskBranch: String) =>
  ["git", "merge-base", "--is-ancestor", taskBranch, "origin/" + baseBranch]

export buildCommitCommand = (message: String) =>
  ["git", "commit", "-m", message]

export buildPushCommand = (branch: String) =>
  ["git", "push", "-u", "origin", branch]
