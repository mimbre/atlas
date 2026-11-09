# The core of an Atlas environment on Fly (Bus, Facts, Flow, Control) as a release. Built
# from the repository root:
#   fly deploy --config fly/<env>/core.toml   (CI does this on a merge)
FROM hexpm/elixir:1.18.4-erlang-28.5.0.2-debian-bookworm-20260610-slim AS build

ENV MIX_ENV=prod
# What the umbrella reads outside beam/ to compile: Control and Runtime the contract (a
# path dependency, which compiles with its generator); Gates the flow generator (a path
# dependency) and the gate definitions it generated, read at compile time.
COPY bff/generator /src/bff/generator
COPY bff/contract /src/bff/contract
COPY flow/generator /src/flow/generator
COPY flow/targets/atlas/flows.json /src/flow/targets/atlas/flows.json
COPY flow/targets/test/atlas/flows.json /src/flow/targets/test/atlas/flows.json
COPY beam /src/beam
WORKDIR /src/beam
RUN mix compile --warnings-as-errors && mix release atlas

FROM debian:bookworm-slim

RUN apt-get update \
  && apt-get install -y --no-install-recommends libstdc++6 openssl libncurses6 ca-certificates python3 \
  && rm -rf /var/lib/apt/lists/*

ENV LANG=C.UTF-8 ATLAS_ROOT=/app RELEASE_DISTRIBUTION=none
COPY --from=build /src/beam/_build/prod/rel/atlas /app/release
# What the core reads from the repository at run time: the description's extra, its
# settings per environment, and the flows Flow runs (rela/flows.yaml, the assembler's copy
# of flow/targets/rela/flows.yaml). The rela image does not get flows.yaml: the running
# rela must not load flows (D-0068).
COPY rela/schema.yaml rela/data-entry.yaml rela/atlas.json rela/atlas.manifest.json rela/flows.yaml rela/flow-runtime.json /app/rela/
COPY rela/modules /app/rela/modules
COPY flow/targets/test/rela/flows.yaml /app/flow/targets/test/rela/flows.yaml
COPY rela/compositions /app/rela/compositions
COPY rela/scripts/verify.py /app/rela/scripts/verify.py
RUN python3 /app/rela/scripts/verify.py /app/rela
COPY fly /app/fly
# Keep test access separate; production continues reading the canonical atlas.json.
RUN python3 -c 'import json; d=json.load(open("/app/rela/atlas.json")); d["guidance"]["control"]=json.load(open("/app/fly/test/worker-access.json")); d["shell"]["tabs"].append({"id":"workers","label":"Workers","to":"/workers"}); open("/app/rela/atlas-test.json","w").write(json.dumps(d))'

CMD ["/app/fly/core-run.sh"]
