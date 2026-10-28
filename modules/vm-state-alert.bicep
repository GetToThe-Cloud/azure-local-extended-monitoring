metadata description = 'Alerts on Azure Local VM state (power state, provisioning state, guest agent) via an Azure Resource Graph query in a log search alert that runs as the shared alert identity (Reader on the cluster resource group, see main.bicep).'

@description('Name of the alert rule.')
param name string

@description('Location of the alert rule (region of the workspace).')
param location string

@description('Resource ID of the Log Analytics workspace (scope of the rule).')
param workspaceId string

@description('Resource ID of the action group.')
param actionGroupId string

@description('Resource ID of the user-assigned managed identity the rule runs its query with.')
param identityId string

@description('Resource groups that contain the Azure Local VMs.')
param resourceGroupNames string[]

@description('Power states that raise an alert.')
param alertPowerStates string[]

@description('Also alert when the guest agent is not Connected.')
param checkGuestAgent bool

@description('VM names to exclude.')
param excludedVmNames string[]

@description('Tags.')
param tags object = {}

var resourceGroupList = join(map(resourceGroupNames, rg => '\'${toLower(rg)}\''), ', ')
var powerStateList = join(map(alertPowerStates, s => '\'${s}\''), ', ')
var excludedList = join(map(excludedVmNames, v => '\'${toLower(v)}\''), ', ')

var queryTemplate = loadTextContent('../queries/vm-state.kql')
var queryStep1 = replace(queryTemplate, '{{RESOURCE_GROUPS}}', resourceGroupList)
var queryStep2 = replace(queryStep1, '{{POWER_STATES}}', powerStateList)
var queryStep3 = replace(queryStep2, '{{EXCLUDED_VMS}}', excludedList)
var query = replace(queryStep3, '{{CHECK_GUEST_AGENT}}', checkGuestAgent ? 'true' : 'false')

resource vmStateAlert 'Microsoft.Insights/scheduledQueryRules@2023-12-01' = {
  name: name
  location: location
  tags: tags
  kind: 'LogAlert'
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${identityId}': {}
    }
  }
  properties: {
    displayName: 'Azure Local - VM state'
    description: 'An Azure Local VM is in an unexpected power state, failed provisioning, or (optionally) has no connected guest agent.'
    severity: 2
    enabled: true
    scopes: [
      workspaceId
    ]
    evaluationFrequency: 'PT15M'
    windowSize: 'PT15M'
    autoMitigate: true
    // The alert identity may still be waiting for its role assignments, and the deploying user may
    // not see the VMs through Resource Graph, so skip validation at deployment time.
    skipQueryValidation: true
    criteria: {
      allOf: [
        {
          query: query
          timeAggregation: 'Count'
          operator: 'GreaterThan'
          threshold: 0
          dimensions: [
            {
              name: 'vmName'
              operator: 'Include'
              values: [
                '*'
              ]
            }
            {
              name: 'problem'
              operator: 'Include'
              values: [
                '*'
              ]
            }
          ]
          failingPeriods: {
            numberOfEvaluationPeriods: 1
            minFailingPeriodsToAlert: 1
          }
        }
      ]
    }
    actions: {
      actionGroups: [
        actionGroupId
      ]
    }
  }
}
