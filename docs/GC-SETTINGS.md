# GC memory settings for .NET workers on Azure App Service

This report covers Azure App Service code deployments on Linux and Windows. The measurements
come from one Linux P1v3 worker with 2 vCPU and 8 GiB of memory. We did not run the same test on
Windows, so the Windows section separates documented behavior from items that still need direct
measurement.

## Summary

The test fixed these settings across its cache-size runs:

| Setting | Test value | Purpose |
|---|---:|---|
| `DOTNET_gcServer` | `1` | Uses Server GC. With DATAS disabled, Server GC can create up to one heap per logical core. |
| `DOTNET_GCDynamicAdaptationMode` | `0` | Disables Dynamic Adaptation To Application Sizes, or DATAS, so DATAS does not respond differently to each cache size. |
| `DOTNET_GCHeapHardLimit` | `0x1A0000000` | Sets the GC heap and bookkeeping limit to 6.50 GiB. This was a test setting, not a production recommendation. |

The 6.50 GiB hard limit did not prevent process termination. Two runs ended with exit code 137
while the GC still reported memory below its configured limit. A GC heap limit applies to the
managed heap and GC bookkeeping. The process also needs memory for the runtime, native libraries,
thread stacks, JIT-compiled code, and other allocations.

For production, keep the default DATAS behavior unless testing shows a reason to disable it. If
the runtime does not see the application's real memory budget, set a GC heap limit that leaves
measured headroom for the rest of the process. Validate that limit under representative load.

## What the Linux test verified

Azure App Service passes app settings to the process as environment variables. The .NET runtime
reads these GC settings during process startup, so changing them requires a restart.

With `DOTNET_GCHeapHardLimit=0x1A0000000`, the worker reported:

| Runtime metric | Measured value |
|---|---:|
| `dotnet_gc_total_available_bytes` | 6,979,321,856 bytes, exactly 6.50 GiB |
| `dotnet_gc_high_memory_threshold_bytes` | 6,332,545,843 bytes, about 5.90 GiB |

The high-memory threshold was about 90.7% of the reported GC budget in this run. .NET documents
90% as the usual default for machines below 80 GB, but applications should use the value reported
by the runtime instead of calculating it.

The worker did not find a finite cgroup memory limit in its Linux container, so it omitted
`container_memory_limit_bytes`. This verifies the behavior of this P1v3 Linux code deployment.
It does not establish that every App Service Linux configuration behaves the same way.

The no-limit arms have not run yet. Until that comparison finishes, this report does not claim
what `GC.GetGCMemoryInfo().TotalAvailableMemoryBytes` will report on this worker when
`DOTNET_GCHeapHardLimit` is absent.

## Why DATAS was disabled for the test

