import test from 'node:test';
import assert from 'node:assert/strict';
import { EventEmitter } from 'node:events';
import { mkdtemp, mkdir, writeFile, readFile, rm, chmod } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { createWatch } from './atlas-watch.mjs';

const originalPath = process.env.PATH;
const originalHome = process.env.ATLAS_RUNTIME_HOME;
const turn = 'turn-1111111111111111';
const question = 'question-2222222222222222';
const worker = 'research';
const pending = (id = question) => ({ worker_id: worker, turn_id: turn, question_id: id, active: true, admission: 'pending', revision: 1, record_ref: `turns/${turn}/questions/${id}.json` });
const handoff = { worker_id: worker, turn_id: turn, provenance: 'coordinator_submitted_declaration', handoff: { kind: 'completion', result: 'Actual declaration' } };
const runtimeInfo = { runtime_build: 'b1', incarnation: 'inc-1', mode: 'open', policy_version: 1, slots: [{ name: worker, busy: false }] };
// Finite CLI queries only. `service status` answers the runtime info (or data.service);
// `events --limit N [--cursor c:OFFSET]` pages data.events as the Runtime's journal does.
const fixtureProgram = `#!/usr/bin/env node
const {readFileSync,appendFileSync}=require('node:fs');
const {join}=require('node:path');
const home=process.env.ATLAS_RUNTIME_HOME, args=process.argv.slice(2);
appendFileSync(join(home,'calls.jsonl'),JSON.stringify(args)+'\\n');
const data=JSON.parse(readFileSync(join(home,'fixture.json')));
const flag=name=>args[args.indexOf(name)+1];
function error(message){console.log(JSON.stringify({error:message}));process.exit(1)}
if(data.failure==='timeout'){setTimeout(()=>{},10000);return}
if(data.failure==='output'){console.log('x'.repeat(2*1024*1024));process.exit(0)}
if(data.failure) error(data.failure);
let value;
if(args[0]==='service' && args[1]==='status') value=data.service||${JSON.stringify(runtimeInfo)};
else if(args[0]==='events' && !args.includes('--follow')) {const events=data.events||[], limit=Number(flag('--limit')), from=args.includes('--cursor')?Number(flag('--cursor').slice(2)):0, to=Math.min(from+limit,events.length);value={events:events.slice(from,to),cursor:'c:'+to,more:to<events.length,...(from===0?{reset:{reason:'retention_gap',from_sequence:1,to_sequence:3}}:{})};}
else if(args[0]==='turns') value={turns:data.turns||[]};
else if(args[0]==='question') {value=data.questions?.[flag('--question')];if(!value)error('Question record unavailable; no matching recorded question');}
else if(args[0]==='handoff') {value=data.handoffs?.[flag('--turn')];if(!value)error('No handoff recorded for this turn');}
else error('Unexpected command '+args.join(' '));
console.log(JSON.stringify(value));
`;
// Stands in for "ssh HOST": drops the host and runs the rest locally.
const fakeSsh = '#!/bin/sh\nshift\nexec "$@"\n';

// Fake `events --follow` children: lines and exits are driven synchronously by the test.
function follow() {
  const spawned = [];
  const spawn = (file, args, options) => {
    const child = new EventEmitter();
    child.stdout = new EventEmitter();
    child.stderr = new EventEmitter();
    child.signals = [];
    child.kill = signal => { child.signals.push(signal); child.emit('close', null, signal); return true; };
    child.send = (...values) => child.stdout.emit('data', Buffer.from(values.map(v => typeof v === 'string' ? v : JSON.stringify(v)).join('\n') + '\n'));
    child.exit = (code, stderr = '') => { if (stderr) child.stderr.emit('data', Buffer.from(stderr)); child.emit('close', code, null); };
    spawned.push({ file, args, options, child });
    return child;
  };
  return { spawn, spawned, get child() { return spawned.at(-1).child; } };
}

