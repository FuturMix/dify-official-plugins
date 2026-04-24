#!/usr/bin/env bash
set -euo pipefail

if [ -z "${GITHUB_OUTPUT:-}" ]; then
  echo "GITHUB_OUTPUT is required" >&2
  exit 1
fi

if [ -z "${CHANGED_FILES_FILE:-}" ] && { [ -z "${BASE_SHA:-}" ] || [ -z "${HEAD_SHA:-}" ]; }; then
  echo "Either CHANGED_FILES_FILE or both BASE_SHA and HEAD_SHA are required" >&2
  exit 1
fi

is_zero_sha() {
  [[ "$1" =~ ^0+$ ]]
}

json_array() {
  if command -v jq >/dev/null 2>&1; then
    jq -R . | jq -s -c .
  else
    python3 -c 'import json, sys; print(json.dumps([line.rstrip("\n") for line in sys.stdin]))'
  fi
}

changed_files=()
declare -A manifest_statuses=()

if [ -n "${CHANGED_FILES_FILE:-}" ]; then
  while IFS=$'\t' read -r status path; do
    [ -n "$path" ] || continue
    changed_files+=("$path")

    if [[ "$path" == */manifest.yaml ]]; then
      plugin_path=${path%/manifest.yaml}
      manifest_statuses["$plugin_path"]=$status
    fi
  done < "$CHANGED_FILES_FILE"

  if [ -n "${EXPECTED_CHANGED_FILES:-}" ] && [ "${#changed_files[@]}" -ne "$EXPECTED_CHANGED_FILES" ]; then
    echo "Expected $EXPECTED_CHANGED_FILES changed files, got ${#changed_files[@]}" >&2
    exit 1
  fi
elif is_zero_sha "$BASE_SHA"; then
  if git rev-parse --verify --quiet "${HEAD_SHA}^" >/dev/null; then
    mapfile -t changed_files < <(git diff --name-only "${HEAD_SHA}^" "$HEAD_SHA")
  else
    mapfile -t changed_files < <(git ls-tree -r --name-only "$HEAD_SHA")
  fi
else
  diff_base_sha=$BASE_SHA
  if [ "${USE_MERGE_BASE:-false}" = "true" ]; then
    diff_base_sha=$(git merge-base "$BASE_SHA" "$HEAD_SHA")
  fi

  echo "Diff base: $diff_base_sha"
  echo "Diff head: $HEAD_SHA"
  mapfile -t changed_files < <(git diff --name-only "$diff_base_sha" "$HEAD_SHA")
fi

declare -A candidate_plugins=()
for changed_file in "${changed_files[@]}"; do
  IFS=/ read -r scope plugin_name _ <<< "$changed_file"
  case "$scope" in
    agent-strategies|datasources|extensions|models|tools|triggers)
      if [ -n "${plugin_name:-}" ]; then
        candidate_plugins["$scope/$plugin_name"]=1
      fi
      ;;
  esac
done

valid_plugins=()
candidate_list=()
if [ ${#candidate_plugins[@]} -gt 0 ]; then
  mapfile -t candidate_list < <(printf '%s\n' "${!candidate_plugins[@]}" | sort)
fi

for plugin_path in "${candidate_list[@]}"; do
  if [ "${manifest_statuses[$plugin_path]:-}" = "removed" ]; then
    continue
  fi

  if [ -f "$plugin_path/manifest.yaml" ] || [ -n "${manifest_statuses[$plugin_path]:-}" ]; then
    valid_plugins+=("$plugin_path")
  fi
done

if [ ${#valid_plugins[@]} -eq 0 ]; then
  {
    echo "has_changes=false"
    echo "plugins=[]"
  } >> "$GITHUB_OUTPUT"
else
  json=$(printf '%s\n' "${valid_plugins[@]}" | json_array)
  {
    echo "has_changes=true"
    echo "plugins=$json"
  } >> "$GITHUB_OUTPUT"
  echo "Detected plugins: $json"
fi
