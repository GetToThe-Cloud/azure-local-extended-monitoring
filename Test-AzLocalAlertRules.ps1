#Requires -Version 5.1
#Requires -Modules Az.Accounts
<#
.SYNOPSIS
    Explains why a log search alert rule of the Azure Local monitoring baseline does or does not fire.

.DESCRIPTION
    Read-only, unless -CreateCanaryRule or -RemoveCanaryRule is used. For every log search alert
    rule in the monitoring resource group (or the ones named with -RuleName) it shows:

      Deployment     The latest deployments in the resource group and their state
      Configuration  Enabled, frequency, window, identity, last modified by
      Identity       The roles of the rule's identity on the scopes it queries, with their age
      Health         Resource health of the rule (does the alert service evaluate it, and does it fail)
      Alerts         Alerts the rule fired in the last 24 hours, and whether an alert processing
                     rule suppressed their notifications
      Query          The rule's own query run against the workspace over the rule's window, the way
                     the alert service runs it, evaluated against the rule's threshold and dimensions.
                     And the same query over 24 hours, to tell old data from no data.

    And once per run:
      Events         Freshness of the Watch-AzLocalVmState.ps1 events per node: time on the node
                     (TimeGenerated) against the time of arrival in the workspace, to spot clock skew
      Workspace      Table plan of the Event table (Basic and Auxiliary do not support alerts) and
                     public network access for queries
      Action groups  Email receivers and their status
      Suppression    Alert processing rules that remove action groups

    Requires Az.OperationalInsights for the query checks.

.PARAMETER ResourceGroupName
    Monitoring resource group with the alert rules.

.PARAMETER SubscriptionId
    Subscription of the monitoring resource group. Defaults to the current Az context.

.PARAMETER RuleName
    Names of the rules to check, wildcards allowed. Default: all log search alert rules in the resource group.

.PARAMETER CreateCanaryRule
    Creates the rule <prefix>-alert-canary: Heartbeat rows in the last 15 minutes, every 5 minutes,
    with the same workspace, identity and action group as the first checked rule. It fires on its
    first evaluation, normally within 10 minutes, and proves that the alert service, the identity and
    the action group work. Remove it with -RemoveCanaryRule.

.PARAMETER RemoveCanaryRule
    Removes the canary rule.

.EXAMPLE
    .\Test-AzLocalAlertRules.ps1 -ResourceGroupName rg-monitoring -RuleName azl-vm-host-state

.EXAMPLE
    .\Test-AzLocalAlertRules.ps1 -ResourceGroupName rg-monitoring -RuleName azl-vm-host-state -CreateCanaryRule
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string] $ResourceGroupName,

    [string] $SubscriptionId,

    [string[]] $RuleName = @(),

    [switch] $CreateCanaryRule,

    [switch] $RemoveCanaryRule
)

$ErrorActionPreference = 'Stop'

$ApiVersions = @{
    QueryRules   = '2023-12-01'
    Identity     = '2023-01-31'
    RoleAssign   = '2022-04-01'
    Health       = '2020-05-01'
    Alerts       = '2019-05-05-preview'
    ActionGroups = '2023-01-01'
    ActionRules  = '2021-08-08'
    Workspace    = '2023-09-01'
    Tables       = '2022-10-01'
    Deployments  = '2021-04-01'
}

$RoleNames = @{
    'acdd72a7-3385-48ef-bd42-f606fba81ae7' = 'Reader'
    '73c42c96-874c-492b-b04d-ab87d138a893' = 'Log Analytics Reader'
    '92aaf0da-9dab-42b6-94a3-d43ce8d16293' = 'Log Analytics Contributor'
    '43d0d8ad-25c7-4714-9337-8ba259a9fe05' = 'Monitoring Reader'
    '749f88d5-cbae-40b8-bcfc-e573ddc772fa' = 'Monitoring Contributor'
    'b24988ac-6180-42a0-ab88-20f7382dd24c' = 'Contributor'
    '8e3af657-a8ff-443c-a75c-2fe8c4bcb635' = 'Owner'
}

