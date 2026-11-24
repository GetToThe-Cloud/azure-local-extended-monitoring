metadata description = 'Leftover checkpoints on Azure Local: a log search alert on VMs that keep running on an .avhdx, and a workbook with how long each VM has been on its checkpoint. Both read the Hyper-V Virtual Storage Device counter that the supplemental DCR collects.'

@description('Prefix for resource names.')
param namePrefix string

@description('Location of the alert rule and the workbook (region of the workspace).')
param location string

@description('Resource ID of the Log Analytics workspace.')
param workspaceId string

@description('Resource ID of the action group.')
param actionGroupId string

@description('Resource ID of the user-assigned managed identity the rule runs its query with.')
param identityId string

@description('Hours a VM disk must run on an .avhdx before the alert fires. A log search alert looks back at most 48 hours, so at most 46.')
@minValue(1)
@maxValue(46)
param minAgeHours int

@description('Age in days that the workbook marks as too old.')
@minValue(1)
param maxAgeDays int

@description('Sampling interval of the counter in seconds. A disk counts as current when it had a sample in the last three intervals (at least 30 minutes).')
param counterIntervalSeconds int

@description('VMs that may keep a checkpoint, for example a test VM with a deliberate baseline. Matched on the VM name read from the disk file name, case-insensitive.')
param excludedVmNames string[]

@description('Deploy the alert rule.')
param deployAlertRule bool = true

@description('Deploy the workbook.')
param deployWorkbook bool = true

@description('Tags.')
param tags object = {}

var recentMinutes = max(30, (counterIntervalSeconds * 3) / 60)
var excludedList = join(map(excludedVmNames, n => '"${toLower(n)}"'), ', ')

var alertQuery = replace(
  replace(
    replace(loadTextContent('../queries/checkpoint-avhdx.kql'), '{{MIN_AGE_HOURS}}', string(minAgeHours)),
    '{{RECENT_MINUTES}}',
    string(recentMinutes)
  ),
  '{{EXCLUDED_VM_NAMES}}',
  excludedList
)

var overviewQuery = replace(
  replace(loadTextContent('../queries/checkpoint-avhdx-overview.kql'), '{{MAX_AGE_DAYS}}', string(maxAgeDays)),
  '{{RECENT_MINUTES}}',
  string(recentMinutes)
)

resource checkpointAlert 'Microsoft.Insights/scheduledQueryRules@2023-12-01' = if (deployAlertRule) {
  name: '${namePrefix}-checkpoint-avhdx'
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
    displayName: 'Azure Local - VM running on a checkpoint for ${minAgeHours} hours'
    description: 'A VM on an Azure Local node has had a disk on an .avhdx (checkpoint) for at least ${minAgeHours} hours. Backup and replication checkpoints are gone within hours, so this one was left behind: a failed job or a manual checkpoint nobody removed. Every read and write goes through the extra layer, and the merge gets bigger every day. Check with Get-VMSnapshot (Recovery = backup, Standard = manual) outside backup windows, and remove it one VM at a time outside peak hours. An .avhdx without a checkpoint: do not merge it yourself, ask your backup vendor first. The workbook "Azure Local - leftover checkpoints" shows how long each VM has been on its checkpoint.'
    severity: 2
    enabled: true
    scopes: [
      workspaceId
    ]
    // Hourly is enough for something measured in hours. The window is the 48-hour maximum of a
    // log search alert, so the query can see when the .avhdx first appeared.
    evaluationFrequency: 'PT1H'
    windowSize: 'P2D'
    autoMitigate: true
    // Skips only the query syntax check; see event-log-alerts.bicep.
    skipQueryValidation: true
    criteria: {
      allOf: [
        {
          query: alertQuery
          timeAggregation: 'Total'
          metricMeasureColumn: 'Disks'
          operator: 'GreaterThan'
          threshold: 0
          dimensions: [
            {
              name: 'VMName'
              operator: 'Include'
              values: [
                '*'
              ]
            }
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

var workbookContent = {
  version: 'Notebook/1.0'
  items: [
    {
      type: 1
      name: 'intro'
      content: {
        json: '## Leftover checkpoints\n\nVMs with a disk on an `.avhdx` (checkpoint) right now, and since when. Backup and replication checkpoints disappear within hours. A VM that stays on its checkpoint for more than ${maxAgeDays} days is marked in **Status**.\n\nSince = the first sample of the *Hyper-V Virtual Storage Device* counter in the last 30 days. Right after the first deployment, older checkpoints look as young as the collection. Who created a checkpoint is not logged by Hyper-V; check the name and type with `Get-VMSnapshot`.'
      }
    }
    {
      type: 3
      name: 'avhdx-per-vm'
      content: {
        version: 'KqlItem/1.0'
        query: overviewQuery
        size: 0
        title: 'VMs on a checkpoint'
        noDataMessage: 'No VM runs on an .avhdx.'
        timeContext: {
          durationMs: 2592000000
        }
        queryType: 0
        resourceType: 'microsoft.operationalinsights/workspaces'
        crossComponentResources: [
          workspaceId
        ]
      }
    }
  ]
  fallbackResourceIds: [
    workspaceId
  ]
  '$schema': 'https://github.com/Microsoft/Application-Insights-Workbooks/blob/master/schema/workbook.json'
}

resource workbook 'Microsoft.Insights/workbooks@2022-04-01' = if (deployWorkbook) {
  name: guid(resourceGroup().id, namePrefix, 'azure-local-leftover-checkpoints')
  location: location
  tags: tags
  kind: 'shared'
  properties: {
    displayName: 'Azure Local - leftover checkpoints'
    category: 'workbook'
    sourceId: toLower(workspaceId)
    version: 'Notebook/1.0'
    serializedData: string(workbookContent)
  }
}

@description('Resource ID of the workbook.')
output workbookId string = deployWorkbook ? workbook.id : ''
