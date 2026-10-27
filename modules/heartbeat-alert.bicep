metadata description = 'Alerts when an Azure Local node stops sending Azure Monitor Agent heartbeats. Nodes that are completely missing from the workspace are detected as well.'

@description('Name of the alert rule.')
param name string

@description('Location of the alert rule (region of the workspace).')
param location string

@description('Resource ID of the Log Analytics workspace.')
param workspaceId string

@description('Resource ID of the action group.')
param actionGroupId string

@description('Arc machine names (host names) of all nodes.')
param nodeNames string[]

@description('Minutes without a heartbeat before the alert fires.')
param thresholdMinutes int

@description('Tags.')
param tags object = {}

var nodeList = join(map(nodeNames, n => '\'${toLower(n)}\''), ', ')
var query = replace(loadTextContent('../queries/node-heartbeat.kql'), '{{NODE_NAMES}}', nodeList)

resource heartbeatAlert 'Microsoft.Insights/scheduledQueryRules@2023-12-01' = {
  name: name
  location: location
  tags: tags
  kind: 'LogAlert'
  properties: {
    displayName: 'Azure Local - node heartbeat missing'
    description: 'An Azure Local node has not sent an Azure Monitor Agent heartbeat for more than ${thresholdMinutes} minutes (node down, isolated, or agent not running).'
    severity: 1
    enabled: true
    scopes: [
      workspaceId
    ]
    evaluationFrequency: 'PT5M'
    windowSize: 'PT1H'
    autoMitigate: true
    criteria: {
      allOf: [
        {
          query: query
          timeAggregation: 'Maximum'
          metricMeasureColumn: 'MinutesSinceLastHeartbeat'
          operator: 'GreaterThan'
          threshold: thresholdMinutes
          dimensions: [
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
