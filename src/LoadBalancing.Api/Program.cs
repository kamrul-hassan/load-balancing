using System.Diagnostics;
using System.Text.Json;
using System.Text.Json.Serialization;
using LoadBalancing.Api;
using Microsoft.AspNetCore.HttpOverrides;
using Microsoft.Extensions.Diagnostics.HealthChecks;

var builder = WebApplication.CreateSlimBuilder(args);

builder.Services.ConfigureHttpJsonOptions(o =>
    o.SerializerOptions.TypeInfoResolverChain.Insert(0, AppJsonContext.Default));

builder.Services.AddSingleton<InstanceInfo>();

// Behind Azure Load Balancer / ingress-nginx the real client IP arrives in X-Forwarded-For.
builder.Services.Configure<ForwardedHeadersOptions>(o =>
{
    o.ForwardedHeaders = ForwardedHeaders.XForwardedFor | ForwardedHeaders.XForwardedProto;
    o.KnownIPNetworks.Clear();
    o.KnownProxies.Clear();
});

builder.Services.AddHealthChecks()
    .AddCheck("self", () => HealthCheckResult.Healthy(), tags: ["live"])
    .AddCheck<ReadinessHealthCheck>("ready", tags: ["ready"]);

const string CorsPolicy = "frontend";
builder.Services.AddCors(o => o.AddPolicy(CorsPolicy, p =>
{
    var origins = builder.Configuration.GetSection("Cors:AllowedOrigins").Get<string[]>() ?? [];
    if (origins.Length == 0) p.AllowAnyOrigin(); else p.WithOrigins(origins);
    p.AllowAnyHeader().AllowAnyMethod();
}));

var app = builder.Build();

app.UseForwardedHeaders();
app.UseCors(CorsPolicy);

var instance = app.Services.GetRequiredService<InstanceInfo>();

// Every response says which replica produced it, handy with curl -i.
app.Use(async (ctx, next) =>
{
    ctx.Response.Headers["X-Served-By"] = instance.PodName;
    ctx.Response.Headers["X-Instance-Id"] = instance.InstanceId;
    await next();
});

var api = app.MapGroup("/api");

api.MapGet("/whoami", (HttpContext ctx, InstanceInfo info) =>
{
    var n = info.IncrementRequests();
    return TypedResults.Ok(new WhoAmIResponse(
        info.InstanceId, info.PodName, info.NodeName, info.PodIp, info.Zone, info.Region, info.Version,
        n, Math.Round(info.Uptime.TotalSeconds, 1), DateTimeOffset.UtcNow,
        ctx.Connection.RemoteIpAddress?.ToString(),
        ctx.Request.Headers["X-Original-Forwarded-For"].FirstOrDefault()
            ?? ctx.Request.Headers["X-Forwarded-For"].FirstOrDefault()));
});

// CPU-bound endpoint: use it to drive the Horizontal Pod Autoscaler.
api.MapGet("/work", (int? ms, InstanceInfo info) =>
{
    var target = Math.Clamp(ms ?? 200, 1, 5000);
    info.IncrementRequests();
    var sw = Stopwatch.StartNew();
    long iterations = 0;
    double x = 0;
    while (sw.ElapsedMilliseconds < target)
    {
        x += Math.Sqrt(iterations++ % 1000 + x % 7);
    }
    GC.KeepAlive(x);
    return TypedResults.Ok(new WorkResponse(info.PodName, info.InstanceId, target, sw.Elapsed.TotalMilliseconds, iterations));
});

// Simulated slow I/O (non-blocking) – shows how a load balancer spreads concurrent connections.
api.MapGet("/delay", async (int? ms, InstanceInfo info, CancellationToken ct) =>
{
    var target = Math.Clamp(ms ?? 500, 1, 30000);
    info.IncrementRequests();
    var sw = Stopwatch.StartNew();
    await Task.Delay(target, ct);
    return TypedResults.Ok(new WorkResponse(info.PodName, info.InstanceId, target, sw.Elapsed.TotalMilliseconds, 0));
});

// Toggle this replica's readiness so Kubernetes removes it from the Service endpoints.
var admin = api.MapGroup("/admin");
admin.MapPost("/ready/{state:bool}", (bool state, InstanceInfo info) =>
{
    info.IsReady = state;
    return TypedResults.Ok(new ReadinessResponse(info.PodName, info.IsReady));
});
admin.MapGet("/ready", (InstanceInfo info) => TypedResults.Ok(new ReadinessResponse(info.PodName, info.IsReady)));

app.MapHealthChecks("/health/live", new() { Predicate = c => c.Tags.Contains("live") });
app.MapHealthChecks("/health/ready", new() { Predicate = c => c.Tags.Contains("ready") });

app.MapGet("/", (InstanceInfo info) => TypedResults.Text($"LoadBalancing.Api {info.Version} on {info.PodName}"));

app.Run();

internal sealed class ReadinessHealthCheck(InstanceInfo info) : IHealthCheck
{
    public Task<HealthCheckResult> CheckHealthAsync(HealthCheckContext context, CancellationToken cancellationToken = default) =>
        Task.FromResult(info.IsReady
            ? HealthCheckResult.Healthy()
            : HealthCheckResult.Unhealthy("Readiness manually disabled via /api/admin/ready/false"));
}

[JsonSourceGenerationOptions(JsonSerializerDefaults.Web)]
[JsonSerializable(typeof(WhoAmIResponse))]
[JsonSerializable(typeof(WorkResponse))]
[JsonSerializable(typeof(ReadinessResponse))]
internal partial class AppJsonContext : JsonSerializerContext;

public partial class Program;
