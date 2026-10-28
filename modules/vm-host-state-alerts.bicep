metadata description = 'Hyper-V VM state alerts on the Azure Local hosts, for all VMs (Azure Local VMs and unmanaged Hyper-V VMs).'

@description('Prefix for resource names.')
param namePrefix string

@description('Location of the alert rules (region of the workspace).')
param location string

@description('Resource ID of the Log Analytics workspace.')
param workspaceId string

@description('Resource ID of the action group.')
param actionGroupId string

@description('Resource ID of the user-assigned managed identity the rule runs its query with.')
param identityId string

@description('Arc machine names (host names) of all nodes.')
param nodeNames string[]

@description('Deploy the alert on SDDC Management event 3000 (VM state counts per node).')
param deploySddcAlert bool

@description('Count transitional states in the SDDC alert.')
param includeTransitional bool

@description('Deploy the alerts on the events of Watch-AzLocalVmState.ps1.')
param deployScriptAlerts bool

@description('Event source of Watch-AzLocalVmState.ps1.')
param eventSource string

@description('Minutes without a run of the script on a node before alerting.')
param scriptMaxSilenceMinutes int

@description('Tags.')
param tags object = {}

var nodeList = join(map(nodeNames, n => '\'${toLower(n)}\''), ', ')

var sddcQuery = replace(loadTextContent('../queries/vm-host-state-sddc.kql'), '{{INCLUDE_TRANSITIONAL}}', includeTransitional ? 'true' : 'false')
var scriptQuery = replace(loadTextContent('../queries/vm-host-state-script.kql'), '{{EVENT_SOURCE}}', eventSource)
var scriptRunQueryStep1 = replace(loadTextContent('../queries/vm-host-state-script-heartbeat.kql'), '{{EVENT_SOURCE}}', eventSource)
var scriptRunQuery = replace(scriptRunQueryStep1, '{{NODE_NAMES}}', nodeList)

// 1. No installation needed: Insights already collects SDDC Management event 3000, which
//    contains VM state counts per node. No VM names, and as fresh as the SDDC cache dump
//    interval (default 60 minutes, 15 minutes after Set-AzLocalHealthSettings.ps1).
resource sddcAlert 'Microsoft.Insights/scheduledQueryRules@2023-12-01' = if (deploySddcAlert) {
  name: '${namePrefix}-vm-host-state-counts'
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
    displayName: 'Azure Local - VMs in abnormal state (per node)'
    description: 'One or more VMs on an Azure Local node are Failed, Paused, Suspended/Saved or Unknown according to the latest SDDC Management snapshot (event 3000).'
    severity: 2
    enabled: true
    scopes: [
      workspaceId
    ]
    evaluationFrequency: 'PT15M'
    // Wide window so the latest snapshot is always included, also with the default 60 minute interval.
    windowSize: 'PT2H'
    autoMitigate: true
    // Skips only the query syntax check. The service still checks the identity's access to the
    // workspace when the rule is saved, which is why Deploy-AzLocalMonitoring.ps1 creates the
    // identity and its roles first and deploys the rules after the roles have propagated.
    skipQueryValidation: true
    criteria: {
      allOf: [
        {
          query: sddcQuery
          timeAggregation: 'Maximum'
          metricMeasureColumn: 'ProblemVmCount'
          operator: 'GreaterThan'
          threshold: 0
          dimensions: [
            {
              name: 'NodeName'
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

// 2. Per VM, with name: events 4101 from Watch-AzLocalVmState.ps1 (clustered scheduled task).
resource scriptVmAlert 'Microsoft.Insights/scheduledQueryRules@2023-12-01' = if (deployScriptAlerts) {
  name: '${namePrefix}-vm-host-state'
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
    displayName: 'Azure Local - VM not Running or Off'
    description: 'A VM on Azure Local is in a state other than Running or Off (for example Paused, PausedCritical, Saved, Starting/Stopping for too long) or its cluster role is Failed, PartialOnline or Pending.'
    severity: 2
    enabled: true
    scopes: [
      workspaceId
    ]
    evaluationFrequency: 'PT5M'
    windowSize: 'PT15M'
    autoMitigate: true
    // Skips only the query syntax check. The service still checks the identity's access to the
    // workspace when the rule is saved, which is why Deploy-AzLocalMonitoring.ps1 creates the
    // identity and its roles first and deploys the rules after the roles have propagated.
    skipQueryValidation: true
    criteria: {
      allOf: [
        {
          query: scriptQuery
          timeAggregation: 'Count'
          operator: 'GreaterThan'
          threshold: 0
          dimensions: [
            {
              name: 'VmName'
              operator: 'Include'
              values: [
                '*'
              ]
            }
            {
              name: 'Problem'
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

// 3. Watchdog: the script must report (event 4100) on every node, otherwise VM problems go unnoticed.
resource scriptRunAlert 'Microsoft.Insights/scheduledQueryRules@2023-12-01' = if (deployScriptAlerts) {
  name: '${namePrefix}-vm-state-monitor-not-running'
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
    displayName: 'Azure Local - VM state monitor not running'
    description: 'Watch-AzLocalVmState.ps1 has not reported for more than ${scriptMaxSilenceMinutes} minutes on a node (task not installed, disabled, failing, or node down).'
    severity: 3
    enabled: true
    scopes: [
      workspaceId
    ]
    evaluationFrequency: 'PT15M'
    windowSize: 'PT1H'
    autoMitigate: true
    // Skips only the query syntax check. The service still checks the identity's access to the
    // workspace when the rule is saved, which is why Deploy-AzLocalMonitoring.ps1 creates the
    // identity and its roles first and deploys the rules after the roles have propagated.
    skipQueryValidation: true
    criteria: {
      allOf: [
        {
          query: scriptRunQuery
          timeAggregation: 'Maximum'
          metricMeasureColumn: 'MinutesSinceLastRun'
          operator: 'GreaterThan'
          threshold: scriptMaxSilenceMinutes
          dimensions: [
            {
              name: 'NodeName'
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
