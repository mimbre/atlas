# The update step bin/atlas and bin/atlas-ops share: the main clone follows develop, so a
# command takes the newest build before running. Sourced after env.sh; the caller sets
# root, prog, updated (non-empty in the run restarted after an update) and defines
# restart_updated, which starts the caller again on the pulled scripts.
#
# When this build cannot be updated, update_failed says why and update_once until when.
# update_quiet set: a failed pull says nothing of its own (the caller says what follows).
update_failed=""
update_once=""
update_build() {
  [ -z "$updated" ] || return 0
  if [ -n "${ATLAS_NO_UPDATE:-}" ]; then
    update_failed="ATLAS_NO_UPDATE is set"
    update_once="it is not set"
    return 0
  fi
  local main branch before out
  main="$(main_clone)" || main=""
  if [ "$main" != "$root" ]; then
    update_failed="$root is not the main clone, which is the build $prog updates"
    update_once="you start it from the main clone${main:+ ($main/bin/$prog)}"
    return 0
  fi
  branch="$(git -C "$root" branch --show-current)"
  if [ "$branch" != develop ]; then
    update_failed="the main clone $root is on ${branch:-a detached HEAD}, not develop"
    update_once="it is on develop again (git -C $root switch develop)"
    return 0
  fi
  before="$(git -C "$root" rev-parse HEAD)"
  if ! out="$(git -C "$root" pull --ff-only -q 2>&1)"; then
    [ -z "$out" ] || printf '%s\n' "$out" >&2
    [ -n "${update_quiet:-}" ] || echo "$prog: could not update develop; trying the build as it is" >&2
    update_failed="the pull of develop failed${out:+ ($(printf '%s\n' "$out" | grep -v '^[[:space:]]*$' | tail -1))}"
    update_once="git -C $root pull --ff-only works"
  fi
  # What a rename or a move on develop left behind: folders with only build output.
  "$root/bin/clean-build" "$root" --moved >&2
  # This run already sourced the old scripts; a renamed or moved path would break them
  # against the new tree. Start again on the pulled scripts, without another update.
  if [ "$(git -C "$root" rev-parse HEAD)" != "$before" ]; then
    restart_updated
  fi
}