[DATAS is enabled by default in .NET 9 and later](https://learn.microsoft.com/en-us/dotnet/standard/garbage-collection/datas).
It changes allocation budgets, heap count, and compaction behavior in response to the
application's live data and allocation rate.

This test disabled DATAS to hold GC behavior constant while varying the Temporal workflow cache
size. That makes the result specific to a DATAS-disabled worker. It does not show that production
workers should disable DATAS. The .NET defaults are the better starting point for most services.

DATAS also does not create an operating-system memory boundary. If the runtime sees more memory
than the application may safely use, DATAS and an explicit heap limit solve different problems.

## What the hard limit covers

The [.NET GC configuration documentation](https://learn.microsoft.com/en-us/dotnet/core/runtime-config/garbage-collector#heap-hard-limit)
defines `DOTNET_GCHeapHardLimit` as the maximum committed memory for the GC heap and GC
bookkeeping. It does not cap total process memory. Other consumers include:

- native libraries, including the Temporal Core library
- the .NET runtime and JIT compiler
- thread stacks
- sockets, buffers, and memory-mapped regions

The 10,000-cache and 8,000-cache runs both ended with exit code 137:

| Cache limit | Peak GC memory load | GC budget | Outcome |
|---:|---:|---:|---|
| 10,000 | 6.42 GiB | 6.50 GiB | Process exited 137 |
| 8,000 | 6.49 GiB | 6.50 GiB | Process exited 137 |

Exit code 137 means the process received `SIGKILL`. In this test, the timing and memory metrics
are consistent with termination under memory pressure. The exit code alone does not identify
whether the Linux kernel or the App Service platform issued the signal.

An earlier analysis estimated a gap of about 1.3 GiB between resident memory and live managed
heap size. That is not a native-memory measurement. The samples were taken about 20 minutes apart,
and the difference can include unused committed GC pages as well as native allocations. A memory
profile is required before assigning the gap to Temporal Core or any other component.

For this 8 GiB test worker, 6.0 GiB is a reasonable next hard-limit candidate because it reserves
2 GiB for memory outside the managed heap. It has not yet been validated as a safe production
setting. The required headroom depends on the workload, process architecture, runtime version,
and App Service configuration.

## Linux and Windows

| Question | Linux code deployment tested here | Windows code deployment |
|---|---|---|
| Does `DOTNET_GCHeapHardLimit` apply? | Yes, verified by `TotalAvailableMemoryBytes`. | Yes. .NET supports the same environment variable on Windows. This test did not verify it on App Service Windows. |
| What platform memory limit does the GC see? | No finite cgroup limit was exposed in this test. | Not verified here. .NET 6 and later honor Windows job-object limits when the host supplies one, but the cited App Service documentation does not state that Windows code deployments receive a per-process job-object limit. |
| Does the App Service plan enforce a per-app quota? | Dedicated plan resources are shared by apps in the plan. This test used one app instance. | [Azure lists no per-app memory quota](https://github.com/MicrosoftDocs/azure-docs/blob/main/includes/azure-websites-limits.md) for Basic, Standard, or Premium code deployments. The apps share the dedicated plan instance. Free and Shared tiers have documented quotas. |
| What should a customer check first? | Compare `TotalAvailableMemoryBytes` with the app's real memory budget. | Confirm 64-bit mode, then compare `TotalAvailableMemoryBytes` with the app's real memory budget. |

Do not assume that a Windows worker's GC budget equals the plan's memory. Measure it. Windows
apps may also run as 32-bit processes, which limits their address space to about 2 GB even on a
64-bit host. Use 64-bit mode for a worker that needs more memory.

Windows containers are a separate App Service hosting model. Azure documents configurable
per-container memory limits for them. Those settings do not establish the behavior of Windows
code deployments.

## How to verify a deployment

First, inspect the app settings that Azure will pass to the process:

```bash
az webapp config appsettings list \
  --resource-group <resource-group> \
  --name <app-name> \
  --query "[?starts_with(name,'DOTNET_')]" \
  --output table
```

Then record what the running process reports after at least one collection:

```csharp
GCMemoryInfo gc = GC.GetGCMemoryInfo();

Console.WriteLine(gc.TotalAvailableMemoryBytes);
Console.WriteLine(gc.HighMemoryLoadThresholdBytes);
Console.WriteLine(gc.MemoryLoadBytes);
Console.WriteLine(gc.TotalCommittedBytes);
```

`TotalAvailableMemoryBytes` reports the configured heap hard limit when one is set. In a
container, .NET otherwise reports an implementation-defined fraction of the container limit.
Outside a detected container limit, it reflects physical memory available to the GC. Treat the
value as a GC input, not proof that the platform will allow the whole process to consume that
amount.

To test behavior without a hard limit, remove the app setting instead of setting an empty value:

```bash
az webapp config appsettings delete \
  --resource-group <resource-group> \
  --name <app-name> \
  --setting-names DOTNET_GCHeapHardLimit
```

Deleting the setting avoids ambiguity in environment-variable parsing and makes the test state
clear.

## Monitoring guidance

Monitor `MemoryLoadBytes` against `TotalAvailableMemoryBytes`, plus process resident memory and
restart count. In the first test phase:

- the two failed runs reached 98.8% and 99.8% of the reported GC budget
- the incomplete 6,000-cache run also reached 99.8%, so this ratio indicates risk but does not
  predict the exact failure time
- CPU stayed between 14% and 19%, so CPU did not provide an early warning
- the 8,000-cache run still reported a 96.9% cache hit ratio shortly before it exited

Set alert thresholds from sustained production measurements. Do not copy 98.8% as a general
threshold because it leaves little time to respond and may behave differently with DATAS enabled.

## Test status

Phase 2 compares cache limits of 10,000, 8,000, and 6,000 with and without the 6.50 GiB hard
limit. Server GC stays enabled and DATAS stays disabled in every run. The comparison is not yet
complete, so the report cannot yet say whether the 6.50 GiB setting was protective or only
restrictive.

The test removes `DOTNET_GCHeapHardLimit` for no-limit runs. It does not leave the key present
with a blank value.

## Sources

- [.NET garbage collector configuration](https://learn.microsoft.com/en-us/dotnet/core/runtime-config/garbage-collector)
- [.NET Dynamic Adaptation To Application Sizes](https://learn.microsoft.com/en-us/dotnet/standard/garbage-collection/datas)
- [`GCMemoryInfo.TotalAvailableMemoryBytes`](https://learn.microsoft.com/en-us/dotnet/api/system.gcmemoryinfo.totalavailablememorybytes)
- [.NET support for cgroup and Windows job-object memory limits](https://github.com/dotnet/designs/blob/main/accepted/2019/support-for-memory-limits.md)
- [Azure App Service limits](https://github.com/MicrosoftDocs/azure-docs/blob/main/includes/azure-websites-limits.md)
- [Azure App Service 32-bit process memory guidance](https://learn.microsoft.com/en-us/troubleshoot/azure/app-service/worker-process-percent-memory-limit-message)
- [Azure App Service Windows container memory limits](https://learn.microsoft.com/en-us/azure/app-service/configure-custom-container#customize-container-memory)
