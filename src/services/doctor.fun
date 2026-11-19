import { Array, Effect } from "effect"

ts {
  import * as fs from "node:fs";
  import * as path from "node:path";

  export interface CheckResultTs {
    name: string;
    ok: boolean;
    message: string;
    required: boolean;
  }

  export interface DoctorReportTs {
    isHealthy: boolean;
    checks: CheckResultTs[];
  }

  export function checkGitInstalledSync(gitCmd: string = "git"): CheckResultTs {
    try {
      const proc = Bun.spawnSync([gitCmd, "--version"]);
      if (proc.exitCode === 0) {
        const output = proc.stdout.toString().trim();
        return {
          name: "git",
          ok: true,
          message: output || "Git is installed",
          required: true,
        };
      }
      const err = proc.stderr.toString().trim() || proc.stdout.toString().trim();
      return {
        name: "git",
        ok: false,
        message: err || `git command exited with code ${proc.exitCode}`,
        required: true,
      };
    } catch (err: any) {
      return {
        name: "git",
        ok: false,
        message: err?.message || "git executable not found in PATH",
        required: true,
      };
    }
  }

  export function checkBunInstalledSync(bunCmd: string = "bun"): CheckResultTs {
    try {
      const proc = Bun.spawnSync([bunCmd, "--version"]);
      if (proc.exitCode === 0) {
        const output = proc.stdout.toString().trim();
        return {
          name: "bun",
          ok: true,
          message: output ? `bun ${output}` : "Bun is installed",
          required: true,
        };
      }
      const err = proc.stderr.toString().trim() || proc.stdout.toString().trim();
      return {
        name: "bun",
        ok: false,
        message: err || `bun command exited with code ${proc.exitCode}`,
        required: true,
      };
    } catch (err: any) {
      return {
        name: "bun",
        ok: false,
        message: err?.message || "bun executable not found in PATH",
        required: true,
      };
    }
  }

  export function checkProviderInstalledSync(customProviders?: readonly string[] | string[]): CheckResultTs {
    const providersToCheck =
      customProviders && customProviders.length > 0
        ? customProviders
        : ["agy", "gemini"];

    for (const provider of providersToCheck) {
      try {
        const proc = Bun.spawnSync([provider, "--version"]);
        if (proc.exitCode === 0) {
          const ver = proc.stdout.toString().trim();
          const providerLabel =
            provider === "agy"
              ? "Antigravity CLI (agy)"
              : provider === "gemini"
              ? "Gemini CLI"
              : provider;
          return {
            name: "provider",
            ok: true,
            message: `${providerLabel} available${ver ? ` (v${ver})` : ""}`,
            required: true,
          };
        }
      } catch (_e) {
        // Not in PATH, continue checking fallback
      }
    }

    return {
      name: "provider",
      ok: false,
      message: `Neither 'agy' nor 'gemini' CLI executable found in PATH`,
      required: true,
    };
  }

  export function checkBoardDirectorySync(boardDir: string): CheckResultTs {
    if (!boardDir || typeof boardDir !== "string" || !fs.existsSync(boardDir)) {
      return {
        name: "board",
        ok: false,
        message: `Board directory does not exist: ${boardDir}`,
        required: true,
      };
    }

    try {
      const stat = fs.statSync(boardDir);
      if (!stat.isDirectory()) {
        return {
          name: "board",
          ok: false,
          message: `Board path is not a directory: ${boardDir}`,
          required: true,
        };
      }
    } catch (err: any) {
      return {
        name: "board",
        ok: false,
        message: `Failed to inspect board directory: ${err?.message || boardDir}`,
        required: true,
      };
    }

    const requiredFiles = ["TASKS.md", "ARCHIVE.md", "AGENTS.md"];
    const missingFiles = requiredFiles.filter(
      (file) => !fs.existsSync(path.join(boardDir, file))
    );

    if (missingFiles.length > 0) {
      return {
        name: "board",
        ok: false,
        message: `Missing required board files in ${boardDir}: ${missingFiles.join(", ")}`,
        required: true,
      };
    }

    return {
      name: "board",
      ok: true,
      message: `Board directory contains all required files (${requiredFiles.join(", ")})`,
      required: true,
    };
  }

  export function checkWorkspacesSync(boardDir: string): CheckResultTs {
    if (!boardDir || typeof boardDir !== "string" || !fs.existsSync(boardDir)) {
      return {
        name: "workspaces",
        ok: false,
        message: `Board directory does not exist: ${boardDir}`,
        required: true,
      };
    }

    const workspacesPath = path.join(boardDir, "workspaces");
    if (!fs.existsSync(workspacesPath)) {
      return {
        name: "workspaces",
        ok: false,
        message: `Workspaces directory does not exist at ${workspacesPath}`,
        required: true,
      };
    }

    try {
      const stat = fs.statSync(workspacesPath);
      if (!stat.isDirectory()) {
        return {
          name: "workspaces",
          ok: false,
          message: `Workspaces path is not a directory: ${workspacesPath}`,
          required: true,
        };
      }
    } catch (err: any) {
      return {
        name: "workspaces",
        ok: false,
        message: `Failed to inspect workspaces directory: ${err?.message || workspacesPath}`,
        required: true,
      };
    }

    try {
      fs.accessSync(workspacesPath, fs.constants.R_OK | fs.constants.W_OK);
      return {
        name: "workspaces",
        ok: true,
        message: `Workspaces directory exists with read/write access: ${workspacesPath}`,
        required: true,
      };
    } catch (err: any) {
      return {
        name: "workspaces",
        ok: false,
        message: `Workspaces directory lacks read/write permissions: ${err?.message || workspacesPath}`,
        required: true,
      };
    }
  }

  export function runDoctorSync(boardDir: string): DoctorReportTs {
    const checks = [
      checkGitInstalledSync(),
      checkBunInstalledSync(),
      checkProviderInstalledSync(),
      checkBoardDirectorySync(boardDir),
      checkWorkspacesSync(boardDir),
    ];
    const isHealthy = checks.every((c) => (c.required ? c.ok : true));
    return {
      isHealthy,
      checks,
    };
  }
}

