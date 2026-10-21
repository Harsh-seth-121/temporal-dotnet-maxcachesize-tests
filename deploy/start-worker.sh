#!/bin/sh
# Wrapper so the worker's exit code survives the container going away.
#
# App Service restarts the container, not the process, so nothing inside the app can record why
# it died. Without this a memory kill and a platform recycle both just stop producing metrics.
#
#   137  SIGKILL  kernel cgroup OOM kill. No managed exception, no dump.
#   134  SIGABRT  unhandled OutOfMemoryException. CLR fatal path, dumpable.
#   143  SIGTERM  graceful: platform recycle, deploy, or app-setting change.
#
# /home is Azure Files and persists across container restarts; /tmp does not.
LOG=/home/LogFiles/exit-codes.log

# Record the start too, so a run that never exits is distinguishable from one whose exit line
# was lost. Also to stdout: /home is readable only over Kudu and SCM basic auth is off on this
# app, so the file alone is written-and-unreachable. stdout reaches the container log, which
# az webapp log tail serves over AAD.
line() { echo "$1" | tee -a "$LOG"; }

line "$(date -u +%Y-%m-%dT%H:%M:%SZ) WORKER-START arm=${ARM:-?} cache=${MAX_CACHED_WORKFLOWS:-?} pid=$$"

./CacheTest.Worker
code=$?

line "$(date -u +%Y-%m-%dT%H:%M:%SZ) WORKER-EXIT arm=${ARM:-?} cache=${MAX_CACHED_WORKFLOWS:-?} code=$code"
sync
exit $code
