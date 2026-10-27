metadata description = 'Role assignment for a service principal on a Log Analytics workspace. Deploy to the resource group of the workspace.'

@description('Name of the Log Analytics workspace.')
param workspaceName string

@description('Principal ID of the managed identity.')
param principalId string

@description('GUID of the built-in role definition.')
param roleDefinitionId string

@description('Description of the role assignment.')
param assignmentDescription string = ''

resource workspace 'Microsoft.OperationalInsights/workspaces@2023-09-01' existing = {
  name: workspaceName
}

resource roleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(workspace.id, principalId, roleDefinitionId)
  scope: workspace
  properties: {
    principalId: principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleDefinitionId)
    description: assignmentDescription
  }
}
