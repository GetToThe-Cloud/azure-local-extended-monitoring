metadata description = 'Role assignment for a service principal on the target resource group.'

@description('Principal ID of the managed identity.')
param principalId string

@description('GUID of the built-in role definition.')
param roleDefinitionId string

@description('Description of the role assignment.')
param assignmentDescription string = ''

resource roleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(resourceGroup().id, principalId, roleDefinitionId)
  properties: {
    principalId: principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', roleDefinitionId)
    description: assignmentDescription
  }
}
