# Runbook

## What this measures

Whether `MaxCachedWorkflows` at 10000 vs 8000 vs 6000 changes Temporal .NET worker behavior, and
where the difference starts.

Cache size is only observable once the number of workflow executions *resident on a worker*
exceeds the limit. Below that every setting behaves identically. So the harness deliberately
ramps resident count through the thresholds and watches where the arms separate.

Four arms, four task queues, one Cloud namespace. The fourth arm (`ctl`, cache 100) is a
positive control: it must thrash. If it does not, the instrumentation is broken and no other
arm's result means anything.

## Before you start

```bash
./deploy/setup.sh
```

That installs the toolchain, signs you into Azure, sets up a Temporal Cloud certificate and
writes both config files. It provisions nothing and starts nothing: it stops at the line where
`00-provision.sh` begins to bill. Re-run it any time; it skips the steps already done, and
`--reset N` redoes step N and everything after it. `--check` verifies without writing.

**Secrets live outside the repo**, in `~/.config/temporal-cache-test/` (mode 700). Override with
`SECRETS_DIR`. Gitignore stops you committing them but does nothing about a shell command or an
agent reading them, and a deny-list of Bash patterns is trivially evaded, so the only robust
answer is keeping them out of the workspace.

What ends up there:

| File | Holds | Written by |
|---|---|---|
| `harness.json` | subscription, resource group, location, prefix, SKUs, worker count, setup progress | setup |
| `testconfig.json` | namespace, address, arms, task queues, worker tuning, load profiles | setup |
| `run-state.json` | per-arm state: pending / launched / collected, and which worker app runs each | setup, then the run scripts |
| `client.pem`, `client.key` | the Temporal Cloud mTLS certificate | you, or setup's generator |
| `metrics_token`, `control_token` | bearer tokens for `/metrics` and the driver's `/release` | setup |
| `grafana_admin_password` | Container Apps Grafana only | `30-deploy-observability.sh` |

`run-state.json` is what `66-run-all.sh`, `64-run-remaining.sh`, `67-watch-all.sh` and
`68-collect-all.sh` drive the run from, and what `71-park.sh` reads to know a population is
still billing. It lives here rather than in `docs/` because it is per-run state, not results:
`docs/` is disposable output that a fresh clone does not have, and every script that writes
there creates its own directories.

Two files and not one because the deploy scripts stage `testconfig.json` into the publish
output so the app finds it in Azure. The experiment definition ships; the subscription id and
resource group stay behind in `harness.json`. Certificates and tokens never enter the zip
either; they reach Azure as app settings.

The resource prefix in `harness.json` becomes `<prefix>-worker.azurewebsites.net` and the task
queue names. Azure web app names are globally unique DNS records, so it has to be yours alone.
Setup refuses to continue while it is still the shared default.

Doing it by hand instead:

```bash
mkdir -p ~/.config/temporal-cache-test && chmod 700 ~/.config/temporal-cache-test
cp /path/to/client.pem /path/to/client.key ~/.config/temporal-cache-test/
cp config/testconfig.sample.json ~/.config/temporal-cache-test/testconfig.json
cp config/harness.sample.json  ~/.config/temporal-cache-test/harness.json
chmod 600 ~/.config/temporal-cache-test/*
# then fill in the namespace, address and prefix, and render the observability templates
```

## Run order

```bash
./deploy/00-provision.sh            # plans first: a quota refusal costs nothing
./deploy/10-deploy-workers.sh       # one binary, four arms, differing by one app setting
./deploy/30-deploy-observability.sh # Prometheus (internal) + Grafana (external)
PROFILE=smoke ./deploy/20-deploy-driver.sh
```

Then the smoke gates below. Only once they pass:

```bash
PROFILE=ramp ./deploy/20-deploy-driver.sh
```

## Smoke test gates

The smoke profile puts 400 resident workflows on each queue: far above the control arm's 100,
far below 6000. The expected result is therefore sharp.

1. **Plumbing.** All four `/` endpoints respond with the right arm and cache size. Prometheus
   shows four healthy targets. Grafana renders with `arm` populated with all four values.
2. **Eviction is detectable.** `ctl` shows non-zero
   `temporal_sticky_cache_total_forced_eviction` and a populated
   `temporal_workflow_task_replay_latency`. The other three show **exactly zero** evictions and
   `temporal_sticky_cache_size` sitting at 400.
3. **Restart detection.** `az webapp restart -g "$RG" -n "${PREFIX}-worker"` (both from `deploy/lib-config.sh`),
   then confirm that arm's `temporal_sticky_cache_size` drops to zero and climbs back, and that
   `changes(process_start_time_seconds[1h])` marks the window.

