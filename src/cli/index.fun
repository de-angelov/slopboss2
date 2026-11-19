import { Effect, Option, Schema } from "effect"
import * as core from "./cli_core.js"

export DEFAULT_BOARD_DIR = core.DEFAULT_BOARD_DIR

export buildGroomPrompt = (boardDir: String, backlogContent: String) => core.buildGroomPrompt(boardDir, backlogContent)

export buildGroomPromptFun = (boardDir: String, backlogContent: String) => core.buildGroomPrompt(boardDir, backlogContent)

export formatDoctorTable = (report: ts { any }) => core.formatDoctorTable(report)

export getHelpMessage = (subcommand: ts { any }) => core.getHelpMessage(subcommand)

export parseCliArgs = (argv: ts { any }) => core.parseCliArgs(argv)

export printStatus = (boardDir: String) => core.printStatus(boardDir)

export printStatusFun = (boardDir: String) => core.printStatus(boardDir)

export runSetup = (boardDir: String, repoUrl: String) => core.runSetup(boardDir, repoUrl)

export runSetupFun = (boardDir: String, repoUrl: String) => core.runSetup(boardDir, repoUrl)

export launchInteractiveGroom = (boardDir: String, model: ts { any }) => core.launchInteractiveGroom(boardDir, model)

export launchInteractiveGroomFun = (boardDir: String, model: ts { any }) => core.launchInteractiveGroom(boardDir, model)

export runDoctorCommand = (dir: String) => core.runDoctorCommand(dir)

export runReconcilerCommand = (dir: String, detach: Boolean, options: ts { any }, maxTicks: Number, pollIntervalMs: Number) => core.runReconcilerCommand(dir, detach, options, maxTicks, pollIntervalMs)

export runInitCommand = (dir: String, repoUrl: String, agents: Number) => core.runInitCommand(dir, repoUrl, agents)

export runGroomCommand = (dir: String, model: ts { any }) => core.runGroomCommand(dir, model)

export runViewCommand = (dir: String, pollIntervalMs: Number) => core.runViewCommand(dir, pollIntervalMs)

export runViewCommandFun = (boardDir: String, pollMs: Number) => core.runViewCommand(boardDir, pollMs)

export runControlLoop = (boardDir: String, maxTicks: Number) => core.runControlLoop(boardDir, maxTicks)

export runControlLoopFun = (boardDir: String, maxTicks: Number) => core.runControlLoop(boardDir, maxTicks)

export dispatchCli = (command: ts { any }, options: ts { any }) => core.dispatchCli(command, options)

export runCli = (argv: ts { any }, options: ts { any }) => core.runCli(argv, options)

export runCliFun = () => core.runCli()