// options: `todo` is passed to node:test.
function scenario(name, run, { todo } = {}) {
  test(name, { todo }, async () => {
    const home = await mkdtemp(join(tmpdir(), 'atlas-watch-'));
    const root = join(home, 'agent-reports/atlas/inbox');
    const runtimeHome = join(home, '.local/state/atlas-runtime');
    const bin = join(home, 'bin');
    const watchers = [];
    try {
      await mkdir(root, { recursive: true }); await mkdir(runtimeHome, { recursive: true }); await mkdir(bin);
      await writeFile(join(bin, 'atlas-runtime'), fixtureProgram); await chmod(join(bin, 'atlas-runtime'), 0o700);
      process.env.PATH = bin + ':' + originalPath; process.env.ATLAS_RUNTIME_HOME = runtimeHome;
      const messages = [];
      let idle = true, pendingMessages = false;
      const stream = follow();
      const c = {
        home, root, runtimeHome, bin, messages, stream,
        ctx: { isIdle: () => idle, hasPendingMessages: () => pendingMessages },
        pi: { sendMessage: async (message, options) => { assert.equal(options.triggerTurn, true); messages.push(message); } },
        busy: value => { idle = !value; }, queued: value => { pendingMessages = value; },
        watch: () => { const watcher = createWatch(home, { spawn: stream.spawn }); watchers.push(watcher); return watcher; },
        fixture: (value, dir = runtimeHome) => writeFile(join(dir, 'fixture.json'), JSON.stringify(value)),
        state: async () => JSON.parse(await readFile(join(root, '.delivery/coordinator-watch.json'), 'utf8')),
        items: async () => Object.values((await c.state()).pending),
        calls: async (dir = runtimeHome) => {
          try { return (await readFile(join(dir, 'calls.jsonl'), 'utf8')).trim().split('\n').map(JSON.parse); }
          catch (error) { if (error.code === 'ENOENT') return []; throw error; }
        },
        ackAll: async watcher => {
          for (const [id, item] of Object.entries((await c.state()).pending)) await watcher.ack(id, item.signature, 'Handled explicitly');
        },
      };
      await c.fixture({});
      await run(c);
      // The only finite `events` reads are bounded replay pages; the follower is the stream.
      for (const call of await c.calls()) {
        if (call[0] === 'events') assert.deepEqual(call.slice(0, 3), ['events', '--limit', '100'], 'events replay page');
      }
    } finally {
      for (const watcher of watchers) await watcher.close();
      process.env.PATH = originalPath;
      if (originalHome === undefined) delete process.env.ATLAS_RUNTIME_HOME;
      else process.env.ATLAS_RUNTIME_HOME = originalHome;
      await rm(home, { recursive: true, force: true });
    }
  });
}

scenario('follows with the default command and no cursor on first start', async c => {
  const watcher = c.watch(); await watcher.check(c.ctx, c.pi, 200000);
  assert.equal(c.stream.spawned.length, 1);
  const { file, args, options } = c.stream.spawned[0];
  assert.equal(file, 'atlas-runtime');
  assert.deepEqual(args, ['events', '--follow']);
  assert.equal(options.env.ATLAS_RUNTIME_HOME, c.runtimeHome);
  await watcher.check(c.ctx, c.pi, 200001);
  assert.equal(c.stream.spawned.length, 1, 'one long-running follower');
});

for (const [kind, outcome] of [['execution_finished', 'finished'], ['execution_failed', 'failed'], ['execution_stopped', 'stopped'], ['execution_killed', 'killed']]) {
  scenario(`${kind} becomes a terminal turn item`, async c => {
    const watcher = c.watch(); await watcher.check(c.ctx, c.pi, 200000);
    c.stream.child.send({ sequence: 7, kind, worker_id: worker, turn_id: turn }, { cursor: 'e1:7' });
    await watcher.check(c.ctx, c.pi, 200001);
    const item = (await c.items()).find(x => x.selectors[0] === 'output');
    assert.deepEqual(item.evidence, { worker_id: worker, turn_id: turn, state: outcome });
    assert.deepEqual(item.selectors, ['output', '--turn', turn]);
    assert.equal((await c.state()).runtimes[c.runtimeHome].cursor, 'e1:7');
    assert.equal(c.messages.length, 1);
  });
}

scenario('killed turn from reconciliation is terminal too', async c => {
  await c.fixture({ turns: [{ turn_id: turn, slot: worker, state: 'killed' }] });
  const watcher = c.watch(); await watcher.check(c.ctx, c.pi, 200000);
  assert.equal((await c.items()).find(x => x.selectors[0] === 'output').evidence.state, 'killed');
});

scenario('question and handoff events are inspected into pending items', async c => {
  await c.fixture({ questions: { [question]: pending() }, handoffs: { [turn]: handoff } });
  const watcher = c.watch(); await watcher.check(c.ctx, c.pi, 200000);
  c.stream.child.send(
    { sequence: 1, kind: 'question_available', worker_id: worker, turn_id: turn, question_id: question, revision: 1 },
    { sequence: 2, kind: 'handoff_submitted', worker_id: worker, turn_id: turn },
    { cursor: 'e1:2' });
  await watcher.check(c.ctx, c.pi, 200001);
  const items = await c.items();
  assert.deepEqual(items.find(x => x.selectors[0] === 'question').selectors,
    ['question', '--worker', worker, '--turn', turn, '--question', question]);
  assert.deepEqual(items.find(x => x.selectors[0] === 'handoff').evidence, handoff);
});

