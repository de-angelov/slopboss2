import { afterEach, beforeEach, describe, expect, it } from "bun:test";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import {
  checkFile,
  checkPaths,
  checkSource,
  extractTsBlocks,
  FORBIDDEN_RULES,
  main,
  MAX_BLOCK_LINES,
  stripCommentsAndStrings,
} from "../scripts/check-purity.js";

describe("AST Purity Checker", () => {
  describe("Block Extraction", () => {
    it("extracts top-level ts { ... } block", () => {
      const source = `
import { Effect } from "effect"

ts {
  type UserId = string;
}

export const run = () => Effect.void
`;
      const blocks = extractTsBlocks(source);
      expect(blocks.length).toBe(1);
      expect(blocks[0].startLine).toBe(4);
      expect(blocks[0].endLine).toBe(6);
      expect(blocks[0].content).toContain("type UserId = string;");
    });

    it("extracts inline ts { ... } blocks in type annotations", () => {
      const source = `
assignStore = (target: ts { Record<string, any> }, source: ts { Record<string, any> }): ts { any } => {
  target
}
`;
      const blocks = extractTsBlocks(source);
      expect(blocks.length).toBe(3);
      expect(blocks[0].content.trim()).toBe("Record<string, any>");
      expect(blocks[1].content.trim()).toBe("Record<string, any>");
      expect(blocks[2].content.trim()).toBe("any");
    });

    it("handles nested braces and string literals inside ts { ... } block", () => {
      const source = `
ts {
  type Nested = {
    a: {
      b: { c: string };
    };
  };
  const str = "{ not a block }";
}
`;
      const blocks = extractTsBlocks(source);
      expect(blocks.length).toBe(1);
      expect(blocks[0].content).toContain("b: { c: string };");
      expect(blocks[0].content).toContain('"{ not a block }"');
    });

    it("does not mistake other funscript constructs with braces for ts blocks", () => {
      const source = `
schema Config = {
  host: String,
  port: Number
}

export schema Result = {
  status: String
}
`;
      const blocks = extractTsBlocks(source);
      expect(blocks.length).toBe(0);
    });

    it("does not match identifiers containing 'ts' as ts blocks", () => {
      const source = `
export results = {
  count: 1
}
const datasets = []
`;
      const blocks = extractTsBlocks(source);
      expect(blocks.length).toBe(0);
    });
  });

  describe("Comment and String Stripping", () => {
    it("strips single-line comments while preserving lines", () => {
      const code = `const a = 1; // let x = 2; interface Foo {}\nconst b = 2;`;
      const stripped = stripCommentsAndStrings(code);
      expect(stripped).not.toContain("let x = 2");
      expect(stripped).not.toContain("interface Foo");
      expect(stripped.split("\n").length).toBe(2);
    });

    it("strips multi-line comments while preserving lines", () => {
      const code = `const a = 1; /* \n while (true) {}\n for (const x of y) {}\n */ const b = 2;`;
      const stripped = stripCommentsAndStrings(code);
      expect(stripped).not.toContain("while (true)");
      expect(stripped).not.toContain("for (const x of y)");
      expect(stripped.split("\n").length).toBe(code.split("\n").length);
    });

    it("strips string literals while preserving lines", () => {
      const code = `const msg = "function test() { let z = 1; }";`;
      const stripped = stripCommentsAndStrings(code);
      expect(stripped).not.toContain("function test");
      expect(stripped).not.toContain("let z");
    });
  });

  describe("Forbidden Constructs Detection", () => {
    it("rejects function declaration in ts { ... }", () => {
      const source = `
ts {
  function computeSum(a: number, b: number): number {
    return a + b;
  }
}
`;
      const violations = checkSource(source, "test.fun");
      expect(violations.some((v) => v.construct === "function")).toBe(true);
      expect(violations.some((v) => v.message.includes("'function'"))).toBe(true);
    });

    it("rejects export function declaration in ts { ... }", () => {
      const source = `
ts {
  export function helper(): void {}
}
`;
      const violations = checkSource(source, "test.fun");
      expect(violations.some((v) => v.construct === "export function")).toBe(true);
    });

    it("rejects for ( loops in ts { ... }", () => {
      const sourceStandard = `
ts {
  for (const item of items) {}
}
`;
      const violations1 = checkSource(sourceStandard, "test.fun");
      expect(violations1.some((v) => v.construct === "for (")).toBe(true);

      const sourceTight = `
ts {
  for(let i = 0; i < 10; i++) {}
}
`;
      const violations2 = checkSource(sourceTight, "test.fun");
      expect(violations2.some((v) => v.construct === "for (")).toBe(true);
      expect(violations2.some((v) => v.construct === "let ")).toBe(true);

      const sourceAwait = `
ts {
  for await (const chunk of stream) {}
}
`;
      const violations3 = checkSource(sourceAwait, "test.fun");
      expect(violations3.some((v) => v.construct === "for (")).toBe(true);
    });

    it("rejects while ( loops in ts { ... }", () => {
      const sourceStandard = `
ts {
  while (isActive) {
    break;
  }
}
`;
      const violations1 = checkSource(sourceStandard, "test.fun");
      expect(violations1.some((v) => v.construct === "while (")).toBe(true);

      const sourceTight = `
ts {
  while(true) {}
}
`;
      const violations2 = checkSource(sourceTight, "test.fun");
      expect(violations2.some((v) => v.construct === "while (")).toBe(true);
    });

    it("rejects let variable declarations in ts { ... }", () => {
      const source = `
ts {
  let counter = 0;
  let [a, b] = [1, 2];
}
`;
      const violations = checkSource(source, "test.fun");
      const letViolations = violations.filter((v) => v.construct === "let ");
      expect(letViolations.length).toBeGreaterThanOrEqual(2);
    });

    it("rejects interface declarations in ts { ... }", () => {
      const source = `
ts {
  interface UserProfile {
    id: string;
    name: string;
  }
  export interface SystemConfig {
    debug: boolean;
  }
}
`;
      const violations = checkSource(source, "test.fun");
      const interfaceViolations = violations.filter((v) => v.construct === "interface ");
      expect(interfaceViolations.length).toBe(2);
    });

    it("does not falsely flag words containing substrings of forbidden keywords", () => {
      const source = `
ts {
  type Letter = "a" | "b";
  type Platform = "darwin" | "linux";
  type Whitelist = Record<string, boolean>;
  type InterfaceId = number;
  const letterCount = 10;
}
`;
      const violations = checkSource(source, "test.fun");
      expect(violations.length).toBe(0);
    });

    it("does not flag forbidden keywords in comments or strings", () => {
      const source = `
ts {
  // We avoid let and interface here
  /*
   * function and while (true) loops are strictly forbidden
   */
  const note = "interface with for (let i = 0) while (x)";
  type Clean = {
    tag: "valid";
  };
}
`;
      const violations = checkSource(source, "test.fun");
      expect(violations.length).toBe(0);
    });
  });

  describe("Block Length Limits", () => {
    it("allows ts { ... } blocks with <= 15 lines", () => {
      const lines = [
        "ts {",
        "  type A = string;",
        "  type B = number;",
        "  type C = boolean;",
        "  type D = Record<string, unknown>;",
        "}",
      ];
      const source = lines.join("\n");
      const violations = checkSource(source, "test.fun");
      expect(violations.length).toBe(0);
    });

    it("allows ts { ... } block of exactly 15 lines", () => {
      const lines = [
        "ts {",
        "  type T1 = 1;",
        "  type T2 = 2;",
        "  type T3 = 3;",
        "  type T4 = 4;",
        "  type T5 = 5;",
        "  type T6 = 6;",
        "  type T7 = 7;",
        "  type T8 = 8;",
        "  type T9 = 9;",
        "  type T10 = 10;",
        "  type T11 = 11;",
        "  type T12 = 12;",
        "  type T13 = 13;",
        "}",
      ];
      expect(lines.length).toBe(MAX_BLOCK_LINES);
      const source = lines.join("\n");
      const violations = checkSource(source, "test.fun");
      expect(violations.length).toBe(0);
    });

    it("rejects ts { ... } blocks exceeding 15 lines", () => {
      const lines = ["ts {"];
      for (let i = 1; i <= 16; i++) {
        lines.push(`  type T${i} = ${i};`);
      }
      lines.push("}");

      expect(lines.length).toBeGreaterThan(MAX_BLOCK_LINES);
      const source = lines.join("\n");
      const violations = checkSource(source, "test.fun");

      expect(violations.some((v) => v.construct === "block-length")).toBe(true);
      expect(
        violations.some((v) => v.message.includes(`Block exceeds ${MAX_BLOCK_LINES} lines`))
      ).toBe(true);
    });

    it("flags multiple violations in a single dirty block", () => {
      const lines = [
        "ts {",
        "  export function bad1() {}",
        "  function bad2() {}",
        "  let count = 0;",
        "  for (const x of xs) {}",
        "  while (count < 10) {}",
        "  interface BadInterface {}",
      ];
      for (let i = 1; i <= 12; i++) {
        lines.push(`  type Filler${i} = ${i};`);
      }
      lines.push("}");

      const source = lines.join("\n");
      const violations = checkSource(source, "test.fun");

      expect(violations.some((v) => v.construct === "export function")).toBe(true);
      expect(violations.some((v) => v.construct === "function")).toBe(true);
      expect(violations.some((v) => v.construct === "let ")).toBe(true);
      expect(violations.some((v) => v.construct === "for (")).toBe(true);
      expect(violations.some((v) => v.construct === "while (")).toBe(true);
      expect(violations.some((v) => v.construct === "interface ")).toBe(true);
      expect(violations.some((v) => v.construct === "block-length")).toBe(true);
    });
  });

  describe("File and Directory Checking", () => {
    let tempDir: string;

    beforeEach(() => {
      tempDir = fs.mkdtempSync(path.join(os.tmpdir(), "purity-test-"));
    });

    afterEach(() => {
      if (fs.existsSync(tempDir)) {
        fs.rmSync(tempDir, { recursive: true, force: true });
      }
    });

    it("passes cleanly on pure .fun files and clean type-only ts escapes", () => {
      const cleanFile = path.join(tempDir, "clean.fun");
      fs.writeFileSync(
        cleanFile,
        `
import { Effect } from "effect"

export schema User = {
  id: String,
  name: String
}

export getUser = (id: String): ts { any } => {
  id
}
`
      );

      const violations = checkFile(cleanFile);
      expect(violations.length).toBe(0);

      const result = checkPaths([tempDir]);
      expect(result.violations.length).toBe(0);
      expect(result.filesChecked).toEqual([cleanFile]);
    });

    it("detects violations when checking a directory with violations", () => {
      const cleanFile = path.join(tempDir, "clean.fun");
      const dirtyFile = path.join(tempDir, "dirty.fun");

      fs.writeFileSync(cleanFile, `export const x = 1\n`);
      fs.writeFileSync(
        dirtyFile,
        `
ts {
  export function doImpureThings(): void {
    let counter = 0;
  }
}
`
      );

      const result = checkPaths([tempDir]);
      expect(result.filesChecked.length).toBe(2);
      expect(result.violations.length).toBeGreaterThan(0);
      expect(result.violations.some((v) => v.file === dirtyFile)).toBe(true);
    });

    it("throws when target path does not exist", () => {
      expect(() => {
        checkPaths([path.join(tempDir, "non-existent-path")]);
      }).toThrow(/does not exist/);
    });

    it("verifies pure production files in src/ pass purity check", () => {
      const pureFiles = [
        "src/cli/bin.fun",
        "src/cli/index.fun",
        "src/cli/view.fun",
        "src/domain/board.fun",
        "src/domain/boardstore.fun",
        "src/domain/dag.fun",
        "src/orchestrator/dispatcher.fun",
        "src/orchestrator/mergetrain.fun",
        "src/orchestrator/reconcile.fun",
        "src/services/coordination.fun",
        "src/services/doctor.fun",
        "src/services/git.fun",
        "src/services/prompt.fun",
        "src/services/provider.fun",
        "src/services/runner.fun",
        "src/services/setup.fun",
        "src/services/sys.fun",
        "src/services/tokens.fun",
        "src/ui/dashboard.fun",
      ];

      for (const file of pureFiles) {
        expect(fs.existsSync(file)).toBe(true);
        const violations = checkFile(file);
        expect(violations).toEqual([]);
      }
    });

    it("verifies strict zero-TS invariant across src/: zero .ts or .js files exist", () => {
      function findTsJsFiles(dir: string): string[] {
        const found: string[] = [];
        const entries = fs.readdirSync(dir, { withFileTypes: true });
        for (const entry of entries) {
          const fullPath = path.join(dir, entry.name);
          if (entry.isDirectory()) {
            found.push(...findTsJsFiles(fullPath));
          } else if (entry.isFile() && (entry.name.endsWith(".ts") || entry.name.endsWith(".js"))) {
            found.push(fullPath);
          }
        }
        return found;
      }

      const forbiddenFiles = findTsJsFiles("src");
      expect(forbiddenFiles).toEqual([]);
      expect(fs.existsSync("src/services/platform.ts")).toBe(false);
      expect(fs.existsSync("src/cli/bin.ts")).toBe(false);
    });

    it(
      "verifies funscript check src/ --no-ts passes cleanly with 0 errors",
      async () => {
        const proc = Bun.spawn(["bun", "run", "check"], {
          stdout: "pipe",
          stderr: "pipe",
        });
        const exitCode = await proc.exited;
        const stdout = await new Response(proc.stdout).text();

        expect(exitCode).toBe(0);
        expect(stdout).toMatch(/Checked \d+ files successfully \(0 errors\)/);
      },
      30000
    );
  });

  describe("CLI Execution via Subprocess", () => {
    let tempDir: string;

    beforeEach(() => {
      tempDir = fs.mkdtempSync(path.join(os.tmpdir(), "purity-cli-test-"));
    });

    afterEach(() => {
      if (fs.existsSync(tempDir)) {
        fs.rmSync(tempDir, { recursive: true, force: true });
      }
    });

    it("exits with 0 when target is clean", async () => {
      const cleanFile = path.join(tempDir, "clean.fun");
      fs.writeFileSync(cleanFile, `export const value = 42\n`);

      const proc = Bun.spawn(["bun", "run", "scripts/check-purity.ts", cleanFile], {
        stdout: "pipe",
        stderr: "pipe",
      });

      const exitCode = await proc.exited;
      const stdout = await new Response(proc.stdout).text();

      expect(exitCode).toBe(0);
      expect(stdout).toContain("Purity check passed");
    });

    it("exits with 1 when target has violations", async () => {
      const dirtyFile = path.join(tempDir, "dirty.fun");
      fs.writeFileSync(
        dirtyFile,
        `
ts {
  interface InvalidInterface {
    id: number;
  }
}
`
      );

      const proc = Bun.spawn(["bun", "run", "scripts/check-purity.ts", dirtyFile], {
        stdout: "pipe",
        stderr: "pipe",
      });

      const exitCode = await proc.exited;
      const stderr = await new Response(proc.stderr).text();

      expect(exitCode).toBe(1);
      expect(stderr).toContain("purity violation");
      expect(stderr).toContain("Forbidden construct 'interface '");
    });

    it("exits with 1 when given a non-existent path", async () => {
      const proc = Bun.spawn(
        ["bun", "run", "scripts/check-purity.ts", path.join(tempDir, "missing.fun")],
        {
          stdout: "pipe",
          stderr: "pipe",
        }
      );

      const exitCode = await proc.exited;
      const stderr = await new Response(proc.stderr).text();

      expect(exitCode).toBe(1);
      expect(stderr).toContain("does not exist");
    });

    it("main() function returns 0 on clean target and 1 on violation", async () => {
      const cleanFile = path.join(tempDir, "clean.fun");
      fs.writeFileSync(cleanFile, `export const value = 42\n`);

      const cleanExit = await main([cleanFile], { silent: true });
      expect(cleanExit).toBe(0);

      const dirtyFile = path.join(tempDir, "dirty.fun");
      fs.writeFileSync(
        dirtyFile,
        `
ts {
  let bad = 1;
}
`
      );

      const dirtyExit = await main([dirtyFile], { silent: true });
      expect(dirtyExit).toBe(1);
    });
  });
});
