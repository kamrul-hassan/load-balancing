// Azure infrastructure for the load-balancing lab:
//   - Azure Container Registry (images pushed by GitHub Actions)
//   - AKS cluster with Standard Load Balancer, Azure CNI Overlay, cluster autoscaler,
//     application routing add-on (managed ingress-nginx) and OIDC issuer
//   - AcrPull role for the cluster's kubelet identity
//
// Deploy:
//   az group create -n rg-lb-lab -l southeastasia
//   az deployment group create -g rg-lb-lab -f infra/main.bicep -p infra/main.bicepparam

targetScope = 'resourceGroup'

@description('Short prefix for resource names (lowercase letters/digits).')
@minLength(3)
@maxLength(12)
param prefix string = 'lblab'

param location string = resourceGroup().location

@description('Kubernetes version. Leave empty to use the AKS default for the region.')
param kubernetesVersion string = ''

@description('VM size for the node pool. Standard_D2s_v5 = 2 vCPU / 8 GiB.')
param nodeVmSize string = 'Standard_D2s_v5'

@minValue(1)
param nodeCountMin int = 2

@minValue(1)
param nodeCountMax int = 5

@description('Availability zones for the node pool, e.g. [\'1\',\'2\',\'3\']. Empty = no zones (cheaper, not all regions support zones).')
param availabilityZones array = []

param tags object = {
  project: 'load-balancing-lab'
}

var suffix = uniqueString(resourceGroup().id)
var acrName = toLower('${prefix}acr${suffix}')
var aksName = '${prefix}-aks'

resource acr 'Microsoft.ContainerRegistry/registries@2023-07-01' = {
  name: acrName
  location: location
  tags: tags
  sku: {
    name: 'Basic'
  }
  properties: {
    adminUserEnabled: false
  }
}

resource aks 'Microsoft.ContainerService/managedClusters@2024-09-01' = {
  name: aksName
  location: location
  tags: tags
  sku: {
    name: 'Base'
    tier: 'Free'
  }
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    dnsPrefix: aksName
    kubernetesVersion: empty(kubernetesVersion) ? null : kubernetesVersion
    enableRBAC: true
    agentPoolProfiles: [
      {
        name: 'system'
        mode: 'System'
        vmSize: nodeVmSize
        osType: 'Linux'
        osSKU: 'AzureLinux'
        type: 'VirtualMachineScaleSets'
        count: nodeCountMin
        minCount: nodeCountMin
        maxCount: nodeCountMax
        enableAutoScaling: true
        availabilityZones: empty(availabilityZones) ? null : availabilityZones
        maxPods: 60
      }
    ]
    networkProfile: {
      networkPlugin: 'azure'
      networkPluginMode: 'overlay'
      podCidr: '10.244.0.0/16'
      serviceCidr: '10.0.0.0/16'
      dnsServiceIP: '10.0.0.10'
      loadBalancerSku: 'standard'
      outboundType: 'loadBalancer'
    }
    ingressProfile: {
      webAppRouting: {
        enabled: true
      }
    }
    oidcIssuerProfile: {
      enabled: true
    }
    securityProfile: {
      workloadIdentity: {
        enabled: true
      }
    }
    autoUpgradeProfile: {
      upgradeChannel: 'patch'
    }
  }
}

// Built-in role: AcrPull
var acrPullRoleId = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '7f951dda-4ed3-4680-a7ca-43fe172d538d')

resource kubeletAcrPull 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(acr.id, aks.id, acrPullRoleId)
  scope: acr
  properties: {
    roleDefinitionId: acrPullRoleId
    principalId: aks.properties.identityProfile.kubeletidentity.objectId
    principalType: 'ServicePrincipal'
  }
}

output acrName string = acr.name
output acrLoginServer string = acr.properties.loginServer
output aksName string = aks.name
output aksNodeResourceGroup string = aks.properties.nodeResourceGroup
output oidcIssuerUrl string = aks.properties.oidcIssuerProfile.issuerURL
