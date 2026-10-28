using './main.bicep'

// ---------------------------------------------------------------------------
// Example values - replace before deploying
// ---------------------------------------------------------------------------

param namePrefix = 'azl'

// Workspace that Insights for Azure Local uses (DCR name starts with AzureStackHCI-)
param workspaceResourceId = '/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-monitoring/providers/Microsoft.OperationalInsights/workspaces/law-azurelocal'

// Resource group with the cluster, the node Arc machines, the Azure Local VMs and the Arc resource bridge
param clusterResourceGroupName = 'rg-azurelocal-prod'

param clusters = [
  {
    name: 'azl-clus01'
    nodeNames: [
      'azl-node01'
      'azl-node02'
    ]
  }
]

param emailReceivers = [
  {
    name: 'Operations'
    emailAddress: 'ops@contoso.com'
  }
]

param actionGroupShortName = 'AzLocalOps'

// Patch night: Sunday 01:00-05:00. Remove this parameter to disable suppression.
param maintenanceWindow = {
  timeZone: 'W. Europe Standard Time'
  daysOfWeek: [
    'Sunday'
  ]
  startTime: '01:00:00'
  endTime: '05:00:00'
}

param thresholds = {
  cpuPercent: 85
  memoryPercentHigh: 90
  memoryPercentNMinusOne: 0 // 0 = automatic: 2 nodes -> 50%, 3 nodes -> 66%, 4 nodes -> 75%
  availableMemoryGB: 1
  volumeLatencyMs: 50
  vhdLatencyMs: 100
  vmMemoryPressurePercent: 100
  heartbeatMinutes: 10
}

// VM state alert
param vmAlertPowerStates = [
  'Stopped'
  'Unknown'
  'Paused'
  'Saved'
]
param vmAlertOnGuestAgent = false
param vmExcludedNames = []

// Hyper-V VM state on the hosts (all VMs, also non-Arc)
param deployVmHostStateSddcAlert = true
param vmHostStateIncludeTransitional = false
param deployVmHostStateScript = true // requires scripts/Register-AzLocalVmStateTask.ps1 on the cluster
param vmHostStateEventSource = 'AzLocalVmStateMonitor'
param vmHostStateScriptMaxSilenceMinutes = 20

// Feature toggles
param deployHealthAlertRouting = true
param deployMetricAlerts = true
param deployEventCollection = true
param deployEventAlerts = true
param deployHeartbeatAlert = true
param deployResourceHealthAlert = true
param deployVmStateAlert = true
param deployAlertRoleAssignments = true // roles for the alert identity; needs roleAssignments/write
param deployAmaExtension = false
param deployHealthAlertsExtension = false

param tags = {
  workload: 'azure-local'
  purpose: 'monitoring'
}
