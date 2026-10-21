namespace CacheTest.Core;

/// <summary>
/// Projects Actions-per-second before a run starts.
///
/// The namespace APS ceiling produces RESOURCE_EXHAUSTED, which Temporal Cloud surfaces as added
/// latency rather than lost work. By eye that is cache slowness, so a throttled run gives a
/// wrong answer. Refuse to start instead.
///
/// Action model, per docs.temporal.io/evaluate/cloud/actions:
///   workflow start      1 Action
///   timer started       1 Action  (EVENT_TYPE_TIMER_STARTED / start_timer)
///   activity scheduled  1 Action
///   workflow REPLAY     0 Actions, so cache misses are free
/// </summary>
public static class ApsPreflight
{
    public const double LimitUtilisation = 0.8;

    public sealed record Projection(
        double SteadyAps, double PeakAps, long TotalActions, int Limit, string Detail)
    {
        public double Threshold => Limit * LimitUtilisation;
        public bool Exceeds => PeakAps > Threshold;
    }

    public static Projection Project(TestConfig cfg)
    {
        var p = cfg.ActiveProfile;
        var queues = cfg.Arms.Count;

        if (p.Kind.Equals("burst", StringComparison.OrdinalIgnoreCase))
        {
            // Each ChurnWorkflow: 1 start + 1 activity schedule = 2 Actions.
            var startsPerSec = p.StartsPerMinute / 60.0;
            var aps = startsPerSec * 2 * queues;
            var burstTotal = (long)(aps * p.DurationMinutes * 60);
            return new(aps, aps, burstTotal, cfg.Temporal.ApsLimit,
                $"burst: {p.StartsPerMinute}/min x {queues} queues x 2 Actions");
        }

        // Ramp. Steady state is one timer per resident workflow per interval, across all queues.
        var steady = (double)p.TargetOpenPerQueue * queues / p.HeartbeatIntervalSeconds;

        // Ramp starts overlap the timers already ticking. Worst case at the last start: full
        // timer load plus the full start rate.
        var peak = steady + p.StartRatePerSecond * queues;

        var rampSeconds = p.StartRatePerSecond > 0
            ? p.TargetOpenPerQueue / p.StartRatePerSecond
            : 0;
        var startActions = (long)p.TargetOpenPerQueue * queues;
        // Nominal hour of steady state, so the total means something before a duration is set.
        var total = startActions + (long)(steady * (3600 + rampSeconds));

        return new(steady, peak, total, cfg.Temporal.ApsLimit,
            $"ramp: {p.TargetOpenPerQueue} open x {queues} queues / {p.HeartbeatIntervalSeconds}s "
            + $"= {steady:F1} steady, +{p.StartRatePerSecond * queues:F1} from starts");
    }

    /// <summary>Throws if the projection would breach the configured ceiling.</summary>
    public static Projection Assert(TestConfig cfg)
    {
        var proj = Project(cfg);
        if (proj.Exceeds)
        {
            throw new InvalidOperationException(
                $"Projected peak {proj.PeakAps:F1} APS exceeds {LimitUtilisation:P0} of the "
                + $"{proj.Limit} APS namespace limit ({proj.Threshold:F1}). "
                + $"{proj.Detail}. Raise temporal.apsLimit once the increase is granted, "
                + $"lengthen heartbeatIntervalSeconds, or lower targetOpenPerQueue.");
        }
        return proj;
    }
}
