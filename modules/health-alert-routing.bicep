metadata description = 'Alert processing rules: route Azure Local health alerts and cluster metric alerts to an action group, and optionally suppress notifications during a weekly maintenance window.'

@description('Prefix for resource names.')
param namePrefix string

@description('Resource IDs of the Azure Local clusters.')
param clusterIds string[]

@description('Resource ID of the resource group with the clusters, nodes, VMs and Arc resource bridges.')
param clusterResourceGroupId string

@description('Resource ID of the Log Analytics workspace (target of the log search alerts).')
param workspaceId string

@description('Resource ID of the action group.')
param actionGroupId string

@description('Severities that are routed (Sev0..Sev4).')
param routedSeverities string[]

@description('Optional weekly maintenance window: { timeZone, daysOfWeek, startTime, endTime }.')
param maintenanceWindow object?

@description('Tags.')
param tags object = {}

var hasMaintenanceWindow = maintenanceWindow != null

var maintenanceSchedule = {
  timeZone: maintenanceWindow.?timeZone ?? 'UTC'
  recurrences: [
    {
      recurrenceType: 'Weekly'
      daysOfWeek: maintenanceWindow.?daysOfWeek ?? [
        'Sunday'
      ]
      startTime: maintenanceWindow.?startTime ?? '00:00:00'
      endTime: maintenanceWindow.?endTime ?? '00:00:00'
    }
  ]
}

// Health alerts (AzureEdgeAlerts) have no alert rule of their own, so the only way to
// notify on them is an alert processing rule scoped to the cluster resources.
// The cluster metric alert rules in this template deliberately have no action group,
// so they are routed by this same rule and nobody gets duplicate notifications.
resource clusterRouting 'Microsoft.AlertsManagement/actionRules@2021-08-08' = {
  name: '${namePrefix}-apr-cluster-routing'
  location: 'global'
  tags: tags
  properties: {
    description: 'Routes Azure Local health alerts and cluster metric alerts to the operations action group.'
    enabled: true
    scopes: clusterIds
    conditions: [
      {
        field: 'Severity'
        operator: 'Equals'
        values: routedSeverities
      }
    ]
    actions: [
      {
        actionType: 'AddActionGroups'
        actionGroupIds: [
          actionGroupId
        ]
      }
    ]
  }
}

// Maintenance window: RemoveAllActionGroups wins over AddActionGroups and over action
// groups configured on the alert rules themselves. Alerts are still created, only the
// notifications are suppressed.
resource maintenanceClusterScope 'Microsoft.AlertsManagement/actionRules@2021-08-08' = if (hasMaintenanceWindow) {
  name: '${namePrefix}-apr-maintenance-cluster'
  location: 'global'
  tags: tags
  properties: {
    description: 'Suppresses notifications for alerts on Azure Local resources during the planned maintenance window.'
    enabled: true
    scopes: [
      clusterResourceGroupId
    ]
    actions: [
      {
        actionType: 'RemoveAllActionGroups'
      }
    ]
    schedule: maintenanceSchedule
  }
}

// The workspace is usually shared, so only suppress the log search alerts of this template.
resource maintenanceWorkspaceScope 'Microsoft.AlertsManagement/actionRules@2021-08-08' = if (hasMaintenanceWindow) {
  name: '${namePrefix}-apr-maintenance-workspace'
  location: 'global'
  tags: tags
  properties: {
    description: 'Suppresses notifications for the Azure Local log search alerts during the planned maintenance window.'
    enabled: true
    scopes: [
      workspaceId
    ]
    conditions: [
      {
        field: 'AlertRuleName'
        operator: 'Contains'
        values: [
          '${namePrefix}-'
        ]
      }
    ]
    actions: [
      {
        actionType: 'RemoveAllActionGroups'
      }
    ]
    schedule: maintenanceSchedule
  }
}
