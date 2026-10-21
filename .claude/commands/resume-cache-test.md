---
description: Resume the MaxCachedWorkflows OOM experiment where it left off
---

Resume the cache-sizing experiment in this repo. Work on the `phase-2` branch.

Do these in order and report the result of each before moving on.

1. **Read `docs/PHASE2-STATE.json` first.** It is the authoritative record of what is done,
   what is in flight and what comes next. It outranks scrollback, any summary, and anything you
   remember. Its `next` field says what to do; its `blocking` field says what stands in the way.

2. **Read `docs/CONTEXT.md`.** One page: the question, the hardware, the phase 1 results, the
   five findings, the measurement gotchas that each cost a run, and the file map. Read it
   instead of the `FINDING-*.md` files, the data directory and `report-data.json`. Numbers come
   from `./deploy/57-report-data.py --summary`, never hand-copied.

3. **Check for an arm left in flight.** Any arm with `"state": "launched"` in the state file
   either finished unobserved or was interrupted. Either way, run `./deploy/71-park.sh` before
   anything else: it stops the driver, drains the namespace in a verified loop, saves the
   partial series into `arm-<x>-aborted/`, stops the worker and marks the arm aborted. A
   population left heartbeating costs roughly $25/hour.

4. **Bring compute back only when there is work for it:** `./deploy/70-resume.sh` restarts the
   local Prometheus and Grafana containers, starts the Azure worker and driver, waits for the
   worker to serve, and runs `./deploy/40-preflight.sh`. It deliberately stops short of
   starting an arm.

5. **Do the work named in `next`.** As of the last update that is chunk 2 of the plan, making
   an arm survive a closed laptop: worker self-sampling to `/home/LogFiles`, driver self-drain
   after `holdMinutes`, `60-run-arm.sh` reduced to launch-and-detach, and a new
   `62-collect-arm.sh`. **Do not start an arm before that lands.** Until it does, an
   unattended arm loses its series to the local scrape gap and burns Actions the whole time.

6. **Rewrite the state file whenever reality changes**, not at the end. Launching an arm,
   collecting one, parking: each writes the file first. Commit and push to `phase-2` before
   every pause, so a cold laptop loses nothing.

7. **Keep the status board live** at `~/.claude/status-table/sessions/<session-id>.json`,
   re-rendered with `python3 ~/.claude/status-table/render.py <session-id>`.

Cost notes: stopped App Service apps still bill their plan, roughly **$3.70/day**.
`./deploy/99-teardown.sh` is the only thing that stops it, is **not reversible**, and a
reprovision costs about 20 minutes. Ask before running it.
