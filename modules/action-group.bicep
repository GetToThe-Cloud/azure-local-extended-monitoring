metadata description = 'Action group for Azure Local alerts.'

@description('Name of the action group.')
param name string

@description('Short name of the action group (max 12 characters).')
@maxLength(12)
param shortName string

@description('E-mail receivers: array of { name, emailAddress }.')
param emailReceivers array

@description('Tags.')
param tags object = {}

resource actionGroup 'Microsoft.Insights/actionGroups@2023-01-01' = {
  name: name
  location: 'global'
  tags: tags
  properties: {
    groupShortName: shortName
    enabled: true
    emailReceivers: [
      for r in emailReceivers: {
        name: r.name
        emailAddress: r.emailAddress
        useCommonAlertSchema: true
      }
    ]
  }
}

@description('Resource ID of the action group.')
output id string = actionGroup.id