scenario('cursor line is persisted and a fresh watcher resumes from it', async c => {
  let watcher = c.watch(); await watcher.check(c.ctx, c.pi, 200000);
  c.stream.child.send({ cursor: 'e1:3' });
  await watcher.close();
  assert.equal((await c.state()).runtimes[c.runtimeHome].cursor, 'e1:3', 'saved without waiting for a check');
  watcher = c.watch(); await watcher.check(c.ctx, c.pi, 200001);
  assert.deepEqual(c.stream.spawned.at(-1).args, ['events', '--follow', '--cursor', 'e1:3']);
});

scenario('saved polling cursor is reused without a gap item', async c => {
  await mkdir(join(c.root, '.delivery'));
  await writeFile(join(c.root, '.delivery/coordinator-watch.json'), JSON.stringify({ version: 1, seen: {}, pending: {}, lastNudge: 0,
    runtimes: { [c.runtimeHome]: { cursor: 'stream:4', work: [], retryAt: 0 } } }));
  const watcher = c.watch(); await watcher.check(c.ctx, c.pi, 200000);
  assert.deepEqual(c.stream.child && c.stream.spawned[0].args, ['events', '--follow', '--cursor', 'stream:4']);
  assert.deepEqual(await c.items(), []);
});

for (const reset of [{ reason: 'retention_gap', from_sequence: 1, to_sequence: 9 }, { reason: 'epoch_changed' }]) {
  scenario(`reset ${reset.reason} records one gap and reconciles`, async c => {
    await c.fixture({ turns: [{ turn_id: turn, slot: worker, state: 'finished' }], handoffs: { [turn]: handoff } });
    const watcher = c.watch(); await watcher.check(c.ctx, c.pi, 200000);
    await c.ackAll(watcher);
    const before = (await c.calls()).length;
    c.stream.child.send({ reset }, { cursor: 'e2:10' });
    await watcher.check(c.ctx, c.pi, 200001);
    const gaps = (await c.items()).filter(x => x.evidence.warning);
    assert.equal(gaps.length, 1);
    assert.deepEqual(gaps[0].evidence.reset, reset);
    const calls = (await c.calls()).slice(before).map(x => x.join(' '));
    assert.ok(calls.includes('service status') && calls.includes('turns') && calls.includes('events --limit 100'));
    assert.deepEqual(await c.items(), gaps, 'already acknowledged records are not re-raised');
  });
}

scenario('unreachable raises one unavailable item; reachable clears it for the next outage', async c => {
  const watcher = c.watch(); await watcher.check(c.ctx, c.pi, 200000);
  const child = c.stream.child;
  child.send({ reachable: false, reason: 'service_stopping' });
  child.send({ reachable: false, reason: 'connect_failed' });
  await watcher.check(c.ctx, c.pi, 200001);
  let items = await c.items();
  assert.equal(items.length, 1);
  assert.deepEqual(items[0].evidence, { reason: 'service_stopping', source: 'client' });
  assert.equal((await c.state()).runtimes[c.runtimeHome].unavailable, true);
  await c.ackAll(watcher);
  await watcher.check(c.ctx, c.pi, 200002);
  assert.equal((await c.state()).runtimes[c.runtimeHome].unavailable, true, 'a command-socket read does not override the follower');
  child.send({ reachable: true });
  await watcher.check(c.ctx, c.pi, 200003);
  assert.equal((await c.state()).runtimes[c.runtimeHome].unavailable, false);
  assert.deepEqual(await c.items(), []);
  child.send({ reachable: false, reason: 'service_stopping' });
  await watcher.check(c.ctx, c.pi, 200004);
  assert.equal((await c.items()).length, 1, 'the same outage reason surfaces again after recovery');
  assert.equal(c.stream.spawned.length, 1, 'the CLI reconnects itself; no respawn');
});

scenario('reachable clears the outage and lifts the query back-off at once', async c => {
  await c.fixture({ failure: 'service is unavailable' });
  const watcher = c.watch(); await watcher.check(c.ctx, c.pi, 200000);
  assert.equal((await c.state()).runtimes[c.runtimeHome].retryAt, 260000);
  await c.fixture({ handoffs: { [turn]: handoff } });
  c.stream.child.send({ reachable: false, reason: 'connect_failed' }, { reachable: true },
    { sequence: 1, kind: 'handoff_submitted', worker_id: worker, turn_id: turn }, { cursor: 'e1:1' });
  await watcher.check(c.ctx, c.pi, 200001);
  const state = await c.state();
  assert.equal(state.runtimes[c.runtimeHome].unavailable, false);
  assert.ok(Object.values(state.pending).some(x => x.selectors[0] === 'handoff'), 'queued work ran inside the old back-off');
});

