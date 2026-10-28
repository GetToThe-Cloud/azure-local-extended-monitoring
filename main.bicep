metadata name = 'Azure Local monitoring baseline'
metadata description = 'Action group, health-alert routing, metric/log/resource-health alerts, extra event collection and VM state alerting for Azure Local clusters.'
metadata author = 'gettothe.cloud'

targetScope = 'resourceGroup'

// ============================================================================
// Types
// ============================================================================

@description('An Azure Local cluster and the Arc machine names of its nodes.')
type clusterType = {
  @description('Name of the Microsoft.AzureStackHCI/clusters resource.')
  name: string

  @description('Names of the Microsoft.HybridCompute/machines resources of the cluster nodes (as shown in the portal).')
  nodeNames: string[]
}

@description('E-mail receiver for the action group.')
type emailReceiverType = {
  name: string
  emailAddress: string
}

@description('Weekly maintenance window in which notifications are suppressed (for example patch night).')
type maintenanceWindowType = {
  @description('Windows time zone ID, for example "W. Europe Standard Time".')
  timeZone: string

  daysOfWeek: ('Monday' | 'Tuesday' | 'Wednesday' | 'Thursday' | 'Friday' | 'Saturday' | 'Sunday')[]

  @description('Start time in HH:mm:ss. Keep start and end on the same day.')
  startTime: string

  @description('End time in HH:mm:ss.')
  endTime: string
}

@description('Alert thresholds.')
type thresholdsType = {
  @description('Node CPU percentage (average over 15 minutes).')
  cpuPercent: int

  @description('Node memory percentage that is always critical.')
  memoryPercentHigh: int

  @description('Node memory percentage for the N-1 capacity warning. 0 = calculate from node count: (N-1)/N * 100.')
  memoryPercentNMinusOne: int

  @description('Minimum available memory per node in GB.')
  availableMemoryGB: int

  @description('CSV volume read/write latency in milliseconds.')
  volumeLatencyMs: int

  @description('VHD latency in milliseconds.')
  vhdLatencyMs: int

  @description('Hyper-V dynamic memory pressure percentage per VM.')
  vmMemoryPressurePercent: int

  @description('Minutes without an AMA heartbeat before a node is reported as silent.')
  heartbeatMinutes: int
}

// ============================================================================
// Parameters
// ============================================================================

@description('Prefix for all resource names created by this template.')
@maxLength(10)
param namePrefix string = 'azl'

@description('Resource ID of the Log Analytics workspace that Insights for Azure Local writes to.')
param workspaceResourceId string

@description('Resource group that contains the Azure Local clusters, their Arc machines (nodes and VMs) and the Arc resource bridges.')
param clusterResourceGroupName string

@description('Subscription of the cluster resource group. Defaults to the subscription of this deployment.')
param clusterSubscriptionId string = subscription().subscriptionId

@description('Azure Local clusters to monitor.')
@minLength(1)
param clusters clusterType[]

@description('E-mail receivers for the action group.')
@minLength(1)
param emailReceivers emailReceiverType[]

@description('Short name of the action group (max 12 characters, shown in SMS/e-mail).')
@maxLength(12)
param actionGroupShortName string = 'AzLocalOps'

@description('Severities of cluster-scoped alerts (health alerts and metric alerts) that are routed to the action group.')
param routedSeverities ('Sev0' | 'Sev1' | 'Sev2' | 'Sev3' | 'Sev4')[] = [
  'Sev0'
  'Sev1'
  'Sev2'
  'Sev3'
]

@description('Optional weekly maintenance window. During this window notifications for the Azure Local alerts are suppressed.')
param maintenanceWindow maintenanceWindowType?

@description('Alert thresholds.')
param thresholds thresholdsType = {
  cpuPercent: 85
  memoryPercentHigh: 90
  memoryPercentNMinusOne: 0
  availableMemoryGB: 1
  volumeLatencyMs: 50
  vhdLatencyMs: 100
  vmMemoryPressurePercent: 100
  heartbeatMinutes: 10
}

// --- Event collection -------------------------------------------------------

