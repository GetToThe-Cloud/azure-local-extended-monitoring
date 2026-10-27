metadata description = 'Supplemental data collection rule for failover clustering and Hyper-V events on Azure Local nodes, associated with every node. Leaves the Insights (AzureStackHCI-) DCR untouched.'

@description('Name of the data collection rule.')
param dcrName string

@description('Location of the DCR. Must be the region of the Log Analytics workspace.')
param location string

@description('Resource ID of the Log Analytics workspace.')
param workspaceId string

@description('XPath queries for the Windows event logs to collect.')
param xPathQueries string[]

@description('Arc machine names of all cluster nodes.')
param nodeNames string[]

@description('Subscription of the cluster resource group.')
param clusterSubscriptionId string

@description('Resource group with the Arc machines of the nodes.')
param clusterResourceGroupName string

@description('Tags.')
param tags object = {}

// A machine with Azure Monitor Agent can be associated with multiple DCRs. Using a
// separate DCR keeps the Insights DCR (with its special data stream) as Insights manages it.
resource dcr 'Microsoft.Insights/dataCollectionRules@2023-03-11' = {
  name: dcrName
  location: location
  tags: tags
  kind: 'Windows'
  properties: {
    description: 'Failover clustering and Hyper-V events from Azure Local nodes. Supplements the AzureStackHCI- Insights DCR.'
    dataSources: {
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
        streams: [
          'Microsoft-Event'
        ]
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