scenario('child exit records unavailable and restarts from the last cursor on the next check', async c => {
  const watcher = c.watch(); await watcher.check(c.ctx, c.pi, 200000);
  c.stream.child.send({ cursor: 'e1:5' });
  c.stream.child.exit(255, 'ssh: connect to host mac-mini port 22: Connection refused\n');
  await watcher.check(c.ctx, c.pi, 200001);
  const items = await c.items();
  assert.equal(items.length, 1);
  assert.match(items[0].evidence.error, /exit 255\): ssh: connect to host/);
  assert.equal(c.stream.spawned.length, 2);
  assert.deepEqual(c.stream.spawned[1].args, ['events', '--follow', '--cursor', 'e1:5']);
  const state = await c.state();
  assert.equal(state.runtimes[c.runtimeHome].unavailable, false, 'a successful status read clears it');
});

scenario('invalid_cursor exit records a gap and restarts without the cursor', async c => {
  const watcher = c.watch(); await watcher.check(c.ctx, c.pi, 200000);
  c.stream.child.send({ cursor: 'e1:5' });
  c.stream.child.exit(1, 'invalid_cursor: cursor is ahead of the journal\n');
  await watcher.check(c.ctx, c.pi, 200001);
  assert.ok((await c.items()).some(x => /invalid_cursor/.test(x.evidence.error) && x.evidence.warning));
  assert.deepEqual(c.stream.spawned[1].args, ['events', '--follow']);
});

scenario('replay after watcher restart does not re-raise acknowledged items', async c => {
  let watcher = c.watch(); await watcher.check(c.ctx, c.pi, 200000);
  const line = { sequence: 3, kind: 'execution_killed', worker_id: worker, turn_id: turn };
  c.stream.child.send(line, { cursor: 'e1:3' });
  await watcher.check(c.ctx, c.pi, 200001);
  await c.ackAll(watcher); await watcher.close();
  watcher = c.watch(); await watcher.check(c.ctx, c.pi, 400000);
  c.stream.child.send(line, { cursor: 'e1:3' });
  await watcher.check(c.ctx, c.pi, 400001);
  assert.deepEqual(await c.items(), []);
  assert.equal(c.messages.length, 1);
});

scenario('unrecognized and partial lines are surfaced, not guessed', async c => {
  const watcher = c.watch(); await watcher.check(c.ctx, c.pi, 200000);
  c.stream.child.stdout.emit('data', Buffer.from('{"cursor":"e1:1"}\n{"type":"heartbeat"}\nnot json\n{"cur'));
  c.stream.child.stdout.emit('data', Buffer.from('sor":"e1:2"}\n'));
  c.stream.child.send({ sequence: 4, kind: 'question_available', worker_id: worker, turn_id: '$(id)', question_id: question });
  await watcher.check(c.ctx, c.pi, 200001);
  const errors = (await c.items()).map(x => x.evidence.error);
  assert.equal(errors.length, 1, 'one stream item, refreshed per bad line');
  assert.match(errors[0], /unsafe identifier/);
  assert.equal((await c.state()).runtimes[c.runtimeHome].cursor, 'e1:2', 'split lines reassemble');
});

scenario('command prefix from the target file runs follow and queries remotely', async c => {
  const ssh = join(c.bin, 'fake-ssh');
  await writeFile(ssh, fakeSsh); await chmod(ssh, 0o700);
  await c.fixture({ handoffs: { [turn]: handoff } });
  await mkdir(join(c.root, '.delivery'));
  const command = [ssh, 'mac-mini', join(c.bin, 'atlas-runtime')];
  await writeFile(join(c.root, '.delivery/runtime-target.json'), JSON.stringify({ runtimeHome: c.runtimeHome, command, timeoutMs: 5000 }));
  const watcher = c.watch(); await watcher.check(c.ctx, c.pi, 200000);
  assert.equal(c.stream.spawned[0].file, ssh);
  assert.deepEqual(c.stream.spawned[0].args, ['mac-mini', join(c.bin, 'atlas-runtime'), 'events', '--follow']);
  c.stream.child.send({ sequence: 1, kind: 'handoff_submitted', worker_id: worker, turn_id: turn }, { cursor: 'e1:1' });
  await watcher.check(c.ctx, c.pi, 200001);
  const item = (await c.items()).find(x => x.selectors[0] === 'handoff');
  assert.deepEqual(item.command, command);
  assert.ok((await c.calls()).some(x => x[0] === 'handoff'));
});

