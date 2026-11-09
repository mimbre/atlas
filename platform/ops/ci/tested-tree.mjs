// CI tests a tree once (docs/guides/prod.md, "CI tests a tree once").
//
// Two records, both artifacts listed repository-wide by name:
//   tested-tree-<tree>               every test job passed on this tree (record-tested-tree);
//   tested-base-<tree>-<base key>    the base check passed on this tree against a base whose
//                                    base file has this blob (record-tested-base). The base
//                                    check's result depends on the tree and that file only.
// On a push to develop or master, and on a pull request into master, `find` looks them up and
// trusts one only when it comes from a completed, successful run of this same workflow file,
// in this repository, not from a fork, not this run, and not expired. Anything else, a lookup
// error included, means the job runs: `find` and `keys` never exit non-zero.
//
// `check-workflow <file>` fails when a job of the workflow is outside that scheme.
//
// Functions return codes; only the edge (summary lines, console) turns them into words.
// Plain Node 18+, no dependencies.

import { appendFileSync, readFileSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
import { pathToFileURL } from 'node:url';

export const suiteRecord = tree => `tested-tree-${tree}`;
export const baseRecord = (tree, baseKey) => `tested-base-${tree}-${baseKey}`;

const hashPattern = /^(?:[0-9a-f]{40}|[0-9a-f]{64})$/;
export const isHash = value => hashPattern.test(value || '');
// A base key is the blob of the base file at the base commit, or `none` when the base has
// no such file (a distinct result: the check then compares against nothing).
export const isBaseKey = value => value === 'none' || isHash(value);

// Where a record lets jobs be skipped: develop, master, and the release pull request. A pull
// request into develop always runs (and records) everything.
export function looksUp({ event, ref, baseRef }) {
  if (event === 'push') return ref === 'refs/heads/develop' || ref === 'refs/heads/master';
  if (event === 'pull_request') return baseRef === 'master';
  return false;
}

// The code why the artifact is not to be trusted as record `name`, or null.
export function distrustArtifact(artifact, { name, repositoryId, currentRunId }) {
  const origin = artifact.workflow_run || {};
  if (artifact.name !== name) return 'other-name';
  if (artifact.expired !== false) return 'expired';
  if (origin.repository_id !== repositoryId) return 'other-repository';
  if (origin.head_repository_id !== repositoryId) return 'fork';
  if (!Number.isInteger(origin.id)) return 'no-run';
  if (origin.id === currentRunId) return 'this-run';
  return null;
}

// The code why the run that uploaded it is not to be trusted, or null.
export function distrustRun(run, artifact, { repositoryId, workflowPath }) {
  if (run?.id !== artifact.workflow_run.id) return 'no-run';
  if (run.repository?.id !== repositoryId) return 'other-repository';
  if (run.head_repository?.id !== repositoryId) return 'fork';
  if (run.path !== workflowPath) return 'other-workflow';
  if (run.status !== 'completed') return 'unfinished';
  if (run.conclusion !== 'success') return 'unsuccessful';
  return null;
}

// {tested: true, runId} for a trusted record `name`; else {tested: false, code} with code
// none, untrusted (with `distrust`, the codes) or lookup-failed (with `error`).
// `api(path)` returns the parsed JSON of a GET, or throws.
export async function findRecord({ name, repository, repositoryId, workflowPath, currentRunId, api }) {
  const context = { name, repositoryId, workflowPath, currentRunId };
  let list;
  try {
    list = await api(`/repos/${repository}/actions/artifacts?name=${name}&per_page=100`);
  } catch (error) {
    return { tested: false, code: 'lookup-failed', error: error.message };
  }
  const distrust = [];
  for (const artifact of list?.artifacts || []) {
    const early = distrustArtifact(artifact, context);
    if (early) { distrust.push(early); continue; }
    let run;
    try {
      run = await api(`/repos/${repository}/actions/runs/${artifact.workflow_run.id}`);
    } catch (error) {
      distrust.push('lookup-failed');
      continue;
    }
    const code = distrustRun(run, artifact, context);
    if (!code) return { tested: true, runId: run.id };
    distrust.push(code);
  }
  return distrust.length ? { tested: false, code: 'untrusted', distrust } : { tested: false, code: 'none' };
}

// The workflow file of this run, from GITHUB_WORKFLOW_REF (owner/repo/<path>@<ref>).
export function workflowPathOf(workflowRef, repository) {
  const prefix = `${repository}/`;
  if (!workflowRef?.startsWith(prefix)) return null;
  return workflowRef.slice(prefix.length).split('@')[0] || null;
}

// Looks up both records. The base check is skipped only together with the suite, so every
// skipped job of a run is explained by one fact: tested == true.
export async function find(env, api) {
  const tree = (env.TREE || '').trim();
  const baseKey = (env.BASE_KEY || '').trim();
  const lookup = name => findRecord({
    name,
    repository: env.GITHUB_REPOSITORY,
    repositoryId: Number(env.GITHUB_REPOSITORY_ID),
    workflowPath: workflowPathOf(env.GITHUB_WORKFLOW_REF, env.GITHUB_REPOSITORY),
    currentRunId: Number(env.GITHUB_RUN_ID),
    api
  });
  let suite, base;
  try {
    if (!looksUp({ event: env.GITHUB_EVENT_NAME, ref: env.GITHUB_REF, baseRef: env.GITHUB_BASE_REF })) {
      suite = base = { tested: false, code: 'not-looked-up' };
    } else if (!isHash(tree)) {
      suite = base = { tested: false, code: 'no-tree' };
    } else if (!Number.isInteger(Number(env.GITHUB_REPOSITORY_ID)) || !env.GITHUB_REPOSITORY_ID ||
               !workflowPathOf(env.GITHUB_WORKFLOW_REF, env.GITHUB_REPOSITORY)) {
      suite = base = { tested: false, code: 'no-context' };
    } else {
      suite = await lookup(suiteRecord(tree));
      if (!suite.tested) base = { tested: false, code: 'suite-runs' };
      else if (!isBaseKey(baseKey)) base = { tested: false, code: 'no-base' };
      else base = await lookup(baseRecord(tree, baseKey));
    }
  } catch (error) {
    suite = base = { tested: false, code: 'lookup-failed', error: error.message };
  }
  const outputs = {
    tree: isHash(tree) ? tree : '',
    base_key: isBaseKey(baseKey) ? baseKey : '',
    tested: String(suite.tested),
    run_id: suite.runId ? String(suite.runId) : '',
    base_tested: String(base.tested),
    base_run_id: base.runId ? String(base.runId) : ''
  };
  return { suite, base, outputs };
}

// `keys`: this checkout's tree, the base commit `base` names, and its base key for `file`.
// Empty values when Git cannot tell; never throws.
export function keys({ cwd, base, file, env = process.env, git = gitIn(cwd, env) }) {
  const tree = git(['rev-parse', '--verify', '-q', 'HEAD^{tree}']);
  const baseCommit = base ? git(['rev-parse', '--verify', '-q', `${base}^{commit}`]) : '';
  let baseKey = '';
  if (isHash(baseCommit) && file) baseKey = git(['rev-parse', '--verify', '-q', `${baseCommit}:${file}`]) || 'none';
  return {
    tree: isHash(tree) ? tree : '',
    base_commit: isHash(baseCommit) ? baseCommit : '',
    base_key: isBaseKey(baseKey) ? baseKey : ''
  };
}

const gitIn = (cwd, env) => args => {
  try {
    return execFileSync('git', args, { cwd, env, encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] }).trim();
  } catch {
    return '';
  }
};

