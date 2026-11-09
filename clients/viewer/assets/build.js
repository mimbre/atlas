// Builds ../priv/static/app.css and ../priv/static/prism/ from the pinned Nova Prism
// package, for offline use. Run `npm ci` then `npm run build` in this directory.
//
// Prism's css/base.css and css/components.css are read here, their @imports inlined and
// every url() asset copied into priv/static/prism/ with its URL rewritten to
// /assets/prism/…, rather than trusting Tailwind to resolve them. The build fails on a
// remote, absolute or missing asset, an unresolvable or conditional import, a version
// other than the pinned ones, or output that lacks the Prism classes the viewer uses.
"use strict";

const fs = require("fs");
const path = require("path");
const { spawnSync } = require("child_process");

const PRISM = "@novasoftwarefoundation/prism";
const VERSIONS = { [PRISM]: "0.1.7", tailwindcss: "3.4.17" };
const USED = ["prism-btn", "prism-tag", "prism-tag-success", "prism-alert", "prism-alert-error", "prism-spinner"];
// Equal to AtlasViewer's @asset_types.
const ASSETS = [".woff2", ".woff", ".ttf", ".otf", ".eot", ".svg", ".png", ".jpg", ".jpeg", ".gif", ".webp"];

const here = __dirname;
const staticDir = path.join(here, "..", "priv", "static");
const assetDir = path.join(staticDir, "prism");
const buildDir = path.join(here, ".build");

function fail(message) {
  console.error("build.js: " + message);
  process.exit(1);
}

function packageRoot(name) {
  const file = path.join(here, "node_modules", name, "package.json");
  if (!fs.existsSync(file)) fail(`${name} is not installed; run npm ci in ${here}`);
  const { version } = JSON.parse(fs.readFileSync(file, "utf8"));
  if (version !== VERSIONS[name]) fail(`${name} is ${version}, expected ${VERSIONS[name]}`);
  return path.dirname(fs.realpathSync(file));
}

const prismRoot = packageRoot(PRISM);
packageRoot("tailwindcss");

function resolveImport(specifier, from) {
  if (/^[a-z]+:/i.test(specifier) || specifier.startsWith("//")) fail(`remote import ${specifier} in ${from}`);
  if (specifier.startsWith(".")) return path.resolve(path.dirname(from), specifier);
  if (specifier.startsWith(PRISM + "/")) return path.join(prismRoot, specifier.slice(PRISM.length + 1));
  try {
    return require.resolve(specifier, { paths: [path.dirname(from), here] });
  } catch {
    fail(`cannot resolve import ${specifier} in ${from}`);
  }
}

function copyAsset(reference, from) {
  if (reference.startsWith("data:") || reference.startsWith("#")) return null;
  if (/^[a-z]+:/i.test(reference) || reference.startsWith("//")) fail(`remote asset ${reference} in ${from}; the viewer must work offline`);
  if (reference.startsWith("/")) fail(`absolute asset ${reference} in ${from}`);
  const [file, suffix] = reference.split(/(?=[?#])/);
  const source = path.resolve(path.dirname(from), decodeURI(file));
  const relative = path.relative(prismRoot, source);
  if (relative.startsWith("..") || path.isAbsolute(relative)) fail(`asset ${reference} in ${from} is outside the Prism package`);
  if (!ASSETS.includes(path.extname(source).toLowerCase())) fail(`asset type of ${reference} in ${from} is not served`);
  if (!fs.statSync(source, { throwIfNoEntry: false })?.isFile()) fail(`asset ${reference} in ${from} does not exist`);
  const target = path.join(assetDir, relative);
  fs.mkdirSync(path.dirname(target), { recursive: true });
  fs.copyFileSync(source, target);
  return "/assets/prism/" + relative.split(path.sep).map(encodeURIComponent).join("/") + (suffix || "");
}

const IMPORT = /@import\s+(?:url\(\s*)?(["']?)([^"')\s;]+)\1\s*\)?\s*([^;]*);/g;
const URL_PATTERN = /url\(\s*(["']?)([^"')]+?)\1\s*\)/g;

function inline(file, seen = new Set()) {
  const real = fs.realpathSync(file);
  if (seen.has(real)) return "";
  seen.add(real);
  const css = fs.readFileSync(real, "utf8").replace(/^@charset[^;]*;/m, "");
  // This file's own url()s are rewritten before its imports are inlined, so an imported
  // file's rewritten URLs are not resolved again against this file.
  const imports = [];
  return css
    .replace(IMPORT, (_, _quote, specifier, condition) => {
      if (condition.trim()) fail(`conditional import ${specifier} ${condition} in ${real}`);
      imports.push(resolveImport(specifier, real));
      return `\u0000${imports.length - 1}\u0000`;
    })
    .replace(URL_PATTERN, (whole, quote, reference) => {
      const rewritten = copyAsset(reference.trim(), real);
      return rewritten === null ? whole : `url("${rewritten}")`;
    })
    .replace(/\u0000(\d+)\u0000/g, (_, index) => inline(imports[Number(index)], seen));
}

fs.rmSync(assetDir, { recursive: true, force: true });
fs.rmSync(buildDir, { recursive: true, force: true });
fs.mkdirSync(buildDir, { recursive: true });

fs.mkdirSync(path.join(assetDir, "fonts"), { recursive: true });
for (const license of ["LICENSE", "fonts/OFL.txt"]) {
  fs.copyFileSync(path.join(prismRoot, license), path.join(assetDir, license));
}
const seen = new Set();
const entry = [
  "@tailwind base;",
  `/* ${PRISM} ${VERSIONS[PRISM]} css/base.css */`,
  inline(path.join(prismRoot, "css", "base.css"), seen),
  `/* ${PRISM} ${VERSIONS[PRISM]} css/components.css */`,
  inline(path.join(prismRoot, "css", "components.css"), seen),
  fs.readFileSync(path.join(here, "app.css"), "utf8"),
].join("\n");
const entryFile = path.join(buildDir, "entry.css");
fs.writeFileSync(entryFile, entry);

const output = path.join(staticDir, "app.css");
const cli = path.join(here, "node_modules", ".bin", process.platform === "win32" ? "tailwindcss.cmd" : "tailwindcss");
const run = spawnSync(cli, ["-c", path.join(here, "tailwind.config.js"), "-i", entryFile, "-o", output, "--minify"], {
  cwd: here,
  stdio: "inherit",
});
if (run.status !== 0) fail("tailwindcss failed");

const built = fs.readFileSync(output, "utf8");
if (/@import/.test(built)) fail("built CSS still contains @import");
for (const name of USED) if (!new RegExp(`\\.${name}(?![\\w-])`).test(built)) fail(`built CSS lacks .${name}`);
for (const [, , reference] of built.matchAll(URL_PATTERN)) {
  if (reference.startsWith("data:") || reference.startsWith("#")) continue;
  if (!reference.startsWith("/assets/prism/")) fail(`built CSS references ${reference}`);
  const file = path.join(assetDir, ...reference.slice("/assets/prism/".length).split(/[?#]/)[0].split("/").map(decodeURIComponent));
  if (!fs.existsSync(file)) fail(`built CSS references missing ${reference}`);
}
fs.rmSync(buildDir, { recursive: true, force: true });
console.log(`build.js: wrote ${path.relative(here, output)} and ${path.relative(here, assetDir)}/ from ${PRISM} ${VERSIONS[PRISM]}`);
