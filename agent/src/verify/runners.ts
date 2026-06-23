import { spawn } from "node:child_process";
import { access, constants } from "node:fs/promises";
import path from "node:path";

export type CheckResult = {
  name: string;
  passed: boolean;
  output: string;
};

export type VerifyReport = {
  file: string;
  allPassed: boolean;
  checks: CheckResult[];
};

type Checker = {
  name: string;
  /** Returns the command to run, or null if this checker doesn't apply to the file/project. */
  resolve: (file: string, projectRoot: string) => Promise<string[] | null>;
};

async function exists(p: string): Promise<boolean> {
  try {
    await access(p, constants.F_OK);
    return true;
  } catch {
    return false;
  }
}

async function run(command: string[], cwd: string, timeoutMs: number): Promise<CheckResult> {
  const name = command.join(" ");
  return new Promise((resolve) => {
    const child = spawn(command[0], command.slice(1), { cwd, shell: false });
    let output = "";
    const timer = setTimeout(() => {
      child.kill("SIGKILL");
      output += "\n[verification timed out]";
    }, timeoutMs);

    child.stdout.on("data", (chunk) => (output += chunk.toString()));
    child.stderr.on("data", (chunk) => (output += chunk.toString()));
    child.on("error", (err) => {
      clearTimeout(timer);
      resolve({ name, passed: false, output: `${output}\n${err.message}` });
    });
    child.on("close", (code) => {
      clearTimeout(timer);
      resolve({ name, passed: code === 0, output });
    });
  });
}

const TS_EXTENSIONS = new Set([".ts", ".tsx", ".js", ".jsx", ".mjs", ".cjs"]);
const PY_EXTENSIONS = new Set([".py"]);

const checkers: Checker[] = [
  {
    name: "eslint",
    resolve: async (file, root) => {
      if (!TS_EXTENSIONS.has(path.extname(file))) return null;
      if (!(await exists(path.join(root, "node_modules/.bin/eslint")))) return null;
      return ["node_modules/.bin/eslint", "--no-warn-ignored", path.relative(root, file)];
    },
  },
  {
    name: "tsc",
    resolve: async (file, root) => {
      if (path.extname(file) !== ".ts" && path.extname(file) !== ".tsx") return null;
      if (!(await exists(path.join(root, "tsconfig.json")))) return null;
      if (!(await exists(path.join(root, "node_modules/.bin/tsc")))) return null;
      return ["node_modules/.bin/tsc", "--noEmit"];
    },
  },
  {
    name: "ruff",
    resolve: async (file) => {
      if (!PY_EXTENSIONS.has(path.extname(file))) return null;
      return ["ruff", "check", file];
    },
  },
  {
    name: "mypy",
    resolve: async (file) => {
      if (!PY_EXTENSIONS.has(path.extname(file))) return null;
      return ["mypy", "--ignore-missing-imports", file];
    },
  },
];

/**
 * Runs every applicable checker for a single changed file. Checkers that
 * don't apply (wrong language, tool not installed/configured) are skipped
 * rather than failed, so a polyglot workspace doesn't get false negatives.
 */
export async function verifyFile(file: string, projectRoot: string, timeoutMs: number): Promise<VerifyReport> {
  const checks: CheckResult[] = [];

  for (const checker of checkers) {
    const command = await checker.resolve(file, projectRoot).catch(() => null);
    if (!command) continue;
    checks.push(await run(command, projectRoot, timeoutMs));
  }

  return { file, allPassed: checks.every((c) => c.passed), checks };
}

/**
 * Runs the project's test suite once, used by the debounced PostToolBatch hook
 * rather than per-edit to conserve NIM's free-tier rate limit and credits.
 */
export async function runTestSuite(projectRoot: string, timeoutMs: number): Promise<CheckResult | null> {
  if (await exists(path.join(projectRoot, "package.json"))) {
    return run(["npm", "test", "--silent"], projectRoot, timeoutMs);
  }
  if (await exists(path.join(projectRoot, "pyproject.toml"))) {
    return run(["pytest", "-q"], projectRoot, timeoutMs);
  }
  return null;
}

/**
 * Lints the whole project, used by the debounced PostToolBatch hook as a
 * backstop. createVerifyFileHook only sees edits made through Write/Edit/
 * MultiEdit; a model that changes code via Bash (sed, a formatter's own
 * --fix flag, etc.) skips that per-file check entirely. This catches it on
 * the next batch boundary regardless of which tool touched the file.
 */
export async function runProjectLint(projectRoot: string, timeoutMs: number): Promise<CheckResult | null> {
  if (await exists(path.join(projectRoot, "node_modules/.bin/eslint"))) {
    return run(["node_modules/.bin/eslint", "."], projectRoot, timeoutMs);
  }
  if (await which("ruff")) {
    return run(["ruff", "check", "."], projectRoot, timeoutMs);
  }
  return null;
}

async function which(bin: string): Promise<boolean> {
  return new Promise((resolve) => {
    const child = spawn("which", [bin], { shell: false });
    child.on("close", (code) => resolve(code === 0));
    child.on("error", () => resolve(false));
  });
}
