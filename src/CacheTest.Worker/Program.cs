using CacheTest.Core;
using Temporalio.Runtime;
using Temporalio.Worker;

var builder = WebApplication.CreateBuilder(args);
var cfg = builder.Configuration;

// Arm identity. Every other difference between the four deployments derives from this.
var armName = cfg["ARM"] ?? "local";
var cacheSize = int.Parse(cfg["MAX_CACHED_WORKFLOWS"] ?? "10000");
var taskQueue = cfg["TASK_QUEUE"] ?? $"cache-test-{armName}";
var metricsToken = cfg["METRICS_BEARER_TOKEN"];
// Loopback only. App Service routes 80/443 to the main port, so /metrics is re-served below.
var promPort = int.Parse(cfg["PROM_PORT"] ?? "9100");

var temporal = new TemporalConfig
{
    Address = cfg["TEMPORAL_ADDRESS"] ?? "localhost:7233",
    Namespace = cfg["TEMPORAL_NAMESPACE"] ?? "default",
    ClientCertB64 = cfg["TEMPORAL_CLIENT_CERT_B64"],
    ClientKeyB64 = cfg["TEMPORAL_CLIENT_KEY_B64"],
    ClientCertPath = cfg["TEMPORAL_CLIENT_CERT_PATH"],
    ClientKeyPath = cfg["TEMPORAL_CLIENT_KEY_PATH"],
};

var workerCfg = new WorkerConfig
{
    MaxConcurrentWorkflowTasks = int.Parse(cfg["MAX_CONCURRENT_WORKFLOW_TASKS"] ?? "200"),
    MaxConcurrentActivities = int.Parse(cfg["MAX_CONCURRENT_ACTIVITIES"] ?? "100"),
    MaxConcurrentWorkflowTaskPolls = int.Parse(cfg["MAX_CONCURRENT_WORKFLOW_TASK_POLLS"] ?? "10"),
};

// Core rejects these at worker construction with an opaque InvalidOperationException from the
// Rust bridge. Fail here, where the message names the setting.
if (cacheSize > 0)
{
    if (workerCfg.MaxConcurrentWorkflowTasks < 2)
        throw new InvalidOperationException("MaxCachedWorkflows > 0 requires MAX_CONCURRENT_WORKFLOW_TASKS >= 2");
    if (workerCfg.MaxConcurrentWorkflowTaskPolls < 2)
        throw new InvalidOperationException("MaxCachedWorkflows > 0 requires MAX_CONCURRENT_WORKFLOW_TASK_POLLS >= 2");
}

var runtime = TemporalFactory.CreateRuntime($"127.0.0.1:{promPort}", armName, cacheSize);
builder.Services.AddSingleton(runtime);
builder.Services.AddSingleton(temporal);
builder.Services.AddSingleton(workerCfg);
builder.Services.AddHttpClient("prom", c => c.BaseAddress = new Uri($"http://127.0.0.1:{promPort}"));
builder.Services.AddHostedService<WorkerService>();
// Samples to /home/LogFiles every 30s so an arm survives the laptop going away. Registered
// after WorkerService so the first sample lands on a worker that is already polling.
builder.Services.AddHostedService<CacheTest.Worker.MetricsSampler>();
// App Service SIGTERM grace window is short and not configurable. Stay inside it.
builder.Services.Configure<HostOptions>(o => o.ShutdownTimeout = TimeSpan.FromSeconds(20));

var app = builder.Build();

// Always On pings root every 5 minutes. That ping keeps the app loaded, which keeps the sticky
// cache alive. Must be fast and 2xx.
app.MapGet("/", () => Results.Text($"arm={armName} cache={cacheSize} queue={taskQueue}"));

// Re-serve the Core exporter on the port App Service routes. Verbatim, so metric names match
// the upstream Grafana dashboard.
app.MapGet("/metrics", async (HttpContext ctx, IHttpClientFactory f) =>
{
    if (!Authorised(ctx, metricsToken)) return Results.Unauthorized();
    var body = await f.CreateClient("prom").GetStringAsync("/metrics");
    return Results.Text(body, "text/plain; version=0.0.4; charset=utf-8");
});

