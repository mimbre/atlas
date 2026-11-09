# Shared by bin/atlas, bin/atlas-ops and bin/atlas-dev, sourced once "$root" (the checkout)
# is known. bin/atlas and bin/atlas-ops set "$prog" (their name, for messages) first and
# resolve the environment through take_env, resolve_env and resolve_places, so both always
# agree on which environment a command works on and where its processes are.

# Keep ordinary invocations on the isolated project dependency without shell setup.
if [ -z "${ATLAS_CONFIG_PYTHON:-}" ] && [ -x "$root/.venv-config/bin/python" ]; then
  export ATLAS_CONFIG_PYTHON="$root/.venv-config/bin/python"
fi

no_env() { echo "$prog: --env needs test or prod" >&2; exit 2; }

# --env from anywhere in the arguments into $env; the other arguments, in order, into the
# array rest.
take_env() {
  env=""
  rest=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --env) [ -n "${2:-}" ] || no_env; env="$2"; shift 2 ;;
      --env=?*) env="${1#--env=}"; shift ;;
      --env=) no_env ;;
      *) rest+=("$1"); shift ;;
    esac
  done
}

# The settings file of $env (prod by default), or ATLAS_ENV_FILE: a private instance whose
# environment is the file's "env". --env and the file's "env" must agree.
resolve_env() {
  settings="${ATLAS_ENV_FILE:-}"
  if [ -z "$settings" ]; then
    env="${env:-prod}"
    settings="$root/env/$env.json"
  fi
  [ -f "$settings" ] || { echo "$prog: no environment '$env' (no $settings)" >&2; exit 1; }
  # Absolute, so the core and the clients find it from their own folders.
  settings="$(cd "$(dirname "$settings")" && pwd -P)/$(basename "$settings")"
  [ -z "${ATLAS_ENV_FILE:-}" ] || export ATLAS_ENV_FILE="$settings"
  # The file says which environment it is; a private file without --env is that one.
  local file_env
  file_env="$(setting env)"
  env="${env:-$file_env}"
  case "$env" in test|prod) ;; *) echo "$prog: no environment '$env'; use --env test or --env prod" >&2; exit 1 ;; esac
  if [ "$file_env" != "$env" ]; then
    echo "$prog: $settings is for $file_env, not $env" >&2; exit 1
  fi
  export ATLAS_ROOT="$root" ATLAS_ENV="$env"
}

# A value from the settings file: plutil on macOS, jq elsewhere (CI).
setting() {
  local v
  if command -v plutil >/dev/null; then v="$(plutil -extract "$1" raw -o - "$settings")"; else v="$(jq -er ".$1" "$settings")"; fi
  echo "${v/#\~/$HOME}"
}

has_setting() {
  if command -v plutil >/dev/null; then plutil -extract "$1" raw -o - "$settings" >/dev/null 2>&1
  else jq -e ".$1" "$settings" >/dev/null 2>&1; fi
}

# Whether a "fly" section says the clients use Fly: unless "in_use" is false.
fly_in_use() {
  if command -v plutil >/dev/null; then [ "$(plutil -extract fly.in_use raw -o - "$settings" 2>/dev/null)" != false ]
  else [ "$(jq -r '.fly.in_use' "$settings")" != false ]; fi
}

# Where the environment's processes are. On Fly (IS-Atlas-26) $fly_app is set, and
# control.host and control.port are Control's on the tailnet (D-0089): the Fly app's
# MagicDNS name and its port; this machine keeps only the TUI's agent log (fly.local).
# Otherwise the core and rela run here.
resolve_places() {
  if has_setting control.host_env; then
    local host_env
    host_env="$(setting control.host_env)"
    host="${!host_env:-}"
  else
    host="$(setting control.host)"
  fi
  port="$(setting control.port)"
  fly_app=""
  fly_rela_app=""
  if has_setting fly.app; then
    fly_rela_app="$(setting fly.rela_app)"
    fly_local="$(setting fly.local)"
    # What move-to-fly and fetch-from-fly need, also before the clients use Fly.
    export ATLAS_FLY_APP="$(setting fly.app)" ATLAS_FLY_RELA_APP="$fly_rela_app" ATLAS_FLY_LOCAL="$fly_local"
    if fly_in_use; then fly_app="$ATLAS_FLY_APP"; export ATLAS_FLY_IN_USE=true; else export ATLAS_FLY_IN_USE=false; fi
  fi
  if [ -n "$fly_app" ]; then
    export ATLAS_TEST_ROOT="$fly_local"
  else
    rela_url="$(setting rela.url)"
    # The rela scripts take their port, data and binaries from these.
    export ATLAS_RELA_PORT="$(setting rela.port)" ATLAS_RELA_DATA="$(setting rela.data)" ATLAS_RELA_BIN="$(setting rela.bin)"
    export ATLAS_TEST_ROOT="$(dirname "$ATLAS_RELA_DATA")"
  fi
  # The background core's files, beside rela's.
  state="$ATLAS_TEST_ROOT"
  pidfile="$state/core.pid"
  headfile="$state/core.head"
  log="$state/core.log"
}

# Control of an environment on Fly answers over the tailnet, or this machine is told why it
# cannot reach it. Nothing is opened or started: the tailnet is this machine's own.
# A name that does not resolve fails at once; the wait is for an address that does not answer.
control_answers() { [ -n "$host" ] && nc -z -w 3 "$host" "$port" >/dev/null 2>&1; }
reach_control() {
  [ -n "$host" ] || { echo "$prog: missing full authenticated Control hostname (control.host_env in $settings); cutover is not configured" >&2; exit 1; }
  control_answers && return 0
  echo "$prog: $env's Control does not answer at $host:$port over the tailnet" >&2
  echo "$prog: not on the tailnet: tailscale status; on it: is $fly_app running? atlas-ops status --env $env" >&2
  exit 1
}

fly_cli() {
  command -v fly || command -v flyctl || {
    echo "$prog: $env runs on Fly; install flyctl (brew install flyctl), then: fly auth login" >&2
    exit 1
  }
}

head_now() { git -C "$root" rev-parse --short HEAD 2>/dev/null || echo unknown; }
listening() { nc -z 127.0.0.1 "$port" 2>/dev/null; }

# The repository's main clone (not a worktree of it). git answers an absolute path, so
# this works from any folder, also from / or from inside another repository.
main_clone() {
  local common
  common="$(git -C "$root" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || return 1
  (cd "$common/.." && pwd -P)
}
