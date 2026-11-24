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

@description('A Windows event to collect from every node, and the severity of its alert.')
type nodeEventType = {
  @description('Event log (channel), for example "System" or "Microsoft-Windows-Hyper-V-StorageVSP-Admin".')
  log: string

  @description('Provider (event source). Needed for shared logs such as System and Application; leave it out for a dedicated channel.')
  provider: string?

  @description('Event IDs. At most 20 per entry: one XPath query in a DCR supports up to 20 expressions.')
  @minLength(1)
  @maxLength(20)
  eventIds: int[]

  @description('1 = Sev1 alert, 2 = Sev2 alert, 0 = collect only, no alert.')
  severity: 0 | 1 | 2

  @description('What the events mean. Documentation only.')
  description: string
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

@description('Failover clustering event IDs (System log) that raise a Sev1 alert. Together with warningClusterEventIds at most 20: they share one XPath query, which supports up to 20 expressions.')
param criticalClusterEventIds int[] = [
  1135 // Node removed from active cluster membership
  1177 // Cluster service shutting down, quorum lost
  5120 // CSV paused / I/O timeout
  5142 // CSV no longer accessible from this node
]

@description('Failover clustering event IDs (System log) that raise a Sev2 alert. Together with criticalClusterEventIds at most 20.')
param warningClusterEventIds int[] = [
  1069 // Cluster resource failed
  1126 // Cluster network interface unreachable by at least one other node
  1127 // Cluster network interface failed
  1129 // Cluster network partitioned
  1130 // Cluster network down
  1205 // Clustered role failed to come online/offline completely
  1254 // Clustered role exceeded its failover threshold
]

@description('Event IDs from the Microsoft-Windows-Hyper-V-Worker-Admin channel that raise a Sev2 alert.')
param hyperVWorkerEventIds int[] = [
  18590 // Guest operating system crashed (bugcheck)
]

@description('Other events from the nodes, each with its own log, provider and severity: unexpected restarts, bugchecks, storage stalls, checkpoint and live migration failures. Severity 0 collects the event without an alert.')
param nodeEvents nodeEventType[] = [
  {
    log: 'System'
    provider: 'Microsoft-Windows-Kernel-Power'
    eventIds: [
      41
    ]
    severity: 1
    description: 'Restart without a clean shutdown: crash, power loss, or power-off with the power button or the BMC (see PowerButtonTimestamp in the event data)'
  }
  {
    log: 'System'
    provider: 'Microsoft-Windows-WER-SystemErrorReporting'
    eventIds: [
      1001
    ]
    severity: 1
    description: 'The node restarted after a bugcheck (stop error), with the stop code'
  }
  {
    log: 'Microsoft-Windows-Hyper-V-StorageVSP-Admin'
    eventIds: [
      9
    ]
    severity: 2
    description: 'An I/O on a virtual disk took about 10 seconds or longer; the event names the VHDX'
  }
  {
    log: 'Microsoft-Windows-SMBServer/Operational'
    eventIds: [
      1020
    ]
    severity: 2
    description: 'A file system operation took longer than 15 seconds. With ReFS CSVs, I/O from other nodes reaches the volume owner over SMB, so this shows up on the owner node'
  }
  {
    log: 'Microsoft-Windows-Hyper-V-VMMS-Admin'
    eventIds: [
      18012
      18014
      18016
    ]
    severity: 2
    description: 'Checkpoint failed (18012), cancelled (18014) or production checkpoint not possible (18016), for example during a backup or replication job'
  }
  {
    log: 'Microsoft-Windows-Hyper-V-High-Availability-Admin'
    eventIds: [
      21502
    ]
    severity: 2
    description: 'A clustered VM operation failed, for example a live migration during a drain or rebalance'
  }
  {
    log: 'System'
    provider: 'Microsoft-Windows-Hyper-V-High-Availability'
    eventIds: [
      21502
    ]
    severity: 2
    description: 'The same event where Windows writes it to the System log instead of the High-Availability Admin channel. An event lands in one log only, so collecting both does not duplicate alerts'
  }
  {
    log: 'System'
    provider: 'User32'
    eventIds: [
      1074
    ]
    severity: 0
    description: 'Shutdown or restart started by a user or process, with the reason. Collected for root cause analysis, no alert'
  }
]

// --- Microsoft Defender attack surface reduction ----------------------------

@description('Collect Microsoft Defender attack surface reduction (ASR) events (1121 block, 1122 audit, 5007 setting changed) and alert on blocks and on rules that are set to Block.')
param deployDefenderAsrMonitoring bool = true

@description('ASR rules that must stay in Audit on Azure Local nodes. An alert fires when a policy sets one of them to Block. Default: "Block process creations originating from PSExec and WMI commands", which makes Cluster-Aware Updating fail in Block. Empty = alert on every ASR rule that is set to Block.')
param defenderAsrAuditOnlyRuleIds string[] = [
  'd1e49aac-8f56-4280-b9ba-993a6d77406c'
]

@description('ASR rules whose blocks (event 1121) do not raise an alert, for example a rule that blocks often and harmlessly in your environment.')
param defenderAsrBlockExcludedRuleIds string[] = []

@description('Also collect ASR audit events (1122), without an alert. Useful to confirm during an update that a rule audits instead of blocks. Can be chatty when many rules are in Audit.')
param defenderCollectAsrAuditEvents bool = true

// --- Hardware errors (WHEA) -------------------------------------------------

@description('Collect WHEA-Logger hardware error events (Critical, Error and Warning) and alert on them: Sev1 for fatal errors, Sev2 when corrected errors pile up on a node.')
param deployHardwareErrorMonitoring bool = true

@description('Number of corrected hardware errors (WHEA warnings, for example 17, 19 or 47) per node and event ID within 24 hours that raises a Sev2 alert.')
@minValue(1)
param hardwareCorrectedErrorThreshold int = 3

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

@description('Deploy the supplemental DCR for the node events (failover clustering, Hyper-V, restarts, storage, Defender ASR, hardware errors) and associate it with all nodes.')
param deployEventCollection bool = true

@description('Deploy log search alerts on the collected node events.')
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

// One XPath query per node event entry; the provider filter only when the entry names one.
var nodeEventXPaths = map(
  nodeEvents,
  e =>
    empty(e.?provider ?? '')
      ? '${e.log}!*[System[(${join(map(e.eventIds, id => 'EventID=${id}'), ' or ')})]]'
      : '${e.log}!*[System[Provider[@Name=\'${e.?provider ?? ''}\'] and (${join(map(e.eventIds, id => 'EventID=${id}'), ' or ')})]]'
)

var defenderEventIds = defenderCollectAsrAuditEvents ? [1121, 1122, 5007] : [1121, 5007]
var defenderXPath = 'Microsoft-Windows-Windows Defender/Operational!*[System[(${join(map(defenderEventIds, id => 'EventID=${id}'), ' or ')})]]'
var defenderXPathList = deployDefenderAsrMonitoring ? [defenderXPath] : []

// WHEA by level instead of by event ID, so hardware errors with an ID that is not listed anywhere are collected too.
var hardwareXPath = 'System!*[System[Provider[@Name=\'Microsoft-Windows-WHEA-Logger\'] and (Level=1 or Level=2 or Level=3)]]'
var hardwareXPathList = deployHardwareErrorMonitoring ? [hardwareXPath] : []

var eventXPathQueries = concat(
  clusterXPathList,
  hyperVXPathList,
  vmStateScriptXPathList,
  nodeEventXPaths,
  defenderXPathList,
  hardwareXPathList
)

// KQL conditions for the Sev1 and Sev2 node event alerts. Every condition names its log and, for a
// shared log such as System, its provider. Event IDs are not unique across logs: 1129 is a
// partitioned cluster network in FailoverClustering and a warn-mode override in Defender.
var clusterEventSets = [
  {
    log: 'System'
    provider: 'Microsoft-Windows-FailoverClustering'
    eventIds: criticalClusterEventIds
    severity: 1
  }
  {
    log: 'System'
    provider: 'Microsoft-Windows-FailoverClustering'
    eventIds: warningClusterEventIds
    severity: 2
  }
  {
    log: 'Microsoft-Windows-Hyper-V-Worker-Admin'
    provider: ''
    eventIds: hyperVWorkerEventIds
    severity: 2
  }
]
var nodeEventSets = map(nodeEvents, e => {
  log: e.log
  provider: e.?provider ?? ''
  eventIds: e.eventIds
  severity: e.severity
})
var alertEventSets = filter(concat(clusterEventSets, nodeEventSets), s => !empty(s.eventIds) && s.severity > 0)
var alertEventConditions = map(alertEventSets, s => {
  severity: s.severity
  condition: empty(s.provider)
    ? '(EventLog == "${s.log}" and EventID in (${join(map(s.eventIds, id => string(id)), ', ')}))'
    : '(EventLog == "${s.log}" and Source in ("${s.provider}") and EventID in (${join(map(s.eventIds, id => string(id)), ', ')}))'
  label: '${replace(empty(s.provider) ? s.log : s.provider, 'Microsoft-Windows-', '')} ${join(map(s.eventIds, id => string(id)), ', ')}'
})
var criticalEventConditions = filter(alertEventConditions, c => c.severity == 1)
var warningEventConditions = filter(alertEventConditions, c => c.severity == 2)
var criticalEventFilter = join(map(criticalEventConditions, c => c.condition), '\n    or ')
var warningEventFilter = join(map(warningEventConditions, c => c.condition), '\n    or ')
var criticalEventSummary = join(map(criticalEventConditions, c => c.label), '; ')
var warningEventSummary = join(map(warningEventConditions, c => c.label), '; ')

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
    criticalEventFilter: criticalEventFilter
    warningEventFilter: warningEventFilter
    criticalEventSummary: criticalEventSummary
    warningEventSummary: warningEventSummary
    tags: tags
  }
  dependsOn: [
    alertIdentityWorkspaceReader
  ]
}

