import { Array, Option, Schema, String } from "effect"

export schema TaskNode = {
  id: String
  dependsOn: Array<String>
}

export schema DagSortResult = {
  order: Array<String>
  hasCycle: Boolean
  cycleNodes: Array<String>
}

export findReadyTasks = (nodes: Array<TaskNode>, completedIds: Array<String>) =>
  ready =
    nodes
    |> filter((node) => {
      isCompleted = completedIds |> Array.contains(node.id)
      allDepsDone =
        node.dependsOn
        |> Array.every((dep) => completedIds |> Array.contains(dep))
      match isCompleted
        | true => false
        | false => allDepsDone
    })
  => ready |> map((n) => n.id)

export topologicalSort = (nodes: Array<TaskNode>) =>
  resolveStep = (currentOrder: Array<String>, remaining: Array<TaskNode>): DagSortResult =>
    readyNodes =
      remaining
      |> Array.filter((node) =>
        node.dependsOn
        |> Array.every((dep) => currentOrder |> Array.contains(dep))
      )
    => match
      | remaining.length #= 0 => {
        order: currentOrder
        hasCycle: false
        cycleNodes: []
      }
      | readyNodes.length #= 0 => {
        order: currentOrder
        hasCycle: true
        cycleNodes: remaining |> Array.map((n) => n.id)
      }
      | _ =>
          readyIds = readyNodes |> Array.map((n) => n.id)
          nextOrder = currentOrder |> Array.appendAll(readyIds)
          nextRemaining =
            remaining
            |> Array.filter((n) => not (readyIds |> Array.contains(n.id)))
          => resolveStep(nextOrder, nextRemaining)
  => resolveStep([], nodes)