// Problems with the scheme in a workflow's text, as {job, code}. Every job is one of:
//   tested-tree; record-tested-tree and record-tested-base (they keep the implicit success()
//   condition: no always(), cancelled() or failure());
//   a deploy-* job: needs tested-tree, and its `if` keeps the clauses below;
//   a base job: needs tested-tree, skips on base_tested, and record-tested-base needs it;
//   else a test job: needs tested-tree, skips on tested, and record-tested-tree needs it.
export const deployClauses = [
  "!cancelled()",
  "!contains(needs.*.result, 'failure')",
  "!contains(needs.*.result, 'cancelled')",
  "(needs.tested-tree.outputs.tested == 'true' || !contains(needs.*.result, 'skipped'))"
];
const skipsOn = output => `!cancelled() && needs.tested-tree.outputs.${output} != 'true'`;

export function parseJobs(text) {
  const lines = text.split('\n');
  const start = lines.indexOf('jobs:');
  if (start < 0) return null;
  const jobs = new Map();
  let current = null;
  for (const line of lines.slice(start + 1)) {
    const header = line.match(/^ {2}([A-Za-z0-9_-]+):\s*$/);
    if (header) { current = header[1]; jobs.set(current, []); continue; }
    if (/^\S/.test(line)) break;
    if (current) jobs.get(current).push(line);
  }
  const parsed = new Map();
  for (const [id, body] of jobs) {
    const needsLine = body.find(l => /^ {4}needs:/.test(l));
    const needs = needsLine
      ? needsLine.replace(/^ {4}needs:\s*/, '').replace(/[[\]]/g, '').split(',').map(s => s.trim()).filter(Boolean)
      : [];
    // The `if`, with its continuation lines, as one line.
    const at = body.findIndex(l => /^ {4}if:/.test(l));
    let condition = '';
    if (at >= 0) {
      const parts = [body[at].replace(/^ {4}if:\s*(>-|>|\|)?/, '')];
      for (const l of body.slice(at + 1)) {
        if (!/^ {5,}\S/.test(l)) break;
        parts.push(l);
      }
      condition = parts.join(' ').replace(/\s+/g, ' ').trim();
    }
    parsed.set(id, { needs, condition });
  }
  return parsed;
}

