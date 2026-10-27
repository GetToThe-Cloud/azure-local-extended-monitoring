metadata description = 'Resource Health alert for the Arc resource bridge (and optionally other resource types) of Azure Local.'

@description('Name of the alert rule.')
param name string

@description('Scopes (resource group IDs) the alert covers.')
param scopes string[]

@description('Resource types to alert on, for example Microsoft.ResourceConnector/appliances.')
@minLength(1)
param resourceTypes string[]

@description('Resource ID of the action group.')
param actionGroupId string

@description('Tags.')
param tags object = {}

// The Arc resource bridge must not be offline for more than 45 days, after that its
// security key can expire and can no longer be refreshed.
resource resourceHealthAlert 'Microsoft.Insights/activityLogAlerts@2020-10-01' = {
  name: name
  location: 'global'
  tags: tags
  properties: {
    description: 'An Azure Local Arc resource bridge (or other listed resource) became unavailable or degraded. VM management from Azure is affected.'
    enabled: true
    scopes: scopes
    condition: {
      allOf: [
        {
          field: 'category'
          equals: 'ResourceHealth'
        }
        {
          anyOf: [
            for resourceType in resourceTypes: {
              field: 'resourceType'
              equals: resourceType
            }
          ]
        }
        {
          anyOf: [
            {
              field: 'properties.currentHealthStatus'
              equals: 'Unavailable'
            }
            {
              field: 'properties.currentHealthStatus'
              equals: 'Degraded'
            }
          ]
        }
        {
          field: 'status'
          equals: 'Active'
        }
      ]
    }
    actions: {
      actionGroups: [
        {
          actionGroupId: actionGroupId
        }
      ]
    }
  }
}
