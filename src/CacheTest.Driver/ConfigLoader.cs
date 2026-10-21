using Temporalio.Client;
using System.Text.Json;
using CacheTest.Core;

namespace CacheTest.Driver;

public static class ConfigLoader
{
    private static readonly JsonSerializerOptions Json = new(JsonSerializerDefaults.Web);

    /// <summary>
    /// Loads the JSON config, then lets environment variables override connection and profile.
    /// On App Service the JSON ships in the zip and secrets arrive as app settings, so neither
    /// has to contain the other.
    /// </summary>
    public static TestConfig Load(string path, IConfiguration env)
    {
        TestConfig cfg;
        if (File.Exists(path))
        {
            cfg = JsonSerializer.Deserialize<TestConfig>(File.ReadAllText(path), Json)
                  ?? throw new InvalidOperationException($"{path} parsed to null");
        }
        else
        {
            var alt = Path.Combine(AppContext.BaseDirectory, path);
            if (!File.Exists(alt))
            {
                throw new FileNotFoundException(
                    $"Config not found at '{path}' or '{alt}'. Copy config/testconfig.sample.json "
                    + "to config/testconfig.json and fill it in.", path);
            }
            cfg = JsonSerializer.Deserialize<TestConfig>(File.ReadAllText(alt), Json)!;
        }

        Override(env["TEMPORAL_ADDRESS"], v => cfg.Temporal.Address = v);
        Override(env["TEMPORAL_NAMESPACE"], v => cfg.Temporal.Namespace = v);
        Override(env["TEMPORAL_CLIENT_CERT_B64"], v => cfg.Temporal.ClientCertB64 = v);
        Override(env["TEMPORAL_CLIENT_KEY_B64"], v => cfg.Temporal.ClientKeyB64 = v);
        Override(env["PROFILE"], v => cfg.Profile = v);
        if (int.TryParse(env["APS_LIMIT"], out var aps)) cfg.Temporal.ApsLimit = aps;

        // ARMS picks a subset by name, comma separated, so a two-arm rerun needs no second
        // config file. Editing the arm list in the config instead once left a driver with a
        // stale single-arm list ramping 3,074 workflows onto a queue nobody polled.
        var pick = env["ARMS"];
        if (!string.IsNullOrWhiteSpace(pick))
        {
            var want = pick.Split([',', ' '], StringSplitOptions.RemoveEmptyEntries
                                             | StringSplitOptions.TrimEntries);
            var missing = want.Where(w => !cfg.Arms.Any(
                a => a.Name.Equals(w, StringComparison.OrdinalIgnoreCase))).ToList();
            if (missing.Count > 0)
            {
                throw new InvalidOperationException(
                    "ARMS names arms that are not configured: " + string.Join(", ", missing)
                    + ". Known: " + string.Join(", ", cfg.Arms.Select(a => a.Name)));
            }
            cfg.Arms = cfg.Arms.Where(
                a => want.Contains(a.Name, StringComparer.OrdinalIgnoreCase)).ToList();
        }

        if (cfg.Arms.Count == 0) throw new InvalidOperationException("No arms configured.");
        var dupes = cfg.Arms.GroupBy(a => a.TaskQueue).Where(g => g.Count() > 1).ToList();
        if (dupes.Count > 0)
        {
            // temporal_sticky_cache_size carries no worker identity, so two arms on one queue
            // publish to the same series and clobber each other.
            throw new InvalidOperationException(
                "Arms must have distinct task queues; duplicated: "
                + string.Join(", ", dupes.Select(d => d.Key)));
        }
        return cfg;
    }

    private static void Override(string? value, Action<string> set)
    {
        if (!string.IsNullOrWhiteSpace(value)) set(value);
    }
}

/// <summary>Live state, surfaced on GET / so a run can be checked without reading logs.</summary>
public sealed class RunState
{
    public string Phase { get; set; } = "starting";
    public int StartedTotal;
    public int OpenEstimate;
    public string? LastError { get; set; }
    public string? HaltReason { get; set; }
    public ITemporalClient? Client { get; set; }
    public List<string> ResidentIds { get; } = new();
}