export function checkWorkflow(text) {
  const jobs = parseJobs(text);
  if (!jobs) return [{ job: null, code: 'no-jobs' }];
  const problems = [];
  const add = (job, code, extra = {}) => problems.push({ job, code, ...extra });
  for (const id of ['tested-tree', 'record-tested-tree', 'record-tested-base']) {
    if (!jobs.has(id)) add(id, 'missing-job');
  }
  const tests = [];
  const bases = [];
  for (const [id, { needs, condition }] of jobs) {
    if (id === 'tested-tree') continue;
    if (id === 'record-tested-tree' || id === 'record-tested-base') {
      if (/always\(\)|cancelled\(\)|failure\(\)/.test(condition)) add(id, 'record-condition');
      continue;
    }
    if (id.startsWith('deploy-')) {
      if (!needs.includes('tested-tree')) add(id, 'not-joined');
      for (const clause of deployClauses) {
        if (!condition.includes(clause)) add(id, 'deploy-condition', { clause });
      }
      continue;
    }
    const base = condition.includes(skipsOn('base_tested'));
    (base ? bases : tests).push(id);
    if (!needs.includes('tested-tree') || !(base || condition.includes(skipsOn('tested')))) add(id, 'not-joined');
  }
  for (const [record, members] of [['record-tested-tree', tests], ['record-tested-base', bases]]) {
    if (!jobs.has(record)) continue;
    const { needs } = jobs.get(record);
    for (const id of ['tested-tree', ...members]) if (!needs.includes(id)) add(record, 'not-recorded', { need: id });
    for (const id of needs) if (!jobs.has(id)) add(record, 'unknown-need', { need: id });
  }
  return problems;
}