@description('Failover clustering event IDs (System log) that raise a Sev1 alert.')
param criticalClusterEventIds int[] = [
  1135 // Node removed from active cluster membership
  1177 // Cluster service shutting down, quorum lost
  5120 // CSV paused / I/O timeout
  5142 // CSV no longer accessible from this node
]

@description('Failover clustering event IDs (System log) that raise a Sev2 alert.')
param warningClusterEventIds int[] = [
  1069 // Cluster resource failed
  1205 // Clustered role failed to come online/offline completely
  1254 // Clustered role exceeded its failover threshold
]

@description('Event IDs from the Microsoft-Windows-Hyper-V-Worker-Admin channel that raise a Sev2 alert.')
param hyperVWorkerEventIds int[] = [
  18590 // Guest operating system crashed (bugcheck)
]

// --- VM state alert ---------------------------------------------------------

@description('Azure Local VM power states that raise an alert.')
param vmAlertPowerStates string[] = [
  'Stopped'
  'Unknown'
  'Paused'
  'Saved'
]

@description('Also alert when the VM guest agent (mocguestagent) is not Connected. Verify in Resource Graph Explorer first that instanceView is populated.')
param vmAlertOnGuestAgent bool = false

@description('Azure Local VM names that are excluded from the VM state alert (for example templates or intentionally stopped VMs).')
param vmExcludedNames string[] = []

// --- Hyper-V VM state on the hosts (all VMs, also non-Arc) -----------------

@description('Alert per node on VM state counts from SDDC Management event 3000 (already collected by Insights, no installation needed, no VM names).')
param deployVmHostStateSddcAlert bool = true

@description('Also count transitional states (Starting, Stopping, Saving, Pausing, Resuming, Snapshotting) in the SDDC alert. Useful with a 15 minute cache dump interval: a VM that is still "Stopping" in the next snapshot is stuck.')
param vmHostStateIncludeTransitional bool = false

@description('Collect and alert on the per-VM events written by scripts/Watch-AzLocalVmState.ps1 (clustered scheduled task, see README).')
param deployVmHostStateScript bool = true

@description('Event source used by Watch-AzLocalVmState.ps1 in the Application log.')
param vmHostStateEventSource string = 'AzLocalVmStateMonitor'

@description('Minutes without a run of Watch-AzLocalVmState.ps1 on a node before the "monitor not running" alert fires.')
param vmHostStateScriptMaxSilenceMinutes int = 20

// --- Feature toggles --------------------------------------------------------

@description('Deploy the alert processing rule that routes health alerts and cluster metric alerts to the action group.')
param deployHealthAlertRouting bool = true

@description('Deploy metric alert rules per cluster.')
param deployMetricAlerts bool = true

@description('Deploy the supplemental DCR for failover clustering and Hyper-V events and associate it with all nodes.')
param deployEventCollection bool = true

@description('Deploy log search alerts on the failover clustering and Hyper-V events.')
param deployEventAlerts bool = true

@description('Deploy the node heartbeat alert.')
param deployHeartbeatAlert bool = true

@description('Deploy the Resource Health alert for the Arc resource bridge.')
param deployResourceHealthAlert bool = true

@description('Resource types in the cluster resource group that are covered by the Resource Health alert.')
param resourceHealthResourceTypes string[] = [
  'Microsoft.ResourceConnector/appliances'
]

@description('Deploy the VM state alert (Azure Resource Graph query via log search alert with managed identity).')
param deployVmStateAlert bool = true

@description('Create the role assignments for the alert identity that every log search alert runs as: Log Analytics Reader on the workspace and, for the Azure Local VM state alert, Reader on the cluster resource group. Requires Owner, User Access Administrator or Role Based Access Control Administrator on those scopes.')
param deployAlertRoleAssignments bool = true

@description('Deploy the log search alert rules. False deploys everything else, including the alert identity and its role assignments. The deploy script uses false for its first phase, so the role assignments have time to propagate before the rules are created: the Log Search Alerts service checks the identity\'s access when a rule is saved.')
param deployLogAlertRules bool = true

@description('Deprecated, use deployAlertRoleAssignments. Kept so existing parameter files keep working; false also disables the role assignments.')
param deployVmStateRoleAssignments bool = true

