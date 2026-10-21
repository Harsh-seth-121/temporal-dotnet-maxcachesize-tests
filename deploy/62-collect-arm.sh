#!/usr/bin/env bash
# Collect one arm from the worker itself. No dependency on local Prometheus having been awake
# while the arm ran: the worker records itself, so this is a download, not a vigil.
#
#   ./deploy/62-collect-arm.sh <arm>            e.g. c10000, c8000-nolimit
#
# Downloads the worker's log share (sampler TSV plus exit-code log), converts the TSV into the
# per-metric JSON 57-report-data.py reads, and marks the arm collected in
# the run-state file.
set -euo pipefail

ARM="${1:?usage: 62-collect-arm.sh <arm>   e.g. c10000 or c8000-nolimit}"
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib-config.sh" || exit 1
# Each arm runs on its own worker app, so the app cannot be assumed. 68-collect-all.sh passes
# WORKER_APP; a bare run defaults to worker 1.
WORKER="$WORKER_APP"
# Own directory. Phase 2 reuses phase 1's arm names (c10000, c8000, c6000), so writing to
# data/arm-<arm> once overwrote phase 1's series and the summary reported a hybrid: today's
# peak cached beside phase 1's exit code.
OUT="$ROOT/docs/results/data/phase2/arm-${ARM}"

say() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }

# An arm can be run more than once. Collecting into the same directory replaces the earlier
# result, which is how phase 1's series were lost. Move the previous run aside first.
if [ -d "$OUT" ] && ls "$OUT"/arm-*.tsv >/dev/null 2>&1; then
  _prev="$OUT-prev-$(date +%Y%m%d-%H%M)"
  mv "$OUT" "$_prev"
  echo "  previous run of $ARM moved to $(basename "$_prev")"
fi
mkdir -p "$OUT"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

say "Downloading the worker log share"
az webapp log download -g "$RG" -n "$WORKER" --log-file "$TMP/logs.zip" --output none
cp "$TMP/logs.zip" "$OUT/logs.zip"
unzip -oq "$TMP/logs.zip" -d "$TMP/logs"

say "Locating this arm's samples"
# One file per process instance, arm-<arm>-<process start>.tsv. More than one means the worker
# restarted mid-arm, which here usually means killed. Take them all; the assembler windows by
# process_start_time_seconds.
#
# This run's files only. Arm names repeat across runs, so a worker that served c10000 before
# still holds those older files, and concatenating splices a finished run onto the front of
# this one. The suffix is the process start epoch. 300s of slack covers the gap between the
# restart and the state file being written.
_since=$("$ROOT/deploy/lib-state-set.py" --print-launched-epoch "$ARM" 2>/dev/null || echo 0)
mapfile -t tsvs < <(find "$TMP/logs" -name "arm-${ARM}-*.tsv" | sort | while read -r f; do
  _stamp="${f##*-}"; _stamp="${_stamp%.tsv}"
  case "$_stamp" in (*[!0-9]*|'') echo "$f"; continue;; esac
  [ "$_stamp" -ge "$(( _since - 300 ))" ] && echo "$f"
done)
if [ "${_since:-0}" -gt 0 ]; then
  echo "  keeping instances started at or after $(( _since - 300 )) (this run only)"
fi
if [ "${#tsvs[@]}" -eq 0 ]; then
  echo "FATAL: no sampler output for arm ${ARM} in the log share." >&2
  echo "       Either the worker was not running this arm, or the build without MetricsSampler" >&2
  echo "       is still deployed. Check 'Sampling every 30s into' in the container log." >&2
  exit 1
fi
echo "  ${#tsvs[@]} instance file(s):"
for f in "${tsvs[@]}"; do printf '    %s  %s rows\n' "$(basename "$f")" "$(grep -cv '^#' "$f" || true)"; done
# Raw samples beside the converted series: primary record, small, and
# 63-backfill-prometheus.sh reads them from here rather than downloading the share again.
cp "${tsvs[@]}" "$OUT/"
cat "${tsvs[@]}" > "$TMP/all.tsv"

say "Converting to the per-metric JSON the assembler reads"
python3 "$ROOT/deploy/lib-tsv-to-series.py" "$TMP/all.tsv" "$OUT"

say "Exit code"
# 137 kernel OOM kill, 134 managed OutOfMemoryException, 143 graceful stop. Anything else is a
# platform event; read it before believing the arm.
if find "$TMP/logs" -name 'exit-codes.log' -print -quit | grep -q .; then
  find "$TMP/logs" -name 'exit-codes.log' -exec cat {} + > "$OUT/exit-codes.log"
  tail -3 "$OUT/exit-codes.log" | sed 's/^/  /'
else
  echo "  no exit-codes.log in the share; the worker may still be running"
fi

say "Recording the outcome"
outcome=$(awk '/WORKER-EXIT/{last=$0} END{print last}' "$OUT/exit-codes.log" 2>/dev/null || true)
"$ROOT/deploy/lib-state-set.py" "$ARM" collected "${outcome:-no exit recorded}" || true

say "Backfilling Prometheus so Grafana covers the whole arm"
# Without backfill the dashboards show only the minutes this laptop was awake, which for an
# unattended arm is a few of them. The samples are already local, so this costs no download.
"$ROOT/deploy/63-backfill-prometheus.sh" "$ARM" || \
  echo "  backfill failed; data is safe in the TSV, re-run ./deploy/63-backfill-prometheus.sh $ARM" >&2

say "Summary"
"$ROOT/deploy/57-report-data.py" --summary
