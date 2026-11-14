// Asserts outputs, codes and exit codes; wording only for presence of the tree hash.
import test from 'node:test';
import assert from 'node:assert/strict';
import { createServer } from 'node:http';
import { execFile, execFileSync } from 'node:child_process';
import { mkdtemp, readFile, realpath, rm, symlink, writeFile, mkdir } from 'node:fs/promises';
import { readFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import {
  baseRecord, checkWorkflow, deployClauses, describeProblem, find, findRecord, githubApi, keys,
  looksUp, suiteRecord, summaryLines, workflowPathOf
} from './tested-tree.mjs';

const here = fileURLToPath(new URL('.', import.meta.url));
const script = join(here, 'tested-tree.mjs');
const repository = 'owner/repo';
const repositoryId = 1001;
const workflowPath = '.github/workflows/ci.yml';
const tree = 'a'.repeat(40);
const otherTree = 'b'.repeat(40);
const baseKey = 'c'.repeat(40);
const otherBaseKey = 'd'.repeat(40);

const artifact = (name = suiteRecord(tree), runId = 77, overrides = {}) => ({
  name,
  expired: false,
  workflow_run: { id: runId, repository_id: repositoryId, head_repository_id: repositoryId },
  ...overrides
});
const run = (overrides = {}) => ({
  id: 77,
  path: workflowPath,
  status: 'completed',
  conclusion: 'success',
  repository: { id: repositoryId },
  head_repository: { id: repositoryId },
  ...overrides
});

// A fake GitHub API: the artifact list filtered by name, and runs by id.
function fakeApi({ artifacts = [], runs = {}, fail = null } = {}) {
  const calls = [];
  const api = async path => {
    calls.push(path);
    if (fail && fail(path)) throw new Error('HTTP 502');
    const list = path.match(/\/actions\/artifacts\?name=([^&]+)/);
    if (list) return { artifacts: artifacts.filter(a => a.name === list[1]) };
    const one = path.match(/\/actions\/runs\/(\d+)$/);
    if (one && runs[one[1]]) return runs[one[1]];
    throw new Error('HTTP 404');
  };
  return { api, calls };
}

const lookup = (api, overrides = {}) =>
  findRecord({ name: suiteRecord(tree), repository, repositoryId, workflowPath, currentRunId: 99, api, ...overrides });

test('same tree with a record from a successful run of this workflow: skip', async () => {
  const { api, calls } = fakeApi({ artifacts: [artifact()], runs: { 77: run() } });
  assert.deepEqual(await lookup(api), { tested: true, runId: 77 });
  assert.deepEqual(calls, [
    `/repos/owner/repo/actions/artifacts?name=tested-tree-${tree}&per_page=100`,
    '/repos/owner/repo/actions/runs/77'
  ]);
});

test('a different tree: full suite', async () => {
  const { api } = fakeApi({ artifacts: [artifact()], runs: { 77: run() } });
  assert.deepEqual(await lookup(api, { name: suiteRecord(otherTree) }), { tested: false, code: 'none' });
});

test('a record from a failed, cancelled or unfinished run: full suite', async () => {
  for (const state of [{ conclusion: 'failure' }, { conclusion: 'cancelled' }, { status: 'in_progress', conclusion: null }]) {
    const { api } = fakeApi({ artifacts: [artifact()], runs: { 77: run(state) } });
    const expected = state.status ? 'unfinished' : 'unsuccessful';
    assert.deepEqual(await lookup(api), { tested: false, code: 'untrusted', distrust: [expected] });
  }
});

test('a lookup error: full suite', async () => {
  const listFails = fakeApi({ fail: () => true });
  const result = await lookup(listFails.api);
  assert.equal(result.tested, false);
  assert.equal(result.code, 'lookup-failed');

  const runFails = fakeApi({ artifacts: [artifact()], runs: { 77: run() }, fail: path => path.includes('/runs/') });
  assert.deepEqual(await lookup(runFails.api), { tested: false, code: 'untrusted', distrust: ['lookup-failed'] });
});

test('a record from a fork, another repository, another workflow, this run, or expired: full suite', async () => {
  const origin = (id, repo, head) => ({ workflow_run: { id, repository_id: repo, head_repository_id: head } });
  const cases = [
    [artifact(suiteRecord(tree), 77, origin(77, repositoryId, 5)), run(), 'fork'],
    [artifact(), run({ head_repository: { id: 5 } }), 'fork'],
    [artifact(suiteRecord(tree), 77, origin(77, 5, 5)), run(), 'other-repository'],
    [artifact(), run({ repository: { id: 5 } }), 'other-repository'],
    [artifact(), run({ path: '.github/workflows/other.yml' }), 'other-workflow'],
    [artifact(suiteRecord(tree), 77, { expired: true }), run(), 'expired'],
    [artifact(suiteRecord(tree), 99), run({ id: 99 }), 'this-run']
  ];
  for (const [a, r, code] of cases) {
    const { api } = fakeApi({ artifacts: [a], runs: { [r.id]: r } });
    assert.deepEqual(await lookup(api), { tested: false, code: 'untrusted', distrust: [code] }, code);
  }
});

test('one trusted record among untrusted ones is enough', async () => {
  const forked = artifact(suiteRecord(tree), 70, { workflow_run: { id: 70, repository_id: repositoryId, head_repository_id: 5 } });
  const failed = artifact(suiteRecord(tree), 71);
  const { api } = fakeApi({ artifacts: [forked, failed, artifact()], runs: { 71: run({ id: 71, conclusion: 'failure' }), 77: run() } });
  assert.deepEqual(await lookup(api), { tested: true, runId: 77 });
});

test('looks up on develop, master and pull requests into master only', () => {
  assert.equal(looksUp({ event: 'push', ref: 'refs/heads/develop' }), true);
  assert.equal(looksUp({ event: 'push', ref: 'refs/heads/master' }), true);
  assert.equal(looksUp({ event: 'pull_request', ref: 'refs/pull/9/merge', baseRef: 'master' }), true);
  assert.equal(looksUp({ event: 'pull_request', ref: 'refs/pull/9/merge', baseRef: 'develop' }), false);
  assert.equal(looksUp({ event: 'push', ref: 'refs/heads/feature' }), false);
  assert.equal(looksUp({ event: 'workflow_dispatch', ref: 'refs/heads/master' }), false);
});

test('the workflow path comes from GITHUB_WORKFLOW_REF of this repository', () => {
  assert.equal(workflowPathOf('owner/repo/.github/workflows/ci.yml@refs/pull/9/merge', repository), workflowPath);
  assert.equal(workflowPathOf('other/repo/.github/workflows/ci.yml@refs/heads/x', repository), null);
  assert.equal(workflowPathOf(undefined, repository), null);
});

const env = (overrides = {}) => ({
  TREE: `${tree}\n`,
  BASE_KEY: baseKey,
  GITHUB_EVENT_NAME: 'push',
  GITHUB_REF: 'refs/heads/develop',
  GITHUB_BASE_REF: '',
  GITHUB_REPOSITORY: repository,
  GITHUB_REPOSITORY_ID: String(repositoryId),
  GITHUB_WORKFLOW_REF: `${repository}/${workflowPath}@refs/heads/develop`,
  GITHUB_RUN_ID: '99',
  ...overrides
});
const releasePr = { GITHUB_EVENT_NAME: 'pull_request', GITHUB_REF: 'refs/pull/9/merge', GITHUB_BASE_REF: 'master' };
const skippedAll = { tree, base_key: baseKey, tested: 'true', run_id: '77', base_tested: 'true', base_run_id: '78' };

test('find: suite and base records for this tree and base key skip both', async () => {
  const { api } = fakeApi({
    artifacts: [artifact(), artifact(baseRecord(tree, baseKey), 78)],
    runs: { 77: run(), 78: run({ id: 78 }) }
  });
  const found = await find(env(), api);
  assert.deepEqual(found.outputs, skippedAll);
  for (const line of summaryLines(found)) assert.ok(line.includes(tree));
});

test('find: the same tree against another base file runs the base job, skips the suite (release PR)', async () => {
  const { api } = fakeApi({
    artifacts: [artifact(), artifact(baseRecord(tree, otherBaseKey), 78)],
    runs: { 77: run(), 78: run({ id: 78 }) }
  });
  const found = await find(env(releasePr), api);
  assert.deepEqual(found.outputs, { ...skippedAll, base_tested: 'false', base_run_id: '' });
  assert.equal(found.base.code, 'none');
});

test('find: a base record alone skips nothing, so every skipped job is explained by tested', async () => {
  const { api, calls } = fakeApi({ artifacts: [artifact(baseRecord(tree, baseKey), 78)], runs: { 78: run({ id: 78 }) } });
  const found = await find(env(), api);
  assert.equal(found.outputs.tested, 'false');
  assert.equal(found.outputs.base_tested, 'false');
  assert.equal(found.base.code, 'suite-runs');
  assert.equal(calls.length, 1);
});

test('find: a base without the base file is its own key', async () => {
  const { api } = fakeApi({
    artifacts: [artifact(), artifact(baseRecord(tree, 'none'), 78)],
    runs: { 77: run(), 78: run({ id: 78 }) }
  });
  assert.equal((await find(env({ BASE_KEY: 'none' }), api)).outputs.base_tested, 'true');
  assert.equal((await find(env({ BASE_KEY: '' }), api)).base.code, 'no-base');
});

test('find: a different tree runs everything', async () => {
  const found = await find(env({ TREE: otherTree }), fakeApi({ artifacts: [artifact()], runs: { 77: run() } }).api);
  assert.deepEqual(found.outputs, { tree: otherTree, base_key: baseKey, tested: 'false', run_id: '', base_tested: 'false', base_run_id: '' });
  for (const line of summaryLines(found)) assert.ok(line.includes(otherTree));
});

test('find: a pull request into develop does not look up', async () => {
  const { api, calls } = fakeApi({ artifacts: [artifact()], runs: { 77: run() } });
  const found = await find(env({ ...releasePr, GITHUB_BASE_REF: 'develop' }), api);
  assert.equal(found.outputs.tested, 'false');
  assert.equal(found.outputs.tree, tree);
  assert.equal(found.suite.code, 'not-looked-up');
  assert.deepEqual(calls, []);
});

test('find: no tree or no context runs everything without asking', async () => {
  const { api, calls } = fakeApi({ artifacts: [artifact()], runs: { 77: run() } });
  assert.equal((await find(env({ TREE: '' }), api)).suite.code, 'no-tree');
  assert.equal((await find(env({ TREE: 'HEAD' }), api)).suite.code, 'no-tree');
  assert.equal((await find(env({ GITHUB_REPOSITORY_ID: '' }), api)).suite.code, 'no-context');
  assert.equal((await find(env({ GITHUB_WORKFLOW_REF: '' }), api)).suite.code, 'no-context');
  assert.deepEqual(calls, []);
});

test('find survives an api that throws synchronously', async () => {
  const found = await find(env(), () => { throw new Error('boom'); });
  assert.equal(found.outputs.tested, 'false');
  assert.equal(found.outputs.base_tested, 'false');
});

// Real Git in a scratch repository: a commit with the base file, one without, a merge-like
// second commit with the same tree.
const gitEnv = {
  ...process.env, GIT_CONFIG_GLOBAL: '/dev/null', GIT_CONFIG_NOSYSTEM: '1',
  GIT_AUTHOR_NAME: 't', GIT_AUTHOR_EMAIL: 't@t', GIT_COMMITTER_NAME: 't', GIT_COMMITTER_EMAIL: 't@t'
};
const git = (cwd, ...args) => execFileSync('git', args, { cwd, env: gitEnv, encoding: 'utf8' }).trim();

test('keys: the tree, the base commit and the blob of the base file there', async () => {
  const dir = await mkdtemp(join(tmpdir(), 'tested-tree-'));
  try {
    git(dir, 'init', '-q');
    await writeFile(join(dir, 'a.txt'), 'a\n');
    git(dir, 'add', '.');
    git(dir, 'commit', '-q', '-m', 'without');
    const without = git(dir, 'rev-parse', 'HEAD');
    await mkdir(join(dir, 'proof'));
    await writeFile(join(dir, 'proof', 'base.json'), '{}\n');
    git(dir, 'add', '.');
    git(dir, 'commit', '-q', '-m', 'with');
    const withFile = git(dir, 'rev-parse', 'HEAD');
    const blob = git(dir, 'rev-parse', 'HEAD:proof/base.json');
    const head = keys({ cwd: dir, base: withFile, file: 'proof/base.json', env: gitEnv });
    assert.deepEqual(head, { tree: git(dir, 'rev-parse', 'HEAD^{tree}'), base_commit: withFile, base_key: blob });
    assert.equal(keys({ cwd: dir, base: without, file: 'proof/base.json', env: gitEnv }).base_key, 'none');
    assert.deepEqual(keys({ cwd: dir, base: 'nowhere', file: 'proof/base.json', env: gitEnv }), { tree: head.tree, base_commit: '', base_key: '' });
    assert.equal(keys({ cwd: dir, base: '', file: 'proof/base.json', env: gitEnv }).base_key, '');
    // Another commit on the same tree has the same key.
    git(dir, 'commit', '-q', '--allow-empty', '-m', 'merge');
    assert.equal(keys({ cwd: dir, base: withFile, file: 'proof/base.json', env: gitEnv }).tree, head.tree);
    assert.deepEqual(keys({ cwd: join(dir, 'proof'), base: withFile, file: 'proof/base.json', env: gitEnv }), head);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test('keys outside a repository gives empty values', async () => {
  const dir = await mkdtemp(join(tmpdir(), 'tested-tree-'));
  try {
    assert.deepEqual(keys({ cwd: dir, base: 'HEAD', file: 'x', env: gitEnv }), { tree: '', base_commit: '', base_key: '' });
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

// Real HTTP on a loopback port, opened and closed inside each test.
async function withServer(handler, body) {
  const server = createServer(handler);
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  try {
    return await body(`http://127.0.0.1:${server.address().port}`);
  } finally {
    server.closeAllConnections?.();
    await new Promise(resolve => server.close(resolve));
  }
}

test('githubApi sends the token and reads JSON; a non-2xx is a lookup error', async () => {
  const seen = [];
  await withServer((request, response) => {
    seen.push([request.url, request.headers.authorization, request.headers['x-github-api-version']]);
    if (request.url.includes('/actions/artifacts')) {
      response.setHeader('content-type', 'application/json');
      response.end(JSON.stringify({ artifacts: [artifact()] }));
    } else {
      response.statusCode = 500;
      response.end('{}');
    }
  }, async url => {
    assert.deepEqual(await lookup(githubApi({ url, token: 't0ken' })), { tested: false, code: 'untrusted', distrust: ['lookup-failed'] });
  });
  assert.deepEqual(seen[0], [`/repos/owner/repo/actions/artifacts?name=tested-tree-${tree}&per_page=100`, 'Bearer t0ken', '2022-11-28']);
});

function runCli(args, extraEnv, cwd = here) {
  return new Promise(resolve => {
    execFile(process.execPath, [script, ...args], { cwd, env: { PATH: process.env.PATH, ...extraEnv } },
      (error, stdout, stderr) => resolve({ code: error ? error.code : 0, stdout, stderr }));
  });
}
const parseOutputs = text => Object.fromEntries(text.trim().split('\n').map(l => l.split('=')));

test('the find command exits 0 and writes outputs and summary, also when the API fails', async () => {
  const dir = await mkdtemp(join(tmpdir(), 'tested-tree-'));
  try {
    const output = join(dir, 'output');
    const stepSummary = join(dir, 'summary');
    await withServer((request, response) => { response.statusCode = 503; response.end(); }, async url => {
      const result = await runCli(['find'], {
        ...env(), GITHUB_API_URL: url, GITHUB_TOKEN: 't', GITHUB_OUTPUT: output, GITHUB_STEP_SUMMARY: stepSummary
      });
      assert.equal(result.code, 0, result.stderr);
    });
    assert.deepEqual(parseOutputs(await readFile(output, 'utf8')),
      { tree, base_key: baseKey, tested: 'false', run_id: '', base_tested: 'false', base_run_id: '' });
    const summary = (await readFile(stepSummary, 'utf8')).trim().split('\n');
    assert.equal(summary.length, 2);
    for (const line of summary) assert.ok(line.includes(tree));
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test('the keys command exits 0 and writes its outputs, also outside a repository', async () => {
  const dir = await mkdtemp(join(tmpdir(), 'tested-tree-'));
  try {
    const output = join(dir, 'output');
    const result = await runCli(['keys'], { ...gitEnv, CI_BASE: 'HEAD', CI_BASE_FILE: 'x', GITHUB_OUTPUT: output }, dir);
    assert.equal(result.code, 0, result.stderr);
    assert.deepEqual(parseOutputs(await readFile(output, 'utf8')), { tree: '', base_commit: '', base_key: '' });
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

// Workflow fixtures for the scheme.
const workflow = jobs => `name: CI\non:\n  push:\njobs:\n${jobs}`;
const job = (id, lines) => `  ${id}:\n${lines.map(l => `    ${l}\n`).join('')}    runs-on: ubuntu-latest\n`;
const testJob = id => job(id, ['needs: tested-tree', "if: ${{ !cancelled() && needs.tested-tree.outputs.tested != 'true' }}"]);
const baseJob = id => job(id, ['needs: tested-tree', "if: ${{ !cancelled() && needs.tested-tree.outputs.base_tested != 'true' }}"]);
const treeJob = job('tested-tree', []);
const record = (id, needs, condition = "needs.tested-tree.outputs.tested != 'true'") =>
  job(id, [`needs: [${needs.join(', ')}]`, 'if: >-', `  ${condition}`]);
const deploy = (needs, clauses = deployClauses) =>
  job('deploy-test', [`needs: [${needs.join(', ')}]`, 'if: >-', "  ${{ github.event_name == 'push'", ...clauses.map(c => `  && ${c}`), '  }}']);
const good = ({ deployJob = deploy(['tested-tree', 'unit']), recordTree = record('record-tested-tree', ['tested-tree', 'unit', 'swift']), extra = '' } = {}) =>
  workflow(treeJob + testJob('unit') + testJob('swift') + baseJob('base') + extra + recordTree +
    record('record-tested-base', ['tested-tree', 'base'], "needs.base.outputs.tree != ''") + deployJob);
const codes = text => checkWorkflow(text).map(({ job, code, need, clause }) => ({ job, code, ...(need ? { need } : {}), ...(clause ? { clause } : {}) }));

test('the workflow scheme: every job joined and recorded', () => {
  assert.deepEqual(checkWorkflow(good()), []);
});

test('the workflow scheme: a new job without needs/if, or missing from its record, fails', () => {
  assert.deepEqual(codes(good({ extra: job('mac', []) , recordTree: record('record-tested-tree', ['tested-tree', 'unit', 'swift', 'mac']) })),
    [{ job: 'mac', code: 'not-joined' }]);
  assert.deepEqual(codes(good({ recordTree: record('record-tested-tree', ['tested-tree', 'unit']) })),
    [{ job: 'record-tested-tree', code: 'not-recorded', need: 'swift' }]);
  assert.deepEqual(codes(good({ recordTree: record('record-tested-tree', ['tested-tree', 'unit', 'swift', 'gone']) })),
    [{ job: 'record-tested-tree', code: 'unknown-need', need: 'gone' }]);
  assert.deepEqual(codes(good({ extra: baseJob('base2') })),
    [{ job: 'record-tested-base', code: 'not-recorded', need: 'base2' }]);
});

test('the workflow scheme: a deploy keeps tested-tree and every clause of its if', () => {
  assert.deepEqual(codes(good({ deployJob: deploy(['unit']) })), [{ job: 'deploy-test', code: 'not-joined' }]);
  for (const dropped of deployClauses) {
    assert.deepEqual(codes(good({ deployJob: deploy(['tested-tree'], deployClauses.filter(c => c !== dropped)) })),
      [{ job: 'deploy-test', code: 'deploy-condition', clause: dropped }]);
  }
});

test('the workflow scheme: the record jobs keep their implicit success condition', () => {
  for (const status of ['always()', '!cancelled()', 'failure()']) {
    assert.deepEqual(codes(good({ recordTree: record('record-tested-tree', ['tested-tree', 'unit', 'swift'], `${status} && true`) })),
      [{ job: 'record-tested-tree', code: 'record-condition' }]);
  }
  assert.deepEqual(codes(workflow(treeJob)), [
    { job: 'record-tested-tree', code: 'missing-job' }, { job: 'record-tested-base', code: 'missing-job' }
  ]);
  assert.deepEqual(codes('name: CI\n'), [{ job: null, code: 'no-jobs' }]);
});

test('every problem code has words', () => {
  for (const problem of [
    { job: null, code: 'no-jobs' }, { job: 'x', code: 'missing-job' }, { job: 'x', code: 'record-condition' },
    { job: 'x', code: 'not-joined' }, { job: 'x', code: 'deploy-condition', clause: 'c' },
    { job: 'x', code: 'not-recorded', need: 'y' }, { job: 'x', code: 'unknown-need', need: 'y' }
  ]) assert.ok(describeProblem(problem).length > 0);
});

test('the real workflow is in the scheme, with model-base as its base job', () => {
  const text = readFileSync(join(here, '..', '..', '.github', 'workflows', 'ci.yml'), 'utf8');
  assert.deepEqual(checkWorkflow(text), []);
  assert.deepEqual(codes(text.replace(/^( {4}if: .*outputs\.)base_tested( != 'true'.*)$/m, '$1tested$2')),
    [{ job: 'record-tested-tree', code: 'not-recorded', need: 'model-base' }]);
});

test('the check-workflow command exits 1 on a job outside the scheme, 0 on the real workflow', async () => {
  const dir = await mkdtemp(join(tmpdir(), 'tested-tree-'));
  try {
    const file = join(dir, 'ci.yml');
    await writeFile(file, good({ extra: job('mac', []) }));
    assert.equal((await runCli(['check-workflow', file], {})).code, 1);
    assert.equal((await runCli(['check-workflow', join(here, '..', '..', '.github', 'workflows', 'ci.yml')], {})).code, 0);
    assert.equal((await runCli(['check-workflow'], {})).code, 2);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});