module defenderAsrAlerts 'modules/defender-asr-alerts.bicep' = if (deployLogAlertRules && deployEventAlerts && deployDefenderAsrMonitoring) {
  name: take('${namePrefix}-asr-alerts-${uniqueString(deployment().name)}', 64)
  params: {
    namePrefix: namePrefix
    location: workspace.location
    workspaceId: workspaceResourceId
    actionGroupId: actionGroup.outputs.id
    identityId: alertIdentity.outputs.id
    auditOnlyRuleIds: defenderAsrAuditOnlyRuleIds
    blockExcludedRuleIds: defenderAsrBlockExcludedRuleIds
    tags: tags
  }
  dependsOn: [
    alertIdentityWorkspaceReader
  ]
}

module hardwareErrorAlerts 'modules/hardware-error-alerts.bicep' = if (deployLogAlertRules && deployEventAlerts && deployHardwareErrorMonitoring) {
  name: take('${namePrefix}-hw-alerts-${uniqueString(deployment().name)}', 64)
  params: {
    namePrefix: namePrefix
    location: workspace.location
    workspaceId: workspaceResourceId
    actionGroupId: actionGroup.outputs.id
    identityId: alertIdentity.outputs.id
    correctedErrorThreshold: hardwareCorrectedErrorThreshold
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
