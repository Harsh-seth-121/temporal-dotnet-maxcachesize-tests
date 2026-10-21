using Microsoft.Extensions.Logging;
using Temporalio.Activities;
using Temporalio.Common;
using Temporalio.Workflows;

namespace CacheTest.Core;

/// <summary>
/// Holds a sticky-cache slot. Each heartbeat wake is one workflow task: hit, or miss then full
/// replay. That split is the measurement.
///
/// No continue-as-new. It starts a new run with empty history, and replay cost scaling with
/// history length is what makes a miss visible.
/// </summary>
[Workflow]
public class ResidentWorkflow
{
    private bool release;
    private int cycles;

    public record Args(int HeartbeatSeconds, int MaxCycles);

    [WorkflowRun]
    public async Task<int> RunAsync(Args args)
    {
        // The .NET data converter is case-sensitive PascalCase. camelCase input binds every
        // field to 0: the workflow completes at once holding no cache slot, and aggregate
        // metrics still look normal. Fail at the first workflow instead.
        if (args.MaxCycles <= 0 || args.HeartbeatSeconds <= 0)
        {
            throw new Temporalio.Exceptions.ApplicationFailureException(
                $"ResidentWorkflow needs positive args, got HeartbeatSeconds={args.HeartbeatSeconds} "
                + $"MaxCycles={args.MaxCycles}. Arguments must be PascalCase.",
                nonRetryable: true);
        }

        while (cycles < args.MaxCycles && !release)
        {
            // Workflow.Random, not Random.Shared: must survive replay. Without jitter a cohort
            // wakes in lockstep, making LRU eviction a cliff at cap+1 instead of a gradient.
            var jittered = args.HeartbeatSeconds * (0.8 + Workflow.Random.NextDouble() * 0.4);

            // WhenAny so release cuts the wait short. Otherwise teardown leaves thousands of
            // workflows burning timer Actions.
            await Workflow.WhenAnyAsync(
                Workflow.DelayAsync(TimeSpan.FromSeconds(jittered)),
                Workflow.WaitConditionAsync(() => release));
            cycles++;
        }
        return cycles;
    }

    [WorkflowSignal]
    public Task ReleaseAsync()
    {
        release = true;
        return Task.CompletedTask;
    }

    /// <summary>Driver confirms residency without reading event history.</summary>
    [WorkflowQuery]
    public int CompletedCycles() => cycles;
}

/// <summary>One activity, then done. Drives the burst profile.</summary>
[Workflow]
public class ChurnWorkflow
{
    [WorkflowRun]
    public Task<int> RunAsync() =>
        Workflow.ExecuteActivityAsync(
            (SleepActivities a) => a.SleepRandomAsync(),
            new()
            {
                StartToCloseTimeout = TimeSpan.FromSeconds(30),
                // Retries are history-neutral: Temporal records the attempt counter on
                // ActivityTaskStarted, no extra ActivityTaskScheduled per attempt, so they do
                // not skew replay cost. MaximumAttempts=1 would lose workflows on worker
                // restart, on one arm only, and the open-loop driver never replaces them.
                RetryPolicy = new()
                {
                    MaximumAttempts = 3,
                    InitialInterval = TimeSpan.FromSeconds(1),
                    BackoffCoefficient = 2.0F,
                    MaximumInterval = TimeSpan.FromSeconds(10),
                },
            });
}

public sealed class SleepActivities
{
    /// <summary>Sleeps 1-5s. Random is safe here: activities are not replayed.</summary>
    [Activity]
    public async Task<int> SleepRandomAsync()
    {
        var ms = Random.Shared.Next(1000, 5001);
        await Task.Delay(ms, ActivityExecutionContext.Current.CancellationToken);
        return ms;
    }
}

/// <summary>
/// Holds a cache slot that costs real memory, so a full cache can exhaust a worker.
///
/// Not via history size. Core retains activity INPUTS (ActivityMachine.SharedState.attrs),
/// drops results, and drains consumed events from HistoryUpdate as it goes, so it holds about
/// one workflow task's worth of events. Big activity results leave per-workflow memory flat.
///
/// The cost comes from retaining results in a field: .NET heap, held for as long as the
/// instance is cached, ~1:1 with bytes retained (measured 2.5% overhead).
/// </summary>
[Workflow]
public class BallastWorkflow
{
    /// <summary>Shaped like real accumulated work, not an opaque buffer. Same memory cost.</summary>
    public record Batch(int BatchNumber, string Reference, byte[] Records);

