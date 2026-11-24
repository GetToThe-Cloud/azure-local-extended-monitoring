metadata description = 'Log search alerts on Microsoft Defender attack surface reduction (ASR) events from the Azure Local nodes: blocks (1121) and rules that are set to Block (5007).'

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

@description('ASR rules that must stay in Audit. Empty = every ASR rule.')
param auditOnlyRuleIds string[]

@description('ASR rules whose blocks do not raise an alert.')
param blockExcludedRuleIds string[]

@description('Tags.')
param tags object = {}

var auditOnlyList = join(map(auditOnlyRuleIds, id => '"${toLower(id)}"'), ', ')
var excludedList = join(map(blockExcludedRuleIds, id => '"${toLower(id)}"'), ', ')

var rules = [
  {
    // Early warning: fires when the policy flips, usually days or weeks before the update window.
    key: 'defender-asr-rule-set-to-block'
    displayName: 'Azure Local - ASR rule set to Block'
    description: 'A Defender policy set an attack surface reduction rule that must stay in Audit on Azure Local to Block (event 5007). With the PSExec and WMI rule (d1e49aac) in Block, the next solution update fails in Cluster-Aware Updating. Fix it in the policy that sets it (Intune or Defender for Endpoint), not on the node.'
    query: replace(loadTextContent('../queries/defender-asr-rule-set-to-block.kql'), '{{AUDIT_ONLY_RULE_IDS}}', auditOnlyList)
    dimensions: [
      'NodeName'
      'RuleId'
      'SettingSource'
    ]
  }
  {
    key: 'defender-asr-block'
    displayName: 'Azure Local - ASR rule blocked an action'
    description: 'A Defender attack surface reduction rule blocked an action on an Azure Local node (event 1121). During an update, a block of WmiPrvSE.exe starting InstallMsuFiles.ps1 (rule d1e49aac) is the reason Cluster-Aware Updating fails. Note: a block during the maintenance window is not notified when an alert processing rule suppresses notifications then.'
    query: replace(loadTextContent('../queries/defender-asr-block.kql'), '{{EXCLUDED_RULE_IDS}}', excludedList)
    dimensions: [
      'NodeName'
      'RuleId'
    ]
  }
]

resource asrAlerts 'Microsoft.Insights/scheduledQueryRules@2023-12-01' = [
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
      severity: 2
      enabled: true
      scopes: [
        workspaceId
      ]
      // Same timing as the cluster event alerts: one event, one stateful alert.
      evaluationFrequency: 'PT5M'
      windowSize: 'PT15M'
      autoMitigate: true
      // Skips only the query syntax check; see event-log-alerts.bicep.
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
              for d in rule.dimensions: {
                name: d
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
