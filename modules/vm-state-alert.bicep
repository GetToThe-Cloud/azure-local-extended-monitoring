metadata description = 'Alerts on Azure Local VM state (power state, provisioning state, guest agent) via an Azure Resource Graph query in a log search alert with a system-assigned managed identity.'

@description('Name of the alert rule.')
param name string

@description('Location of the alert rule (region of the workspace).')
param location string

@description('Resource ID of the Log Analytics workspace (scope of the rule).')
param workspaceId string

@description('Resource ID of the action group.')
param actionGroupId string

@description('Resource groups that contain the Azure Local VMs.')
param resourceGroupNames string[]

@description('Power states that raise an alert.')
param alertPowerStates string[]

@description('Also alert when the guest agent is not Connected.')
param checkGuestAgent bool

@description('VM names to exclude.')
param excludedVmNames string[]

@description('Create the role assignments for the managed identity of the rule.')
param deployRoleAssignments bool

@description('Subscription of the cluster resource group.')
param clusterSubscriptionId string

@description('Resource group with the Azure Local VMs.')
param clusterResourceGroupName string

@description('Subscription of the workspace.')
param workspaceSubscriptionId string

@description('Resource group of the workspace.')
param workspaceResourceGroupName string

@description('Name of the workspace.')
param workspaceName string

@description('Tags.')
param tags object = {}

var readerRoleId = 'acdd72a7-3385-48ef-bd42-f606fba81ae7'
var logAnalyticsReaderRoleId = '73c42c96-874c-492b-b04d-ab87d138a893'

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
    type: 'SystemAssigned'
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
    // The managed identity gets its roles after the rule exists, and the deploying user may
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

// Reader on the VM resource group: Resource Graph only returns what the identity can read.
module clusterReader 'role-assignment-rg.bicep' = if (deployRoleAssignments) {
  name: take('ra-reader-${uniqueString(vmStateAlert.id)}', 64)
  scope: resourceGroup(clusterSubscriptionId, clusterResourceGroupName)
  params: {
    principalId: vmStateAlert.identity.principalId
    roleDefinitionId: readerRoleId
    assignmentDescription: 'Azure Local VM state alert: read VM resources via Resource Graph.'
  }
}

// Log Analytics Reader on the workspace: the rule runs its query through the workspace.
module workspaceReader 'role-assignment-workspace.bicep' = if (deployRoleAssignments) {
  name: take('ra-lareader-${uniqueString(vmStateAlert.id)}', 64)
  scope: resourceGroup(workspaceSubscriptionId, workspaceResourceGroupName)
  params: {
    workspaceName: workspaceName
    principalId: vmStateAlert.identity.principalId
    roleDefinitionId: logAnalyticsReaderRoleId
    assignmentDescription: 'Azure Local VM state alert: run log search alert queries.'
  }
}

@description('Principal ID of the managed identity of the alert rule.')
output principalId string = vmStateAlert.identity.principalId
