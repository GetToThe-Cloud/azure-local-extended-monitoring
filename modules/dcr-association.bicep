metadata description = 'Associates a data collection rule with Azure Local nodes (Microsoft.HybridCompute/machines). Deploy to the resource group of the nodes.'

@description('Name of the association.')
param associationName string

@description('Resource ID of the data collection rule.')
param dataCollectionRuleId string

@description('Arc machine names of the nodes.')
param nodeNames string[]

resource nodes 'Microsoft.HybridCompute/machines@2024-07-10' existing = [
  for nodeName in nodeNames: {
    name: nodeName
  }
]

resource associations 'Microsoft.Insights/dataCollectionRuleAssociations@2023-03-11' = [
  for (nodeName, i) in nodeNames: {
    name: associationName
    scope: nodes[i]
    properties: {
      description: 'Azure Local failover clustering and Hyper-V event collection.'
      dataCollectionRuleId: dataCollectionRuleId
    }
  }
]
