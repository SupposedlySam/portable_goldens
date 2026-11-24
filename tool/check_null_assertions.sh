#!/usr/bin/env bash
# Fails if the package's own code uses the null assertion operator (`!`).
#
# A `!` is a runtime crash waiting for the one caller the author didn't
# picture. Use a pattern (`if (x case final y?)`, `switch` with `final y?`),
# a null check that promotes, or a non-nullable type instead. Tests may use
# it: a crash there is a failing test, which is what it should be.
#
# The match is textual: `name!`, `call()!`, `list[0]!` followed by `.`, `;`,
# `,`, `)`, `]`, a space or end of line. It skips `!=`, `is!` and comment
# lines, and says how many files it read, so a run that read none is not
# taken for a clean one.
set -euo pipefail
cd "$(dirname "$0")/.."

dirs=(lib bin)
files="$(find "${dirs[@]}" -name '*.dart' | wc -l | tr -d ' ')"
if [[ "$files" -eq 0 ]]; then
  echo "No Dart files under ${dirs[*]}: nothing was checked." >&2
  exit 1
fi

hits="$(grep -rnE '[])A-Za-z0-9_]!([].;,) []|$)' "${dirs[@]}" \
  | grep -v '!=' | grep -vE '\bis!' | grep -vE ':[0-9]+:\s*//' || true)"

if [[ -n "$hits" ]]; then
  echo "Null assertions (!) in package code:" >&2
  echo "$hits" >&2
  exit 1
fi
echo "No null assertions in $files files under ${dirs[*]}."