@description('Install the Azure Monitor Agent extension on the clusters. Not needed when Insights is already enabled.')
param deployAmaExtension bool = false

@description('Install the health alerts (AzureEdgeAlerts) extension on the clusters. Requires healthAlertsExtensionPublisher and healthAlertsExtensionType.')
param deployHealthAlertsExtension bool = false

@description('Publisher of the AzureEdgeAlerts extension. Read it from a cluster where health alerts are enabled (see README).')
param healthAlertsExtensionPublisher string = ''

@description('Type of the AzureEdgeAlerts extension. Read it from a cluster where health alerts are enabled (see README).')
param healthAlertsExtensionType string = ''

@description('Clusters to install the Azure Monitor Agent extension on. Empty = all clusters.')
param amaExtensionClusters string[] = []

@description('Clusters to install the health alerts extension on. Empty = all clusters.')
param healthAlertsExtensionClusters string[] = []

@description('Tags for all resources.')
param tags object = {}

// ============================================================================
// Variables
// ============================================================================

var workspaceIdParts = split(workspaceResourceId, '/')
var workspaceSubscriptionId = workspaceIdParts[2]
var workspaceResourceGroupName = workspaceIdParts[4]
var workspaceName = last(workspaceIdParts)

var clusterResourceGroupId = '/subscriptions/${clusterSubscriptionId}/resourceGroups/${clusterResourceGroupName}'
var clusterIds = [
  for c in clusters: resourceId(clusterSubscriptionId, clusterResourceGroupName, 'Microsoft.AzureStackHCI/clusters', c.name)
]
var allNodeNames = flatten(map(clusters, c => c.nodeNames))

// XPath queries for the supplemental DCR
var allClusterEventIds = concat(criticalClusterEventIds, warningClusterEventIds)
var clusterEventFilter = join(map(allClusterEventIds, id => 'EventID=${id}'), ' or ')
var hyperVEventFilter = join(map(hyperVWorkerEventIds, id => 'EventID=${id}'), ' or ')
var clusterXPath = 'System!*[System[Provider[@Name=\'Microsoft-Windows-FailoverClustering\'] and (${clusterEventFilter})]]'
var hyperVXPath = 'Microsoft-Windows-Hyper-V-Worker-Admin!*[System[(${hyperVEventFilter})]]'
var vmStateScriptXPath = 'Application!*[System[Provider[@Name=\'${vmHostStateEventSource}\'] and (EventID=4100 or EventID=4101)]]'
var clusterXPathList = empty(allClusterEventIds) ? [] : [clusterXPath]
var hyperVXPathList = empty(hyperVWorkerEventIds) ? [] : [hyperVXPath]
var vmStateScriptXPathList = deployVmHostStateScript ? [vmStateScriptXPath] : []
var eventXPathQueries = concat(clusterXPathList, hyperVXPathList, vmStateScriptXPathList)

var deployClusterExtensions = deployAmaExtension || deployHealthAlertsExtension

// Log search alerts run their query as one shared user-assigned identity. Without an identity a
// rule uses the permissions of whoever last saved it, which breaks silently when that account
// loses access (an expired PIM activation, a colleague who leaves, a pipeline principal).
var deployAnyLogAlert = deployEventAlerts || deployHeartbeatAlert || deployVmStateAlert || deployVmHostStateSddcAlert || deployVmHostStateScript
var createAlertRoleAssignments = deployAlertRoleAssignments && deployVmStateRoleAssignments
var readerRoleId = 'acdd72a7-3385-48ef-bd42-f606fba81ae7'
var logAnalyticsReaderRoleId = '73c42c96-874c-492b-b04d-ab87d138a893'

// ============================================================================
// Existing resources
// ============================================================================

resource workspace 'Microsoft.OperationalInsights/workspaces@2023-09-01' existing = {
  name: workspaceName
  scope: resourceGroup(workspaceSubscriptionId, workspaceResourceGroupName)
}

// ============================================================================
// Modules
// ============================================================================