export schema CheckResult = {
  name: String
  ok: Boolean
  message: String
  required: Boolean
}

export schema DoctorReport = {
  isHealthy: Boolean
  checks: Array<CheckResult>
}

export checkGitInstalled = () => effect
  => checkGitInstalledSync("git")

export checkGitInstalledWith = (gitCmd: String) => effect
  => checkGitInstalledSync(gitCmd)

export checkBunInstalled = () => effect
  => checkBunInstalledSync("bun")

export checkBunInstalledWith = (bunCmd: String) => effect
  => checkBunInstalledSync(bunCmd)

export checkProviderInstalled = () => effect
  => checkProviderInstalledSync([])

export checkProviderInstalledWith = (providers: Array<String>) => effect
  => checkProviderInstalledSync(providers)

export checkBoardDirectory = (boardDir: String) => effect
  => checkBoardDirectorySync(boardDir)

export checkWorkspaces = (boardDir: String) => effect
  => checkWorkspacesSync(boardDir)

export runDoctor = (boardDir: String) => effect
  gitCheck <- checkGitInstalled()
  bunCheck <- checkBunInstalled()
  providerCheck <- checkProviderInstalled()
  boardCheck <- checkBoardDirectory(boardDir)
  workspacesCheck <- checkWorkspaces(boardDir)
  allChecks = [gitCheck, bunCheck, providerCheck, boardCheck, workspacesCheck]
  healthy = allChecks |> Array.every((c) => match c.required
    | true => c.ok
    | false => true
  )
  => {
    isHealthy: healthy,
    checks: allChecks
  }