If gate 2 fails on `ctl`, stop. Everything downstream is meaningless.

## Guards: when a result is not trustworthy

Check all of these before reporting any number. Each is a property of the apparatus, not a
finding. If one fired, repeat the run.

```promql
# Memory-bound, not config-bound: evicting while below the configured cap
temporal_sticky_cache_size{arm="10k"} < 10000
  and on() rate(temporal_sticky_cache_total_forced_eviction{arm="10k"}[5m]) > 0

# Slot starvation, not cache behavior
min by (arm) (temporal_worker_task_slots_available{worker_type="WorkflowWorker"}) == 0

# A platform restart wiped the cache
changes(process_start_time_seconds[1h]) > 0

# Uneven offered load across arms makes the comparison meaningless
sum by (arm) (rate(temporal_workflow_task_execution_latency_count[5m]))
```

Also watch `temporal_request_failure`: `RESOURCE_EXHAUSTED` from the namespace APS ceiling
presents as latency and is indistinguishable from cache slowness by eye.

## The headline queries

**Primary signal: the cache hit ratio.** This is the cleanest discriminator and was verified
against real Azure workers: the arms whose cache exceeds the population sit at essentially 100%,
the thrashing control sits around 5%.

```promql
sum by (arm) (rate(temporal_sticky_cache_hit[5m]))
  /
( sum by (arm) (rate(temporal_sticky_cache_hit[5m]))
+ sum by (arm) (rate(temporal_sticky_cache_miss[5m])) )
```

**Eviction rate**, the thing cache size directly controls:

```promql
sum by (arm) (rate(temporal_sticky_cache_total_forced_eviction[5m]))
```

**Replay cost**, the consequence you actually care about:

```promql
histogram_quantile(0.99,
  sum by (arm, le) (rate(temporal_workflow_task_replay_latency_bucket[5m])))
```

Milliseconds, not seconds: `UseSecondsForDuration` is left at its default of false, which is
also what the upstream dashboard expects. For the same reason counters carry **no** `_total`
suffix, so ignore the `_total`-suffixed PromQL in the public Temporal docs.

**Do not use `temporal_workflow_task_replay_latency_count` as a replay counter.** Measured on
real workers, an arm with **zero** cache misses still reported 739 observations on that
histogram, so it counts more than cache-miss replays. Use `temporal_sticky_cache_miss` to count
replays and treat the replay-latency histogram as a measure of how expensive they are, not how
many there were.

## Known confound: arm vs instance

Cache size is perfectly confounded with App Service instance and task queue. A slow VM would
look exactly like a cache effect.

If the first run shows a difference worth reporting, confirm it by **rotating the arms**: swap
`MAX_CACHED_WORKFLOWS` between the `10k` and `6k` apps, redeploy, and re-run. The effect should
follow the cache size, not the app. If it follows the app, you measured the VM.

## Ending a run

Resident workflows keep firing heartbeat timers, and every timer is a billable Action. Ending
the run means releasing them, not just stopping the driver:

```bash
source deploy/lib-config.sh
curl -X POST -H "Authorization: Bearer $(cat "$(secret control_token)")" \
  "$DRIVER_URL/release"
```

There is also a dead-man switch: resident workflows carry an `ExecutionTimeout`
(`RESIDENT_HORIZON_HOURS`, default 12) so a dead driver cannot burn Actions indefinitely.

## Teardown

```bash
./deploy/99-teardown.sh
```

App Service plans bill for allocated compute even when apps are stopped, so stopping is not
teardown. Only deletion stops the meter.

Then **revoke the client certificate**. It was base64'd into App Service app settings and may
persist in deployment history and activity logs; deleting the apps does not revoke it.

## Gotchas worth knowing

- **Workflow arguments are case-sensitive PascalCase.** camelCase binds every field to zero, and
  a `ResidentWorkflow` with `MaxCycles=0` completes instantly holding no cache slot. That is
  invisible in aggregate metrics, so the workflow now throws on non-positive args.
- **Terminated workflows linger in the worker cache.** Server-side termination does not evict a
  worker's cache entry, so cache state carries across runs. Restart the worker apps between
  runs, or the previous population silently occupies slots.
- **Changing any app setting restarts the app**, which empties the cache. Set everything before
  the measurement window opens, never during.
- **Heartbeats are jittered ±20%** on purpose. Without it a cohort wakes in lockstep and LRU
  eviction becomes a cliff at cap+1 rather than the gradient the experiment wants to see.