scenario('invalid target stops following but still delivers inbox work', async c => {
  const watcher = c.watch(); await watcher.check(c.ctx, c.pi, 200000);
  const calls = (await c.calls()).length, child = c.stream.child;
  await writeFile(join(c.root, '.delivery/runtime-target.json'), JSON.stringify({ runtimeHome: 'relative-home', executable: '/missing/atlas-runtime' }));
  await writeFile(join(c.root, 'question.md'), 'From: runtime\nTo: coordinator\nNeed an answer');
  await watcher.check(c.ctx, c.pi, 200001);
  const state = await c.state();
  assert.match(state.pending['runtime:configuration'].evidence.error, /absolute/);
  assert.ok(state.pending['inbox:question.md']);
  assert.deepEqual(child.signals, ['SIGTERM']);
  assert.equal(Object.keys(state.pending).length, 2, 'an intentional stop is not an outage');
  assert.equal((await c.calls()).length, calls);
  for (const command of [['ssh', 'host'], [], '/bin/ssh host']) {
    await writeFile(join(c.root, '.delivery/runtime-target.json'), JSON.stringify({ runtimeHome: c.runtimeHome, command }));
    await watcher.check(c.ctx, c.pi, 200002);
    assert.match((await c.state()).pending['runtime:configuration'].evidence.error, /command/);
  }
});

scenario('live target change switches follower, cursor and acknowledgement identity', async c => {
  await c.fixture({ turns: [{ turn_id: turn, slot: worker, state: 'finished' }] });
  const watcher = c.watch(); await watcher.check(c.ctx, c.pi, 200000);
  c.stream.child.send({ cursor: 'e1:9' });
  await c.ackAll(watcher);
  const first = c.stream.child;
  const other = join(c.home, 'dedicated-runtime'), executable = join(c.home, 'dedicated-cli');
  await mkdir(other);
  await writeFile(executable, fixtureProgram); await chmod(executable, 0o700);
  await c.fixture({ turns: [{ turn_id: turn, slot: worker, state: 'finished' }] }, other);
  await writeFile(join(c.root, '.delivery/runtime-target.json'), JSON.stringify({ runtimeHome: other, executable }));
  process.env.PATH = originalPath;
  await watcher.check(c.ctx, c.pi, 200001);
  assert.deepEqual(first.signals, ['SIGTERM']);
  assert.equal(c.stream.spawned[1].file, executable);
  assert.deepEqual(c.stream.spawned[1].args, ['events', '--follow']);
  first.send({ sequence: 10, kind: 'execution_killed', worker_id: worker, turn_id: 'turn-3333333333333333' });
  let items = await c.items();
  assert.equal(items.length, 1);
  assert.equal(items[0].runtimeHome, other);
  await c.ackAll(watcher);
  await writeFile(join(c.root, '.delivery/runtime-target.json'), JSON.stringify({ runtimeHome: c.runtimeHome, executable }));
  await watcher.check(c.ctx, c.pi, 200002);
  assert.deepEqual(c.stream.spawned[2].args, ['events', '--follow', '--cursor', 'e1:9']);
  assert.deepEqual(await c.items(), []);
});

scenario('close terminates the follower without recording an outage', async c => {
  const watcher = c.watch(); await watcher.check(c.ctx, c.pi, 200000);
  const child = c.stream.child;
  await watcher.close();
  assert.deepEqual(child.signals, ['SIGTERM']);
  assert.deepEqual(await c.items(), []);
});

scenario('inbox busy/restart/reminders/exact ack and edited message', async c => {
  let watcher = c.watch();
  c.busy(true);
  await watcher.check(c.ctx, c.pi, 200000);
  await writeFile(join(c.root, 'question.md'), 'From: runtime\nTo: coordinator\nWhich branch?');
  await watcher.check(c.ctx, c.pi, 200001);
  assert.equal(c.messages.length, 0);
  await watcher.close();
  watcher = c.watch(); c.busy(false);
  await watcher.check(c.ctx, c.pi, 200002);
  assert.match(c.messages[0].content, /question.md/);
  await watcher.check(c.ctx, c.pi, 200003); assert.equal(c.messages.length, 1);
  await watcher.check(c.ctx, c.pi, 320003); assert.equal(c.messages.length, 2);
  await assert.rejects(watcher.ack('inbox:question.md', 'stale', 'answered'));
  await c.ackAll(watcher);
  await watcher.check(c.ctx, c.pi, 500000); assert.equal(c.messages.length, 2);
  await writeFile(join(c.root, 'question.md'), 'From: runtime\nTo: coordinator\nNew blocker');
  c.queued(true); await watcher.check(c.ctx, c.pi, 500001); assert.equal(c.messages.length, 2);
  c.queued(false); await watcher.check(c.ctx, c.pi, 500002); assert.equal(c.messages.length, 3);
});

