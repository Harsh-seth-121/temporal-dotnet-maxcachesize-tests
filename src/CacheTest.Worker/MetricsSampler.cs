namespace CacheTest.Worker;

/// <summary>
/// Writes the worker's own metrics to disk every 30s, so an arm does not depend on a laptop
/// being awake to be measured.
///
/// Prometheus runs in local Docker. A sleeping laptop stops scraping and loses the stretch of
/// an arm that matters. The worker is awake for the whole arm, so it records itself.
///
/// /home/LogFiles is Azure Files backed on App Service Linux: survives a kernel OOM kill and a
/// restart, and `az webapp log download` already pulls it. No new ingress, nothing to deploy.
///
/// The file name carries the process start time, so instances separate themselves. Phase 1 had
/// to window every export to a dominant process_start_time_seconds because one capture spanned
/// three instances; here the third writes a different file.
/// </summary>
public sealed class MetricsSampler(
    IHttpClientFactory factory, IConfiguration cfg, ILogger<MetricsSampler> log)
    : BackgroundService
{
    // What the report assembler reads, plus the two series phase 1 recovered by hand. Prefix
    // match, so a family's _sum, _count and _bucket lines come along.
    private static readonly string[] Wanted =
    [
        "process_resident_memory_bytes", "process_cpu_seconds_total", "process_start_time_seconds",
        "dotnet_gc_committed_bytes", "dotnet_gc_heap_size_bytes", "dotnet_gc_memory_load_bytes",
        "dotnet_gc_fragmented_bytes", "dotnet_gc_pause_seconds_total",
        "dotnet_gc_allocated_bytes_total", "dotnet_gc_total_available_bytes",
        "temporal_sticky_cache_size", "temporal_sticky_cache_total_forced_eviction",
        "temporal_sticky_cache_hit", "temporal_sticky_cache_miss",
        "temporal_workflow_task_execution_latency", "temporal_worker_task_slots_used",
    ];

    protected override async Task ExecuteAsync(CancellationToken ct)
    {
        var arm = cfg["ARM"] ?? "unknown";
        var started = new DateTimeOffset(
            System.Diagnostics.Process.GetCurrentProcess().StartTime.ToUniversalTime())
            .ToUnixTimeSeconds();

        // SAMPLES_DIR exists so a local run does not try to write to an App Service path.
        var dir = cfg["SAMPLES_DIR"] ?? "/home/LogFiles/samples";
        string path;
        try
        {
            Directory.CreateDirectory(dir);
            path = Path.Combine(dir, $"arm-{arm}-{started}.tsv");
            if (!File.Exists(path))
                await File.WriteAllTextAsync(path, "# unix_seconds\tmetric\tvalue\n", ct);
        }
        catch (Exception e)
        {
            // Sampling is observability, not the experiment. Refusing to start on an
            // unwritable log directory turns a reporting gap into a dead arm.
            log.LogError(e, "metrics sampler disabled: cannot write to {Dir}", dir);
            return;
        }

        log.LogInformation("sampling every 30s into {Path}", path);
        var client = factory.CreateClient("prom");
        var token = cfg["METRICS_BEARER_TOKEN"];

        while (!ct.IsCancellationRequested)
        {
            try
            {
                var now = DateTimeOffset.UtcNow.ToUnixTimeSeconds();
                var lines = new List<string>(32);
                // SDK exporter on loopback: no token needed, skips the proxy endpoint.
                Collect(lines, now, await client.GetStringAsync("/metrics", ct));
                // Runtime endpoint is behind the bearer check. Ask for it the way an outside
                // scraper would rather than duplicating how it is built.
                Collect(lines, now, await GetRuntimeAsync(token, ct));
                if (lines.Count > 0)
                    await File.AppendAllLinesAsync(path, lines, ct);
            }
            catch (OperationCanceledException) { break; }
            catch (Exception e)
            {
                // One failed sample is a gap of 30 seconds. Killing the loop is a gap of an arm.
                log.LogWarning(e, "sample failed");
            }

            try { await Task.Delay(TimeSpan.FromSeconds(30), ct); }
            catch (OperationCanceledException) { break; }
        }
    }

    private async Task<string> GetRuntimeAsync(string? token, CancellationToken ct)
    {
        // App Service names this differently depending on how the app was deployed. A wrong
        // port costs every runtime series: RSS, GC load, CPU. Try each, then Kestrel's default.
        var port = Environment.GetEnvironmentVariable("PORT")
                   ?? Environment.GetEnvironmentVariable("WEBSITES_PORT")
                   ?? Environment.GetEnvironmentVariable("ASPNETCORE_URLS")?.Split(':').LastOrDefault()?.TrimEnd('/')
                   ?? "8080";
        using var c = new HttpClient { BaseAddress = new Uri($"http://127.0.0.1:{port}") };
        if (!string.IsNullOrEmpty(token))
            c.DefaultRequestHeaders.Authorization = new("Bearer", token);
        return await c.GetStringAsync("/metrics/runtime", ct);
    }

    /// <summary>Flatten Prometheus exposition into timestamped rows, keeping only what is read.</summary>
    private static void Collect(List<string> into, long now, string exposition)
    {
        foreach (var raw in exposition.Split('\n'))
        {
            var line = raw.Trim();
            if (line.Length == 0 || line[0] == '#') continue;
            var name = line.Split('{', ' ')[0];
            if (!Wanted.Any(w => name.StartsWith(w, StringComparison.Ordinal))) continue;
            var sp = line.LastIndexOf(' ');
            if (sp <= 0) continue;
            // Name and labels verbatim: labels carry the arm, so a collector need not guess.
            into.Add($"{now}\t{line[..sp]}\t{line[(sp + 1)..]}");
        }
    }
}
