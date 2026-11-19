// FunScript Project Configuration & Best Practices Policy
//
// Policies supported:
// - noTs: boolean | string[] - Disallows ts { ... } escapes and standalone .ts files
// - noGlobalThis: boolean | string[] - Disallows direct references to globalThis
// - effectOnly: string[] - Restricts directories to pure Effect workflows and types

export config = {
  noTs: [
    "src/services",
    "src/ui"
  ]
}
