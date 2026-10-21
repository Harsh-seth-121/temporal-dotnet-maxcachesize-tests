# Rerun the c6000 pair

> Written 2026-10-21 so a later session can run this without the conversation it came from.
> Branch `phase-2`. Nothing is running in Azure: every app is Stopped, the namespace is drained.

## Why this run exists

Phase 2 ran six arms at 520 KB retained, all six at once, one worker app on its own App Service
plan each. Five died with exit 137. One did not:

| Arm | Cache | GC budget | Peak RSS | Evictions | Outcome |
|---|---|---|---|---|---|
| c10000-nolimit | 10,000 | 4.91 GiB | 6.36 GiB | 1 | died 15:12Z |
| c8000-nolimit | 8,000 | 4.91 GiB | 6.39 GiB | 70,853 | died 15:17Z |
| c6000 | 6,000 | 6.50 GiB | 6.42 GiB | 74,637 | died 15:20Z |
| c8000 | 8,000 | 6.50 GiB | 6.42 GiB | 48,542 | died 15:31Z |
| c10000 | 10,000 | 6.50 GiB | 6.40 GiB | 8 | died 15:51Z |
| **c6000-nolimit** | 6,000 | 4.91 GiB | 6.37 GiB | 137,289 | **survived the hold** |

`c6000` and `c6000-nolimit` differ only in whether `DOTNET_GCHeapHardLimit` is set. One died at
15:20Z and the other finished. That is the single result in phase 2 that a reader will lean on,
and it rests on one run of each. Peak RSS across all six arms spans 6.36 to 6.42 GiB, a 60 MB
band, so the two arms were about equally close to the edge and the difference in outcome could
be a coin flip.

**This rerun answers one question: does c6000-nolimit survive again?** If it does, "the hard
limit kills the 6,000 arm" is worth writing down. If it dies, the phase 2 survivor was noise and
the report should say all six configurations die at roughly 6.4 GiB.

## Run it

Both arms at once. They already sit on separate worker apps on separate plans, so running them
together costs nothing in isolation and halves the wall clock.

```bash
ARMS="c6000,c6000-nolimit" ./deploy/66-run-all.sh
```

That script does the whole thing: drains the namespace, configures worker-3 for `c6000` with
`DOTNET_GCHeapHardLimit=0x1A0000000` and worker-6 for `c6000-nolimit` with the setting deleted,
waits for both to serve an empty cache, starts the driver with `ARMS` set to just these two, and
checks that the driver reports exactly the queues the workers were configured for before it lets
the run proceed. It returns in a few minutes and the laptop is not needed afterwards.

Roughly 100 minutes: about 13 minutes of ramp, a 75-minute hold, then the driver's own drain.

### Before you start it

1. **Collect the previous run's data out of the way, or accept that it moves.**
   `62-collect-arm.sh` renames an existing arm directory to `arm-<name>-prev-<stamp>` and the
   report assembler skips `-prev-` directories. So the rerun replaces these two arms in
   `report-data.json` rather than sitting beside them. If you want both runs in one comparison,
   add two new arms (`c6000-run2`, `c6000-nolimit-run2`) to `docs/PHASE2-STATE.json` and to
   `~/.config/temporal-cache-test/testconfig.json` with their own task queues, and name those in
   `ARMS` instead.
2. **The state file still says these two are `collected`.** `66-run-all.sh` does not care, but
   `lib-state-summary.py` will read oddly until the run finishes and marks them again.

### Collect it

```bash
WORKER_APP=${PREFIX}-worker-3 ./deploy/62-collect-arm.sh c6000
WORKER_APP=${PREFIX}-worker-6 ./deploy/62-collect-arm.sh c6000-nolimit
./deploy/57-report-data.py --summary
```

`68-collect-all.sh` also works and collects every launched arm, which is more than you need here.

## What to check in the result

- **Instance file count.** One `arm-<name>-<epoch>.tsv` per process. Two files means the worker
  was killed and restarted, which is the signature of a death even when the exit log is missing.
  `c6000-nolimit` had exactly one file in the first run; that is how its survival was confirmed.
- **Exit code.** 137 is a kernel OOM kill with no dump. 134 is a managed `OutOfMemoryException`.
  143 is a graceful stop.
- **Peak RSS.** The first run put every arm between 6.36 and 6.42 GiB. A rerun landing outside
  that band is more interesting than the survive/die outcome itself.
- **`dotnet_gc_total_available_bytes`.** 6.50 GiB on the limit arm, 4.91 GiB on the nolimit arm.
  If the nolimit arm reports something else, the GC sized differently and the comparison changed
  underneath you.

## Things that bit this project already

- **The driver's arm list is baked into its zip at deploy time.** A driver deployed before the
  arms were written ramped 3,074 workflows onto a queue no worker polled, with every worker
  idle and the run looking healthy from outside. Two defences now exist: the `ARMS` environment
  variable selects a subset without touching any config file, and `66-run-all.sh` compares the
  queues the driver reports against the ones it configured and aborts plus drains on a mismatch.
- **A 58 MB zip uploaded from this laptop gets Kudu 400 BadRequest on the newer worker apps**,
  while a 174-byte zip to the same app succeeds. `11-deploy-fleet.sh` stages the zip in blob
  storage once and each app pulls it with `--src-url`. Use that path, not `az webapp deploy
  --src-path`, for anything large. `az storage blob upload` itself gets connection-reset on this
  network sometimes; it retries three times.
- **Arm names repeat across runs and the samples live on the worker.** Worker 1 still held
  `arm-c10000-*.tsv` from an earlier solo run, and collecting would have concatenated a finished,
  already-reported run onto the front of a new one. `62-collect-arm.sh` now keeps only instance
  files whose process-start epoch is at or after the arm's `launched_at`, so this is handled, but
  it is the reason a collection that returns suspiciously long wall times should be checked.
- **A live snapshot is not evidence of survival.** Five arms showed full caches and healthy RSS
  hours after they had been killed, because the platform restarted them and they refilled. Only
  the instance file count and the exit log tell you what happened.
- **`dotnet_gc_memory_load_bytes` is machine memory load, not heap against the GC budget.** The
  nolimit arms read 6.49 GiB load against a 4.91 GiB budget. Do not compare those two numbers.

## State of the world when this was written

- Every app in the resource group carrying the configured prefix is **Stopped**, namespace drained
  to 0 running.
- Six worker apps exist, `-worker` and `-worker-2` through `-worker-6`, one P1v3 plan each.
  The five extra plans bill about $3.70/day each whether or not the app runs. The decision on
  record is to leave them stopped, not delete them.
- Phase 2 data is in `docs/results/data/phase2/arm-*`, backfilled into local Prometheus and
  visible in Grafana at `http://127.0.0.1:3000/d/temporal-core-sdk/02415ea`.
- `docs/PHASE2-STATE.json` is the authoritative record and outranks any summary, including this
  file, where they disagree.
- `docs/results/oom-report-phase2.html` is **not written yet**.
