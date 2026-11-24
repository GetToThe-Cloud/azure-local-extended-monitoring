metadata description = 'Log search alerts on WHEA-Logger hardware errors from the Azure Local nodes: fatal errors (Sev1) and a pile-up of corrected errors (Sev2).'

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

@description('Number of corrected hardware errors per node and event ID within 24 hours that raises the Sev2 alert.')
@minValue(1)
param correctedErrorThreshold int

@description('Tags.')
param tags object = {}

var rules = [
  {
    key: 'hardware-errors-fatal'
    severity: 1
    displayName: 'Azure Local - fatal hardware error'
    description: 'WHEA-Logger reported a fatal hardware error on an Azure Local node, for example 18 (processor) or 46 (memory). Windows logs it at the next start, so the node already went down once. Open a hardware case before the next failure.'
    query: loadTextContent('../queries/hardware-errors-fatal.kql')
    evaluationFrequency: 'PT5M'
    windowSize: 'PT15M'
    operator: 'GreaterThan'
    threshold: 0
  }
  {
    key: 'hardware-errors-corrected'
    severity: 2
    displayName: 'Azure Local - corrected hardware errors piling up'
    description: 'At least ${correctedErrorThreshold} corrected hardware errors of the same type on an Azure Local node within 24 hours (WHEA-Logger warnings, for example 17 PCI Express, 19 processor or 47 memory). Check the component in the event and the BMC log.'
    query: loadTextContent('../queries/hardware-errors-corrected.kql')
    evaluationFrequency: 'PT1H'
    windowSize: 'P1D'
    operator: 'GreaterThanOrEqual'
    threshold: correctedErrorThreshold
  }
]

resource hardwareAlerts 'Microsoft.Insights/scheduledQueryRules@2023-12-01' = [
  for rule in rules: {
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
      evaluationFrequency: rule.evaluationFrequency
      windowSize: rule.windowSize
      autoMitigate: true
      // Skips only the query syntax check; see event-log-alerts.bicep.
      skipQueryValidation: true
      criteria: {
        allOf: [
          {
            query: rule.query
            timeAggregation: 'Total'
            metricMeasureColumn: 'EventCount'
            operator: rule.operator
            threshold: rule.threshold
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
