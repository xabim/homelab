#!/usr/bin/env bash
set -euo pipefail

BASE_DIR="/srv/data/media/video"
DONE_FLAG=".immich-go.done"
SERVER="https://immich.home"
FORCE="${FORCE:-0}"

cd "$BASE_DIR"

for year in */; do
  year="${year%/}"
  [ -d "$year" ] || continue

  flag_path="${BASE_DIR}/${year}/${DONE_FLAG}"

  if [[ "$FORCE" != "1" && -f "$flag_path" ]]; then
    echo "SKIP: ${year} (flag ${DONE_FLAG} exists)"
    continue
  fi

  echo "RUN:  ${year}"

  log_file="${BASE_DIR}/${year}/immich-go-upload.log"
  tmp_file="$(mktemp)"

  set +e
  immich-go upload from-folder \
    --api-key "$IMMICH_TOKEN" \
    --folder-as-album PATH \
    --recursive \
    --concurrent-tasks 1 \
    --no-ui \
    --server "$SERVER" \
    "$year" |& tee "$tmp_file" | tee "$log_file"
  exit_code=${PIPESTATUS[0]}
  set -e

  # Parser robusto: encuentra la última línea "Errors:" y extrae el primer número
  errors="$(
    grep -E '^[[:space:]]*Errors:[[:space:]]*' "$tmp_file" \
      | tail -n 1 \
      | sed -E 's/.*Errors:[[:space:]]*([0-9]+).*/\1/'
  )"

  if [[ -z "${errors}" || ! "${errors}" =~ ^[0-9]+$ ]]; then
    echo "WARN: Could not parse Errors count for ${year}. Not marking as done."
    echo "      (exit_code=${exit_code})"
    rm -f "$tmp_file"
    continue
  fi

  if [[ "$errors" == "0" ]]; then
    echo "DONE: ${year} (Errors=0) -> writing flag ${DONE_FLAG}"
    {
      echo "date: $(date -Is)"
      echo "server: ${SERVER}"
      echo "exit_code: ${exit_code}"
      echo "errors: ${errors}"
      echo "log: ${log_file}"
    } > "$flag_path"
  else
    echo "RETRY: ${year} (Errors=${errors}) -> not marking done"
    echo "       (exit_code=${exit_code})"
  fi

  rm -f "$tmp_file"
done
