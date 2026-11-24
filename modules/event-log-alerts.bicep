metadata description = 'Log search alerts on the node events collected by the supplemental DCR: failover clustering, Hyper-V, unexpected restarts, storage and other node events.'

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

@description('KQL condition on the Event table for the events that raise a Sev1 alert. Empty = no Sev1 rule.')
param criticalEventFilter string

@description('KQL condition on the Event table for the events that raise a Sev2 alert. Empty = no Sev2 rule.')
param warningEventFilter string

@description('Readable list of the Sev1 events, for the rule description.')
param criticalEventSummary string

@description('Readable list of the Sev2 events, for the rule description.')
param warningEventSummary string

@description('Tags.')
param tags object = {}

var baseQuery = loadTextContent('../queries/node-events.kql')

// The rule names stay "cluster-events-*" so an upgrade updates the existing rules in place.
var rules = [
  {
    key: 'cluster-events-critical'
    deploy: !empty(criticalEventFilter)
    severity: 1
    displayName: 'Azure Local - critical node events'
    description: 'Node out of the cluster, quorum loss, CSV I/O problems, unexpected restarts or bugchecks. Events: ${criticalEventSummary}.'
    query: replace(baseQuery, '{{EVENT_FILTER}}', criticalEventFilter)
  }
  {
    key: 'cluster-events-warning'
    deploy: !empty(warningEventFilter)
    severity: 2
    displayName: 'Azure Local - cluster, VM and storage events'
    description: 'Cluster resource, role or network failures, guest OS crashes, storage stalls, checkpoint or live migration failures. Events: ${warningEventSummary}.'
    query: replace(baseQuery, '{{EVENT_FILTER}}', warningEventFilter)
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
      // Skips only the query syntax check. The service still checks the identity's access to the
      // workspace when the rule is saved, which is why Deploy-AzLocalMonitoring.ps1 creates the
      // identity and its roles first and deploys the rules after the roles have propagated.
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