scenario('bootstrap pending native question and existing handoff survive acknowledged restart', async c => {
  await c.fixture({ events: [{ sequence: 1, kind: 'question_available', worker_id: worker, turn_id: turn, question_id: question, revision: 1 }],
    turns: [{ turn_id: turn, slot: worker, state: 'running' }], questions: { [question]: pending() }, handoffs: { [turn]: handoff } });
  let watcher = c.watch(); await watcher.check(c.ctx, c.pi, 200000);
  const items = await c.items();
  assert.equal(items.filter(x => x.selectors[0] === 'question').length, 1);
  assert.equal(items.filter(x => x.selectors[0] === 'handoff').length, 1);
  await c.ackAll(watcher); await watcher.close();
  watcher = c.watch(); await watcher.check(c.ctx, c.pi, 400000);
  assert.deepEqual((await c.state()).pending, {}); assert.equal(c.messages.length, 1);
});

// History turns (C2b, I-W): `turns` answers the history contract's turn shape; its slot is the
// guidance worker name the question/handoff selectors take (P20).
const slot = 'dev1';
const historyTurn = (state, id = turn) => ({ turn_id: id, slot, state, native_outcome: null, started_at: '2026-11-16T10:00:00Z',
  ended_at: null, harness: 'codex', configured_model: 'gpt-5', reported_model: null, conversation_id: null });

for (const outcome of ['finished', 'failed', 'stopped', 'killed']) {
  scenario(`history turn in state ${outcome} becomes output and handoff items on its slot`, async c => {
    await c.fixture({ turns: [historyTurn(outcome)], handoffs: { [turn]: { ...handoff, worker_id: slot } } });
    const watcher = c.watch(); await watcher.check(c.ctx, c.pi, 200000);
    const items = await c.items();
    const output = items.filter(x => x.selectors[0] === 'output');
    assert.equal(output.length, 1);
    assert.deepEqual(output[0].selectors, ['output', '--turn', turn]);
    assert.deepEqual(output[0].evidence, { worker_id: slot, turn_id: turn, state: outcome });
    assert.deepEqual(items.filter(x => x.selectors[0] === 'handoff').map(x => x.selectors), [['handoff', '--worker', slot, '--turn', turn]]);
    assert.ok((await c.calls()).some(x => x.join(' ') === `handoff --worker ${slot} --turn ${turn}`));
  });
}

scenario('a history turn that has not ended gets no output item, only the handoff inspection', async c => {
  const other = 'turn-4444444444444444';
  await c.fixture({ turns: [historyTurn('running'), historyTurn('unknown', other)] });
  const watcher = c.watch(); await watcher.check(c.ctx, c.pi, 200000);
  assert.deepEqual(await c.items(), []);
  const calls = (await c.calls()).map(x => x.join(' '));
  assert.ok(calls.includes(`handoff --worker ${slot} --turn ${turn}`) && calls.includes(`handoff --worker ${slot} --turn ${other}`));
});

scenario('turns contributes no question: a pending field on a history turn is not read', async c => {
  await c.fixture({ turns: [{ ...historyTurn('running'), pending_question: { id: question, question_id: question } }],
    questions: { [question]: pending() } });
  const watcher = c.watch(); await watcher.check(c.ctx, c.pi, 200000);
  assert.deepEqual((await c.calls()).filter(x => x[0] === 'question'), []);
  assert.deepEqual(await c.items(), []);
});

scenario('a history turn with an unsafe identifier is surfaced once and never becomes a selector', async c => {
  await c.fixture({ turns: [{ ...historyTurn('finished'), slot: '$(id)' }, { ...historyTurn('killed'), turn_id: 'turn x' }] });
  const watcher = c.watch(); await watcher.check(c.ctx, c.pi, 200000);
  const items = await c.items();
  assert.equal(items.length, 1);
  assert.match(items[0].evidence.error, /unsafe identifier/);
  assert.deepEqual(items[0].selectors, ['turns']);
  assert.deepEqual((await c.calls()).filter(x => !['service', 'turns', 'events'].includes(x[0])), []);
});

// C2b 3 rests on C1's journal reconcile step (I-W: `events --limit 100` pages in fresh()/gap(),
// each event through event()).
scenario('a pending question absent from turns is found through the journal reconcile', async c => {
  await c.fixture({ turns: [historyTurn('running')], questions: { [question]: { ...pending(), worker_id: slot } },
    events: [{ sequence: 1, kind: 'question_available', worker_id: slot, turn_id: turn, question_id: question, revision: 1 }] });
  const watcher = c.watch(); await watcher.check(c.ctx, c.pi, 200000);
  const items = (await c.items()).filter(x => x.selectors[0] === 'question');
  assert.deepEqual(items.map(x => x.selectors), [['question', '--worker', slot, '--turn', turn, '--question', question]]);
});

