#!/bin/zsh
# Usage: secret.sh NAME -> prints one secret of this machine from Infisical to stdout.
# Where it is: machine.json's "infisical" (domain, project_id, env, path). Credentials: the
# universal-auth client ID and secret in the login keychain (account: machine.json's
# "machine", services atlas-infisical-client-id and atlas-infisical-client-secret), readable
# only in the logged-in GUI session. Nothing is written to disk, and no secret is ever a
# process argument (`ps` shows none): the client ID and secret reach `infisical login` in
# its environment (INFISICAL_UNIVERSAL_AUTH_CLIENT_ID/_SECRET, IS-Atlas-116), its access
# token reaches `infisical secrets get` as INFISICAL_TOKEN.
set -e
export PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin
C=$HOME/.config/atlas-runtime/machine.json
get() { plutil -extract "$1" raw -o - "$C" }
M=$(get machine)
D=$(get infisical.domain)
TOK=$(INFISICAL_UNIVERSAL_AUTH_CLIENT_ID=$(security find-generic-password -a "$M" -s atlas-infisical-client-id -w) \
  INFISICAL_UNIVERSAL_AUTH_CLIENT_SECRET=$(security find-generic-password -a "$M" -s atlas-infisical-client-secret -w) \
  infisical login --method=universal-auth --domain="$D" --silent --plain 2>/dev/null | tail -1)
INFISICAL_TOKEN=$TOK infisical secrets get "$1" --projectId "$(get infisical.project_id)" \
  --env "$(get infisical.env)" --path "$(get infisical.path)" --domain="$D" --plain 2>/dev/null | tail -1
