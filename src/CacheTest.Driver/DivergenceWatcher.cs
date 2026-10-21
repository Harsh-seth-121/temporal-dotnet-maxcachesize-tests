using System.Globalization;
using CacheTest.Core;

namespace CacheTest.Driver;

/// <summary>
/// Decides when the arms have separated, by scraping each worker's /metrics directly.
///
/// Not Prometheus: it sits behind internal-only Container Apps ingress, unreachable from an App
/// Service driver without VNet integration. The workers' /metrics are already reachable and
/// already authenticated.
/// </summary>
public sealed class DivergenceWatcher(TestConfig cfg, IConfiguration env, ILogger log)
{
    private const string EvictionMetric = "temporal_sticky_cache_total_forced_eviction";
    private const int RequiredConsecutive = 3;

    private readonly HttpClient http = new() { Timeout = TimeSpan.FromSeconds(10) };
    private readonly Dictionary<string, double> previous = new();
    private int consecutive;

    /// <summary>Returns a reason string once divergence has held, otherwise null.</summary>
    public async Task<string?> CheckAsync(CancellationToken ct)
    {
        // Smallest real cache vs largest. Control arm excluded by its flag: it thrashes from
        // the start, so including it declares divergence instantly.
        var real = cfg.Arms.Where(a => !a.IsControl && a.MaxCachedWorkflows > 0)
                           .OrderBy(a => a.MaxCachedWorkflows).ToList();
        if (real.Count < 2) return null;

        var low = real.First();
        var high = real.Last();

        var lowDelta = await DeltaAsync(low, ct);
        var highDelta = await DeltaAsync(high, ct);
        if (lowDelta is null || highDelta is null) return null;  // scrape gap, not a signal

        var diverged = lowDelta > 0 && highDelta == 0;
        consecutive = diverged ? consecutive + 1 : 0;

        log.LogInformation(
            "divergence check: {Low}(+{LowD}) vs {High}(+{HighD}) consecutive={N}/{Req}",
            low.Name, lowDelta, high.Name, highDelta, consecutive, RequiredConsecutive);

        // One non-zero reading can be a worker restart or a scrape gap. Holding across checks
        // is what stops the ramp ending early on noise.
        if (consecutive >= RequiredConsecutive)
        {
            return $"{low.Name} (cache {low.MaxCachedWorkflows}) is evicting while "
                 + $"{high.Name} (cache {high.MaxCachedWorkflows}) is not, "
                 + $"sustained over {RequiredConsecutive} checks";
        }
        return null;
    }

    private async Task<double?> DeltaAsync(ArmConfig arm, CancellationToken ct)
    {
        var current = await ScrapeAsync(arm, ct);
        if (current is null) return null;
        var delta = previous.TryGetValue(arm.Name, out var prev)
            ? Math.Max(0, current.Value - prev)   // a counter reset means restart, not negative
            : (double?)null;
        previous[arm.Name] = current.Value;
        return delta;
    }

    private async Task<double?> ScrapeAsync(ArmConfig arm, CancellationToken ct)
    {
        var baseUrl = env[$"METRICS_URL_{arm.Name.ToUpperInvariant()}"]
                      ?? env["METRICS_URL_TEMPLATE"]?.Replace("{arm}", arm.Name);
        if (string.IsNullOrWhiteSpace(baseUrl)) return null;

        try
        {
            using var req = new HttpRequestMessage(HttpMethod.Get, $"{baseUrl.TrimEnd('/')}/metrics");
            var token = env["METRICS_BEARER_TOKEN"];
            if (!string.IsNullOrEmpty(token))
            {
                req.Headers.Authorization = new("Bearer", token);
            }
            using var resp = await http.SendAsync(req, ct);
            if (!resp.IsSuccessStatusCode) return null;
            return Sum(await resp.Content.ReadAsStringAsync(ct), EvictionMetric);
        }
        catch (Exception e)
        {
            log.LogWarning("scrape of {Arm} failed: {Msg}", arm.Name, e.Message);
            return null;
        }
    }

    /// <summary>Sums every labelled series of one metric out of a Prometheus text exposition.</summary>
    internal static double Sum(string exposition, string metric)
    {
        var total = 0.0;
        foreach (var line in exposition.Split('\n'))
        {
            if (line.Length == 0 || line[0] == '#') continue;
            if (!line.StartsWith(metric, StringComparison.Ordinal)) continue;
            // Must be the whole name: guard against a longer metric sharing this prefix.
            var after = line.Length > metric.Length ? line[metric.Length] : ' ';
            if (after != ' ' && after != '{') continue;
            var sp = line.LastIndexOf(' ');
            if (sp < 0) continue;
            if (double.TryParse(line[(sp + 1)..].Trim(), NumberStyles.Float,
                                CultureInfo.InvariantCulture, out var v))
            {
                total += v;
            }
        }
        return total;
    }
}

public static class Releaser
{
    /// <summary>
    /// Signals every running ResidentWorkflow to finish. Otherwise they keep firing heartbeat
    /// timers long after the test, and every timer is a billable Action.
    /// </summary>
    public static async Task<int> ReleaseAllAsync(TestConfig cfg, RunState state)
    {
        if (state.Client is null) return 0;
        var n = 0;
        await foreach (var wf in state.Client.ListWorkflowsAsync(
            "WorkflowType = 'ResidentWorkflow' AND ExecutionStatus = 'Running'"))
        {
            try
            {
                await state.Client.GetWorkflowHandle(wf.Id, wf.RunId)
                                  .SignalAsync<ResidentWorkflow>(w => w.ReleaseAsync());
                n++;
            }
            catch { /* already gone; nothing to release */ }
        }
        return n;
    }
}
