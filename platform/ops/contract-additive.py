"""Is a change of Control's contract additive? (D-0105, D-0103)

    python3 platform/ops/contract-additive.py <published blocks.json> <this blocks.json>

Compares the contract this tree generates (platform/atlas_control/backend/targets/json/
blocks.json) with the last published one (prod's, on master). Clients are tolerant readers:
a new block, model, kind of markup or field never breaks one. What does: a block, model,
kind of markup or field that is gone, or a field of another type, unless the published
version marked it deprecated first (`deprecated` in the contract; AtlasBFF.Schema). Each
such change is a GitHub warning annotation and a line in the job summary; the exit status
is 0 whatever it finds: it warns in the PR, it never blocks.
"""
import json
import os
import sys

KINDS = (("blocks", "block"), ("models", "model"), ("markup", "kind of markup"))


def breaking(published, current):
    """The changes from `published` to `current` that are not additive, in plain words."""
    found = []
    for key, what in KINDS:
        now = {entry["name"]: entry for entry in current.get(key, [])}
        for entry in published.get(key, []):
            name = entry["name"]
            if entry.get("deprecated"):
                continue
            if name not in now:
                found.append(f"{what} {name} is removed without being deprecated first")
                continue
            fields = {field["name"]: field for field in now[name].get("fields", [])}
            for field in entry.get("fields", []):
                if field.get("deprecated"):
                    continue
                other = fields.get(field["name"])
                if other is None:
                    found.append(
                        f"{what} {name}: field {field['name']} is removed without being deprecated first")
                elif other["type"] != field["type"]:
                    found.append(
                        f"{what} {name}: field {field['name']} is now {other['type']}, was "
                        f"{field['type']}, without being deprecated first")
    return found


def report(published, current, out=sys.stdout):
    found = breaking(published, current)
    summary = os.environ.get("GITHUB_STEP_SUMMARY")
    lines = [f"Contract {published.get('version')} → {current.get('version')}: "
             + ("not additive" if found else "additive")]
    lines += [f"- {change}" for change in found]
    for change in found:
        print(f"::warning title=Contract change is not additive (D-0105)::{change}", file=out)
    print("\n".join(lines), file=out)
    if summary:
        with open(summary, "a") as file:
            file.write("\n".join(lines) + "\n")
    return found


if __name__ == "__main__":
    if len(sys.argv) != 3:
        print(__doc__, file=sys.stderr)
        sys.exit(2)
    with open(sys.argv[1]) as a, open(sys.argv[2]) as b:
        report(json.load(a), json.load(b))
