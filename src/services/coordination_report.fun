import { Effect, FileSystem, Option, Schema, String } from "effect"
import { atomicWriteFileEffect, BunServices } from "../domain/boardstore.js"

export schema CoordinationReport = {
  status: String
  summary: String
}

export error CoordinationReportError(message: String)

export validateCoordinationReport = (report: CoordinationReport) =>
  statusValid = report.status #= "acted" or report.status #= "idle" or report.status #= "blocked"
  summaryLength =
    report.summary
    |> trim
    |> length
  match
    | not statusValid => Effect.fail(CoordinationReportError({ message: "status must be acted, idle, or blocked" }))
    | summaryLength #= 0 or String.length(report.summary) > 2000 => Effect.fail(CoordinationReportError({ message: "summary must be 1 to 2000 characters" }))
    | _ => Effect.succeed(report)

export writeCoordinationReport = (path: String, report: CoordinationReport) => effect {
  _ <- match String.trim(path) #= ""
    | true => Effect.fail(CoordinationReportError({ message: "no active Team Lead coordination session" }))
    | false => Effect.void
  _ <- validateCoordinationReport(report)
  data = Schema.encodeSync(Schema.fromJsonString(CoordinationReport))(report)
  _ <- atomicWriteFileEffect(path, data) |> Effect.provide(BunServices.layer)
  => report
}

export readCoordinationReport = (path: String) =>
  effect {
    fs <- FileSystem.FileSystem
    raw <- fs.readFileString(path)
    parsed = Schema.decodeUnknownOption(Schema.fromJsonString(CoordinationReport))(raw)
    report = parsed |> getOrElse(() => { status: "", summary: "" })
    _ <- validateCoordinationReport(report)
    => report
  }
  |> Effect.provide(BunServices.layer)
