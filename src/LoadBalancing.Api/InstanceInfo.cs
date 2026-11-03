using System.Diagnostics;
using System.Reflection;

namespace LoadBalancing.Api;

/// <summary>
/// Identity of the process serving requests. In Kubernetes the POD_NAME / NODE_NAME / POD_IP
/// variables are injected through the Downward API, so each replica reports who it is.
/// </summary>
public sealed class InstanceInfo
{
    private long _requestCount;
    private readonly Stopwatch _uptime = Stopwatch.StartNew();

    public InstanceInfo(IConfiguration config)
    {
        InstanceId = Guid.NewGuid().ToString("N")[..8];
        PodName = config["POD_NAME"] ?? Environment.MachineName;
        NodeName = config["NODE_NAME"] ?? "local";
        PodIp = config["POD_IP"] ?? "n/a";
        Zone = config["NODE_ZONE"] ?? "n/a";
        Region = config["AZURE_REGION"] ?? "local";
        Version = config["APP_VERSION"]
            ?? Assembly.GetExecutingAssembly()
                .GetCustomAttribute<AssemblyInformationalVersionAttribute>()?.InformationalVersion
            ?? "dev";
        StartedAtUtc = DateTimeOffset.UtcNow;
    }

    public string InstanceId { get; }
    public string PodName { get; }
    public string NodeName { get; }
    public string PodIp { get; }
    public string Zone { get; }
    public string Region { get; }
    public string Version { get; }
    public DateTimeOffset StartedAtUtc { get; }
    public TimeSpan Uptime => _uptime.Elapsed;
    public long RequestCount => Interlocked.Read(ref _requestCount);

    /// <summary>Readiness flag. Flip it off to watch the load balancer drain this instance.</summary>
    public volatile bool IsReady = true;

    public long IncrementRequests() => Interlocked.Increment(ref _requestCount);
}

public sealed record WhoAmIResponse(
    string InstanceId,
    string PodName,
    string NodeName,
    string PodIp,
    string Zone,
    string Region,
    string Version,
    long RequestNumber,
    double UptimeSeconds,
    DateTimeOffset ServedAtUtc,
    string? ClientIp,
    string? ForwardedFor);

public sealed record WorkResponse(string PodName, string InstanceId, int RequestedMs, double ElapsedMs, long Iterations);

public sealed record ReadinessResponse(string PodName, bool Ready);
