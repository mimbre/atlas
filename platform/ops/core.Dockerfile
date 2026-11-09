# The core of an Atlas environment on Fly (Bus, Facts, Flow, Control) as a release. Built
# from the repository root:
#   fly deploy --config products/software_factory/environments/<env>/core.toml   (CI does this on a merge)
FROM hexpm/elixir:1.18.4-erlang-28.5.0.2-debian-bookworm-20260610-slim AS build

ENV MIX_ENV=prod
# What the umbrella (products/software_factory, its apps in platform/) reads to compile:
# Control and Runtime the contract (platform/atlas_control/bff/contract, a path dependency
# inside Control's folder, which compiles with its generator); the release the model
# (products/software_factory/model/contract, which Facts, Flow, Gates, Runtime and Control are wired
# to) and the Rela DSL it is written in (products/software_factory/model/generator). No generated JSON: the model is
# compiled in (D-0083).
COPY products/software_factory/model/generator /src/products/software_factory/model/generator
COPY products/software_factory/model/contract /src/products/software_factory/model/contract
COPY platform/atlas_bus /src/platform/atlas_bus
COPY platform/atlas_code /src/platform/atlas_code
COPY platform/atlas_control /src/platform/atlas_control
COPY platform/atlas_facts /src/platform/atlas_facts
COPY platform/atlas_flow /src/platform/atlas_flow
COPY platform/atlas_gates /src/platform/atlas_gates
COPY platform/atlas_learn /src/platform/atlas_learn
COPY platform/atlas_runtime /src/platform/atlas_runtime
COPY products/software_factory/mix.exs products/software_factory/.formatter.exs products/software_factory/.gitignore /src/products/software_factory/
COPY products/software_factory/config /src/products/software_factory/config
COPY products/software_factory/integration /src/products/software_factory/integration
WORKDIR /src/products/software_factory
RUN mix compile --warnings-as-errors && mix release atlas

# Optional Control ingress binaries, pinned and checksum verified for each architecture.
FROM debian:bookworm-slim AS tailscale
ARG TARGETARCH
ARG TAILSCALE_VERSION=1.104.7
ARG TAILSCALE_SHA256_AMD64=e56693ff74a64f2591b7e819c280635a100aae1ddfb0ef058fcd052b7cd8d16c
ARG TAILSCALE_SHA256_ARM64=d6bed2720310b328b861f943d7b4016c5358a9bad60575eb51e8143b79068484
RUN apt-get update \
  && apt-get install -y --no-install-recommends ca-certificates curl \
  && rm -rf /var/lib/apt/lists/*
RUN arch="${TARGETARCH:-amd64}" \
  && case "$arch" in \
       amd64) sum="$TAILSCALE_SHA256_AMD64" ;; \
       arm64) sum="$TAILSCALE_SHA256_ARM64" ;; \
       *) echo "tailscale: no pinned archive for architecture $arch" >&2; exit 1 ;; \
     esac \
  && archive="tailscale_${TAILSCALE_VERSION}_${arch}.tgz" \
  && curl -fsSL -o "/tmp/$archive" "https://pkgs.tailscale.com/stable/$archive" \
  && { echo "$sum  /tmp/$archive" | sha256sum -c - \
       || { echo "tailscale $TAILSCALE_VERSION ($arch): the archive does not match its pinned SHA-256" >&2; exit 1; }; } \
  && mkdir /tailscale \
  && tar -xzf "/tmp/$archive" -C /tailscale --strip-components=1 \
  && /tailscale/tailscale version


FROM debian:bookworm-slim

RUN apt-get update \
  && apt-get install -y --no-install-recommends libstdc++6 openssl libncurses6 ca-certificates python3 \
  && rm -rf /var/lib/apt/lists/*

COPY --from=tailscale /tailscale/tailscale /tailscale/tailscaled /usr/local/bin/

ENV LANG=C.UTF-8 ATLAS_ROOT=/app RELEASE_DISTRIBUTION=none
COPY --from=build /src/products/software_factory/_build/prod/rel/atlas /app/release
# The Rela project the model generated, checked against its manifest at build and at start
# (verify.py). The core reads none of it: Facts compares rela's served schema with the
# compiled model at boot. No atlas.json, flow-runtime.json or flows.yaml: proofs only, or
# rela's (the running rela must not load flows either, D-0068).
COPY products/software_factory/model/targets/rela/schema.yaml products/software_factory/model/targets/rela/data-entry.yaml products/software_factory/model/targets/rela/atlas.manifest.json /app/products/software_factory/model/targets/rela/
COPY products/software_factory/model/targets/rela/modules /app/products/software_factory/model/targets/rela/modules
COPY products/software_factory/model/targets/rela/compositions /app/products/software_factory/model/targets/rela/compositions
COPY platform/atlas_facts/rela/scripts/verify.py /app/platform/atlas_facts/rela/scripts/verify.py
RUN python3 /app/platform/atlas_facts/rela/scripts/verify.py /app/products/software_factory/model/targets/rela
# Each environment's settings, test's Workers tab and worker access among them (the
# "control" of products/software_factory/environments/<env>/core.json), and the ops scripts
# (platform/ops; .dockerignore leaves out what is not for the images).
COPY platform/ops /app/platform/ops
COPY products/software_factory/environments/test /app/products/software_factory/environments/test
COPY products/software_factory/environments/prod /app/products/software_factory/environments/prod

CMD ["/app/platform/ops/core-run.sh"]
