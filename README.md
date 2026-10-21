# temporal-dotnet-maxcachesize-tests

Load-test harness measuring whether Temporal .NET SDK `MaxCachedWorkflows` at 10000 vs 8000 vs
6000 changes worker behavior under sustained load, and where the difference starts.

Four workers run side by side on one Temporal Cloud namespace, one task queue each, differing
only by cache size. The fourth arm (cache 100) is a positive control that must thrash: without
it, "cache size doesn't matter" is indistinguishable from "the metrics are broken".

Workers and load driver run on Azure App Service; Prometheus and Grafana on Azure Container
Apps. SDK version is pinned to **Temporalio 1.17.0**.

- `src/CacheTest.Core` config, workflows, activity, client and runtime factories, APS preflight
- `src/CacheTest.Worker` ASP.NET host running one worker, re-serving `/metrics` on the main port
- `src/CacheTest.Driver` load profiles (ramp / burst / smoke) and divergence detection
- `deploy/setup.sh` one-time onboarding: tools, logins, certificate, config
- `deploy/` provisioning, deployment, teardown
- `observability/` Prometheus and Grafana templates, rendered by setup
- `docs/RUNBOOK.md` **start here**

## Quick start

macOS or Linux. Everything else the harness needs, setup installs.

```bash
./deploy/setup.sh                   # tools, az login, Temporal cert, config. Provisions nothing
./deploy/00-provision.sh            # plans first: a quota refusal costs nothing
./deploy/10-deploy-workers.sh
./deploy/30-deploy-observability.sh # or: docker compose -f observability/docker-compose.yml up -d
PROFILE=smoke ./deploy/20-deploy-driver.sh
```

`setup.sh` is re-runnable and doubles as the config editor: it skips the steps already done,
`--reset N` redoes step N and everything after it, and `--check` verifies without writing.
It stops at the line where provisioning begins to bill.

Pick your own resource prefix when it asks. It becomes `<prefix>-worker.azurewebsites.net`,
a globally unique DNS name, and the Temporal task queue names.

See `docs/RUNBOOK.md` for the smoke gates, the validity guards, and teardown.

## Local dry run

The whole experiment runs on a laptop at 1/100 scale against `temporal server start-dev`, with
caches of 100/80/60/5 and 90 resident workflows per queue. That reproduces the real divergence:
the arm whose cache exceeds the population stays at zero evictions while the rest evict.