// Process-level metrics: measured CPU, plus the memory detail that precedes an OOM.
// Hand-rolled rather than prometheus-net. Byte-identical binaries across arms is a design goal,
// and this is ~40 lines.
app.MapGet("/metrics/runtime", (HttpContext ctx) =>
{
    if (!Authorised(ctx, metricsToken)) return Results.Unauthorized();

    var proc = System.Diagnostics.Process.GetCurrentProcess();
    proc.Refresh();   // Process snapshots. Without this the CPU counters never move.
    var startUnix = new DateTimeOffset(proc.StartTime.ToUniversalTime()).ToUnixTimeSeconds();
    var labels = $"{{arm=\"{armName}\",cache_size=\"{cacheSize}\"}}";
    var sb = new System.Text.StringBuilder();

    void G(string name, string help, object v) {
        sb.AppendLine($"# HELP {name} {help}");
        sb.AppendLine($"# TYPE {name} gauge");
        sb.AppendLine($"{name}{labels} {v}");
    }
    void C(string name, string help, object v) {
        sb.AppendLine($"# HELP {name} {help}");
        sb.AppendLine($"# TYPE {name} counter");
        sb.AppendLine($"{name}{labels} {v}");
    }

    // --- restart detection: a step change here means the process died ---
    G("process_start_time_seconds", "Process start time, unix epoch", startUnix);

    // --- CPU. Seconds. Utilisation derived in PromQL against available_cores, which honours
    //     the cgroup quota rather than the host core count. ---
    C("process_cpu_seconds_total", "Total CPU seconds, user plus system", F(proc.TotalProcessorTime.TotalSeconds));
    C("process_cpu_user_seconds_total", "User-mode CPU seconds", F(proc.UserProcessorTime.TotalSeconds));
    C("process_cpu_system_seconds_total", "Kernel-mode CPU seconds", F(proc.PrivilegedProcessorTime.TotalSeconds));
    G("process_available_cores", "Cores visible to this process, cgroup-aware", Environment.ProcessorCount);
    G("process_threads", "OS thread count", proc.Threads.Count);

    // --- memory ---
    G("process_resident_memory_bytes", "Resident set size", proc.WorkingSet64);
    G("process_virtual_memory_bytes", "Virtual memory size", proc.VirtualMemorySize64);
    G("dotnet_gc_heap_bytes", "Managed heap in use", GC.GetTotalMemory(false));
    C("dotnet_gc_allocated_bytes_total", "Cumulative bytes allocated", GC.GetTotalAllocatedBytes(false));
    C("dotnet_gc_pause_seconds_total", "Cumulative GC pause time", F(GC.GetTotalPauseDuration().TotalSeconds));
    for (var gen = 0; gen <= 2; gen++)
        sb.AppendLine($"dotnet_gc_collections{{arm=\"{armName}\",generation=\"{gen}\"}} {GC.CollectionCount(gen)}");

    // --- GC's own view of the ceiling. If TotalAvailableMemoryBytes reflects the host rather
    //     than the plan, the GC grows past the 8 GiB allocation and the kill has nothing to do
    //     with the SKU. ---
    var gc = GC.GetGCMemoryInfo();
    if (gc.Index > 0)   // Index 0 = no GC yet, struct not meaningful
    {
        G("dotnet_gc_total_available_bytes", "Memory the GC believes it may use", gc.TotalAvailableMemoryBytes);
        G("dotnet_gc_high_memory_threshold_bytes", "Load above which the GC gets aggressive", gc.HighMemoryLoadThresholdBytes);
        G("dotnet_gc_memory_load_bytes", "Current memory load as the GC sees it", gc.MemoryLoadBytes);
        G("dotnet_gc_committed_bytes", "Committed by the GC at last collection", gc.TotalCommittedBytes);
        G("dotnet_gc_heap_size_bytes", "Heap size at last collection", gc.HeapSizeBytes);
        G("dotnet_gc_fragmented_bytes", "Fragmentation at last collection", gc.FragmentedBytes);
        G("dotnet_gc_pinned_objects", "Pinned objects at last collection", gc.PinnedObjectsCount);

        // ReadOnlySpan: must copy out immediately, cannot be captured or held.
        var gens = gc.GenerationInfo.ToArray();
        var names = new[] { "gen0", "gen1", "gen2", "loh", "poh" };
        for (var i2 = 0; i2 < gens.Length && i2 < names.Length; i2++)
        {
            var gl = $"{{arm=\"{armName}\",generation=\"{names[i2]}\"}}";
            sb.AppendLine($"dotnet_gc_generation_size_bytes{gl} {gens[i2].SizeAfterBytes}");
            sb.AppendLine($"dotnet_gc_generation_fragmentation_bytes{gl} {gens[i2].FragmentationAfterBytes}");
        }
    }

    // --- cgroup limit. Absent or absurd means the GC is sizing to the host, and the premise
    //     does not hold. Reported so it is checkable. ---
    var cgroup = ReadCgroupMemoryLimit();
    if (cgroup is not null) G("container_memory_limit_bytes", "cgroup memory limit", cgroup.Value);

    return Results.Text(sb.ToString(), "text/plain; version=0.0.4; charset=utf-8");
});

