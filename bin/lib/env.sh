# Shared by bin/atlas and bin/atlas-dev, sourced once "$root" (the checkout) is known.

# Keep ordinary invocations on the isolated project dependency without shell setup.
if [ -z "${ATLAS_CONFIG_PYTHON:-}" ] && [ -x "$root/.venv-config/bin/python" ]; then
  export ATLAS_CONFIG_PYTHON="$root/.venv-config/bin/python"
fi
