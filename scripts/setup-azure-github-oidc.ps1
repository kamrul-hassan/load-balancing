<#
.SYNOPSIS
  One-time setup: lets GitHub Actions sign in to Azure with OpenID Connect (no stored passwords).

.DESCRIPTION
  Creates the resource group, an Entra ID app registration + service principal, federated
  credentials for this repo (main branch, the 'production' environment and pull requests),
  and role assignments on the resource group. Then prints the GitHub secrets/variables to add,
  or sets them for you if the GitHub CLI (gh) is installed and signed in.

.EXAMPLE
  az login
  ./scripts/setup-azure-github-oidc.ps1 -GitHubRepo "kamrul/load-balancing" -ResourceGroup rg-lb-lab -Location southeastasia
#>
param(
    [Parameter(Mandatory)] [string] $GitHubRepo,          # owner/repo
    [string] $ResourceGroup = 'rg-lb-lab',
    [string] $Location = 'southeastasia',
    [string] $AppName = 'gh-load-balancing-lab',
    [string] $Prefix = 'lblab'
)

$ErrorActionPreference = 'Stop'

$subscriptionId = az account show --query id -o tsv
$tenantId       = az account show --query tenantId -o tsv
Write-Host "Subscription: $subscriptionId  Tenant: $tenantId" -ForegroundColor Cyan

az group create --name $ResourceGroup --location $Location --output none
$rgId = az group show --name $ResourceGroup --query id -o tsv

# App registration + service principal
$appId = az ad app list --display-name $AppName --query "[0].appId" -o tsv
if (-not $appId) {
    $appId = az ad app create --display-name $AppName --query appId -o tsv
    Write-Host "Created app registration $AppName ($appId)"
}
$spId = az ad sp list --filter "appId eq '$appId'" --query "[0].id" -o tsv
if (-not $spId) {
    $spId = az ad sp create --id $appId --query id -o tsv
}

# Federated credentials: which GitHub workflow runs may act as this identity.
$subjects = @{
    'main-branch' = "repo:${GitHubRepo}:ref:refs/heads/main"
    'production'  = "repo:${GitHubRepo}:environment:production"
    'pull-request'= "repo:${GitHubRepo}:pull_request"
}
$existing = az ad app federated-credential list --id $appId --query "[].name" -o tsv
foreach ($name in $subjects.Keys) {
    if ($existing -contains $name) { continue }
    $body = @{
        name      = $name
        issuer    = 'https://token.actions.githubusercontent.com'
        subject   = $subjects[$name]
        audiences = @('api://AzureADTokenExchange')
    } | ConvertTo-Json -Compress
    $tmp = New-TemporaryFile
    Set-Content -Path $tmp -Value $body -Encoding utf8
    az ad app federated-credential create --id $appId --parameters "@$tmp" --output none
    Remove-Item $tmp
    Write-Host "Federated credential: $name -> $($subjects[$name])"
}

# Roles, scoped to the lab resource group only:
#  - Contributor: create AKS/ACR, fetch cluster credentials
#  - Role Based Access Control Administrator: the Bicep template grants AcrPull to the AKS kubelet
#  - AcrPush: push images from CI
foreach ($role in @('Contributor', 'Role Based Access Control Administrator', 'AcrPush')) {
    az role assignment create --assignee-object-id $spId --assignee-principal-type ServicePrincipal `
        --role $role --scope $rgId --output none 2>$null
    Write-Host "Role '$role' on $ResourceGroup"
}

$secrets = [ordered]@{
    AZURE_CLIENT_ID       = $appId
    AZURE_TENANT_ID       = $tenantId
    AZURE_SUBSCRIPTION_ID = $subscriptionId
}
$variables = [ordered]@{
    AZURE_RESOURCE_GROUP = $ResourceGroup
    AZURE_LOCATION       = $Location
    AKS_CLUSTER_NAME     = "$Prefix-aks"
    # ACR_NAME is printed by the 'Infrastructure' workflow / Bicep output (it contains a unique suffix).
}

if (Get-Command gh -ErrorAction SilentlyContinue) {
    foreach ($k in $secrets.Keys)   { gh secret set $k --repo $GitHubRepo --body $secrets[$k] }
    foreach ($k in $variables.Keys) { gh variable set $k --repo $GitHubRepo --body $variables[$k] }
    Write-Host "`nGitHub secrets and variables set on $GitHubRepo." -ForegroundColor Green
} else {
    Write-Host "`nAdd these in GitHub -> Settings -> Secrets and variables -> Actions:" -ForegroundColor Yellow
    Write-Host "Secrets:";   $secrets.GetEnumerator()   | ForEach-Object { "  $($_.Key) = $($_.Value)" }
    Write-Host "Variables:"; $variables.GetEnumerator() | ForEach-Object { "  $($_.Key) = $($_.Value)" }
}
Write-Host "`nAlso create an environment named 'production' (Settings -> Environments) — add reviewers there if you want manual approval before deploys."
Write-Host "After running the Infrastructure workflow, set variable ACR_NAME to the 'acrName' output."