app.Run();

// Invariant culture so a non-English locale cannot emit "1,5" and break the exposition format.
static string F(double d) => d.ToString("F3", System.Globalization.CultureInfo.InvariantCulture);

/// <summary>
/// Container memory ceiling. cgroup v2 first, then v1. A v1 value of 9223372036854771712 means
/// no limit: the GC then sizes to the host VM's RAM, not the App Service plan.
/// </summary>
static long? ReadCgroupMemoryLimit()
{
    foreach (var path in new[] { "/sys/fs/cgroup/memory.max",
                                 "/sys/fs/cgroup/memory/memory.limit_in_bytes" })
    {
        try
        {
            if (!File.Exists(path)) continue;
            var raw = File.ReadAllText(path).Trim();
            if (raw == "max") return null;                       // cgroup v2, unlimited
            if (long.TryParse(raw, out var v) && v > 0 && v < long.MaxValue / 2) return v;
        }
        catch { /* not readable in this sandbox; absence is the signal */ }
    }
    return null;
}

static bool Authorised(HttpContext ctx, string? token) =>
    string.IsNullOrEmpty(token) || ctx.Request.Headers.Authorization == $"Bearer {token}";

public sealed class WorkerService(
    TemporalRuntime runtime,
    TemporalConfig temporal,
    WorkerConfig workerCfg,
    IConfiguration cfg,
    ILogger<WorkerService> log) : BackgroundService
{
    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        var armName = cfg["ARM"] ?? "local";
        var cacheSize = int.Parse(cfg["MAX_CACHED_WORKFLOWS"] ?? "10000");
        var taskQueue = cfg["TASK_QUEUE"] ?? $"cache-test-{armName}";

        var client = await TemporalFactory.ConnectAsync(temporal, runtime, stoppingToken);
        log.LogInformation(
            "connected arm={Arm} cache={Cache} queue={Queue} ns={Ns}",
            armName, cacheSize, taskQueue, temporal.Namespace);

        using var worker = new TemporalWorker(client, new TemporalWorkerOptions(taskQueue)
        {
            MaxCachedWorkflows = cacheSize,
            MaxConcurrentWorkflowTasks = workerCfg.MaxConcurrentWorkflowTasks,
            MaxConcurrentActivities = workerCfg.MaxConcurrentActivities,
            MaxConcurrentWorkflowTaskPolls = workerCfg.MaxConcurrentWorkflowTaskPolls,
            GracefulShutdownTimeout = TimeSpan.FromSeconds(10),
        }
            .AddWorkflow<ResidentWorkflow>()
            .AddWorkflow<ChurnWorkflow>()
            .AddWorkflow<BallastWorkflow>()
            .AddAllActivities(new SleepActivities())
            .AddAllActivities(new BallastActivities()));

        await worker.ExecuteAsync(stoppingToken);
    }
}