    public record Args(
        int BatchCount,
        int BytesPerBatch,
        int HeartbeatSeconds,
        int MaxCycles);

    // The memory lever. Drop this field and per-workflow cost stays flat near 135 KB whatever
    // the payload size.
    private readonly List<Batch> retained = new();
    private bool release;
    private int cycles;

    [WorkflowRun]
    public async Task<int> RunAsync(Args args)
    {
        if (args.BatchCount <= 0 || args.BytesPerBatch <= 0 ||
            args.MaxCycles <= 0 || args.HeartbeatSeconds <= 0)
        {
            throw new Temporalio.Exceptions.ApplicationFailureException(
                $"BallastWorkflow needs positive args, got BatchCount={args.BatchCount} "
                + $"BytesPerBatch={args.BytesPerBatch} HeartbeatSeconds={args.HeartbeatSeconds} "
                + $"MaxCycles={args.MaxCycles}. Arguments must be PascalCase.",
                nonRetryable: true);
        }

        // Local activities resolving inside one workflow task bill as ONE Action for the whole
        // batch. Regular activities bill one each: 10,000 Actions here instead of 80,000.
        var opts = new LocalActivityOptions
        {
            StartToCloseTimeout = TimeSpan.FromSeconds(10),
            RetryPolicy = new() { MaximumAttempts = 3 },
        };

        var batches = await Workflow.WhenAllAsync(
            Enumerable.Range(0, args.BatchCount).Select(n =>
                Workflow.ExecuteLocalActivityAsync(
                    (BallastActivities a) => a.BuildBatch(n, args.BytesPerBatch), opts)));
        retained.AddRange(batches);

        // MetricMeter is per-execution: fetch here, never in a static initialiser. Replay-safe,
        // so these drop during replay instead of double-counting.
        var meter = Workflow.MetricMeter;
        meter.CreateHistogram<long>("cachetest_workflow_history_size_bytes", "By",
            "History size at the workflow task boundary").Record(Workflow.CurrentHistorySize);
        meter.CreateHistogram<long>("cachetest_workflow_history_length", "",
            "History event count at the workflow task boundary").Record(Workflow.CurrentHistoryLength);
        meter.CreateHistogram<long>("cachetest_workflow_retained_bytes", "By",
            "Bytes deliberately retained by this workflow")
            .Record((long)args.BatchCount * args.BytesPerBatch);

        // Tripwire. Well under the 4 MiB threshold at this size; catches a scaled-up payload
        // before Temporal terminates histories.
        if (Workflow.ContinueAsNewSuggested)
        {
            Workflow.Logger.LogWarning(
                "continue-as-new suggested at {Bytes}B over {Events} events. Do NOT act on it: "
                + "it would evict this run, start a fresh one with empty history, and silently "
                + "drop this workflow out of the resident population.",
                Workflow.CurrentHistorySize, Workflow.CurrentHistoryLength);
        }

        while (cycles < args.MaxCycles && !release)
        {
            // Same jitter as ResidentWorkflow: lockstep wakes turn LRU eviction into a cliff.
            var jittered = args.HeartbeatSeconds * (0.8 + Workflow.Random.NextDouble() * 0.4);
            await Workflow.WhenAnyAsync(
                Workflow.DelayAsync(TimeSpan.FromSeconds(jittered)),
                Workflow.WaitConditionAsync(() => release));
            cycles++;
        }
        return cycles;
    }

    [WorkflowSignal]
    public Task ReleaseAsync()
    {
        release = true;
        return Task.CompletedTask;
    }

    [WorkflowQuery]
    public int RetainedBatches() => retained.Count;
}

public sealed class BallastActivities
{
    /// <summary>
    /// Sized batch. Non-uniform content so it does not compress on the wire and the runtime
    /// cannot share pages, either of which would understate memory cost.
    /// </summary>
    [Activity]
    public BallastWorkflow.Batch BuildBatch(int batchNumber, int bytes)
    {
        var records = new byte[bytes];
        for (var i = 0; i < records.Length; i++)
        {
            records[i] = (byte)((i * 31 + batchNumber * 17) & 0xFF);
        }
        return new BallastWorkflow.Batch(batchNumber, $"batch-{batchNumber:D4}", records);
    }
}
