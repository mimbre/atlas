#!/bin/zsh
# Usage: secret.sh NAME -> prints one secret of this machine from Infisical to stdout.
# Where it is: machine.json's "infisical" (domain, project_id, env, path). Credentials: the
# universal-auth client ID and secret in the login keychain (account: machine.json's
# "machine", services atlas-infisical-client-id and atlas-infisical-client-secret), readable
# only in the logged-in GUI session. Nothing is written to disk, and no secret is an
# argument of a process (`ps` shows none): infisical reads the client ID and secret from
# INFISICAL_UNIVERSAL_AUTH_CLIENT_ID/_SECRET, set for its one login only, and the token from
# INFISICAL_TOKEN.
set -e
export PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin
C=$HOME/.config/atlas-runtime/machine.json
get() { plutil -extract "$1" raw -o - "$C" }
M=$(get machine)
D=$(get infisical.domain)
CID=$(security find-generic-password -a "$M" -s atlas-infisical-client-id -w)
CS=$(security find-generic-password -a "$M" -s atlas-infisical-client-secret -w)
TOK=$(INFISICAL_UNIVERSAL_AUTH_CLIENT_ID=$CID INFISICAL_UNIVERSAL_AUTH_CLIENT_SECRET=$CS \
  infisical login --method=universal-auth --domain="$D" --silent --plain 2>/dev/null | tail -1)
unset CID CS
INFISICAL_TOKEN=$TOK infisical secrets get "$1" --projectId "$(get infisical.project_id)" \
  --env "$(get infisical.env)" --path "$(get infisical.path)" --domain="$D" --plain 2>/dev/null | tail -1