# Roles that include reading the workspace data (query/read) or, for Resource Graph, the resources
$ReadRoleIds = @(
    'acdd72a7-3385-48ef-bd42-f606fba81ae7'
    '73c42c96-874c-492b-b04d-ab87d138a893'
    '92aaf0da-9dab-42b6-94a3-d43ce8d16293'
    'b24988ac-6180-42a0-ab88-20f7382dd24c'
    '8e3af657-a8ff-443c-a75c-2fe8c4bcb635'
)

$script:Findings = [System.Collections.Generic.List[object]]::new()

$CheckColor = @{
    OK   = 'Green'
    INFO = 'Gray'
    WARN = 'Yellow'
    FAIL = 'Red'
}

# ============================================================================
# Helpers
# ============================================================================

function Write-Section {
    param([string] $Title)
    Write-Host ''
    Write-Host "=== $Title ===" -ForegroundColor White
}

function Write-Check {
    param(
        [ValidateSet('OK', 'INFO', 'WARN', 'FAIL')]
        [string] $Status,
        [string] $Text,
        [string] $Subject = ''
    )
    Write-Host ("  [{0}] {1}" -f $Status.PadRight(4), $Text) -ForegroundColor $CheckColor[$Status]
    if ($Status -in @('WARN', 'FAIL')) {
        $script:Findings.Add([pscustomobject]@{ Status = $Status; Subject = $Subject; Text = $Text })
    }
}

function Invoke-Arm {
    param(
        [Parameter(Mandatory)] [string] $Path,
        [string] $Method = 'GET',
        [string] $Payload
    )
    $request = @{ Path = $Path; Method = $Method }
    if ($Payload) { $request.Payload = $Payload }
    $response = Invoke-AzRestMethod @request
    if ($response.StatusCode -eq 404) { return $null }
    if ($response.StatusCode -ge 400) {
        throw "$Method $Path returned HTTP $($response.StatusCode): $($response.Content)"
    }
    if ([string]::IsNullOrWhiteSpace($response.Content)) { return $null }
    return ($response.Content | ConvertFrom-Json)
}

function Get-Age {
    # Minutes between a timestamp (string or DateTime) and now, or $null.
    param($Timestamp)
    if (-not $Timestamp) { return $null }
    $utc = ([datetime]$Timestamp).ToUniversalTime()
    return [int][math]::Floor(((Get-Date).ToUniversalTime() - $utc).TotalMinutes)
}

function Format-Utc {
    param($Value)
    if (-not $Value) { return '?' }
    return ('{0:yyyy-MM-dd HH:mm} UTC' -f ([datetime]$Value).ToUniversalTime())
}

function Get-RoleName {
    param([string] $RoleDefinitionId)
    $guid = ($RoleDefinitionId -split '/')[-1]
    if ($RoleNames.ContainsKey($guid)) { return $RoleNames[$guid] }
    return $guid
}

function Test-ScopeCovers {
    param([string] $AssignmentScope, [string] $TargetScope)
    $assignment = $AssignmentScope.TrimEnd('/').ToLowerInvariant()
    $target = $TargetScope.TrimEnd('/').ToLowerInvariant()
    if ($assignment -eq '') { return $true }
    return ($target -eq $assignment) -or $target.StartsWith("$assignment/")
}

function Test-ReadAccess {
    # Prints the role assignments of a principal that apply to a scope; returns $true when one gives read access.
    param([string] $PrincipalId, [string] $Scope, [string] $Label, [string] $Subject)
    $path = "$Scope/providers/Microsoft.Authorization/roleAssignments?api-version=$($ApiVersions.RoleAssign)&`$filter=principalId%20eq%20'$PrincipalId'"
    try {
        $response = Invoke-Arm -Path $path
    }
    catch {
        Write-Check 'WARN' "Cannot read the role assignments on ${Label}: $($_.Exception.Message)" $Subject
        return $false
    }

    $hasRead = $false
    foreach ($assignment in @($response.value)) {
        if (-not $assignment) { continue }
        if (-not (Test-ScopeCovers -AssignmentScope "$($assignment.properties.scope)" -TargetScope $Scope)) { continue }
        $guid = ("$($assignment.properties.roleDefinitionId)" -split '/')[-1]
        $age = Get-Age $assignment.properties.createdOn
        $where = if ("$($assignment.properties.scope)".TrimEnd('/') -ieq $Scope.TrimEnd('/')) { 'on' } else { "inherited from $($assignment.properties.scope) to" }
        if ($ReadRoleIds -contains $guid) {
            $hasRead = $true
            Write-Check 'OK' "$(Get-RoleName $guid) $where $Label, assigned $age minutes ago"
        }
        else {
            Write-Check 'INFO' "$(Get-RoleName $guid) $where $Label (no read access to the data)"
        }
    }
    if (-not $hasRead) {
        Write-Check 'FAIL' "The identity has no role on $Label that lets it read the data: the rule cannot run its query" $Subject
    }
    return $hasRead
}

