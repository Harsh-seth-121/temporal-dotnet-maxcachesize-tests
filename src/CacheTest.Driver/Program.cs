using CacheTest.Driver;
using CacheTest.Core;
using Temporalio.Client;

var builder = WebApplication.CreateBuilder(args);
var cfg = builder.Configuration;

// Same config shape as the workers, so the arms it loads and the arms they serve cannot drift.
var configPath = cfg["CONFIG_PATH"] ?? "config/testconfig.json";
var testConfig = ConfigLoader.Load(configPath, cfg);

builder.Services.AddSingleton(testConfig);
builder.Services.AddSingleton<RunState>();
builder.Services.AddHostedService<DriverService>();
builder.Services.Configure<HostOptions>(o => o.ShutdownTimeout = TimeSpan.FromSeconds(20));

var app = builder.Build();

// Always On pings the root; it also doubles as the run status page.
app.MapGet("/", (RunState s, TestConfig c) => Results.Json(new
{
    profile = c.Profile,
    arms = c.Arms.Select(a => new { a.Name, a.TaskQueue, a.MaxCachedWorkflows }),
    s.Phase,
    s.StartedTotal,
    s.OpenEstimate,
    s.LastError,
    s.HaltReason,
}));

app.MapGet("/healthz", () => Results.Ok("ok"));

// Ends a run without redeploying: releases every resident workflow, stopping their timer
// Actions. Token-gated, because this is a public azurewebsites.net host and an unauthenticated
// kill switch there is an open invitation.
app.MapPost("/release", async (HttpContext ctx, TestConfig c, RunState s) =>
{
    var token = cfg["CONTROL_BEARER_TOKEN"] ?? cfg["METRICS_BEARER_TOKEN"];
    if (string.IsNullOrEmpty(token))
    {
        return Results.Problem("No CONTROL_BEARER_TOKEN configured; refusing to expose /release.",
                               statusCode: 503);
    }
    if (ctx.Request.Headers.Authorization != $"Bearer {token}") return Results.Unauthorized();

    var n = await Releaser.ReleaseAllAsync(c, s);
    return Results.Json(new { released = n });
});

app.Run();
