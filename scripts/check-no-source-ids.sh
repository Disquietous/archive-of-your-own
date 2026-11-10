#!/bin/zsh
# Guardrail (design/source-controls-plan.md): no Swift file compares a
# source id. The UI asks the core what a row offers — WorkControls,
# UserControls, TagControls, SourceCapabilities — and never which source it
# is from. Exemptions are pinned below, one per line as file:fragment, and
# each must say why in the code.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

allowed=(
  # The archive's own search form, until the AO3Source search move retires it.
  'packages/AO3Kit/Sources/State/SearchModel.swift:static let archiveFormSource = "ao3"'
  # The per-source search model the source-search plan owns.
  'apps/macos/Search/ScribbleHubSearchModel.swift:static let sourceID = "scribblehub"'
)

pattern='(==|!=|\?\?|\bcase)[[:space:]]*"(ao3|scribblehub|mockrated)"|"(ao3|scribblehub|mockrated)"[[:space:]]*(==|!=)|\bisAO3\b|\b(ao3|scribblehub|mockrated)Only\b|source(ID|Id|_id|Tab)?[[:space:]]*(==|!=)[[:space:]]*"'
hits=$(grep -rnE "$pattern" apps packages/AO3Kit/Sources --include='*.swift' \
       | grep -v '/Generated/' || true)
# Any remaining bare source-id literal is also a comparison in waiting.
literals=$(grep -rnE '"(ao3|scribblehub|mockrated)"' apps packages/AO3Kit/Sources --include='*.swift' \
       | grep -v '/Generated/' || true)
# Comment lines may name a source as an example.
all=$(printf '%s\n%s\n' "$hits" "$literals" | sort -u | sed '/^$/d' \
      | grep -vE '^[^:]+:[0-9]+:[[:space:]]*//' || true)

bad=()
while IFS= read -r line; do
  [[ -z "$line" ]] && continue
  file="${line%%:*}"
  rest="${line#*:}"; rest="${rest#*:}"
  ok=0
  for a in "${allowed[@]}"; do
    afile="${a%%:*}"; afrag="${a#*:}"
    if [[ "$file" == "$afile" && "$rest" == *"$afrag"* ]]; then ok=1; break; fi
  done
  (( ok )) || bad+=("$line")
done <<< "$all"

if (( ${#bad[@]} )); then
  echo "error: Swift compares a source id — ask the row's controls or capabilities instead:" >&2
  printf '  %s\n' "${bad[@]}" >&2
  exit 1
fi
echo "==> No source-id comparisons in Swift."