module actionGroup 'modules/action-group.bicep' = {
  name: take('${namePrefix}-actiongroup-${uniqueString(deployment().name)}', 64)
  params: {
    name: '${namePrefix}-ag-azurelocal'
    shortName: actionGroupShortName
    emailReceivers: emailReceivers
    tags: tags
  }
}

module alertIdentity 'modules/alert-identity.bicep' = {
  name: take('${namePrefix}-alert-identity-${uniqueString(deployment().name)}', 64)
  params: {
    name: '${namePrefix}-id-alert-rules'
    location: workspace.location
    tags: tags
  }
}

// Log Analytics Reader on the workspace: every log search alert runs its query there.
module alertIdentityWorkspaceReader 'modules/role-assignment-workspace.bicep' = if (deployAnyLogAlert && createAlertRoleAssignments) {
  name: take('${namePrefix}-ra-alert-law-${uniqueString(deployment().name)}', 64)
  scope: resourceGroup(workspaceSubscriptionId, workspaceResourceGroupName)
  params: {
    workspaceName: workspaceName
    principalId: alertIdentity.outputs.principalId
    roleDefinitionId: logAnalyticsReaderRoleId
    assignmentDescription: 'Azure Local monitoring: log search alert rules query this workspace.'
  }
}

// Reader on the cluster resource group: the Azure Local VM state alert reads the VMs through Resource Graph.
module alertIdentityClusterReader 'modules/role-assignment-rg.bicep' = if (deployVmStateAlert && createAlertRoleAssignments) {
  name: take('${namePrefix}-ra-alert-rg-${uniqueString(deployment().name)}', 64)
  scope: resourceGroup(clusterSubscriptionId, clusterResourceGroupName)
  params: {
    principalId: alertIdentity.outputs.principalId
    roleDefinitionId: readerRoleId
    assignmentDescription: 'Azure Local monitoring: VM state alert reads Azure Local VMs through Resource Graph.'
  }
}

module healthAlertRouting 'modules/health-alert-routing.bicep' = if (deployHealthAlertRouting) {
  name: take('${namePrefix}-routing-${uniqueString(deployment().name)}', 64)
  params: {
    namePrefix: namePrefix
    clusterIds: clusterIds
    clusterResourceGroupId: clusterResourceGroupId
    workspaceId: workspaceResourceId
    actionGroupId: actionGroup.outputs.id
    routedSeverities: routedSeverities
    maintenanceWindow: maintenanceWindow
    tags: tags
  }
}

module clusterMetricAlerts 'modules/cluster-metric-alerts.bicep' = [
  for (c, i) in clusters: if (deployMetricAlerts) {
    name: take('${namePrefix}-metrics-${c.name}-${uniqueString(deployment().name)}', 64)
    params: {
      namePrefix: namePrefix
      clusterName: c.name
      clusterId: clusterIds[i]
      nodeCount: length(c.nodeNames)
      thresholds: thresholds
      tags: tags
    }
  }
]

module eventCollection 'modules/event-collection.bicep' = if (deployEventCollection && !empty(eventXPathQueries)) {
  name: take('${namePrefix}-events-dcr-${uniqueString(deployment().name)}', 64)
  params: {
    dcrName: '${namePrefix}-dcr-azurelocal-cluster-events'
    location: workspace.location
    workspaceId: workspaceResourceId
    xPathQueries: eventXPathQueries
    nodeNames: allNodeNames
    clusterSubscriptionId: clusterSubscriptionId
    clusterResourceGroupName: clusterResourceGroupName
    tags: tags
  }
}

module eventLogAlerts 'modules/event-log-alerts.bicep' = if (deployLogAlertRules && deployEventAlerts) {
  name: take('${namePrefix}-event-alerts-${uniqueString(deployment().name)}', 64)
  params: {
    namePrefix: namePrefix
    location: workspace.location
    workspaceId: workspaceResourceId
    actionGroupId: actionGroup.outputs.id
    identityId: alertIdentity.outputs.id
    criticalEventIds: criticalClusterEventIds
    warningEventIds: concat(warningClusterEventIds, hyperVWorkerEventIds)
    tags: tags
  }
  dependsOn: [
    alertIdentityWorkspaceReader
  ]
}

