import { Array, Option, Schema, String } from "effect"

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
  assignee?: String
  branch?: String
  dependsOn: Array<String>
}

export schema Board = {
  tasks: Array<Task>
}

// Parses Markdown bullet tasks
export parseTaskLine = (line: String) =>
  trimmed = line |> String.trim
  parsed = match trimmed
    | t when t |> String.startsWith("- [x]") =>
      body = t |> String.substring(5) |> String.trim
      {
        id: "TASK-" + globalThis.String(Date.now()),
        title: body,
        description: body,
        status: Done,
        dependsOn: []
      }
    | t when t |> String.startsWith("- [/]") =>
      body = t |> String.substring(5) |> String.trim
      {
        id: "TASK-" + globalThis.String(Date.now()),
        title: body,
        description: body,
        status: InProgress,
        dependsOn: []
      }
    | t when t |> String.startsWith("- [ ]") =>
      body = t |> String.substring(5) |> String.trim
      {
        id: "TASK-" + globalThis.String(Date.now()),
        title: body,
        description: body,
        status: Todo,
        dependsOn: []
      }
    | _ =>
      {
        id: "TASK-NOTE",
        title: trimmed,
        description: trimmed,
        status: Blocked,
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
