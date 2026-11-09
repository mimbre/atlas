# rela for an Atlas environment on Fly. Built from the repository root:
#   fly deploy --config products/software_factory/environments/<env>/rela.toml   (CI does this on a merge)
FROM debian:bookworm-slim

RUN apt-get update \
  && apt-get install -y --no-install-recommends ca-certificates curl python3 python3-yaml sqlite3 \
  && rm -rf /var/lib/apt/lists/*

# The rela version start-test.sh pins, for this machine (linux_amd64).
COPY platform/atlas_facts/rela/scripts /app/platform/atlas_facts/rela/scripts
RUN ATLAS_RELA_BIN=/app/bin /app/platform/atlas_facts/rela/scripts/start-test.sh install

COPY products/software_factory/targets/rela/schema.yaml products/software_factory/targets/rela/data-entry.yaml products/software_factory/targets/rela/atlas.json products/software_factory/targets/rela/atlas.manifest.json /app/products/software_factory/targets/rela/
COPY products/software_factory/targets/rela/modules /app/products/software_factory/targets/rela/modules
COPY products/software_factory/targets/rela/compositions /app/products/software_factory/targets/rela/compositions
RUN python3 /app/platform/atlas_facts/rela/scripts/verify.py /app/products/software_factory/targets/rela
COPY platform/ops/apply-move.sh platform/ops/rela-run.sh platform/ops/counts.sh platform/ops/manifest.sh /app/platform/ops/

CMD ["/app/platform/ops/rela-run.sh"]
