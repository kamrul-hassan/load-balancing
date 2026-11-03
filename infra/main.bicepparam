using 'main.bicep'

param prefix = 'lblab'
param nodeVmSize = 'Standard_D2s_v5'
param nodeCountMin = 2
param nodeCountMax = 5
// Spread nodes across zones to see the load balancer fan out across datacenters.
// Southeast Asia supports zones 1-3. Set to [] in regions without zones.
param availabilityZones = [
  '1'
  '2'
  '3'
]
