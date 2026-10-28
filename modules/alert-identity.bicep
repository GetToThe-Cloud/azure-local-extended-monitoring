metadata description = 'User-assigned managed identity that every log search alert rule of this template runs its query with, so the rules do not depend on the permissions of whoever deployed or last edited them.'

@description('Name of the managed identity.')
param name string

@description('Location of the identity.')
param location string

@description('Tags.')
param tags object = {}

resource identity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: name
  location: location
  tags: tags
}

@description('Resource ID of the identity.')
output id string = identity.id

@description('Principal (object) ID of the identity.')
output principalId string = identity.properties.principalId
