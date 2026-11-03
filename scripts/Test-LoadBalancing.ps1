<#
.SYNOPSIS
  Quick load-balancing check from Windows: fire N requests and count which replica answered.

.EXAMPLE
  ./scripts/Test-LoadBalancing.ps1 -Url http://localhost:8080 -Requests 200
  ./scripts/Test-LoadBalancing.ps1 -Url http://<azure-lb-ip> -Requests 500 -Parallel 20
  ./scripts/Test-LoadBalancing.ps1 -Url http://<ip> -KeepAlive   # reuse one connection: watch L4 stickiness
#>
param(
    [string] $Url = 'http://localhost:8080',
    [int]    $Requests = 200,
    [int]    $Parallel = 10,
    [switch] $KeepAlive
)

$ErrorActionPreference = 'Stop'
$endpoint = "$($Url.TrimEnd('/'))/api/whoami"
Write-Host "GET $endpoint  x$Requests  (parallel $Parallel, keep-alive: $($KeepAlive.IsPresent))" -ForegroundColor Cyan

$sw = [Diagnostics.Stopwatch]::StartNew()

if ($KeepAlive) {
    # One HttpClient = pooled keep-alive connections. Behind a pure L4 balancer most requests stick to one pod.
    $client = [System.Net.Http.HttpClient]::new()
    $results = 1..$Requests | ForEach-Object {
        try {
            $r = $client.GetAsync($endpoint).GetAwaiter().GetResult()
            ($r.Content.ReadAsStringAsync().GetAwaiter().GetResult() | ConvertFrom-Json).podName
        } catch { 'ERROR' }
    }
} else {
    $results = 1..$Requests | ForEach-Object -ThrottleLimit $Parallel -Parallel {
        try {
            (Invoke-RestMethod -Uri $using:endpoint -DisableKeepAlive -TimeoutSec 10).podName
        } catch { 'ERROR' }
    }
}

$sw.Stop()
$groups = $results | Group-Object | Sort-Object Name
$max = ($groups | Measure-Object Count -Maximum).Maximum

foreach ($g in $groups) {
    $pct = [math]::Round(100 * $g.Count / $Requests, 1)
    $bar = '#' * [math]::Max(1, [int](40 * $g.Count / $max))
    $color = if ($g.Name -eq 'ERROR') { 'Red' } else { 'Green' }
    Write-Host ('{0,-40} {1,6} {2,6}%  {3}' -f $g.Name, $g.Count, $pct, $bar) -ForegroundColor $color
}
Write-Host ("`n{0} replicas, {1:N1} req/s" -f ($groups | Where-Object Name -ne 'ERROR').Count, ($Requests / $sw.Elapsed.TotalSeconds))
# Requires PowerShell 7+ (ForEach-Object -Parallel). Install: winget install Microsoft.PowerShell
