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
COPY transport /src/transport
COPY beam /src/beam
WORKDIR /src/beam
RUN mix compile --warnings-as-errors && mix release atlas

# Tailscale (D-0089): the machine joins the tailnet itself, so every client reaches Control
# there; Control has no public address. The static release for the build's architecture
# (Fly's machines: amd64), pinned and checked against its SHA-256 like the rela archive
# (rela/scripts/start-test.sh). A new version: its sha256 is published beside it, at
# <the archive's URL>.sha256; update all three arguments together.
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

# iptables: tailscaled's firewall rules when the machine has a kernel TUN; jq: reading
# `tailscale status --json` (fly/core-run.sh).
RUN apt-get update \
  && apt-get install -y --no-install-recommends libstdc++6 openssl libncurses6 ca-certificates python3 iptables jq \
  && rm -rf /var/lib/apt/lists/*
COPY --from=tailscale /tailscale/tailscale /tailscale/tailscaled /usr/local/bin/

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
