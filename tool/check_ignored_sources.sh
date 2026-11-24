#!/usr/bin/env bash
# Fails if an ignore rule matches a file the package is made of.
#
# pub reads .gitignore (or .pubignore, which replaces it) and leaves out
# every file a rule matches, tracked or not. So a rule that matches a source
# file drops it from the published package while the suite still passes in
# the checkout that has it; and git never commits it, if it is new. It
# happened once: a bare `build/` matched `lib/src/build/`, and is now
# `/build/`.
#
# Asked of git for tracked and untracked files alike, against .gitignore and,
# where there is one, .pubignore.
set -euo pipefail
cd "$(dirname "$0")/.."

dirs=(lib bin test example tool)
rules=(--exclude-standard)
[[ -f .pubignore ]] && rules+=(--exclude-from=.pubignore)

ignored=""
for rule in "${rules[@]}"; do
  ignored+="$(git ls-files --cached --others --ignored "$rule" -- "${dirs[@]}" \
    | grep -vE '(^|/)\.dart_tool/|^example/build/' || true)"$'\n'
done
ignored="$(printf '%s' "$ignored" | sed '/^$/d' | sort -u)"
checked="$(git ls-files --cached --others --exclude-standard -- "${dirs[@]}" | wc -l | tr -d ' ')"

if [[ -n "$ignored" ]]; then
  echo "Source files an ignore rule matches (not published, maybe not committed):" >&2
  echo "$ignored" >&2
  exit 1
fi
echo "No ignored source files among $checked under ${dirs[*]} (rules: ${rules[*]})."