function Get-RuleEvaluation {
    # Evaluates query results the way the rule does: per dimension combination, aggregated and compared to the threshold.
    param([object[]] $Rows, $Criteria)

    $dimensionNames = @($Criteria.dimensions | Where-Object { $_ } | ForEach-Object { "$($_.name)" })
    $groups = [ordered]@{}
    foreach ($row in $Rows) {
        $key = '(no dimensions)'
        if ($dimensionNames.Count -gt 0) {
            $key = ($dimensionNames | ForEach-Object { "$_=$($row.$_)" }) -join ', '
        }
        if (-not $groups.Contains($key)) { $groups[$key] = [System.Collections.Generic.List[double]]::new() }
        if ($Criteria.metricMeasureColumn) {
            $raw = "$($row.($Criteria.metricMeasureColumn))"
            $number = 0.0
            if ([double]::TryParse($raw, [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref] $number)) {
                $groups[$key].Add($number)
            }
        }
        else {
            $groups[$key].Add(1)
        }
    }

    $threshold = [double]$Criteria.threshold
    foreach ($key in $groups.Keys) {
        $values = $groups[$key]
        $value = 0.0
        if ($values.Count -gt 0) {
            switch ("$($Criteria.timeAggregation)") {
                'Count' { $value = $values.Count }
                'Total' { $value = ($values | Measure-Object -Sum).Sum }
                'Average' { $value = ($values | Measure-Object -Average).Average }
                'Minimum' { $value = ($values | Measure-Object -Minimum).Minimum }
                default { $value = ($values | Measure-Object -Maximum).Maximum }
            }
        }
        $fires = $false
        switch ("$($Criteria.operator)") {
            'GreaterThan' { $fires = $value -gt $threshold }
            'GreaterThanOrEqual' { $fires = $value -ge $threshold }
            'LessThan' { $fires = $value -lt $threshold }
            'LessThanOrEqual' { $fires = $value -le $threshold }
            default { $fires = $value -eq $threshold }
        }
        [pscustomobject]@{
            Dimensions = $key
            Value      = $value
            Fires      = $fires
        }
    }
}

function Invoke-WorkspaceQuery {
    param([string] $CustomerId, [string] $Query, [timespan] $Timespan)
    $request = @{ WorkspaceId = $CustomerId; Query = $Query; ErrorAction = 'Stop' }
    if ($Timespan) { $request.Timespan = $Timespan }
    return @((Invoke-AzOperationalInsightsQuery @request).Results)
}

# ============================================================================
# Main
# ============================================================================

if ($SubscriptionId) {
    Set-AzContext -Subscription $SubscriptionId | Out-Null
}
$context = Get-AzContext
if (-not $context -or -not $context.Subscription) {
    throw 'No Az context. Run Connect-AzAccount first.'
}
$subscriptionIdInUse = $context.Subscription.Id
$resourceGroupId = "/subscriptions/$subscriptionIdInUse/resourceGroups/$ResourceGroupName"
$canQuery = [bool](Get-Command Invoke-AzOperationalInsightsQuery -ErrorAction SilentlyContinue)

Write-Host "Subscription $($context.Subscription.Name) ($subscriptionIdInUse), signed in as $($context.Account.Id)" -ForegroundColor Gray
Write-Host "Time now: $((Get-Date).ToUniversalTime().ToString('yyyy-MM-dd HH:mm')) UTC" -ForegroundColor Gray

