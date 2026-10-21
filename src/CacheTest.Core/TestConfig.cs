namespace CacheTest.Core;

/// <summary>Root of config/testconfig.json. Also bindable from App Service app settings.</summary>
public sealed class TestConfig
{
    public TemporalConfig Temporal { get; set; } = new();
    public List<ArmConfig> Arms { get; set; } = new();
    public WorkerConfig Worker { get; set; } = new();

    /// <summary>Which entry of Profiles the driver runs.</summary>
    public string Profile { get; set; } = "smoke";
    public Dictionary<string, ProfileConfig> Profiles { get; set; } = new();

    public ProfileConfig ActiveProfile =>
        Profiles.TryGetValue(Profile, out var p)
            ? p
            : throw new InvalidOperationException(
                $"Profile '{Profile}' not found. Known: {string.Join(", ", Profiles.Keys)}");

    public ArmConfig Arm(string name) =>
        Arms.FirstOrDefault(a => a.Name == name)
        ?? throw new InvalidOperationException(
            $"Arm '{name}' not found. Known: {string.Join(", ", Arms.Select(a => a.Name))}");
}

public sealed class TemporalConfig
{
    public string Address { get; set; } = "localhost:7233";
    public string Namespace { get; set; } = "default";

    /// <summary>PEM file paths. Used locally; in Azure the B64 properties win.</summary>
    public string? ClientCertPath { get; set; }
    public string? ClientKeyPath { get; set; }

    /// <summary>Base64 PEM, injected as an App Service app setting. Never written to disk.</summary>
    public string? ClientCertB64 { get; set; }
    public string? ClientKeyB64 { get; set; }

    /// <summary>Namespace Actions-per-second ceiling. Preflight refuses to exceed 80% of it.</summary>
    public int ApsLimit { get; set; } = 500;

    public bool UsesTls =>
        !string.IsNullOrWhiteSpace(ClientCertB64) || !string.IsNullOrWhiteSpace(ClientCertPath);
}

public sealed class ArmConfig
{
    /// <summary>Short label: 10k, 8k, 6k, ctl. Becomes the `arm` metric tag.</summary>
    public string Name { get; set; } = "";
    public string TaskQueue { get; set; } = "";
    public int MaxCachedWorkflows { get; set; } = 10000;

    /// <summary>
    /// The positive-control arm, sized to thrash. Must be excluded from the divergence
    /// criterion or divergence fires instantly. A flag, not a cache-size threshold, so the
    /// logic survives a scaled-down local dry run.
    /// </summary>
    public bool IsControl { get; set; }
}

public sealed class WorkerConfig
{
    // Core rejects MaxCachedWorkflows > 0 unless these are >= 2. Validated below.
    public int MaxConcurrentWorkflowTasks { get; set; } = 200;
    public int MaxConcurrentActivities { get; set; } = 400;
    public int MaxConcurrentWorkflowTaskPolls { get; set; } = 10;
}

public sealed class ProfileConfig
{
    /// <summary>ramp | burst</summary>
    public string Kind { get; set; } = "ramp";

    // ramp
    public int TargetOpenPerQueue { get; set; }
    public double StartRatePerSecond { get; set; }
    public int HeartbeatIntervalSeconds { get; set; } = 300;
    public bool HaltOnDivergence { get; set; }

    // burst
    public int StartsPerMinute { get; set; }
    public int DurationMinutes { get; set; } = 30;

    // The memory lever. Each workflow retains BatchCount x BytesPerBatch in a field while
    // cached. Zero batches means the lightweight ResidentWorkflow.
    public int BatchCount { get; set; }
    public int BytesPerBatch { get; set; } = 80 * 1024;

    /// <summary>How long to hold the population after the ramp. 0 means hold indefinitely.</summary>
    public int HoldMinutes { get; set; }

    /// <summary>
    /// Terminate the population when the hold ends instead of leaving it heartbeating. Bounds
    /// the cost of an unwatched arm: ~8,191 workflows waking every HeartbeatIntervalSeconds is
    /// ~98,000 Actions an hour on nothing.
    /// </summary>
    public bool DrainAfterHold { get; set; }

    public bool UsesBallast => BatchCount > 0;
}