module heartbeatAlert 'modules/heartbeat-alert.bicep' = if (deployLogAlertRules && deployHeartbeatAlert) {
  name: take('${namePrefix}-heartbeat-${uniqueString(deployment().name)}', 64)
  params: {
    name: '${namePrefix}-node-heartbeat-missing'
    location: workspace.location
    workspaceId: workspaceResourceId
    actionGroupId: actionGroup.outputs.id
    identityId: alertIdentity.outputs.id
    nodeNames: allNodeNames
    thresholdMinutes: thresholds.heartbeatMinutes
    tags: tags
  }
  dependsOn: [
    alertIdentityWorkspaceReader
  ]
}

module resourceHealthAlert 'modules/resource-health-alert.bicep' = if (deployResourceHealthAlert) {
  name: take('${namePrefix}-resourcehealth-${uniqueString(deployment().name)}', 64)
  params: {
    name: '${namePrefix}-arc-resource-bridge-health'
    scopes: [
      clusterResourceGroupId
    ]
    resourceTypes: resourceHealthResourceTypes
    actionGroupId: actionGroup.outputs.id
    tags: tags
  }
}

module vmStateAlert 'modules/vm-state-alert.bicep' = if (deployLogAlertRules && deployVmStateAlert) {
  name: take('${namePrefix}-vmstate-${uniqueString(deployment().name)}', 64)
  params: {
    name: '${namePrefix}-vm-state'
    location: workspace.location
    workspaceId: workspaceResourceId
    actionGroupId: actionGroup.outputs.id
    resourceGroupNames: [
      clusterResourceGroupName
    ]
    identityId: alertIdentity.outputs.id
    alertPowerStates: vmAlertPowerStates
    checkGuestAgent: vmAlertOnGuestAgent
    excludedVmNames: vmExcludedNames
    tags: tags
  }
  dependsOn: [
    alertIdentityWorkspaceReader
    alertIdentityClusterReader
  ]
}

module vmHostStateAlerts 'modules/vm-host-state-alerts.bicep' = if (deployLogAlertRules && (deployVmHostStateSddcAlert || deployVmHostStateScript)) {
  name: take('${namePrefix}-vmhoststate-${uniqueString(deployment().name)}', 64)
  params: {
    namePrefix: namePrefix
    location: workspace.location
    workspaceId: workspaceResourceId
    actionGroupId: actionGroup.outputs.id
    identityId: alertIdentity.outputs.id
    nodeNames: allNodeNames
    deploySddcAlert: deployVmHostStateSddcAlert
    includeTransitional: vmHostStateIncludeTransitional
    deployScriptAlerts: deployVmHostStateScript
    eventSource: vmHostStateEventSource
    scriptMaxSilenceMinutes: vmHostStateScriptMaxSilenceMinutes
    tags: tags
  }
  dependsOn: [
    alertIdentityWorkspaceReader
  ]
}

module clusterExtensions 'modules/cluster-extensions.bicep' = [
  for c in clusters: if (deployClusterExtensions) {
    name: take('${namePrefix}-ext-${c.name}-${uniqueString(deployment().name)}', 64)
    scope: resourceGroup(clusterSubscriptionId, clusterResourceGroupName)
    params: {
      clusterName: c.name
      deployAma: deployAmaExtension && (empty(amaExtensionClusters) || contains(amaExtensionClusters, c.name))
      deployHealthAlerts: deployHealthAlertsExtension && (empty(healthAlertsExtensionClusters) || contains(healthAlertsExtensionClusters, c.name))
      healthAlertsPublisher: healthAlertsExtensionPublisher
      healthAlertsType: healthAlertsExtensionType
    }
  }
]

// ============================================================================
// Outputs
// ============================================================================

@description('Resource ID of the action group.')
output actionGroupId string = actionGroup.outputs.id

@description('XPath queries used by the supplemental DCR.')
output eventXPathQueries string[] = eventXPathQueries

@description('Resource ID of the managed identity the log search alert rules run as.')
output alertIdentityId string = alertIdentity.outputs.id

@description('Principal (object) ID of the managed identity the log search alert rules run as.')
output alertIdentityPrincipalId string = alertIdentity.outputs.principalId