$allRules = @()
$ruleList = Invoke-Arm -Path "$resourceGroupId/providers/Microsoft.Insights/scheduledQueryRules?api-version=$($ApiVersions.QueryRules)"
if ($ruleList) { $allRules = @($ruleList.value | Where-Object { $_ }) }

# ----------------------------------------------------------------------------
# Canary rule
# ----------------------------------------------------------------------------

$prefix = 'azl'
$firstRule = $allRules | Where-Object { $_.name -like '*-vm-host-state' } | Select-Object -First 1
if (-not $firstRule) { $firstRule = $allRules | Select-Object -First 1 }
if ($firstRule) { $prefix = ($firstRule.name -split '-')[0] }
$canaryName = "$prefix-alert-canary"
$canaryId = "$resourceGroupId/providers/Microsoft.Insights/scheduledQueryRules/$canaryName"

if ($RemoveCanaryRule) {
    Invoke-Arm -Path "$($canaryId)?api-version=$($ApiVersions.QueryRules)" -Method DELETE | Out-Null
    Write-Host "Removed $canaryName." -ForegroundColor Green
    return
}

if ($CreateCanaryRule) {
    $template = $firstRule
    if ($RuleName.Count -gt 0) {
        $named = $allRules | Where-Object { $n = $_.name; @($RuleName | Where-Object { $n -like $_ }).Count -gt 0 } | Select-Object -First 1
        if ($named) { $template = $named }
    }
    if (-not $template) { throw "No log search alert rule in $ResourceGroupName to copy the workspace, identity and action group from." }

    $identity = @{ type = 'None' }
    $identityText = 'no identity: it runs with your permissions'
    if ("$($template.identity.type)" -match 'UserAssigned') {
        $identityResourceId = @($template.identity.userAssignedIdentities.PSObject.Properties.Name)[0]
        $identity = @{ type = 'UserAssigned'; userAssignedIdentities = @{ $identityResourceId = @{} } }
        $identityText = "identity $(($identityResourceId -split '/')[-1])"
    }

    $body = @{
        location   = $template.location
        kind       = 'LogAlert'
        identity   = $identity
        properties = @{
            displayName         = 'Azure Local - alert canary (test rule, remove after use)'
            description         = "Fires when the Heartbeat table has rows in the last 15 minutes. Created by Test-AzLocalAlertRules.ps1 to prove that the alert service, the identity and the action group work. Remove with -RemoveCanaryRule."
            severity            = 4
            enabled             = $true
            scopes              = @($template.properties.scopes)
            evaluationFrequency = 'PT5M'
            windowSize          = 'PT15M'
            autoMitigate        = $true
            criteria            = @{
                allOf = @(
                    @{
                        query           = 'Heartbeat | project TimeGenerated, Computer'
                        timeAggregation = 'Count'
                        operator        = 'GreaterThan'
                        threshold       = 0
                        failingPeriods  = @{ numberOfEvaluationPeriods = 1; minFailingPeriodsToAlert = 1 }
                    }
                )
            }
            actions             = @{ actionGroups = @($template.properties.actions.actionGroups) }
        }
    }
    Invoke-Arm -Path "$($canaryId)?api-version=$($ApiVersions.QueryRules)" -Method PUT -Payload ($body | ConvertTo-Json -Depth 20) | Out-Null
    Write-Host "Created $canaryName on the same workspace and action group as $($template.name), with $identityText." -ForegroundColor Green
    Write-Host 'It should fire within about 10 minutes. Then:' -ForegroundColor Green
    Write-Host '  - Fires and you get the mail: the alert service, identity and action group work; the problem is in the rule or its data.'
    Write-Host '  - Fires, no mail: the action group or an alert processing rule (run this script again to see isSuppressed).'
    Write-Host '  - Does not fire: the alert service cannot run queries on the workspace with this identity.'
    Write-Host "Remove it afterwards: .\Test-AzLocalAlertRules.ps1 -ResourceGroupName $ResourceGroupName -RemoveCanaryRule"
    return
}

# ----------------------------------------------------------------------------
# Deployments
# ----------------------------------------------------------------------------

