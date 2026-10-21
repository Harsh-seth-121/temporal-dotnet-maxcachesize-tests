using Temporalio.Client;
using Temporalio.Runtime;

namespace CacheTest.Core;

public static class TemporalFactory
{
    /// <summary>
    /// Metrics live on the Runtime, not the client or worker, and GlobalTags is runtime-wide.
    /// One runtime per process means one set of tags per process, which is why each arm is its
    /// own App Service app.
    ///
    /// The exporter binds LOOPBACK: App Service routes only 80/443 to the app's single port and
    /// will not route this one, so the ASP.NET host re-serves /metrics there.
    ///
    /// HasCounterTotalSuffix and UseSecondsForDuration stay at their defaults (false, false).
    /// The upstream Temporal dashboard's PromQL wants no _total suffix and integer-millisecond
    /// histogram buckets.
    /// </summary>
    public static TemporalRuntime CreateRuntime(string promBindAddress, string arm, int cacheSize) =>
        new(new TemporalRuntimeOptions
        {
            Telemetry = new()
            {
                Metrics = new()
                {
                    Prometheus = new(promBindAddress),
                    GlobalTags = new Dictionary<string, string>
                    {
                        ["arm"] = arm,
                        ["cache_size"] = cacheSize.ToString(),
                    },
                },
            },
        });

    public static async Task<ITemporalClient> ConnectAsync(
        TemporalConfig cfg, TemporalRuntime? runtime, CancellationToken ct = default)
    {
        TlsOptions? tls = null;
        if (cfg.UsesTls)
        {
            // ClientCert / ClientPrivateKey are byte[] of PEM, not paths and not X509Certificate2.
            // In Azure these arrive base64 in app settings and never touch the filesystem.
            tls = new TlsOptions
            {
                ClientCert = await LoadPemAsync(cfg.ClientCertB64, cfg.ClientCertPath, "client cert", ct),
                ClientPrivateKey = await LoadPemAsync(cfg.ClientKeyB64, cfg.ClientKeyPath, "client key", ct),
            };
        }

        return await TemporalClient.ConnectAsync(new(cfg.Address)
        {
            Namespace = cfg.Namespace,
            Tls = tls,
            Runtime = runtime,
        });
    }

    private static IEnumerable<string> CandidatePaths(string path)
    {
        if (Path.IsPathRooted(path)) { yield return path; yield break; }
        yield return path;
        yield return Path.Combine(Directory.GetCurrentDirectory(), path);
        yield return Path.Combine(AppContext.BaseDirectory, path);
        // Walk up looking for the repo root, so `dotnet run` from a project dir still works.
        var dir = new DirectoryInfo(AppContext.BaseDirectory);
        for (var i = 0; i < 8 && dir is not null; i++, dir = dir.Parent)
        {
            if (Directory.Exists(Path.Combine(dir.FullName, "certs")))
            {
                yield return Path.Combine(dir.FullName, path);
                yield break;
            }
        }
    }

    private static async Task<byte[]> LoadPemAsync(
        string? b64, string? path, string what, CancellationToken ct)
    {
        if (!string.IsNullOrWhiteSpace(b64))
        {
            try { return Convert.FromBase64String(b64.Trim()); }
            catch (FormatException e)
            {
                throw new InvalidOperationException($"{what} base64 is malformed", e);
            }
        }
        if (!string.IsNullOrWhiteSpace(path))
        {
            // A relative path resolves against the host content root: the project directory
            // under `dotnet run`, the publish directory in Azure. Neither is the repo root where
            // certs/ lives. Try each plausible root, and on failure name all of them.
            var tried = new List<string>();
            foreach (var candidate in CandidatePaths(path))
            {
                tried.Add(candidate);
                if (File.Exists(candidate)) return await File.ReadAllBytesAsync(candidate, ct);
            }
            throw new FileNotFoundException(
                $"{what} not found. Tried:{Environment.NewLine}  "
                + string.Join(Environment.NewLine + "  ", tried)
                + $"{Environment.NewLine}Certs are gitignored; place yours in certs/.", path);
        }
        throw new InvalidOperationException($"No {what} configured (neither B64 nor path).");
    }
}
