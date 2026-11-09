# The core of an Atlas environment on Fly (Bus, Facts, Flow, Control) as a release. Built
# from the repository root:
#   fly deploy --config fly/<env>/core.toml   (CI does this on a merge)
FROM hexpm/elixir:1.18.4-erlang-28.5.0.2-debian-bookworm-20260610-slim AS build

ENV MIX_ENV=prod
# What the umbrella reads outside beam/ to compile: Control and Runtime the contract (a
# path dependency, which compiles with its generator); the release the model (model/contract,
# which Facts, Flow, Gates, Runtime and Control are wired to) and the Rela DSL it is written
# in (model/dsl). No generated JSON: the model is compiled in (D-0083).
COPY bff/generator /src/bff/generator
COPY bff/contract /src/bff/contract
COPY model/dsl /src/model/dsl
COPY model/contract /src/model/contract
COPY beam /src/beam
WORKDIR /src/beam
RUN mix compile --warnings-as-errors && mix release atlas

FROM debian:bookworm-slim

RUN apt-get update \
  && apt-get install -y --no-install-recommends libstdc++6 openssl libncurses6 ca-certificates python3 \
  && rm -rf /var/lib/apt/lists/*

ENV LANG=C.UTF-8 ATLAS_ROOT=/app RELEASE_DISTRIBUTION=none
COPY --from=build /src/beam/_build/prod/rel/atlas /app/release
# The Rela project the model generated, checked against its manifest at build and at start
# (verify.py). The core reads none of it: Facts compares rela's served schema with the
# compiled model at boot. No atlas.json, flow-runtime.json or flows.yaml: proofs only, or
# rela's (the running rela must not load flows either, D-0068).
COPY rela/schema.yaml rela/data-entry.yaml rela/atlas.manifest.json /app/rela/
COPY rela/modules /app/rela/modules
COPY rela/compositions /app/rela/compositions
COPY rela/scripts/verify.py /app/rela/scripts/verify.py
RUN python3 /app/rela/scripts/verify.py /app/rela
# Each environment's settings, test's Workers tab and worker access among them (the
# "control" of fly/<env>/core.json).
COPY fly /app/fly

CMD ["/app/fly/core-run.sh"]
