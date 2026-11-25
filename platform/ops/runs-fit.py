#!/usr/bin/env python3
"""Does the update keep a place for every open flow run of an environment?

A run remembers its flow and its state by name (D-0102). An update that removes or renames
a flow, or a state of one, goes through only once no open run is in it: deploy.sh runs this
before `fly deploy` and deploys nothing while a run would lose its place.

  runs-fit.py open <port>                          # on the rela machine: the open runs, as JSON
  runs-fit.py check <runs> <current> <new>         # here: the runs the update takes out

`open` pages rela's API on loopback (http://127.0.0.1:<port>/api/v1/flow_runs, 100 a page,
until `meta.has_more` is false) and prints `[{"key", "flow", "state", "status"}, ...]` of
every run whose status is neither `completed` nor `ended`. Plain Python 3, nothing else: the
rela image has no other tools.

`check` reads that list, the running model's flows and the new model's (each
`{"<flow>": ["<state>", ...]}`: the deployed core's and `mix model.flows --env <env>`), prints
one line per run whose flow and state the running model has and the new one does not, and
exits 1 when there is one; 0 when the update keeps them all. A run the running model has no
place for already is not the update's: Flow ends it (IS-Atlas-139).
"""
import json
import sys
import urllib.request

PAGE = 100


def open_runs(fetch):
    """Every run whose status is neither completed nor ended; `fetch(page)` returns one parsed page."""
    runs, page = [], 1
    while True:
        body = fetch(page)
        for item in body.get('data') or []:
            props = item.get('properties') or {}
            if props.get('status') not in ('completed', 'ended'):
                runs.append({'key': item.get('id'), 'flow': props.get('flow'),
                             'state': props.get('state'), 'status': props.get('status')})
        if not (body.get('meta') or {}).get('has_more'):
            return runs
        page += 1


def misfits(runs, current, new):
    """One line per run the update takes its flow or state from."""
    lines = []
    for run in runs:
        flow, state = run.get('flow'), run.get('state')
        if state not in current.get(flow, []):
            continue
        if flow not in new:
            lines.append(f"{run.get('key')}: flow {flow} (state {state}) is no flow of the new model")
        elif state not in new[flow]:
            lines.append(f"{run.get('key')}: state {state} is no state of flow {flow} in the new model")
    return lines


def http_page(port):
    def fetch(page):
        url = f'http://127.0.0.1:{port}/api/v1/flow_runs?per_page={PAGE}&page={page}'
        with urllib.request.urlopen(url, timeout=30) as response:
            return json.load(response)
    return fetch


def main(argv):
    if len(argv) == 2 and argv[0] == 'open':
        json.dump(open_runs(http_page(int(argv[1]))), sys.stdout)
        print()
        return 0
    if len(argv) == 4 and argv[0] == 'check':
        models = []
        for path in argv[1:]:
            with open(path) as f:
                models.append(json.load(f))
        lines = misfits(*models)
        for line in lines:
            print(line)
        return 1 if lines else 0
    print(__doc__.split('\n\n')[2], file=sys.stderr)
    return 2


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