scenario('legacy state preserves unresolved events and acknowledged terminal work', async c => {
  await mkdir(join(c.root, '.delivery'));
  await writeFile(join(c.root, '.delivery/coordinator-watch.json'), JSON.stringify({ version: 1,
    seen: { [`turn:${turn}`]: 'old-signature' }, pending: { 'inbox:legacy.md': { path: 'legacy', signature: 'keep' } }, lastNudge: 0 }));
  await c.fixture({ turns: [{ turn_id: turn, slot: worker, state: 'finished' }], handoffs: { [turn]: handoff } });
  const watcher = c.watch(); await watcher.check(c.ctx, c.pi, 200000);
  const state = await c.state();
  assert.equal(state.pending['inbox:legacy.md'].signature, 'keep');
  assert.equal(Object.values(state.pending).filter(x => x.selectors?.[0] === 'output').length, 0);
  assert.equal(Object.values(state.pending).filter(x => x.selectors?.[0] === 'handoff').length, 1);
});

scenario('disappeared queued question surfaces a gap without blocking later handoffs', async c => {
  await c.fixture({ handoffs: { [turn]: handoff } });
  const watcher = c.watch(); await watcher.check(c.ctx, c.pi, 200000);
  c.stream.child.send({ sequence: 1, kind: 'question_available', worker_id: worker, turn_id: turn, question_id: question },
    { sequence: 2, kind: 'handoff_submitted', worker_id: worker, turn_id: turn }, { cursor: 'e1:2' });
  await watcher.check(c.ctx, c.pi, 200001);
  const state = await c.state();
  assert.ok(Object.values(state.pending).some(x => x.evidence?.warning));
  assert.ok(Object.values(state.pending).some(x => x.selectors?.[0] === 'handoff'));
  assert.equal(state.runtimes[c.runtimeHome].retryAt, 0);
});

scenario('notification failure retains discovered work and cursor for a fresh watcher', async c => {
  await c.fixture({ handoffs: { [turn]: handoff } });
  let watcher = c.watch(); await watcher.check(c.ctx, c.pi, 200000);
  c.stream.child.send({ sequence: 1, kind: 'handoff_submitted', worker_id: worker, turn_id: turn }, { cursor: 'e1:1' });
  await assert.rejects(watcher.check(c.ctx, { sendMessage: async () => { throw new Error('notification unavailable'); } }, 200001));
  const before = await c.state();
  assert.equal(before.runtimes[c.runtimeHome].cursor, 'e1:1');
  await watcher.close();
  watcher = c.watch(); await watcher.check(c.ctx, c.pi, 200002);
  assert.deepEqual((await c.state()).pending, before.pending);
  assert.equal(c.messages.length, 1);
});

scenario('query outage preserves cursor and inbox delivery without repeated error flood', async c => {
  const watcher = c.watch(); await watcher.check(c.ctx, c.pi, 200000);
  c.stream.child.send({ sequence: 1, kind: 'handoff_submitted', worker_id: worker, turn_id: turn }, { cursor: 'e1:1' });
  await c.fixture({ failure: 'service is unavailable' });
  await writeFile(join(c.root, 'question.md'), 'From: server\nTo: coordinator\nNeed help');
  await watcher.check(c.ctx, c.pi, 200001);
  let state = await c.state();
  assert.ok(state.pending['inbox:question.md']);
  assert.equal(Object.values(state.pending).filter(x => x.evidence?.error).length, 1);
  assert.equal(state.runtimes[c.runtimeHome].cursor, 'e1:1');
  await c.ackAll(watcher);
  await watcher.check(c.ctx, c.pi, 260002);
  assert.deepEqual((await c.state()).pending, {});
});

for (const failure of ['timeout', 'output']) {
  scenario(`bounded subprocess ${failure} still delivers inbox`, async c => {
    await c.fixture({ failure });
    await writeFile(join(c.root, 'question.md'), 'From: server\nTo: coordinator\nHelp');
    const watcher = c.watch(), start = Date.now();
    await watcher.check(c.ctx, c.pi, 200000);
    assert.ok(Date.now() - start < 5000);
    assert.ok((await c.state()).pending['inbox:question.md']);
    assert.ok(Object.values((await c.state()).pending).some(x => x.evidence?.error));
  });
}

// The operations cutover (S2 C1): `service status` is the runtime info, a reachability probe only;
// pending questions come from the journal replay.
const eventsCalls = async c => (await c.calls()).filter(x => x[0] === 'events');
const filler = (from, count) => Array.from({ length: count }, (_, i) => ({ sequence: from + i, kind: 'capacity_available' }));
const kinds = async c => (await c.items()).map(x => x.selectors[0]);

