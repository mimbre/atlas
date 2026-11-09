# rela for an Atlas environment on Fly. Built from the repository root:
#   fly deploy --config fly/<env>/rela.toml   (CI does this on a merge)
FROM debian:bookworm-slim

RUN apt-get update \
  && apt-get install -y --no-install-recommends ca-certificates curl python3 python3-yaml sqlite3 \
  && rm -rf /var/lib/apt/lists/*

# The rela version start-test.sh pins, for this machine (linux_amd64).
COPY rela/scripts /app/rela/scripts
RUN ATLAS_RELA_BIN=/app/bin /app/rela/scripts/start-test.sh install

COPY rela/schema.yaml rela/data-entry.yaml rela/atlas.json rela/atlas.manifest.json /app/rela/
COPY rela/modules /app/rela/modules
COPY rela/compositions /app/rela/compositions
RUN python3 /app/rela/scripts/verify.py /app/rela
COPY fly/apply-move.sh fly/rela-run.sh fly/counts.sh fly/manifest.sh /app/fly/

CMD ["/app/fly/rela-run.sh"]
