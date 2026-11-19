import { Array, DateTime, Option, Schema, String } from "effect"

export schema TaskStatus =
  | Todo
  | InProgress
  | Blocked
  | Done

export schema Task = {
  id: String
  title: String
  description: String
  status: TaskStatus
  assignee: Option<String>
  branch: Option<String>
  dependsOn: Array<String>
}

export schema Board = {
  tasks: Array<Task>
}

// Parses Markdown bullet tasks
export parseTaskLine = (line: String) =>
  trimmed = line |> String.trim
  nowMs = DateTime.toEpochMillis(DateTime.nowUnsafe())
  parsed = match trimmed
    | t when t |> String.startsWith("- [x]") =>
      body = t |> String.substring(5) |> String.trim
      {
        id: "TASK-" + globalThis.String(nowMs),
        title: body,
        description: body,
        status: Done,
        assignee: Option.none(),
        branch: Option.none(),
        dependsOn: []
      }
    | t when t |> String.startsWith("- [/]") =>
      body = t |> String.substring(5) |> String.trim
      {
        id: "TASK-" + globalThis.String(nowMs),
        title: body,
        description: body,
        status: InProgress,
        assignee: Option.none(),
        branch: Option.none(),
        dependsOn: []
      }
    | t when t |> String.startsWith("- [ ]") =>
      body = t |> String.substring(5) |> String.trim
      {
        id: "TASK-" + globalThis.String(nowMs),
        title: body,
        description: body,
        status: Todo,
        assignee: Option.none(),
        branch: Option.none(),
        dependsOn: []
      }
    | _ =>
      {
        id: "TASK-NOTE",
        title: trimmed,
        description: trimmed,
        status: Blocked,
        assignee: Option.none(),
        branch: Option.none(),
        dependsOn: []
      }
  => parsed

export formatTaskLine = (task: Task) =>
  prefix = match task.status
    | Done => "- [x] "
    | InProgress => "- [/] "
    | Blocked => "- [!] "
    | Todo => "- [ ] "
  
  meta = match task.assignee
    | Some(agent) => " [assigned: " + agent + "]"
    | None => ""

  => prefix + task.id + ": " + task.title + meta
