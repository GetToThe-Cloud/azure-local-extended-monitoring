metadata description = 'Optional Arc extensions on an Azure Local cluster: Azure Monitor Agent and health alerts (AzureEdgeAlerts). Deploy to the resource group of the cluster.'

@description('Name of the Azure Local cluster.')
param clusterName string

@description('Install the Azure Monitor Agent extension (not needed when Insights is already enabled).')
param deployAma bool

@description('Install the health alerts extension.')
param deployHealthAlerts bool

@description('Publisher of the AzureEdgeAlerts extension.')
param healthAlertsPublisher string

@description('Type of the AzureEdgeAlerts extension.')
param healthAlertsType string

var deployHealthAlertsExtension = deployHealthAlerts && !empty(healthAlertsPublisher) && !empty(healthAlertsType)

resource cluster 'Microsoft.AzureStackHCI/clusters@2024-04-01' existing = {
  name: clusterName
}

resource arcSettings 'Microsoft.AzureStackHCI/clusters/arcSettings@2024-04-01' existing = {
  parent: cluster
  name: 'default'
}

// Cluster-aware: the extension is installed on every node, including nodes added later.
resource ama 'Microsoft.AzureStackHCI/clusters/arcSettings/extensions@2024-04-01' = if (deployAma) {
  parent: arcSettings
  name: 'AzureMonitorWindowsAgent'
  properties: {
    extensionParameters: {
      publisher: 'Microsoft.Azure.Monitor'
      type: 'AzureMonitorWindowsAgent'
      autoUpgradeMinorVersion: false
      enableAutomaticUpgrade: true
    }
  }
}

// Same extension the portal installs via Capabilities > Health alerts.
resource healthAlerts 'Microsoft.AzureStackHCI/clusters/arcSettings/extensions@2024-04-01' = if (deployHealthAlertsExtension) {
  parent: arcSettings
  name: 'AzureEdgeAlerts'
  properties: {
    extensionParameters: {
      publisher: healthAlertsPublisher
      type: healthAlertsType
      enableAutomaticUpgrade: true
    }
  }
}
