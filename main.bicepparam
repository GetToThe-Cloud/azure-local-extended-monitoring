using './main.bicep'

// ---------------------------------------------------------------------------
// Example values - replace before deploying
// ---------------------------------------------------------------------------

param namePrefix = 'azl'

// Workspace that Insights for Azure Local uses (DCR name starts with AzureStackHCI-)
param workspaceResourceId = '/subscriptions/0c099ebb-b857-4ac4-98b6-b753e9dc4850/resourcegroups/rsg-lz-monitoring-01/providers/microsoft.operationalinsights/workspaces/law-lz-01'

// Resource group with the cluster, the node Arc machines, the Azure Local VMs and the Arc resource bridge
param clusterResourceGroupName = 'rsg-lz-azlocal-01'

param clusters = [
  {
    name: 'cluster'
    nodeNames: [
      'node01'
    ]
  }
]

param emailReceivers = [
  {
    name: 'Operations'
    emailAddress: 'demo@gettothe.cloud'
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
param deployVmStateRoleAssignments = true
param deployAmaExtension = false
param deployHealthAlertsExtension = false

param tags = {
  workload: 'azure-local'
  purpose: 'monitoring'
}
