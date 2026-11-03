using System.Net;
using System.Net.Http.Json;
using Microsoft.AspNetCore.Hosting;
using Microsoft.AspNetCore.Mvc.Testing;

namespace LoadBalancing.Api.Tests;

public sealed class ApiTests(ApiFactory factory) : IClassFixture<ApiFactory>
{
    private readonly HttpClient _client = factory.CreateClient();

    [Fact]
    public async Task WhoAmI_returns_pod_identity_and_headers()
    {
        var response = await _client.GetAsync("/api/whoami");

        response.EnsureSuccessStatusCode();
        var body = await response.Content.ReadFromJsonAsync<WhoAmIResponse>();
        Assert.NotNull(body);
        Assert.Equal("test-pod", body.PodName);
        Assert.Equal("test-node", body.NodeName);
        Assert.True(body.RequestNumber >= 1);
        Assert.Equal("test-pod", response.Headers.GetValues("X-Served-By").Single());
    }

    [Fact]
    public async Task WhoAmI_increments_request_counter()
    {
        var first = await _client.GetFromJsonAsync<WhoAmIResponse>("/api/whoami");
        var second = await _client.GetFromJsonAsync<WhoAmIResponse>("/api/whoami");

        Assert.True(second!.RequestNumber > first!.RequestNumber);
        Assert.Equal(first.InstanceId, second.InstanceId);
    }

    [Theory]
    [InlineData(10, 10)]
    [InlineData(0, 1)]
    [InlineData(-50, 1)]
    public async Task Work_clamps_duration(int requested, int expected)
    {
        var body = await _client.GetFromJsonAsync<WorkResponse>($"/api/work?ms={requested}");
        Assert.Equal(expected, body!.RequestedMs);
        Assert.True(body.ElapsedMs >= expected);
    }

    [Fact]
    public async Task Live_probe_is_healthy()
    {
        var response = await _client.GetAsync("/health/live");
        Assert.Equal(HttpStatusCode.OK, response.StatusCode);
    }
}

/// <summary>Readiness toggling mutates singleton state, so it gets its own factory.</summary>
public sealed class ReadinessTests(ApiFactory factory) : IClassFixture<ApiFactory>
{
    [Fact]
    public async Task Readiness_can_be_toggled_off_and_on()
    {
        var client = factory.CreateClient();

        Assert.Equal(HttpStatusCode.OK, (await client.GetAsync("/health/ready")).StatusCode);

        (await client.PostAsync("/api/admin/ready/false", null)).EnsureSuccessStatusCode();
        Assert.Equal(HttpStatusCode.ServiceUnavailable, (await client.GetAsync("/health/ready")).StatusCode);
        // Liveness must stay green, otherwise Kubernetes would restart the pod instead of draining it.
        Assert.Equal(HttpStatusCode.OK, (await client.GetAsync("/health/live")).StatusCode);

        (await client.PostAsync("/api/admin/ready/true", null)).EnsureSuccessStatusCode();
        Assert.Equal(HttpStatusCode.OK, (await client.GetAsync("/health/ready")).StatusCode);
    }
}

public sealed class ApiFactory : WebApplicationFactory<Program>
{
    protected override void ConfigureWebHost(IWebHostBuilder builder)
    {
        builder.UseSetting("POD_NAME", "test-pod");
        builder.UseSetting("NODE_NAME", "test-node");
    }
}