Write-Section "Latest deployments in $ResourceGroupName"
try {
    $deployments = Invoke-Arm -Path "$resourceGroupId/providers/Microsoft.Resources/deployments?api-version=$($ApiVersions.Deployments)&`$top=5"
    foreach ($deployment in @($deployments.value | Where-Object { $_ })) {
        $state = "$($deployment.properties.provisioningState)"
        $status = if ($state -eq 'Succeeded') { 'OK' } elseif ($state -eq 'Failed') { 'WARN' } else { 'INFO' }
        Write-Check $status ("{0}: {1} at {2}" -f $deployment.name, $state, (Format-Utc $deployment.properties.timestamp)) 'Deployment'
    }
}
catch {
    Write-Check 'INFO' "Cannot list deployments: $($_.Exception.Message)"
}

# ----------------------------------------------------------------------------
# Rules
# ----------------------------------------------------------------------------

$rules = $allRules | Where-Object { $_.name -ne $canaryName }
if ($RuleName.Count -gt 0) {
    $rules = $allRules | Where-Object { $n = $_.name; @($RuleName | Where-Object { $n -like $_ }).Count -gt 0 }
}
$rules = @($rules)
if ($rules.Count -eq 0) {
    throw "No matching log search alert rules found in $ResourceGroupName."
}

$workspaceCache = @{}
$actionGroupIds = @()
$eventSources = @()

