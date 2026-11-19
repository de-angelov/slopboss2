import { main } from "./check-purity.js";

// Execute purity checker before test suites run
const exitCode = await main(["src"], { silent: false });
if (exitCode !== 0) {
  console.error("❌ [purity] Purity gate failed! Cheating or forbidden constructs detected in .fun files.");
  process.exit(exitCode);
}
