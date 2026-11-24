metadata description = 'Supplemental data collection rule for node events and performance counters on Azure Local nodes, associated with every node. Leaves the Insights (AzureStackHCI-) DCR untouched.'

@description('Name of the data collection rule.')
param dcrName string

@description('Location of the DCR. Must be the region of the Log Analytics workspace.')
param location string

@description('Resource ID of the Log Analytics workspace.')
param workspaceId string

@description('XPath queries for the Windows event logs to collect.')
param xPathQueries string[]

@description('Performance counters to collect, for example \'\\Hyper-V Virtual Storage Device(*)\\Latency\'. Empty = no counters.')
param performanceCounters string[] = []

@description('Sampling interval of the performance counters in seconds.')
@minValue(10)
param performanceCounterIntervalSeconds int = 300

@description('Arc machine names of all cluster nodes.')
param nodeNames string[]

@description('Subscription of the cluster resource group.')
param clusterSubscriptionId string

@description('Resource group with the Arc machines of the nodes.')
param clusterResourceGroupName string

@description('Tags.')
param tags object = {}

var eventDataSources = empty(xPathQueries)
  ? {}
  : {
      windowsEventLogs: [
        {
          name: 'azureLocalClusterEvents'
          streams: [
            'Microsoft-Event'
          ]
          xPathQueries: xPathQueries
        }
      ]
    }

var counterDataSources = empty(performanceCounters)
  ? {}
  : {
      performanceCounters: [
        {
          name: 'azureLocalNodeCounters'
          streams: [
            'Microsoft-Perf'
          ]
          samplingFrequencyInSeconds: performanceCounterIntervalSeconds
          counterSpecifiers: performanceCounters
        }
      ]
    }

var streams = concat(empty(xPathQueries) ? [] : ['Microsoft-Event'], empty(performanceCounters) ? [] : ['Microsoft-Perf'])

// A machine with Azure Monitor Agent can be associated with multiple DCRs. Using a
// separate DCR keeps the Insights DCR (with its special data stream) as Insights manages it.
resource dcr 'Microsoft.Insights/dataCollectionRules@2023-03-11' = {
  name: dcrName
  location: location
  tags: tags
  kind: 'Windows'
  properties: {
    description: 'Node events and performance counters from Azure Local nodes. Supplements the AzureStackHCI- Insights DCR.'
    dataSources: union(eventDataSources, counterDataSources)
    destinations: {
      logAnalytics: [
        {
          name: 'workspace'
          workspaceResourceId: workspaceId
        }
      ]
    }
    dataFlows: [
      {
        streams: streams
        destinations: [
          'workspace'
        ]
      }
    ]
  }
}

module associations 'dcr-association.bicep' = {
  name: take('dcra-${uniqueString(dcrName, clusterResourceGroupName)}', 64)
  scope: resourceGroup(clusterSubscriptionId, clusterResourceGroupName)
  params: {
    associationName: '${dcrName}-assoc'
    dataCollectionRuleId: dcr.id
    nodeNames: nodeNames
  }
}

@description('Resource ID of the data collection rule.')
output id string = dcr.id