foreach ($rule in $rules) {
    $p = $rule.properties
    $subject = $rule.name
    Write-Section "Rule $($rule.name) ($($p.displayName))"

    # Configuration
    if ($p.enabled) { Write-Check 'OK' 'Enabled' }
    else { Write-Check 'FAIL' 'Disabled' $subject }
    Write-Check 'INFO' "Evaluates every $($p.evaluationFrequency) over $($p.windowSize), autoMitigate $($p.autoMitigate), skipQueryValidation $($p.skipQueryValidation)"
    if ($rule.systemData) {
        Write-Check 'INFO' ("Last modified {0} by {1} ({2})" -f (Format-Utc $rule.systemData.lastModifiedAt), $rule.systemData.lastModifiedBy, $rule.systemData.lastModifiedByType)
    }
    $actionGroupIds += @($p.actions.actionGroups)

    $criteria = @($p.criteria.allOf)[0]
    $scope = "$(@($p.scopes)[0])"
    $usesResourceGraph = "$($criteria.query)" -match 'arg\(\s*""\s*\)'
    if ("$($criteria.query)" -match 'Source\s*==\s*"([^"]+)"') { $eventSources += $Matches[1] }

    # Identity
    $principalId = $null
    $identityType = "$($rule.identity.type)"
    if (-not $identityType -or $identityType -eq 'None') {
        Write-Check 'WARN' "No managed identity: the query runs with the permissions $($rule.systemData.lastModifiedBy) had when the rule was last saved" $subject
    }
    elseif ($identityType -match 'UserAssigned') {
        $identityResourceId = @($rule.identity.userAssignedIdentities.PSObject.Properties.Name)[0]
        $principalId = "$($rule.identity.userAssignedIdentities.PSObject.Properties[$identityResourceId].Value.principalId)"
        if (-not $principalId) {
            $identityResource = Invoke-Arm -Path "$($identityResourceId)?api-version=$($ApiVersions.Identity)"
            if ($identityResource) { $principalId = "$($identityResource.properties.principalId)" }
        }
        if ($principalId) {
            Write-Check 'OK' "Runs as user-assigned identity $(($identityResourceId -split '/')[-1]) (principal $principalId)"
        }
        else {
            Write-Check 'FAIL' "User-assigned identity $identityResourceId not found" $subject
        }
    }
    else {
        $principalId = "$($rule.identity.principalId)"
        Write-Check 'OK' "Runs as its system-assigned identity (principal $principalId)"
    }

    if ($principalId) {
        Test-ReadAccess -PrincipalId $principalId -Scope $scope -Label "the rule scope ($(($scope -split '/')[-1]))" -Subject $subject | Out-Null
        if ($usesResourceGraph) {
            Write-Check 'INFO' 'Resource Graph query: the identity only sees resources it has Reader on (or inherits it for)'
        }
    }

    # Resource health
    $healthUnknown = $false
    try {
        $health = Invoke-Arm -Path "$($rule.id)/providers/Microsoft.ResourceHealth/availabilityStatuses/current?api-version=$($ApiVersions.Health)"
        if ($health) {
            $state = "$($health.properties.availabilityState)"
            $since = $health.properties.occuredTime
            if (-not $since) { $since = $health.properties.occurredTime }
            $text = "Resource health: $state. $($health.properties.summary) $($health.properties.reasonType)".Trim()
            if ($since) { $text += " (since $(Format-Utc $since))" }
            # Unknown is judged after the fired alerts are known: it lags behind and also shows on rules that fire
            $status = switch ($state) { 'Available' { 'OK' } 'Unknown' { 'INFO' } default { 'FAIL' } }
            Write-Check $status $text $subject
            $healthUnknown = ($state -eq 'Unknown')
        }
        else {
            Write-Check 'INFO' 'Resource health: no status'
        }
    }
    catch {
        Write-Check 'INFO' "Resource health not readable: $($_.Exception.Message)"
    }

    # Alerts fired by this rule
    $alerts = @()
    $alertsKnown = $false
    try {
        $alertsPath = "/subscriptions/$subscriptionIdInUse/providers/Microsoft.AlertsManagement/alerts?api-version=$($ApiVersions.Alerts)&timeRange=1d&alertRule=$([uri]::EscapeDataString($rule.id))"
        $ruleId = "$($rule.id)"
        $alerts = @((Invoke-Arm -Path $alertsPath).value | Where-Object { $_ -and "$($_.properties.essentials.alertRule)" -ieq $ruleId })
        $alertsKnown = $true
        if ($alerts.Count -eq 0) {
            Write-Check 'INFO' 'No alerts from this rule in the last 24 hours'
        }
        foreach ($alert in $alerts) {
            $e = $alert.properties.essentials
            $suppressed = [bool]$e.actionStatus.isSuppressed
            $status = if ($suppressed) { 'WARN' } else { 'OK' }
            $text = "Alert {0}: {1}, {2}" -f (Format-Utc $e.startDateTime), $e.monitorCondition, $e.alertState
            if ($suppressed) { $text += ', notifications SUPPRESSED by an alert processing rule' }
            Write-Check $status $text $subject
        }
    }
    catch {
        Write-Check 'INFO' "Cannot list fired alerts: $($_.Exception.Message)"
    }

    if ($healthUnknown -and $alertsKnown) {
        if ($alerts.Count -gt 0) {
            Write-Check 'INFO' 'Resource health Unknown, but the rule fired: Resource health lags behind and can be ignored here'
        }
        elseif ([System.Xml.XmlConvert]::ToTimeSpan("$($p.evaluationFrequency)").TotalMinutes -le 15) {
            Write-Check 'WARN' 'Resource health Unknown and no alerts in 24 hours: the alert service may not complete its evaluations of this rule' $subject
        }
    }

    # The rule's own query
    if (-not $canQuery) {
        Write-Check 'WARN' 'Install-Module Az.OperationalInsights to test the query of the rule' $subject
        continue
    }
    if ($scope -notmatch '/providers/Microsoft\.OperationalInsights/workspaces/') {
        Write-Check 'INFO' "Scope is not a Log Analytics workspace, query not tested: $scope"
        continue
    }

    if (-not $workspaceCache.ContainsKey($scope)) {
        $workspaceCache[$scope] = Invoke-Arm -Path "$($scope)?api-version=$($ApiVersions.Workspace)"
    }
    $workspace = $workspaceCache[$scope]
    if (-not $workspace) {
        Write-Check 'FAIL' "Workspace $scope not found" $subject
        continue
    }

    $window = [System.Xml.XmlConvert]::ToTimeSpan("$($p.windowSize)")
    try {
        $windowRows = @(Invoke-WorkspaceQuery -CustomerId $workspace.properties.customerId -Query $criteria.query -Timespan $window)
        $dayRows = @(Invoke-WorkspaceQuery -CustomerId $workspace.properties.customerId -Query $criteria.query -Timespan (New-TimeSpan -Days 1))
    }
    catch {
        Write-Check 'FAIL' "The query of the rule fails when you run it: $($_.Exception.Message)" $subject
        continue
    }

    $measure = if ($criteria.metricMeasureColumn) { "$($criteria.timeAggregation) of $($criteria.metricMeasureColumn)" } else { 'number of rows' }
    Write-Check 'INFO' "Condition: $measure $($criteria.operator) $($criteria.threshold), per $(@($criteria.dimensions | ForEach-Object { $_.name }) -join ' + ')"
    Write-Check 'INFO' "Query over the rule window ($($p.windowSize)): $($windowRows.Count) rows. Over 24 hours: $($dayRows.Count) rows."

    $evaluation = @(Get-RuleEvaluation -Rows $windowRows -Criteria $criteria)
    foreach ($result in $evaluation) {
        $verdict = 'does not meet the condition'
        if ($result.Fires) { $verdict = 'meets the condition' }
        Write-Check 'INFO' ("  {0}: {1} -> {2}" -f $result.Dimensions, $result.Value, $verdict)
    }
    $firing = @($evaluation | Where-Object { $_.Fires })
    if ($firing.Count -gt 0 -and $alertsKnown -and $alerts.Count -eq 0) {
        Write-Check 'FAIL' "The data meets the condition right now, yet the rule fired nothing in 24 hours: the alert service does not evaluate the rule successfully (see identity and resource health above)" $subject
    }
    elseif ($firing.Count -gt 0) {
        Write-Check 'OK' 'The data meets the condition and the rule has fired'
    }
    elseif ($dayRows.Count -gt 0 -and $windowRows.Count -eq 0) {
        Write-Check 'WARN' "Rows within 24 hours, none within the $($p.windowSize) window: the data is older than the window (event no longer written, ingestion delay or node clock, see the event freshness below)" $subject
    }
    else {
        Write-Check 'INFO' 'The data does not meet the condition: nothing to alert on right now'
    }
}

