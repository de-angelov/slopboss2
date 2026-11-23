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
  ready = nodes |> filter((node) =>
    isCompleted = completedIds |> Array.contains(node.id)
    allDepsDone = node.dependsOn |> Array.every((dep) => completedIds |> Array.contains(dep))
    when (isCompleted) => false
    => allDepsDone
  )
  => ready |> map((n) => n.id)

export topologicalSort = (nodes: Array<TaskNode>) =>
  resolveStep = (currentOrder: Array<String>, remaining: Array<TaskNode>): DagSortResult =>
    when (remaining.length #= 0) => { order: currentOrder, hasCycle: false, cycleNodes: [] }
    readyNodes = remaining |> filter((node) =>
      node.dependsOn |> Array.every((dep) => currentOrder |> Array.contains(dep))
    )
    when (readyNodes.length #= 0) => { order: currentOrder, hasCycle: true, cycleNodes: remaining |> map((n) => n.id) }
    readyIds = readyNodes |> map((n) => n.id)
    nextOrder = currentOrder |> appendAll(readyIds)
    nextRemaining = remaining |> filter((n) => not (readyIds |> Array.contains(n.id)))
    => resolveStep(nextOrder, nextRemaining)

  => resolveStep([], nodes)
