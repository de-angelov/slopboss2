import * as fs from "node:fs";
import { createRequire } from "node:module";
import * as path from "node:path";

export interface PurityViolation {
  file: string;
  line: number;
  column: number;
  construct: string;
  message: string;
}

export interface TsBlock {
  startLine: number;
  startCol: number;
  endLine: number;
  endCol: number;
  contentStartLine: number;
  contentStartCol: number;
  content: string;
  raw: string;
}

export interface CheckPurityResult {
  violations: PurityViolation[];
  filesChecked: string[];
}

export const FORBIDDEN_RULES: Array<{
  construct: string;
  regex: RegExp;
}> = [
  { construct: "export function", regex: /\bexport\s+(?:async\s+)?function\b/g },
  { construct: "function", regex: /(?<!\bexport\s+(?:async\s+)?)\b(?:async\s+)?function\b/g },
  { construct: "for (", regex: /\bfor\s*(?:await\s*)?\(/g },
  { construct: "while (", regex: /\bwhile\s*\(/g },
  { construct: "let ", regex: /\blet\s+/g },
  { construct: "interface ", regex: /\binterface\s+/g },
];

export const MAX_BLOCK_LINES = 15;

let cachedLexer: any = null;
let cachedParser: any = null;

/**
 * Dynamically resolves and loads the FunScript compiler's Lexer and Parser if available.
 */
export function getFunScriptClasses(): { Lexer: any; Parser: any } | null {
  if (cachedLexer && cachedParser) {
    return { Lexer: cachedLexer, Parser: cachedParser };
  }

  try {
    const req = createRequire(import.meta.url);
    const lexerModule = req("../node_modules/funscript/dist/lexer/lexer.js");
    const parserModule = req("../node_modules/funscript/dist/parser/parser.js");
    cachedLexer = lexerModule.Lexer;
    cachedParser = parserModule.Parser;
    return { Lexer: cachedLexer, Parser: cachedParser };
  } catch {
    try {
      const req = createRequire(import.meta.url);
      const fsPkgDir = path.dirname(req.resolve("funscript/package.json"));
      const lexerModule = req(path.join(fsPkgDir, "dist/lexer/lexer.js"));
      const parserModule = req(path.join(fsPkgDir, "dist/parser/parser.js"));
      cachedLexer = lexerModule.Lexer;
      cachedParser = parserModule.Parser;
      return { Lexer: cachedLexer, Parser: cachedParser };
    } catch {
      return null;
    }
  }
}

/**
 * Parses FunScript source using the official FunScript AST parser.
 * Returns null if the compiler classes are unavailable or if parsing fails.
 */
export function parseWithFunScriptAst(source: string, filename = "<unknown>"): any {
  const classes = getFunScriptClasses();
  if (!classes) return null;
  try {
    const lexer = new classes.Lexer(source, filename);
    const tokens = lexer.tokenize();
    const parser = new classes.Parser(tokens, filename, source);
    return parser.parse();
  } catch {
    return null;
  }
}

/**
 * Extracts TsEscape nodes directly from FunScript AST when available.
 */
export function extractTsBlocksFromAst(source: string, filename = "<unknown>"): TsBlock[] | null {
  const ast = parseWithFunScriptAst(source, filename);
  if (!ast) return null;

  const blocks: TsBlock[] = [];
  function walk(node: any) {
    if (!node || typeof node !== "object") return;
    if (
      node.kind === "TsEscapeDeclaration" ||
      node.kind === "TsEscapeExpression" ||
      node.kind === "TsEscapeTypeNode"
    ) {
      if (node.span) {
        const raw = source.slice(node.span.start.offset, node.span.end.offset);
        const openBraceIdx = raw.indexOf("{");
        const closeBraceIdx = raw.lastIndexOf("}");
        const content =
          openBraceIdx !== -1 && closeBraceIdx !== -1
            ? raw.slice(openBraceIdx + 1, closeBraceIdx)
            : node.code || "";

        const beforeOpen = raw.slice(0, openBraceIdx + 1);
        const beforeLines = beforeOpen.split("\n");
        const contentStartLine = node.span.start.line + beforeLines.length - 1;
        const contentStartCol =
          beforeLines.length === 1
            ? node.span.start.column + openBraceIdx + 1
            : beforeLines[beforeLines.length - 1].length + 1;

        blocks.push({
          startLine: node.span.start.line,
          startCol: node.span.start.column,
          endLine: node.span.end.line,
          endCol: node.span.end.column,
          contentStartLine,
          contentStartCol,
          content,
          raw,
        });
      }
    }
    for (const key of Object.keys(node)) {
      if (key === "span") continue;
      const val = node[key];
      if (Array.isArray(val)) {
        for (const item of val) walk(item);
      } else if (val && typeof val === "object") {
        walk(val);
      }
    }
  }

  walk(ast);
  return blocks;
}

/**
 * Replaces characters inside comments and string literals with spaces.
 * Preserves exact line numbers and column offsets without producing false positive keyword matches.
 */
export function stripCommentsAndStrings(code: string): string {
  let result = "";
  let i = 0;
  const len = code.length;
  let inString: string | null = null;
  let inLineComment = false;
  let inBlockComment = false;

  while (i < len) {
    const ch = code[i];
    const next = code[i + 1];

    if (inLineComment) {
      if (ch === "\n") {
        inLineComment = false;
        result += "\n";
      } else {
        result += " ";
      }
      i++;
      continue;
    }

    if (inBlockComment) {
      if (ch === "*" && next === "/") {
        inBlockComment = false;
        result += "  ";
        i += 2;
        continue;
      }
      result += ch === "\n" ? "\n" : " ";
      i++;
      continue;
    }

    if (inString) {
      if (ch === "\\") {
        result += "  ";
        i += 2;
        continue;
      }
      if (ch === inString) {
        inString = null;
        result += " ";
        i++;
        continue;
      }
      result += ch === "\n" ? "\n" : " ";
      i++;
      continue;
    }

    if (ch === "/" && next === "/") {
      inLineComment = true;
      result += "  ";
      i += 2;
      continue;
    }

    if (ch === "/" && next === "*") {
      inBlockComment = true;
      result += "  ";
      i += 2;
      continue;
    }

    if (ch === '"' || ch === "'" || ch === "`") {
      inString = ch;
      result += " ";
      i++;
      continue;
    }

    result += ch;
    i++;
  }

  return result;
}

/**
 * Scans FunScript source text and extracts all `ts { ... }` blocks with exact line/column positions.
 * Handles nested braces, strings, and comments.
 */
export function extractTsBlocks(source: string, filename = "<unknown>"): TsBlock[] {
  // First attempt FunScript AST extraction if possible
  const astBlocks = extractTsBlocksFromAst(source, filename);
  if (astBlocks && astBlocks.length > 0) {
    return astBlocks;
  }

  // Fallback to robust token/lexical extraction
  const blocks: TsBlock[] = [];
  const len = source.length;
  let i = 0;
  let line = 1;
  let col = 1;
  let inString: string | null = null;
  let inLineComment = false;
  let inBlockComment = false;

  function advance(): string {
    const ch = source[i++];
    if (ch === "\n") {
      line++;
      col = 1;
    } else {
      col++;
    }
    return ch;
  }

  while (i < len) {
    const ch = source[i];
    const next = source[i + 1];

    if (inLineComment) {
      if (ch === "\n") inLineComment = false;
      advance();
      continue;
    }
    if (inBlockComment) {
      if (ch === "*" && next === "/") {
        advance();
        advance();
        inBlockComment = false;
        continue;
      }
      advance();
      continue;
    }
    if (inString) {
      if (ch === "\\") {
        advance();
        advance();
        continue;
      }
      if (ch === inString) inString = null;
      advance();
      continue;
    }

    if (ch === "/" && next === "/") {
      inLineComment = true;
      advance();
      advance();
      continue;
    }
    if (ch === "/" && next === "*") {
      inBlockComment = true;
      advance();
      advance();
      continue;
    }
    if (ch === '"' || ch === "'" || ch === "`") {
      inString = ch;
      advance();
      continue;
    }

    // Check for 'ts' keyword followed by '{'
    const isWordStart = i === 0 || /[^a-zA-Z0-9_$]/.test(source[i - 1]);
    if (isWordStart && source.slice(i, i + 2) === "ts") {
      let j = i + 2;
      while (
        j < len &&
        (source[j] === " " || source[j] === "\t" || source[j] === "\r" || source[j] === "\n")
      ) {
        j++;
      }
      if (source[j] === "{") {
        const startLine = line;
        const startCol = col;
        const startOffset = i;

        while (i <= j) {
          advance();
        }

        let depth = 1;
        let tsStr: string | null = null;
        let tsLineComm = false;
        let tsBlockComm = false;
        const contentStartOffset = i;
        const contentStartLine = line;
        const contentStartCol = col;

        while (i < len && depth > 0) {
          const c = source[i];
          const n = source[i + 1];

          if (tsLineComm) {
            if (c === "\n") tsLineComm = false;
            advance();
            continue;
          }
          if (tsBlockComm) {
            if (c === "*" && n === "/") {
              advance();
              advance();
              tsBlockComm = false;
              continue;
            }
            advance();
            continue;
          }
          if (tsStr) {
            if (c === "\\") {
              advance();
              advance();
              continue;
            }
            if (c === tsStr) tsStr = null;
            advance();
            continue;
          }
          if (c === "/" && n === "/") {
            tsLineComm = true;
            advance();
            advance();
            continue;
          }
          if (c === "/" && n === "*") {
            tsBlockComm = true;
            advance();
            advance();
            continue;
          }
          if (c === '"' || c === "'" || c === "`") {
            tsStr = c;
            advance();
            continue;
          }
          if (c === "{") {
            depth++;
            advance();
            continue;
          }
          if (c === "}") {
            depth--;
            if (depth === 0) {
              const contentEndOffset = i;
              const endLine = line;
              const endCol = col;
              advance();
              blocks.push({
                startLine,
                startCol,
                endLine,
                endCol,
                content: source.slice(contentStartOffset, contentEndOffset),
                contentStartLine,
                contentStartCol,
                raw: source.slice(startOffset, i),
              });
              break;
            }
            advance();
            continue;
          }
          advance();
        }
        continue;
      }
    }

    advance();
  }

  return blocks;
}

/**
 * Inspects source code of a `.fun` file and returns any purity violations.
 */
export function checkSource(source: string, filename = "<unknown>"): PurityViolation[] {
  const violations: PurityViolation[] = [];
  const blocks = extractTsBlocks(source, filename);

  for (const block of blocks) {
    const lineCount = block.endLine - block.startLine + 1;
    if (lineCount > MAX_BLOCK_LINES) {
      violations.push({
        file: filename,
        line: block.startLine,
        column: block.startCol,
        construct: "block-length",
        message: `Block exceeds ${MAX_BLOCK_LINES} lines (${lineCount} lines, maximum allowed is ${MAX_BLOCK_LINES})`,
      });
    }

    const cleanContent = stripCommentsAndStrings(block.content);

    for (const rule of FORBIDDEN_RULES) {
      rule.regex.lastIndex = 0;
      let match: RegExpExecArray | null;
      while ((match = rule.regex.exec(cleanContent)) !== null) {
        const offset = match.index;
        const linesBefore = cleanContent.slice(0, offset).split("\n");
        const line = block.contentStartLine + linesBefore.length - 1;
        const col =
          linesBefore.length === 1
            ? block.contentStartCol + offset
            : linesBefore[linesBefore.length - 1].length + 1;

        violations.push({
          file: filename,
          line,
          column: col,
          construct: rule.construct,
          message: `Forbidden construct '${rule.construct}' found in ts { ... } block`,
        });
      }
    }
  }

  return violations;
}

/**
 * Checks a single `.fun` file for purity violations.
 */
export function checkFile(filePath: string): PurityViolation[] {
  const content = fs.readFileSync(filePath, "utf8");
  return checkSource(content, filePath);
}

/**
 * Recursively collects all `.fun` files from target path (file or directory).
 */
export function collectFunFiles(targetPath: string): string[] {
  if (!fs.existsSync(targetPath)) {
    throw new Error(`Target path does not exist: ${targetPath}`);
  }

  const stat = fs.statSync(targetPath);
  if (stat.isFile()) {
    return [targetPath];
  }

  if (stat.isDirectory()) {
    const results: string[] = [];
    const entries = fs.readdirSync(targetPath, { withFileTypes: true });
    for (const entry of entries) {
      const fullPath = path.join(targetPath, entry.name);
      if (entry.isDirectory()) {
        results.push(...collectFunFiles(fullPath));
      } else if (entry.isFile() && entry.name.endsWith(".fun")) {
        results.push(fullPath);
      }
    }
    return results;
  }

  return [];
}

/**
 * Checks multiple paths or directories for purity violations.
 */
export function checkPaths(targets: string[]): CheckPurityResult {
  const filesChecked: string[] = [];
  const violations: PurityViolation[] = [];

  for (const target of targets) {
    const files = collectFunFiles(target);
    for (const file of files) {
      if (!filesChecked.includes(file)) {
        filesChecked.push(file);
        const fileViolations = checkFile(file);
        violations.push(...fileViolations);
      }
    }
  }

  return { violations, filesChecked };
}

/**
 * CLI Entrypoint.
 * Returns exit code: 0 if clean, 1 if violations found or errors occur.
 */
export async function main(
  args: string[] = process.argv.slice(2),
  options: { silent?: boolean } = {}
): Promise<number> {
  const targets = args.length > 0 ? args : [fs.existsSync("src") ? "src" : "."];

  try {
    const { violations, filesChecked } = checkPaths(targets);

    if (filesChecked.length === 0) {
      if (!options.silent) {
        console.log(`[purity] No .fun files found in target(s): ${targets.join(", ")}`);
      }
      return 0;
    }

    if (violations.length > 0) {
      const filesWithViolations = new Set(violations.map((v) => v.file)).size;
      if (!options.silent) {
        console.error(
          `\n❌ [purity] Found ${violations.length} purity violation(s) across ${filesWithViolations} file(s):\n`
        );

        for (const v of violations) {
          console.error(`  ${v.file}:${v.line}:${v.column} - ${v.message}`);
        }

        console.error(
          `\nPurity check failed: ${violations.length} violation(s) found in ${filesChecked.length} file(s) checked.\n`
        );
      }
      return 1;
    }

    if (!options.silent) {
      console.log(
        `✅ [purity] Purity check passed: ${filesChecked.length} .fun file(s) inspected, 0 violations.`
      );
    }
    return 0;
  } catch (error: any) {
    if (!options.silent) {
      console.error(`❌ [purity] Error: ${error.message}`);
    }
    return 1;
  }
}

if (import.meta.main) {
  const exitCode = await main();
  process.exit(exitCode);
}