# ----------------------------------------------------------------------------
# Event freshness of Watch-AzLocalVmState.ps1
# ----------------------------------------------------------------------------

$eventSources = @($eventSources | Select-Object -Unique)
$firstWorkspace = @($workspaceCache.Values | Where-Object { $_ })[0]
if ($canQuery -and $firstWorkspace -and $eventSources.Count -gt 0) {
    foreach ($source in $eventSources) {
        Write-Section "Events of $source (last 2 days)"
        $freshnessQuery = @"
Event
| where TimeGenerated > ago(2d)
| where Source == "$source"
| summarize Events = count(), LastOnNode = max(TimeGenerated), LastArrived = max(ingestion_time()) by Computer, EventID
| extend MinutesSinceOnNode = datetime_diff('minute', now(), LastOnNode),
         MinutesSinceArrived = datetime_diff('minute', now(), LastArrived),
         ArrivalDelayMinutes = datetime_diff('minute', LastArrived, LastOnNode)
| order by Computer asc, EventID asc
"@
        try {
            $freshRows = @(Invoke-WorkspaceQuery -CustomerId $firstWorkspace.properties.customerId -Query $freshnessQuery)
        }
        catch {
            Write-Check 'WARN' "Freshness query failed: $($_.Exception.Message)" 'Events'
            continue
        }
        if ($freshRows.Count -eq 0) {
            Write-Check 'FAIL' "No events of $source in the workspace in the last 2 days" 'Events'
        }
        foreach ($row in $freshRows) {
            $sinceNode = [int]$row.MinutesSinceOnNode
            $delay = [int]$row.ArrivalDelayMinutes
            $text = "{0} event {1}: {2} events, last one {3} min ago on the node clock, arrived {4} min ago, delay {5} min" -f $row.Computer, $row.EventID, $row.Events, $sinceNode, $row.MinutesSinceArrived, $delay
            $status = 'OK'
            if ($sinceNode -gt 15) { $status = 'WARN' }
            if ($delay -gt 10 -or $delay -lt -2) {
                $status = 'WARN'
                $text += ' (large difference between node time and arrival: check ingestion or the node clock)'
            }
            Write-Check $status $text 'Events'
        }
    }
}

# ----------------------------------------------------------------------------
# Workspace
# ----------------------------------------------------------------------------