// The edge: words for the summary and the console.
const distrustWords = {
  'other-name': 'another name', expired: 'expired', 'other-repository': 'another repository',
  fork: 'a fork', 'no-run': 'no run', 'this-run': 'this run', 'other-workflow': 'another workflow',
  unfinished: 'an unfinished run', unsuccessful: 'an unsuccessful run', 'lookup-failed': 'lookup failed'
};
function reason(result) {
  switch (result.code) {
    case 'none': return '';
    case 'untrusted': return ` (untrusted: ${[...new Set(result.distrust.map(c => distrustWords[c] || c))].join(', ')})`;
    case 'lookup-failed': return ` (lookup failed: ${result.error})`;
    case 'not-looked-up': return ' (not looked up for this event)';
    case 'suite-runs': return ' (the suite runs, so the base check runs too)';
    default: return ` (${result.code})`;
  }
}
export function summaryLines({ suite, base, outputs }) {
  const tree = outputs.tree || '(none)';
  return [
    suite.tested
      ? `tests skipped: tree ${tree} passed in run ${suite.runId}`
      : `full suite: no record for tree ${tree}${reason(suite)}`,
    base.tested
      ? `base check skipped: tree ${tree} passed against base file ${outputs.base_key} in run ${base.runId}`
      : `base check runs: no record for tree ${tree} against base file ${outputs.base_key || '(none)'}${reason(base)}`
  ];
}
const problemWords = {
  'no-jobs': () => 'the workflow has no jobs',
  'missing-job': () => 'this job of the scheme is missing',
  'record-condition': () => 'keep the implicit success() condition: no always(), cancelled() or failure()',
  'not-joined': () => `add "needs: tested-tree" and "if: \${{ ${skipsOn('tested')} }}" (a test job) or "if: \${{ ${skipsOn('base_tested')} }}" (a base job)`,
  'deploy-condition': p => `keep the clause ${p.clause} in its if`,
  'not-recorded': p => `add ${p.need} to its needs`,
  'unknown-need': p => `${p.need} is no job`
};
export const describeProblem = p => `${p.job ? `${p.job}: ` : ''}${problemWords[p.code](p)}`;

export function githubApi({ url = 'https://api.github.com', token, fetch = globalThis.fetch }) {
  return async path => {
    const response = await fetch(url + path, {
      headers: {
        accept: 'application/vnd.github+json',
        'x-github-api-version': '2022-11-28',
        'user-agent': 'tested-tree',
        ...(token ? { authorization: `Bearer ${token}` } : {})
      },
      signal: AbortSignal.timeout(20000)
    });
    if (!response.ok) throw new Error(`GET ${path}: HTTP ${response.status}`);
    return response.json();
  };
}

const outputText = outputs => Object.entries(outputs).map(([k, v]) => `${k}=${v}\n`).join('');

async function main([command, file]) {
  const env = process.env;
  if (command === 'keys') {
    const outputs = keys({ cwd: process.cwd(), base: env.CI_BASE, file: env.CI_BASE_FILE, env });
    process.stdout.write(outputText(outputs));
    if (env.GITHUB_OUTPUT) appendFileSync(env.GITHUB_OUTPUT, outputText(outputs));
    return 0;
  }
  if (command === 'find') {
    const found = await find(env, githubApi({ url: env.GITHUB_API_URL, token: env.GITHUB_TOKEN }));
    const lines = summaryLines(found);
    for (const line of lines) console.log(line);
    if (env.GITHUB_OUTPUT) appendFileSync(env.GITHUB_OUTPUT, outputText(found.outputs));
    if (env.GITHUB_STEP_SUMMARY) appendFileSync(env.GITHUB_STEP_SUMMARY, lines.map(l => `${l}\n`).join(''));
    return 0;
  }
  if (command === 'check-workflow' && file) {
    const problems = checkWorkflow(readFileSync(file, 'utf8'));
    for (const problem of problems) console.log(`::error file=${file}::${describeProblem(problem)}`);
    return problems.length ? 1 : 0;
  }
  console.error('usage: tested-tree.mjs keys | find | check-workflow <workflow file>');
  return 2;
}

if (import.meta.url === pathToFileURL(process.argv[1] || '').href) {
  main(process.argv.slice(2)).then(code => { process.exitCode = code; }, error => {
    // keys and find never fail a run; only check-workflow and usage do.
    console.log(`::warning::tested-tree: ${error.message}`);
    process.exitCode = ['find', 'keys'].includes(process.argv[2]) ? 0 : 1;
  });
}
