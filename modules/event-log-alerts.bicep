metadata description = 'Log search alerts on failover clustering and Hyper-V events collected by the supplemental DCR.'

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

@description('Event IDs that raise a Sev1 alert.')
param criticalEventIds int[]

@description('Event IDs that raise a Sev2 alert.')
param warningEventIds int[]

@description('Tags.')
param tags object = {}

var baseQuery = loadTextContent('../queries/cluster-events.kql')
var criticalIdList = join(map(criticalEventIds, id => string(id)), ', ')
var warningIdList = join(map(warningEventIds, id => string(id)), ', ')

var rules = [
  {
    key: 'cluster-events-critical'
    deploy: !empty(criticalEventIds)
    severity: 1
    displayName: 'Azure Local - critical cluster events'
    description: 'Node removed from cluster membership, quorum loss or CSV I/O problems (event IDs ${criticalIdList}).'
    query: replace(baseQuery, '{{EVENT_IDS}}', criticalIdList)
  }
  {
    key: 'cluster-events-warning'
    deploy: !empty(warningEventIds)
    severity: 2
    displayName: 'Azure Local - cluster resource and VM events'
    description: 'Cluster resource or role failures and guest OS crashes (event IDs ${warningIdList}).'
    query: replace(baseQuery, '{{EVENT_IDS}}', warningIdList)
  }
]

resource eventAlerts 'Microsoft.Insights/scheduledQueryRules@2023-12-01' = [
  for rule in rules: if (rule.deploy) {
    name: '${namePrefix}-${rule.key}'
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
      displayName: rule.displayName
      description: rule.description
      severity: rule.severity
      enabled: true
      scopes: [
        workspaceId
      ]
      // 15 minute window with 5 minute evaluation absorbs ingestion latency.
      // autoMitigate keeps the alert stateful, so one event results in one notification.
      evaluationFrequency: 'PT5M'
      windowSize: 'PT15M'
      autoMitigate: true
      // Validation at creation would run as the alert identity, whose role assignment can take a few
      // minutes to propagate. The queries are covered by the test procedure in the README instead.
      skipQueryValidation: true
      criteria: {
        allOf: [
          {
            query: rule.query
            timeAggregation: 'Total'
            metricMeasureColumn: 'EventCount'
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
              {
                name: 'EventIdText'
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
]