scenario('runtime-info service status and a finished turn give output and handoff items, no unavailable', async c => {
  await c.fixture({ turns: [{ turn_id: turn, slot: worker, state: 'finished' }], handoffs: { [turn]: handoff } });
  const watcher = c.watch(); await watcher.check(c.ctx, c.pi, 200000);
  const state = await c.state();
  assert.deepEqual((await kinds(c)).sort(), ['handoff', 'output']);
  assert.equal(state.runtimes[c.runtimeHome].unavailable, false);
  assert.ok(!Object.keys(state.pending).some(id => id.endsWith(':unavailable')));
});

scenario('a pending question known only from the journal is recorded', async c => {
  await c.fixture({ events: [{ sequence: 4, kind: 'question_available', worker_id: worker, turn_id: turn, question_id: question, revision: 1 }],
    turns: [{ turn_id: turn, slot: worker, state: 'running' }], questions: { [question]: pending() } });
  const watcher = c.watch(); await watcher.check(c.ctx, c.pi, 200000);
  const [[id, item]] = Object.entries((await c.state()).pending);
  assert.ok(id.endsWith(`:question:${turn}:${question}`), 'question item recorded');
  assert.deepEqual(item.selectors, ['question', '--worker', worker, '--turn', turn, '--question', question]);
  assert.deepEqual(await eventsCalls(c), [['events', '--limit', '100']]);
});

scenario('a journal question that was answered records nothing', async c => {
  await c.fixture({ events: [{ sequence: 4, kind: 'question_available', worker_id: worker, turn_id: turn, question_id: question, revision: 1 }],
    questions: { [question]: { ...pending(), active: false, admission: 'accepted' } } });
  const watcher = c.watch(); await watcher.check(c.ctx, c.pi, 200000);
  assert.deepEqual(await c.items(), []);
  assert.ok((await c.calls()).some(x => x[0] === 'question'), 'the question was inspected');
});

scenario('the replay pages to the end: 250 events are three pages, and page 3 is read', async c => {
  const late = 'turn-4444444444444444';
  const events = [...filler(1, 240), { sequence: 241, kind: 'handoff_submitted', worker_id: worker, turn_id: late }, ...filler(242, 9)];
  await c.fixture({ events, handoffs: { [late]: { ...handoff, turn_id: late } } });
  const watcher = c.watch();
  for (let i = 0; i < 3; i++) await watcher.check(c.ctx, c.pi, 200000 + i);
  assert.deepEqual(await eventsCalls(c), [['events', '--limit', '100'], ['events', '--limit', '100', '--cursor', 'c:100'],
    ['events', '--limit', '100', '--cursor', 'c:200']]);
  assert.ok((await c.items()).some(x => x.selectors[0] === 'handoff' && x.evidence.turn_id === late));
});

scenario('the replay stops on more: false, not on a short page: 200 events are two pages', async c => {
  await c.fixture({ events: filler(1, 200) });
  const watcher = c.watch();
  for (let i = 0; i < 3; i++) await watcher.check(c.ctx, c.pi, 200000 + i);
  assert.deepEqual(await eventsCalls(c), [['events', '--limit', '100'], ['events', '--limit', '100', '--cursor', 'c:100']]);
  assert.deepEqual(await c.items(), [], 'the first page\'s reset is no gap');
  assert.deepEqual((await c.state()).runtimes[c.runtimeHome].work, []);
});

scenario('a stopped Runtime answering service status with exit 0 is unavailable', async c => {
  await c.fixture({ service: { service: 'stopped' } });
  const watcher = c.watch(); await watcher.check(c.ctx, c.pi, 200000);
  const state = await c.state();
  assert.equal(state.runtimes[c.runtimeHome].unavailable, true);
  const items = await c.items();
  assert.equal(items.length, 1);
  assert.deepEqual(items[0].selectors, ['service', 'status']);
  assert.match(items[0].evidence.error, /stopped/);
});

scenario('a replayed question without a record is recorded once and never replays again', async c => {
  await c.fixture({ events: [{ sequence: 1, kind: 'question_available', worker_id: worker, turn_id: turn, question_id: question, revision: 1 }] });
  const watcher = c.watch();
  for (let i = 0; i < 5; i++) await watcher.check(c.ctx, c.pi, 200000 + i);
  assert.equal((await eventsCalls(c)).length, 1, 'one replay, not one per cycle');
  const items = await c.items();
  assert.equal(items.length, 1);
  assert.deepEqual(items[0].evidence, { worker_id: worker, turn_id: turn, question_id: question,
    error: 'Question record unavailable; no matching recorded question' });
  assert.ok(Object.keys((await c.state()).pending)[0].endsWith(`:missing_question:${turn}:${question}`));
  assert.deepEqual((await c.state()).runtimes[c.runtimeHome].work, []);
});
