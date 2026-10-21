using CacheTest.Core;
using Temporalio.Client;

namespace CacheTest.Driver;

public sealed class DriverService(
    TestConfig cfg, RunState state, IConfiguration env, ILogger<DriverService> log)
    : BackgroundService
{
    /// <summary>
    /// Four HTTP scrapes per workflow started would dominate the ramp loop. Overridable so a
    /// short local dry run still exercises the path.
    /// </summary>
    private readonly int DivergenceCheckEveryNStarts =
        int.TryParse(env["DIVERGENCE_CHECK_EVERY"], out var n) && n > 0 ? n : 60;

    protected override async Task ExecuteAsync(CancellationToken ct)
    {
        try
        {
            // Preflight BEFORE connecting. The namespace APS ceiling throttles with
            // RESOURCE_EXHAUSTED, which presents as latency and reads like cache slowness.
            // A throttled run gives a confident wrong answer.
            var proj = ApsPreflight.Assert(cfg);
            log.LogInformation(
                "preflight ok: {Steady:F1} steady APS, {Peak:F1} peak, limit {Limit} ({Detail})",
                proj.SteadyAps, proj.PeakAps, proj.Limit, proj.Detail);

            var client = await TemporalFactory.ConnectAsync(cfg.Temporal, null, ct);
            state.Client = client;
            log.LogInformation("connected to {Ns}", cfg.Temporal.Namespace);

            var p = cfg.ActiveProfile;
            state.Phase = $"running:{cfg.Profile}";

            if (p.Kind.Equals("burst", StringComparison.OrdinalIgnoreCase))
                await RunBurstAsync(client, p, ct);
            else
                await RunRampAsync(client, p, ct);

            state.Phase = "finished";
        }
        catch (OperationCanceledException) { state.Phase = "cancelled"; }
        catch (Exception e)
        {
            state.Phase = "failed";
            state.LastError = e.Message;
            log.LogError(e, "driver failed");
        }
    }

    /// <summary>
    /// Grows the population on every arm in lockstep, one workflow per arm per tick, so offered
    /// load stays equal. Staggering lets a load difference pass for a cache-size difference.
    /// </summary>
    private async Task RunRampAsync(ITemporalClient client, ProfileConfig p, CancellationToken ct)
    {
        var delay = TimeSpan.FromSeconds(1.0 / Math.Max(p.StartRatePerSecond, 0.0001));
        // Enough cycles to outlive any run. The release signal is how a run ends.
        var maxCycles = Math.Max(1, (int)(TimeSpan.FromHours(12).TotalSeconds / p.HeartbeatIntervalSeconds));
        var args = new ResidentWorkflow.Args(p.HeartbeatIntervalSeconds, maxCycles);
        var residentHorizon = TimeSpan.FromHours(
            double.TryParse(env["RESIDENT_HORIZON_HOURS"], out var h) && h > 0 ? h : 12);

        var divergence = new DivergenceWatcher(cfg, env, log);
        var runTag = DateTimeOffset.UtcNow.ToUnixTimeSeconds();

        // Starts are network-bound round trips to Cloud, not CPU. One at a time caps the ramp
        // at a few per second: hours for 7500 x 4 arms before measurement begins. Fire the arms
        // concurrently, several ticks in flight, counts still in lockstep.
        var inFlight = new SemaphoreSlim(
            int.TryParse(env["START_CONCURRENCY"], out var sc) && sc > 0 ? sc : 16);

        async Task StartOneAsync(ArmConfig arm, int idx)
        {
            await inFlight.WaitAsync(ct);
            try
            {
                var id = $"res-{runTag}-{arm.Name}-{idx}";
                if (p.UsesBallast)
                {
                    // Retains BatchCount x BytesPerBatch in a field. That is what makes a
                    // full cache cost real memory.
                    await client.StartWorkflowAsync(
                        (BallastWorkflow wf) => wf.RunAsync(new BallastWorkflow.Args(
                            p.BatchCount, p.BytesPerBatch, p.HeartbeatIntervalSeconds, maxCycles)),
                        new(id, arm.TaskQueue) { ExecutionTimeout = residentHorizon });
                    Interlocked.Increment(ref state.StartedTotal);
                    return;
                }

                await client.StartWorkflowAsync(
                    (ResidentWorkflow wf) => wf.RunAsync(args),
                    new(id, arm.TaskQueue)
                    {
                        // Dead-man switch. A dead driver leaves residents firing heartbeat
                        // timers forever, and every timer is a billable Action. Bounds an
                        // unattended failure to one horizon instead of a weekend.
                        ExecutionTimeout = residentHorizon,
                    });
                Interlocked.Increment(ref state.StartedTotal);
            }
            catch (Exception e)
            {
                state.LastError = $"start failed on {arm.Name}: {e.Message}";
                log.LogWarning("start failed on {Arm}: {Msg}", arm.Name, e.Message);
            }
            finally { inFlight.Release(); }
        }

        // Issued, not awaited. Awaiting each index inline serializes every start behind one
        // round trip to Cloud: StartRatePerSecond becomes a fiction, the inFlight semaphore
        // becomes dead code, and ramp duration tracks how loaded the worker is.
        var issued = new List<Task>(p.TargetOpenPerQueue);

        for (var i = 0; i < p.TargetOpenPerQueue && !ct.IsCancellationRequested; i++)
        {
            // All arms for one index together: they never drift apart by more than inFlight
            // starts. StartOneAsync swallows its own exceptions, so these tasks never fault.
            issued.Add(Task.WhenAll(cfg.Arms.Select(a => StartOneAsync(a, i))));
            state.OpenEstimate = (i + 1) * cfg.Arms.Count;

            // The criterion needs a sustained signal anyway, and scraping four endpoints per
            // start would dominate the loop.
            if (p.HaltOnDivergence && i > 0 && i % DivergenceCheckEveryNStarts == 0)
            {
                var reason = await divergence.CheckAsync(ct);
                if (reason is not null)
                {
                    state.HaltReason = reason;
                    state.Phase = "halted:divergence";
                    log.LogInformation("halting ramp: {Reason}", reason);
                    return;
                }
            }

            await Task.Delay(delay, ct);
        }

        // The loop above sets the rate; this waits for the last starts in flight. Without it
        // the hold begins while workflows are still being created.
        await Task.WhenAll(issued);
        log.LogInformation("ramp issued {Count} starts", state.StartedTotal);

        // Bounded hold, so a worker that refuses to die does not consume the whole window.
        if (p.HoldMinutes > 0)
        {
            state.Phase = $"ramp complete, holding {p.HoldMinutes}m";
            log.LogInformation("ramp complete at {Open} open, holding {Mins} minutes",
                state.OpenEstimate, p.HoldMinutes);
            await Task.Delay(TimeSpan.FromMinutes(p.HoldMinutes), ct);
            state.Phase = "hold complete";
            log.LogInformation("hold complete");

            if (p.DrainAfterHold)
                await DrainAsync(client, ct);
        }
        else
        {
            state.Phase = "ramp complete, holding";
            await Task.Delay(Timeout.InfiniteTimeSpan, ct);
        }
    }

    /// <summary>
    /// Terminate every running workflow, verify, repeat.
    ///
    /// In the driver, not the laptop: after the hold the population keeps waking on its
    /// heartbeat timer, ~98,000 Actions an hour at this size, until somebody notices.
    ///
    /// Looped, not one pass: terminate runs against eventually-consistent visibility, so one
    /// pass misses anything mid-start. One pass once left 134 of ~7,200 running.
    /// </summary>
    private async Task DrainAsync(ITemporalClient client, CancellationToken ct)
    {
        const string running = "ExecutionStatus='Running'";
        for (var pass = 1; pass <= 6 && !ct.IsCancellationRequested; pass++)
        {
            state.Phase = $"draining:pass{pass}";
            var terminated = 0;
            // 8,000 simultaneous terminates hit the namespace rate limit, which surfaces as
            // failures rather than backpressure.
            var inflight = new List<Task>(32);
            await foreach (var wf in client.ListWorkflowsAsync(running).WithCancellation(ct))
            {
                inflight.Add(TerminateQuietlyAsync(client, wf.Id, wf.RunId, ct));
                terminated++;
                if (inflight.Count < 32) continue;
                await Task.WhenAll(inflight);
                inflight.Clear();
            }
            await Task.WhenAll(inflight);

            // Visibility lags the terminate calls; counting immediately reports the old number.
            await Task.Delay(TimeSpan.FromSeconds(20), ct);
            var left = await client.CountWorkflowsAsync(running);
            log.LogInformation("drain pass {Pass}: terminated {Count}, {Left} still running",
                pass, terminated, left.Count);
            if (left.Count == 0)
            {
                state.Phase = "drained";
                return;
            }
        }
        state.Phase = "drain incomplete";
        log.LogWarning("drain did not reach zero after 6 passes; the population is still billing");
    }

    private async Task TerminateQuietlyAsync(
        ITemporalClient client, string id, string? runId, CancellationToken ct)
    {
        try
        {
            await client.GetWorkflowHandle(id, runId).TerminateAsync(
                "arm complete, draining so the population stops billing",
                new() { Rpc = new() { CancellationToken = ct } });
        }
        catch (Exception e)
        {
            // Finishing between the list and the terminate is not an error, and one failure
            // must not abandon the rest of the population.
            log.LogDebug(e, "terminate {Id} failed", id);
        }
    }

    private async Task RunBurstAsync(ITemporalClient client, ProfileConfig p, CancellationToken ct)
    {
        var delay = TimeSpan.FromSeconds(60.0 / Math.Max(p.StartsPerMinute, 1));
        var deadline = DateTimeOffset.UtcNow.AddMinutes(p.DurationMinutes);
        var runTag = DateTimeOffset.UtcNow.ToUnixTimeSeconds();
        var i = 0;

        while (DateTimeOffset.UtcNow < deadline && !ct.IsCancellationRequested)
        {
            foreach (var arm in cfg.Arms)
            {
                try
                {
                    // Fire and forget. Awaiting completion caps throughput at the activity
                    // duration and holds the start rate below target.
                    await client.StartWorkflowAsync(
                        (ChurnWorkflow wf) => wf.RunAsync(),
                        new($"churn-{runTag}-{arm.Name}-{i}", arm.TaskQueue));
                    Interlocked.Increment(ref state.StartedTotal);
                }
                catch (Exception e)
                {
                    state.LastError = $"burst start failed on {arm.Name}: {e.Message}";
                }
            }
            i++;
            await Task.Delay(delay, ct);
        }
    }
}
