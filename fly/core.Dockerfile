# The core of an Atlas environment on Fly (Bus, Facts, Flow, Control) as a release. Built
# from the repository root:
#   fly deploy --config fly/<env>/core.toml   (CI does this on a merge)
FROM hexpm/elixir:1.18.4-erlang-28.5.0.2-debian-bookworm-20260610-slim AS build

ENV MIX_ENV=prod
# Control reads the contract at compile time; the contract compiles with the generator.
COPY bff/generator /src/bff/generator
COPY bff/contract /src/bff/contract
COPY beam /src/beam
WORKDIR /src/beam
RUN mix compile --warnings-as-errors && mix release atlas

FROM debian:bookworm-slim

RUN apt-get update \
  && apt-get install -y --no-install-recommends libstdc++6 openssl libncurses6 ca-certificates python3 \
  && rm -rf /var/lib/apt/lists/*

ENV LANG=C.UTF-8 ATLAS_ROOT=/app RELEASE_DISTRIBUTION=none
COPY --from=build /src/beam/_build/prod/rel/atlas /app/release
# What the core reads from the repository at run time: the description's extra, and its
# settings per environment.
COPY rela/schema.yaml rela/data-entry.yaml rela/atlas.json rela/atlas.manifest.json /app/rela/
COPY rela/modules /app/rela/modules
COPY rela/compositions /app/rela/compositions
COPY rela/scripts/verify.py /app/rela/scripts/verify.py
RUN python3 /app/rela/scripts/verify.py /app/rela
COPY fly /app/fly
# Keep test access separate; production continues reading the canonical atlas.json.
RUN python3 -c 'import json; d=json.load(open("/app/rela/atlas.json")); d["guidance"]["control"]=json.load(open("/app/fly/test/worker-access.json")); d["shell"]["tabs"].append({"id":"workers","label":"Workers","to":"/workers"}); open("/app/rela/atlas-test.json","w").write(json.dumps(d))'

CMD ["/app/fly/core-run.sh"]
