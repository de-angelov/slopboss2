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
  ready = nodes |> Array.filter((node) =>
    isCompleted = completedIds |> Array.contains(node.id)
    allDepsDone = node.dependsOn |> Array.every((dep) => completedIds |> Array.contains(dep))
    when (isCompleted) => false
    => allDepsDone
  )
  => ready |> Array.map((n) => n.id)

export topologicalSort = (nodes: Array<TaskNode>) =>
  resolveStep = (currentOrder: Array<String>, remaining: Array<TaskNode>): DagSortResult =>
    when (remaining.length #= 0) => { order: currentOrder, hasCycle: false, cycleNodes: [] }
    readyNodes = remaining |> Array.filter((node) =>
      node.dependsOn |> Array.every((dep) => currentOrder |> Array.contains(dep))
    )
    when (readyNodes.length #= 0) => { order: currentOrder, hasCycle: true, cycleNodes: remaining |> Array.map((n) => n.id) }
    readyIds = readyNodes |> Array.map((n) => n.id)
    nextOrder = currentOrder |> Array.appendAll(readyIds)
    nextRemaining = remaining |> Array.filter((n) => not (readyIds |> Array.contains(n.id)))
    => resolveStep(nextOrder, nextRemaining)

  => resolveStep([], nodes)
