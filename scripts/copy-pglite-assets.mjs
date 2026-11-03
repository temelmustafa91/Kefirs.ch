import { copyFileSync, existsSync, readdirSync, statSync } from "node:fs";
import { join } from "node:path";

// Nitro inlines `@electric-sql/pglite` and the wasm/data files are not emitted.
// Copy them beside the bundled module after the Vercel preset has written
// `.vercel/output` (its own `compiled` hook must stay intact).
const root = process.cwd();
const srcDir = join(root, "node_modules/@electric-sql/pglite/dist");
const files = ["pglite.data", "pglite.wasm", "initdb.wasm"];
const functionsDir = join(root, ".vercel/output/functions");

function copyInto(funcDir) {
  const destDir = join(funcDir, "_libs");
  if (!existsSync(destDir)) return;
  for (const name of files) {
    const from = join(srcDir, name);
    if (!existsSync(from)) continue;
    copyFileSync(from, join(destDir, name));
  }
}

function walk(dir) {
  if (!existsSync(dir)) return;
  for (const name of readdirSync(dir)) {
    const path = join(dir, name);
    let st;
    try {
      st = statSync(path);
    } catch {
      continue;
    }
    if (!st.isDirectory()) continue;
    if (name.endsWith(".func")) copyInto(path);
    else walk(path);
  }
}

walk(functionsDir);