foreach ($scope in $workspaceCache.Keys) {
    $workspace = $workspaceCache[$scope]
    if (-not $workspace) { continue }
    Write-Section "Workspace $($workspace.name)"
    Write-Check 'INFO' "Public network access for queries: $($workspace.properties.publicNetworkAccessForQuery), for ingestion: $($workspace.properties.publicNetworkAccessForIngestion)"
    try {
        $table = Invoke-Arm -Path "$scope/tables/Event?api-version=$($ApiVersions.Tables)"
        if ($table) {
            $plan = "$($table.properties.plan)"
            if ($plan -and $plan -ne 'Analytics') {
                Write-Check 'FAIL' "Event table plan is ${plan}: log search alerts do not run on Basic or Auxiliary tables" 'Workspace'
            }
            else {
                Write-Check 'OK' "Event table plan: $plan"
            }
        }
    }
    catch {
        Write-Check 'INFO' "Cannot read the Event table: $($_.Exception.Message)"
    }
}

# ----------------------------------------------------------------------------
# Action groups
# ----------------------------------------------------------------------------

Write-Section 'Action groups'
foreach ($actionGroupId in @($actionGroupIds | Where-Object { $_ } | Select-Object -Unique)) {
    try {
        $group = Invoke-Arm -Path "$($actionGroupId)?api-version=$($ApiVersions.ActionGroups)"
    }
    catch {
        Write-Check 'WARN' "Cannot read action group ${actionGroupId}: $($_.Exception.Message)" 'Action group'
        continue
    }
    if (-not $group) {
        Write-Check 'FAIL' "Action group $actionGroupId not found" 'Action group'
        continue
    }
    $status = if ($group.properties.enabled) { 'OK' } else { 'FAIL' }
    Write-Check $status "$($group.name): enabled $($group.properties.enabled)" 'Action group'
    foreach ($receiver in @($group.properties.emailReceivers | Where-Object { $_ })) {
        $receiverStatus = "$($receiver.status)"
        $status = if ($receiverStatus -eq 'Disabled') { 'FAIL' } else { 'OK' }
        $text = "Email $($receiver.name) <$($receiver.emailAddress)>: $receiverStatus"
        if ($receiverStatus -eq 'Disabled') { $text += ' (unsubscribed: re-enable the receiver in the action group)' }
        Write-Check $status $text 'Action group'
    }
}

# ----------------------------------------------------------------------------
# Alert processing rules that remove notifications
# ----------------------------------------------------------------------------

Write-Section 'Alert processing rules that remove action groups'
try {
    $processingRules = @((Invoke-Arm -Path "/subscriptions/$subscriptionIdInUse/providers/Microsoft.AlertsManagement/actionRules?api-version=$($ApiVersions.ActionRules)").value | Where-Object { $_ })
    $removing = @($processingRules | Where-Object { @($_.properties.actions | Where-Object { $_.actionType -eq 'RemoveAllActionGroups' }).Count -gt 0 })
    if ($removing.Count -eq 0) {
        Write-Check 'OK' 'None in this subscription'
    }
    foreach ($processingRule in $removing) {
        $schedule = $processingRule.properties.schedule
        $when = 'always (no schedule)'
        if ($schedule) {
            $recurrence = @($schedule.recurrences | ForEach-Object { "$($_.recurrenceType) $(@($_.daysOfWeek) -join ',') $($_.startTime)-$($_.endTime)" }) -join '; '
            $when = "$($schedule.timeZone): $recurrence".Trim()
        }
        $status = if ($processingRule.properties.enabled -and -not $schedule) { 'WARN' } else { 'INFO' }
        Write-Check $status "$($processingRule.name) (enabled $($processingRule.properties.enabled)): $when" 'Suppression'
    }
}
catch {
    Write-Check 'INFO' "Cannot list alert processing rules: $($_.Exception.Message)"
}

# ----------------------------------------------------------------------------
# Summary
# ----------------------------------------------------------------------------

Write-Section 'Findings'
if ($script:Findings.Count -eq 0) {
    Write-Host '  Nothing wrong found.' -ForegroundColor Green
}
else {
    foreach ($finding in $script:Findings) {
        Write-Host ("  [{0}] {1}: {2}" -f $finding.Status.PadRight(4), $finding.Subject, $finding.Text) -ForegroundColor $CheckColor[$finding.Status]
    }
}
