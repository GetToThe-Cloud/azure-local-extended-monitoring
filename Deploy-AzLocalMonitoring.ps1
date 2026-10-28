#Requires -Version 5.1
#Requires -Modules Az.Accounts, Az.Resources
<#
.SYNOPSIS
    Checks the prerequisites of the Azure Local monitoring baseline, fixes what can be fixed
    automatically, and deploys main.bicep when everything is in order.

.DESCRIPTION
    Run from a management workstation with Az PowerShell, signed in with Connect-AzAccount.

    Checks (and fixes where possible):
      Tooling        Az modules, Bicep CLI (installed via 'az bicep install' when Azure CLI is present)
      Parameters     main.bicepparam compiles, no placeholder values left
      Clusters       Cluster exists and is connected, node list matches the cluster
                     (corrected automatically), Arc machines of the nodes exist and are connected
      Extensions     AzureEdgeTelemetryAndDiagnostics (platform metrics), Azure Monitor Agent
                     (installed via Bicep if missing), AzureEdgeAlerts (health alerts; installed via
                     Bicep with publisher/type copied from a cluster that has it)
      Insights       Insights DCR (AzureStackHCI-) associated with every node and sending to the
                     workspace in the parameters (workspace corrected automatically when all
                     clusters use the same Insights workspace)
      Arc bridge     Arc resource bridge present and Running
      Azure          Monitoring resource group (created if missing), resource providers
                     (registered if missing)
      Permissions    Effective permissions of the signed-in identity on every scope the deployment
                     writes to. All log search alerts run as one user-assigned identity; missing
                     roleAssignments/write disables its role assignments and prints the commands
                     for someone who has the rights.
      Data flow      Heartbeat, SDDC Management events and VM state monitor events in the workspace
                     (requires Az.OperationalInsights)
      Cluster nodes  With -ConfigureClusterNodes: Health Service settings and the VM state
                     scheduled task are applied on the cluster over PowerShell remoting.

    Any check with status Fail stops the script before the deployment. Otherwise the script
    shows an Azure what-if, asks for confirmation (unless -Force) and deploys.

    The deployment runs in two phases when the alert identity or its role assignments are new.
    Phase 1 deploys everything except the log search alert rules. The script then waits until
    the role assignments are -RolePropagationMinutes old, because the Log Search Alerts service
    checks the identity's access when a rule is saved and rejects it with "The provided
    credentials have insufficient access" while a new assignment is still propagating. Phase 2
    deploys the full template and retries that specific error. When the role assignments
    already exist, the script skips straight to phase 2.

    -WhatIf runs all checks, shows what would be fixed and the Azure what-if, and changes nothing.

.PARAMETER ResourceGroupName
    Resource group for the alert rules, action group and DCR (the monitoring resource group).

.PARAMETER SubscriptionId
    Subscription of the monitoring resource group. Defaults to the current Az context.

.PARAMETER Location
    Region for the monitoring resource group if it has to be created. Defaults to the workspace region.

.PARAMETER TemplateFile
    Path to main.bicep.

.PARAMETER ParameterFile
    Path to main.bicepparam.

.PARAMETER DeploymentName
    Name of the deployment.

.PARAMETER ConfigureClusterNodes
    Apply the Health Service settings and register the VM state scheduled task on every cluster
    over PowerShell remoting (WinRM to the nodes required).

.PARAMETER NodeCredential
    Credential for PowerShell remoting to the nodes. Defaults to the current user.

.PARAMETER NodeDnsSuffix
    DNS suffix appended to node names for PowerShell remoting, for example 'corp.contoso.com'.

.PARAMETER VolumeCapacityWarningPercent
    Health Service volume capacity warning threshold applied with -ConfigureClusterNodes.

.PARAMETER VolumeCapacityCriticalPercent
    Health Service volume capacity critical threshold applied with -ConfigureClusterNodes.

.PARAMETER SkipDataFlowChecks
    Skip the queries against the Log Analytics workspace.

.PARAMETER RolePropagationMinutes
    How old a role assignment of the alert identity must be before the log search alert rules
    are deployed. Default 5. Phase 2 also retries up to three times, three minutes apart, when
    the Log Search Alerts service still reports insufficient access.

.PARAMETER Force
    Deploy without asking for confirmation after the what-if.

.EXAMPLE
    .\Deploy-AzLocalMonitoring.ps1 -ResourceGroupName rg-monitoring -WhatIf

.EXAMPLE
    .\Deploy-AzLocalMonitoring.ps1 -ResourceGroupName rg-monitoring -ConfigureClusterNodes -NodeDnsSuffix corp.contoso.com

.EXAMPLE
    .\Deploy-AzLocalMonitoring.ps1 -ResourceGroupName rg-monitoring -SubscriptionId 00000000-0000-0000-0000-000000000000 -Force
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [string] $ResourceGroupName,

    [string] $SubscriptionId,

    [string] $Location,

    [string] $TemplateFile = (Join-Path $PSScriptRoot 'main.bicep'),

    [string] $ParameterFile = (Join-Path $PSScriptRoot 'main.bicepparam'),

    [string] $DeploymentName = "azl-monitoring-$(Get-Date -Format 'yyyyMMdd-HHmmss')",

    [switch] $ConfigureClusterNodes,

    [pscredential] $NodeCredential,

    [string] $NodeDnsSuffix,

    [ValidateRange(1, 99)]
    [int] $VolumeCapacityWarningPercent = 80,

    [ValidateRange(1, 99)]
    [int] $VolumeCapacityCriticalPercent = 90,

    [switch] $SkipDataFlowChecks,

    [ValidateRange(0, 60)]
    [int] $RolePropagationMinutes = 5,

    [switch] $Force
)

$ErrorActionPreference = 'Stop'

# ============================================================================
# Constants
# ============================================================================

$ApiVersions = @{
    Cluster     = '2024-04-01'
    Machine     = '2024-07-10'
    Dcr         = '2023-03-11'
    Workspace   = '2023-09-01'
    Appliance   = '2022-10-27'
    Providers   = '2021-04-01'
    Permissions = '2022-04-01'
    Resources   = '2021-04-01'
    QueryRules  = '2023-12-01'
    Identity    = '2023-01-31'
    RoleAssign  = '2022-04-01'
}

$RoleIds = @{
    Reader             = 'acdd72a7-3385-48ef-bd42-f606fba81ae7'
    LogAnalyticsReader = '73c42c96-874c-492b-b04d-ab87d138a893'
}

# Roles that give the alert identity the read access it needs. Any of them, at the scope or above, counts.
$ReadRoleIds = @(
    'acdd72a7-3385-48ef-bd42-f606fba81ae7' # Reader
    '73c42c96-874c-492b-b04d-ab87d138a893' # Log Analytics Reader
    '92aaf0da-9dab-42b6-94a3-d43ce8d16293' # Log Analytics Contributor
    'b24988ac-6180-42a0-ab88-20f7382dd24c' # Contributor
    '8e3af657-a8ff-443c-a75c-2fe8c4bcb635' # Owner
)

# Phase 2 retries when the Log Search Alerts service still rejects the identity
$RuleDeployAttempts = 3
$RuleRetryMinutes = 3

$ExtensionNames = @{
    Telemetry   = 'AzureEdgeTelemetryAndDiagnostics'
    Ama         = 'AzureMonitorWindowsAgent'
    HealthAlert = 'AzureEdgeAlerts'
}

$RemoteScriptFolder = 'C:\ProgramData\AzLocalMonitoring'
$NodeScripts = @('Watch-AzLocalVmState.ps1', 'Register-AzLocalVmStateTask.ps1', 'Set-AzLocalHealthSettings.ps1')

# ============================================================================
# State
# ============================================================================

$script:Results = [System.Collections.Generic.List[object]]::new()
$script:Overrides = @{}
$script:Provided = @{}
$script:TemplateParameters = $null
$script:ManualRoleAssignments = $false
$script:IsWhatIf = [bool]$WhatIfPreference

$StatusColor = @{
    Pass    = 'Green'
    Fixed   = 'Cyan'
    Info    = 'Gray'
    Warning = 'Yellow'
    Fail    = 'Red'
}

# ============================================================================
# Helpers
# ============================================================================

function Write-Section {
    param([string] $Title)
    Write-Host ''
    Write-Host "=== $Title ===" -ForegroundColor White
}

function Add-Result {
    param(
        [string] $Area,
        [string] $Target,
        [ValidateSet('Pass', 'Fixed', 'Info', 'Warning', 'Fail')]
        [string] $Status,
        [string] $Detail
    )
    $script:Results.Add([pscustomobject]@{
            Area   = $Area
            Target = $Target
            Status = $Status
            Detail = $Detail
        })
    Write-Host ("  [{0}] {1} | {2}: {3}" -f $Status.ToUpper().PadRight(7), $Area, $Target, $Detail) -ForegroundColor $StatusColor[$Status]
}

function Test-HasFailure {
    return @($script:Results | Where-Object { $_.Status -eq 'Fail' }).Count -gt 0
}

function Invoke-Arm {
    param(
        [Parameter(Mandatory)] [string] $Path,
        [string] $Method = 'GET',
        [string] $Payload
    )
    $request = @{
        Path    = $Path
        Method  = $Method
        WhatIf  = $false
        Confirm = $false
    }
    if ($Payload) { $request.Payload = $Payload }

    $response = Invoke-AzRestMethod @request
    if ($response.StatusCode -eq 404) { return $null }
    if ($response.StatusCode -ge 400) {
        throw "$Method $Path returned HTTP $($response.StatusCode): $($response.Content)"
    }
    if ([string]::IsNullOrWhiteSpace($response.Content)) { return $null }
    return ($response.Content | ConvertFrom-Json)
}

function ConvertTo-PlainObject {
    # Converts ConvertFrom-Json output (PSCustomObject) into hashtables and arrays,
    # as required by -TemplateParameterObject.
    param($InputObject)

    if ($null -eq $InputObject) { return $null }

    if ($InputObject -is [System.Management.Automation.PSCustomObject]) {
        $hash = @{}
        foreach ($property in $InputObject.PSObject.Properties) {
            $hash[$property.Name] = ConvertTo-PlainObject $property.Value
        }
        return $hash
    }

    if ($InputObject -is [System.Collections.IDictionary]) {
        $hash = @{}
        foreach ($key in $InputObject.Keys) {
            $hash[$key] = ConvertTo-PlainObject $InputObject[$key]
        }
        return $hash
    }

    if ($InputObject -is [System.Collections.IEnumerable] -and $InputObject -isnot [string]) {
        $list = @()
        foreach ($item in $InputObject) {
            $list += , (ConvertTo-PlainObject $item)
        }
        return , $list
    }

    return $InputObject
}

function Get-Setting {
    # Effective value of a template parameter: override > parameter file > template default.
    param([string] $Name)

    if ($script:Overrides.ContainsKey($Name)) { return , $script:Overrides[$Name] }
    if ($script:Provided.ContainsKey($Name)) { return , $script:Provided[$Name] }

    $definition = $script:TemplateParameters.PSObject.Properties[$Name]
    if ($definition -and $definition.Value.PSObject.Properties['defaultValue']) {
        $default = $definition.Value.defaultValue
        if ($default -is [string] -and $default.StartsWith('[')) { return $null }
        return , (ConvertTo-PlainObject $default)
    }
    return $null
}

function Get-BoolSetting {
    param([string] $Name, [bool] $Default = $false)
    $value = Get-Setting $Name
    if ($null -eq $value) { return $Default }
    return [bool]$value
}

function Get-EffectivePermission {
    param([string] $Scope)
    try {
        $result = Invoke-Arm -Path "$Scope/providers/Microsoft.Authorization/permissions?api-version=$($ApiVersions.Permissions)"
    }
    catch {
        Write-Verbose "Could not read permissions on ${Scope}: $($_.Exception.Message)"
        return @()
    }
    if ($null -eq $result) { return @() }
    return @($result.value)
}

function Test-Action {
    # True when the action is allowed by at least one permission entry and not excluded by
    # that entry's notActions. Deny assignments are not evaluated.
    param($Permissions, [string] $Action)
    foreach ($permission in $Permissions) {
        $allowed = $false
        foreach ($pattern in @($permission.actions)) {
            if ($Action -like $pattern) { $allowed = $true; break }
        }
        if (-not $allowed) { continue }

        $excluded = $false
        foreach ($pattern in @($permission.notActions)) {
            if ($Action -like $pattern) { $excluded = $true; break }
        }
        if (-not $excluded) { return $true }
    }
    return $false
}

function Get-MissingAction {
    param([string] $Scope, [string[]] $Actions)
    $permissions = Get-EffectivePermission -Scope $Scope
    return @($Actions | Select-Object -Unique | Where-Object { -not (Test-Action -Permissions $permissions -Action $_) })
}

function Add-PathEntry {
    param([string] $Folder)
    $separator = [System.IO.Path]::PathSeparator
    if (($env:PATH -split [regex]::Escape($separator)) -notcontains $Folder) {
        $env:PATH = "$Folder$separator$env:PATH"
    }
}

function Resolve-BicepCli {
    $command = Get-Command -Name 'bicep' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($command) { return $command.Source }

    $azBin = Join-Path $HOME '.azure/bin'
    foreach ($candidate in @((Join-Path $azBin 'bicep.exe'), (Join-Path $azBin 'bicep'))) {
        if (Test-Path -Path $candidate) {
            Add-PathEntry -Folder $azBin
            return $candidate
        }
    }
    return $null
}

function Get-ShortName {
    param([string] $Name)
    return ($Name -split '\.')[0].ToLowerInvariant()
}

function Invoke-WorkspaceQuery {
    param([string] $WorkspaceCustomerId, [string] $Query)
    $response = Invoke-AzOperationalInsightsQuery -WorkspaceId $WorkspaceCustomerId -Query $Query -ErrorAction Stop
    return @($response.Results)
}

function Get-IdentityPrincipalId {
    # Principal ID of a user-assigned identity, or $null when it does not exist yet.
    param([Parameter(Mandatory)] [string] $IdentityId)
    $identity = Invoke-Arm -Path "$($IdentityId)?api-version=$($ApiVersions.Identity)"
    if ($identity -and $identity.properties.principalId) { return "$($identity.properties.principalId)" }
    return $null
}

function Test-ScopeCovers {
    # True when a role assignment at $AssignmentScope applies to $TargetScope (same scope or a parent).
    param([string] $AssignmentScope, [string] $TargetScope)
    $assignment = $AssignmentScope.TrimEnd('/').ToLowerInvariant()
    $target = $TargetScope.TrimEnd('/').ToLowerInvariant()
    if ($assignment -eq '') { return $true }
    return ($target -eq $assignment) -or $target.StartsWith("$assignment/")
}

function Get-IdentityRoleState {
    # For every requirement: is a read role assigned to the principal at that scope or above, and since when (UTC).
    param(
        [Parameter(Mandatory)] [string] $PrincipalId,
        [Parameter(Mandatory)] [object[]] $Requirements
    )
    $state = @()
    foreach ($requirement in $Requirements) {
        $path = "$($requirement.Scope)/providers/Microsoft.Authorization/roleAssignments?api-version=$($ApiVersions.RoleAssign)&`$filter=principalId%20eq%20'$PrincipalId'"
        $assignments = @()
        $response = Invoke-Arm -Path $path
        if ($response -and $response.value) { $assignments = @($response.value) }

        $since = $null
        foreach ($assignment in $assignments) {
            $roleId = ("$($assignment.properties.roleDefinitionId)" -split '/')[-1]
            if ($ReadRoleIds -notcontains $roleId) { continue }
            if (-not (Test-ScopeCovers -AssignmentScope "$($assignment.properties.scope)" -TargetScope $requirement.Scope)) { continue }

            $created = [datetime]::MinValue
            if ($assignment.properties.createdOn) {
                $created = ([datetime]$assignment.properties.createdOn).ToUniversalTime()
            }
            if ($null -eq $since -or $created -lt $since) { $since = $created }
        }

        $state += [pscustomobject]@{
            Label    = $requirement.Label
            Scope    = $requirement.Scope
            RoleId   = $requirement.RoleId
            Assigned = ($null -ne $since)
            Since    = $since
        }
    }
    return $state
}

function Wait-Until {
    # Waits until a UTC point in time, with a progress bar.
    param([Parameter(Mandatory)] [datetime] $UntilUtc, [string] $Activity)
    $total = ($UntilUtc - (Get-Date).ToUniversalTime()).TotalSeconds
    while ($true) {
        $left = ($UntilUtc - (Get-Date).ToUniversalTime()).TotalSeconds
        if ($left -le 0) { break }
        $percent = 0
        if ($total -gt 0) { $percent = [int][math]::Min(100, [math]::Max(0, 100 * ($total - $left) / $total)) }
        Write-Progress -Activity $Activity -Status ("{0}:{1:00} left" -f [int][math]::Floor($left / 60), [int][math]::Floor($left % 60)) -PercentComplete $percent
        Start-Sleep -Seconds ([int][math]::Min(15, [math]::Ceiling($left)))
    }
    Write-Progress -Activity $Activity -Completed
}

function Write-RoleAssignmentCommand {
    param([string] $PrincipalId, [object[]] $RoleState)
    foreach ($role in @($RoleState | Where-Object { -not $_.Assigned })) {
        Write-Host "  New-AzRoleAssignment -ObjectId $PrincipalId -ObjectType ServicePrincipal -RoleDefinitionId $($role.RoleId) -Scope $($role.Scope)"
    }
}

function Show-Summary {
    Write-Section 'Summary'
    $script:Results | Format-Table -AutoSize -Wrap Status, Area, Target, Detail | Out-Host
    $counts = $script:Results | Group-Object Status | ForEach-Object { "$($_.Name): $($_.Count)" }
    Write-Host ("  " + ($counts -join '  |  '))
}

# ============================================================================
# Main
# ============================================================================

$tempFolder = Join-Path ([System.IO.Path]::GetTempPath()) ("azlmon-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tempFolder -Force -WhatIf:$false | Out-Null

try {
    # ------------------------------------------------------------------------
    Write-Section 'Azure context and tooling'
    # ------------------------------------------------------------------------

    $context = Get-AzContext
    if (-not $context -or -not $context.Account) {
        Add-Result 'Azure' 'Sign-in' 'Fail' 'No Az context. Run Connect-AzAccount first.'
        throw 'Not signed in to Azure.'
    }

    if ($SubscriptionId -and $context.Subscription.Id -ne $SubscriptionId) {
        $savedWhatIf = $WhatIfPreference
        $WhatIfPreference = $false
        $context = Set-AzContext -Subscription $SubscriptionId
        $WhatIfPreference = $savedWhatIf
    }
    $deploySubscriptionId = $context.Subscription.Id
    Add-Result 'Azure' 'Sign-in' 'Pass' "$($context.Account.Id) | subscription $($context.Subscription.Name) ($deploySubscriptionId)"

    foreach ($moduleName in @('Az.Accounts', 'Az.Resources')) {
        $module = Get-Module -Name $moduleName -ListAvailable | Sort-Object Version -Descending | Select-Object -First 1
        Add-Result 'Tooling' $moduleName 'Pass' "version $($module.Version)"
    }

    $hasLogAnalyticsModule = [bool](Get-Module -Name 'Az.OperationalInsights' -ListAvailable)
    if ($hasLogAnalyticsModule) {
        Add-Result 'Tooling' 'Az.OperationalInsights' 'Pass' 'available for data flow checks'
    }
    elseif (-not $SkipDataFlowChecks) {
        Add-Result 'Tooling' 'Az.OperationalInsights' 'Warning' 'not installed, data flow checks are skipped (Install-Module Az.OperationalInsights)'
    }

    $bicep = Resolve-BicepCli
    if (-not $bicep -and (Get-Command -Name 'az' -ErrorAction SilentlyContinue)) {
        if ($PSCmdlet.ShouldProcess('Bicep CLI', 'Install with az bicep install')) {
            & az bicep install | Out-Null
            $bicep = Resolve-BicepCli
            if ($bicep) { Add-Result 'Tooling' 'Bicep CLI' 'Fixed' "installed via Azure CLI: $bicep" }
        }
    }
    if (-not $bicep) {
        Add-Result 'Tooling' 'Bicep CLI' 'Fail' 'not found. Install it: https://learn.microsoft.com/azure/azure-resource-manager/bicep/install'
        throw 'Bicep CLI is required.'
    }
    $bicepVersionText = (& $bicep --version) -join ' '
    Add-Result 'Tooling' 'Bicep CLI' 'Pass' $bicepVersionText

    # ------------------------------------------------------------------------
    Write-Section 'Template and parameters'
    # ------------------------------------------------------------------------

    foreach ($file in @($TemplateFile, $ParameterFile)) {
        if (-not (Test-Path -Path $file)) {
            Add-Result 'Parameters' (Split-Path $file -Leaf) 'Fail' "not found: $file"
            throw "File not found: $file"
        }
    }

    $templateJsonPath = Join-Path $tempFolder 'main.json'
    $parametersJsonPath = Join-Path $tempFolder 'main.parameters.json'

    & $bicep build $TemplateFile --outfile $templateJsonPath
    if ($LASTEXITCODE -ne 0) {
        Add-Result 'Parameters' 'main.bicep' 'Fail' 'bicep build failed, see the errors above'
        throw 'Template does not compile.'
    }
    Add-Result 'Parameters' 'main.bicep' 'Pass' 'compiles'

    & $bicep build-params $ParameterFile --outfile $parametersJsonPath
    if ($LASTEXITCODE -ne 0) {
        Add-Result 'Parameters' 'main.bicepparam' 'Fail' 'bicep build-params failed, see the errors above'
        throw 'Parameter file does not compile.'
    }
    Add-Result 'Parameters' 'main.bicepparam' 'Pass' 'compiles'

    $script:TemplateParameters = (Get-Content -Path $templateJsonPath -Raw | ConvertFrom-Json).parameters
    $parameterJson = Get-Content -Path $parametersJsonPath -Raw | ConvertFrom-Json
    foreach ($property in $parameterJson.parameters.PSObject.Properties) {
        $script:Provided[$property.Name] = ConvertTo-PlainObject $property.Value.value
    }

    $namePrefix = Get-Setting 'namePrefix'
    $workspaceResourceId = Get-Setting 'workspaceResourceId'
    $clusterResourceGroupName = Get-Setting 'clusterResourceGroupName'
    $clusterSubscriptionId = Get-Setting 'clusterSubscriptionId'
    if (-not $clusterSubscriptionId) { $clusterSubscriptionId = $deploySubscriptionId }
    $clusters = @(Get-Setting 'clusters')
    $emailReceivers = @(Get-Setting 'emailReceivers')

    $placeholderProblems = @()
    if (-not $workspaceResourceId -or $workspaceResourceId -match '00000000-0000-0000-0000-000000000000') {
        $placeholderProblems += 'workspaceResourceId'
    }
    if (@($emailReceivers | Where-Object { $_.emailAddress -match 'contoso\.com$' }).Count -gt 0) {
        $placeholderProblems += 'emailReceivers (contoso.com)'
    }
    if (@($clusters | Where-Object { $_.name -eq 'azl-clus01' }).Count -gt 0) {
        $placeholderProblems += 'clusters (azl-clus01 is the example name)'
    }
    if ($placeholderProblems.Count -gt 0) {
        Add-Result 'Parameters' 'Placeholders' 'Fail' "example values still in main.bicepparam: $($placeholderProblems -join ', ')"
    }
    else {
        Add-Result 'Parameters' 'Placeholders' 'Pass' 'no example values found'
    }

    if (Test-HasFailure) { throw 'Fix the parameter file first.' }

    # ------------------------------------------------------------------------
    Write-Section 'Azure Local clusters'
    # ------------------------------------------------------------------------

    $clusterResourceGroupId = "/subscriptions/$clusterSubscriptionId/resourceGroups/$clusterResourceGroupName"
    if (-not (Invoke-Arm -Path "$($clusterResourceGroupId)?api-version=$($ApiVersions.Resources)")) {
        Add-Result 'Clusters' $clusterResourceGroupName 'Fail' 'cluster resource group not found'
        throw 'Cluster resource group not found.'
    }

    $deployMetricAlerts = Get-BoolSetting 'deployMetricAlerts' $true
    $correctedClusters = @()
    $clusterNodeMap = @{}
    $insightsWorkspaces = @{}
    $missingAma = @()
    $missingHealthAlerts = @()
    $knownHealthAlertsExtension = $null
    $nodeListChanged = $false

    foreach ($cluster in $clusters) {
        $clusterName = $cluster.name
        $clusterId = "$clusterResourceGroupId/providers/Microsoft.AzureStackHCI/clusters/$clusterName"
        try {
            $clusterResource = Invoke-Arm -Path "$($clusterId)?api-version=$($ApiVersions.Cluster)"
        }
        catch {
            Add-Result 'Cluster' $clusterName 'Fail' "cannot read the cluster: $($_.Exception.Message)"
            continue
        }

        if (-not $clusterResource) {
            Add-Result 'Cluster' $clusterName 'Fail' "not found in $clusterResourceGroupName"
            continue
        }

        # Connectivity
        $connectivity = "$($clusterResource.properties.connectivityStatus)"
        $status = "$($clusterResource.properties.status)"
        if ($connectivity -eq 'Connected' -or $status -eq 'ConnectedRecently') {
            Add-Result 'Cluster' $clusterName 'Pass' "connectivity $connectivity, status $status"
        }
        else {
            Add-Result 'Cluster' $clusterName 'Warning' "connectivity '$connectivity', status '$status': alerts may lag or not fire until the cluster reconnects"
        }

        # Node list
        $configuredNodes = @($cluster.nodeNames | Where-Object { $_ })
        $reportedNodes = @($clusterResource.properties.reportedProperties.nodes | ForEach-Object { $_.name } | Where-Object { $_ })
        $effectiveNodes = $configuredNodes

        if ($reportedNodes.Count -eq 0) {
            Add-Result 'Cluster' "$clusterName nodes" 'Warning' 'cluster reports no nodes, using the configured list'
        }
        else {
            $configuredSet = @($configuredNodes | ForEach-Object { $_.ToLowerInvariant() } | Sort-Object -Unique)
            $reportedSet = @($reportedNodes | ForEach-Object { $_.ToLowerInvariant() } | Sort-Object -Unique)
            $difference = @()
            if ($configuredSet.Count -gt 0) {
                $difference = @(Compare-Object -ReferenceObject $configuredSet -DifferenceObject $reportedSet)
            }

            if ($configuredSet.Count -gt 0 -and $difference.Count -eq 0) {
                Add-Result 'Cluster' "$clusterName nodes" 'Pass' ($reportedNodes -join ', ')
            }
            else {
                $effectiveNodes = $reportedNodes
                $nodeListChanged = $true
                Add-Result 'Cluster' "$clusterName nodes" 'Fixed' "configured [$($configuredNodes -join ', ')] differs from cluster [$($reportedNodes -join ', ')]: deploying with the cluster's node list (update main.bicepparam)"
            }
        }

        $correctedClusters += , @{ name = $clusterName; nodeNames = @($effectiveNodes) }
        $clusterNodeMap[$clusterName] = @($effectiveNodes)

        # Nodes: Arc machine and Insights DCR association
        $nodesWithInsights = @()
        foreach ($nodeName in $effectiveNodes) {
            $machineId = "$clusterResourceGroupId/providers/Microsoft.HybridCompute/machines/$nodeName"
            try {
                $machine = Invoke-Arm -Path "$($machineId)?api-version=$($ApiVersions.Machine)"
            }
            catch {
                Add-Result 'Node' $nodeName 'Fail' "cannot read the Arc machine: $($_.Exception.Message)"
                continue
            }
            if (-not $machine) {
                Add-Result 'Node' $nodeName 'Fail' "Arc machine not found in $clusterResourceGroupName (needed for the DCR association)"
                continue
            }

            $machineStatus = "$($machine.properties.status)"
            if ($machineStatus -eq 'Connected') {
                Add-Result 'Node' $nodeName 'Pass' 'Arc machine Connected'
            }
            else {
                Add-Result 'Node' $nodeName 'Warning' "Arc machine status '$machineStatus'"
            }

            $associations = Invoke-Arm -Path "$machineId/providers/Microsoft.Insights/dataCollectionRuleAssociations?api-version=$($ApiVersions.Dcr)"
            foreach ($association in @($associations.value)) {
                $dcrId = "$($association.properties.dataCollectionRuleId)"
                if (-not $dcrId) { continue }
                $dcr = Invoke-Arm -Path "$($dcrId)?api-version=$($ApiVersions.Dcr)"
                if (-not $dcr) { continue }

                $xPaths = @($dcr.properties.dataSources.windowsEventLogs | ForEach-Object { $_.xPathQueries }) -join ' '
                $isInsightsDcr = ($dcr.name -like 'AzureStackHCI-*') -or ($xPaths -match 'SDDC-Management')
                if (-not $isInsightsDcr) { continue }

                $nodesWithInsights += $nodeName
                foreach ($destination in @($dcr.properties.destinations.logAnalytics)) {
                    $workspaceId = "$($destination.workspaceResourceId)".ToLowerInvariant()
                    if ($workspaceId) { $insightsWorkspaces[$workspaceId] = $destination.workspaceResourceId }
                }

                if ($xPaths -notmatch 'SDDC-Management' -or $xPaths -notmatch 'windows-health') {
                    Add-Result 'Insights' "$nodeName ($($dcr.name))" 'Warning' 'Insights DCR does not collect both SDDC-Management and Health event channels: Insights shows "Needs update"?'
                }
            }
        }

        $nodesWithoutInsights = @($effectiveNodes | Where-Object { $nodesWithInsights -notcontains $_ })
        if ($nodesWithoutInsights.Count -eq 0 -and $effectiveNodes.Count -gt 0) {
            Add-Result 'Insights' $clusterName 'Pass' 'Insights DCR associated with every node'
        }
        else {
            Add-Result 'Insights' $clusterName 'Fail' "no Insights DCR on: $($nodesWithoutInsights -join ', '). Enable Insights (cluster > Capabilities > Insights, or the Insights Azure Policy initiative) and rerun"
        }

        # Extensions
        $extensionList = Invoke-Arm -Path "$clusterId/arcSettings/default/extensions?api-version=$($ApiVersions.Cluster)"
        $extensions = @{}
        foreach ($extension in @($extensionList.value)) {
            $extensions[$extension.name] = $extension
            if ("$($extension.properties.extensionParameters.type)" -eq 'AzureMonitorWindowsAgent') {
                $extensions[$ExtensionNames.Ama] = $extension
            }
        }

        foreach ($key in @('Telemetry', 'Ama', 'HealthAlert')) {
            $extensionName = $ExtensionNames[$key]
            $extension = $extensions[$extensionName]

            if (-not $extension) {
                switch ($key) {
                    'Telemetry' {
                        $status = 'Warning'
                        if ($deployMetricAlerts) { $status = 'Fail' }
                        Add-Result 'Extension' "$clusterName $extensionName" $status 'missing: no platform metrics, metric alerts will not fire. Install it from the banner on the cluster Overview/Extensions page'
                    }
                    'Ama' { $missingAma += $clusterName }
                    'HealthAlert' { $missingHealthAlerts += $clusterName }
                }
                continue
            }

            $state = "$($extension.properties.aggregateState)"
            if (-not $state) { $state = "$($extension.properties.provisioningState)" }

            if ($key -eq 'HealthAlert' -and -not $knownHealthAlertsExtension) {
                $parameters = $extension.properties.extensionParameters
                if ($parameters.publisher -and $parameters.type) {
                    $knownHealthAlertsExtension = @{ Publisher = "$($parameters.publisher)"; Type = "$($parameters.type)"; Source = $clusterName }
                }
            }

            if ($state -eq 'Succeeded') {
                Add-Result 'Extension' "$clusterName $extensionName" 'Pass' 'Succeeded'
            }
            elseif ($state -match 'Progress|Accepted|Updating|Creating') {
                Add-Result 'Extension' "$clusterName $extensionName" 'Warning' "state $state"
            }
            else {
                $status = 'Warning'
                if ($key -eq 'Telemetry' -and $deployMetricAlerts) { $status = 'Fail' }
                Add-Result 'Extension' "$clusterName $extensionName" $status "state '$state': check the extension on the cluster Extensions page"
            }
        }
    }

    if ($nodeListChanged) {
        $script:Overrides['clusters'] = $correctedClusters
    }

    # Azure Monitor Agent: install via Bicep where missing
    if ($missingAma.Count -gt 0) {
        $script:Overrides['deployAmaExtension'] = $true
        $script:Overrides['amaExtensionClusters'] = @($missingAma)
        Add-Result 'Extension' "AzureMonitorWindowsAgent" 'Fixed' "missing on $($missingAma -join ', '): installed by the deployment (Insights must still be enabled)"
    }

    # Health alerts: install via Bicep where missing, publisher/type from parameters or from a cluster that has it
    if ($missingHealthAlerts.Count -gt 0) {
        $publisher = Get-Setting 'healthAlertsExtensionPublisher'
        $type = Get-Setting 'healthAlertsExtensionType'
        $source = 'main.bicepparam'
        if ((-not $publisher -or -not $type) -and $knownHealthAlertsExtension) {
            $publisher = $knownHealthAlertsExtension.Publisher
            $type = $knownHealthAlertsExtension.Type
            $source = "cluster $($knownHealthAlertsExtension.Source)"
        }

        if ($publisher -and $type) {
            $script:Overrides['deployHealthAlertsExtension'] = $true
            $script:Overrides['healthAlertsExtensionPublisher'] = $publisher
            $script:Overrides['healthAlertsExtensionType'] = $type
            $script:Overrides['healthAlertsExtensionClusters'] = @($missingHealthAlerts)
            Add-Result 'Extension' 'AzureEdgeAlerts' 'Fixed' "missing on $($missingHealthAlerts -join ', '): installed by the deployment ($publisher / $type from $source)"
        }
        else {
            Add-Result 'Extension' 'AzureEdgeAlerts' 'Fail' "health alerts not enabled on $($missingHealthAlerts -join ', ') and the extension publisher/type is unknown. Enable it once in the portal (cluster > Capabilities > Health alerts) and rerun: the script copies it to the other clusters"
        }
    }

    # Arc resource bridge
    $appliances = Invoke-Arm -Path "$clusterResourceGroupId/providers/Microsoft.ResourceConnector/appliances?api-version=$($ApiVersions.Appliance)"
    $applianceList = @($appliances.value)
    if ($applianceList.Count -eq 0) {
        $status = 'Info'
        if (Get-BoolSetting 'deployResourceHealthAlert' $true) { $status = 'Warning' }
        Add-Result 'Arc bridge' $clusterResourceGroupName $status 'no Arc resource bridge found in the cluster resource group: the Resource Health alert covers nothing'
    }
    foreach ($appliance in $applianceList) {
        $applianceStatus = "$($appliance.properties.status)"
        if ($applianceStatus -eq 'Running') {
            Add-Result 'Arc bridge' $appliance.name 'Pass' 'Running'
        }
        else {
            Add-Result 'Arc bridge' $appliance.name 'Warning' "status '$applianceStatus': VM management from Azure is affected; the bridge must not be offline longer than 45 days"
        }
    }

    # ------------------------------------------------------------------------
    Write-Section 'Log Analytics workspace'
    # ------------------------------------------------------------------------

    if ($insightsWorkspaces.Count -eq 1) {
        $insightsWorkspaceId = @($insightsWorkspaces.Values)[0]
        if ($insightsWorkspaceId.ToLowerInvariant() -ne "$workspaceResourceId".ToLowerInvariant()) {
            Add-Result 'Workspace' 'workspaceResourceId' 'Fixed' "Insights sends to $insightsWorkspaceId, main.bicepparam has ${workspaceResourceId}: deploying against the Insights workspace (update main.bicepparam)"
            $workspaceResourceId = $insightsWorkspaceId
            $script:Overrides['workspaceResourceId'] = $insightsWorkspaceId
        }
        else {
            Add-Result 'Workspace' 'workspaceResourceId' 'Pass' 'matches the Insights workspace of every cluster'
        }
    }
    elseif ($insightsWorkspaces.Count -gt 1) {
        Add-Result 'Workspace' 'workspaceResourceId' 'Fail' "the clusters' Insights DCRs send to different workspaces: $($insightsWorkspaces.Values -join ', '). Deploy per workspace (one parameter file per workspace)"
    }

    $workspace = Invoke-Arm -Path "$($workspaceResourceId)?api-version=$($ApiVersions.Workspace)"
    if (-not $workspace) {
        Add-Result 'Workspace' $workspaceResourceId 'Fail' 'not found or no read access'
        throw 'Workspace not found.'
    }
    $workspaceLocation = $workspace.location
    $workspaceCustomerId = $workspace.properties.customerId
    Add-Result 'Workspace' $workspace.name 'Pass' "region $workspaceLocation"

    $workspaceIdParts = $workspaceResourceId -split '/'
    $workspaceSubscriptionId = $workspaceIdParts[2]
    $workspaceResourceGroupName = $workspaceIdParts[4]

    # ------------------------------------------------------------------------
    Write-Section 'Resource group and resource providers'
    # ------------------------------------------------------------------------

    $monitoringResourceGroupId = "/subscriptions/$deploySubscriptionId/resourceGroups/$ResourceGroupName"
    $monitoringResourceGroup = Invoke-Arm -Path "$($monitoringResourceGroupId)?api-version=$($ApiVersions.Resources)"
    $monitoringResourceGroupExists = [bool]$monitoringResourceGroup

    if ($monitoringResourceGroupExists) {
        Add-Result 'Azure' $ResourceGroupName 'Pass' "exists ($($monitoringResourceGroup.location))"
    }
    else {
        $rgLocation = $Location
        if (-not $rgLocation) { $rgLocation = $workspaceLocation }

        if ($PSCmdlet.ShouldProcess($ResourceGroupName, "Create resource group in $rgLocation")) {
            $resourceGroupRequest = @{ Name = $ResourceGroupName; Location = $rgLocation }
            $tags = Get-Setting 'tags'
            if ($tags -is [hashtable] -and $tags.Count -gt 0) { $resourceGroupRequest.Tag = $tags }
            New-AzResourceGroup @resourceGroupRequest | Out-Null
            $monitoringResourceGroupExists = $true
            Add-Result 'Azure' $ResourceGroupName 'Fixed' "created in $rgLocation"
        }
        else {
            Add-Result 'Azure' $ResourceGroupName 'Info' "does not exist, would be created in $rgLocation"
        }
    }

    $providerChecks = @(
        @{ Subscription = $deploySubscriptionId; Namespace = 'Microsoft.Insights' }
        @{ Subscription = $deploySubscriptionId; Namespace = 'Microsoft.AlertsManagement' }
        @{ Subscription = $deploySubscriptionId; Namespace = 'Microsoft.ManagedIdentity' }
        @{ Subscription = $clusterSubscriptionId; Namespace = 'Microsoft.Insights' }
        @{ Subscription = $workspaceSubscriptionId; Namespace = 'Microsoft.OperationalInsights' }
    )
    $checkedProviders = @{}
    foreach ($check in $providerChecks) {
        $key = "$($check.Subscription)/$($check.Namespace)"
        if ($checkedProviders.ContainsKey($key)) { continue }
        $checkedProviders[$key] = $true

        $providerPath = "/subscriptions/$($check.Subscription)/providers/$($check.Namespace)"
        $provider = Invoke-Arm -Path "$($providerPath)?api-version=$($ApiVersions.Providers)"
        $state = "$($provider.registrationState)"
        $label = "$($check.Namespace) ($($check.Subscription))"

        if ($state -eq 'Registered') {
            Add-Result 'Provider' $label 'Pass' 'Registered'
            continue
        }

        if ($PSCmdlet.ShouldProcess($label, 'Register resource provider')) {
            try {
                Invoke-Arm -Path "$providerPath/register?api-version=$($ApiVersions.Providers)" -Method 'POST' | Out-Null
                for ($i = 0; $i -lt 18 -and $state -ne 'Registered'; $i++) {
                    Start-Sleep -Seconds 10
                    $state = "$((Invoke-Arm -Path "$($providerPath)?api-version=$($ApiVersions.Providers)").registrationState)"
                }
                if ($state -eq 'Registered') {
                    Add-Result 'Provider' $label 'Fixed' 'registered'
                }
                else {
                    Add-Result 'Provider' $label 'Warning' "registration started, state '$state'. Rerun in a few minutes if the deployment fails on this provider"
                }
            }
            catch {
                Add-Result 'Provider' $label 'Fail' "not registered and registration failed: $($_.Exception.Message)"
            }
        }
        else {
            Add-Result 'Provider' $label 'Info' "state '$state', would be registered"
        }
    }

    # ------------------------------------------------------------------------
    Write-Section 'Permissions of the signed-in identity'
    # ------------------------------------------------------------------------

    $deployVmStateAlert = Get-BoolSetting 'deployVmStateAlert' $true
    $deployEventCollection = Get-BoolSetting 'deployEventCollection' $true
    $deployExtensions = (Get-BoolSetting 'deployAmaExtension' $false) -or (Get-BoolSetting 'deployHealthAlertsExtension' $false)
    $deployLogAlerts = (Get-BoolSetting 'deployEventAlerts' $true) -or (Get-BoolSetting 'deployHeartbeatAlert' $true) -or $deployVmStateAlert -or (Get-BoolSetting 'deployVmHostStateSddcAlert' $true) -or (Get-BoolSetting 'deployVmHostStateScript' $true)

    # All log search alerts run as one user-assigned identity. It needs Log Analytics Reader on the
    # workspace, and Reader on the cluster resource group for the Resource Graph VM state alert.
    $deployRoleAssignments = $deployLogAlerts -and (Get-BoolSetting 'deployAlertRoleAssignments' $true) -and (Get-BoolSetting 'deployVmStateRoleAssignments' $true)
    $deployClusterRoleAssignment = $deployRoleAssignments -and $deployVmStateAlert

    if ($deployLogAlerts -and -not $deployRoleAssignments) {
        $script:ManualRoleAssignments = $true
        Add-Result 'Permissions' 'Role assignments' 'Info' 'disabled in the parameters: the commands for the alert identity are printed after the deployment'
    }

    # Role assignments first: missing rights disable them instead of blocking the deployment.
    if ($deployRoleAssignments) {
        $missingRoleRights = @()
        $missingRoleRights += Get-MissingAction -Scope $workspaceResourceId -Actions @('Microsoft.Authorization/roleAssignments/write')
        if ($deployClusterRoleAssignment) {
            $missingRoleRights += Get-MissingAction -Scope $clusterResourceGroupId -Actions @('Microsoft.Authorization/roleAssignments/write')
        }

        if ($missingRoleRights.Count -gt 0) {
            $deployRoleAssignments = $false
            $deployClusterRoleAssignment = $false
            $script:ManualRoleAssignments = $true
            $script:Overrides['deployAlertRoleAssignments'] = $false
            Add-Result 'Permissions' 'Role assignments' 'Warning' 'no roleAssignments/write on the workspace and/or cluster resource group: the alert identity is deployed without roles, so no log search alert can read the workspace until an Owner runs the commands printed after the deployment'
        }
        else {
            Add-Result 'Permissions' 'Role assignments' 'Pass' 'roleAssignments/write for the alert identity on the workspace and cluster resource group'
        }
    }

    $monitoringScope = $monitoringResourceGroupId
    $monitoringActions = @('Microsoft.Resources/deployments/write', 'Microsoft.Insights/actionGroups/write', 'Microsoft.ManagedIdentity/userAssignedIdentities/write')
    if (-not $monitoringResourceGroupExists) {
        $monitoringScope = "/subscriptions/$deploySubscriptionId"
        $monitoringActions += 'Microsoft.Resources/subscriptions/resourceGroups/write'
    }
    if (Get-BoolSetting 'deployHealthAlertRouting' $true) { $monitoringActions += 'Microsoft.AlertsManagement/actionRules/write' }
    if ($deployMetricAlerts) { $monitoringActions += 'Microsoft.Insights/metricAlerts/write' }
    if ($deployLogAlerts) {
        $monitoringActions += 'Microsoft.Insights/scheduledQueryRules/write'
        $monitoringActions += 'Microsoft.ManagedIdentity/userAssignedIdentities/assign/action'
    }
    if (Get-BoolSetting 'deployResourceHealthAlert' $true) { $monitoringActions += 'Microsoft.Insights/activityLogAlerts/write' }
    if ($deployEventCollection) { $monitoringActions += 'Microsoft.Insights/dataCollectionRules/write' }

    $clusterActions = @('Microsoft.AzureStackHCI/clusters/read', 'Microsoft.HybridCompute/machines/read')
    if ($deployEventCollection -or $deployExtensions -or $deployClusterRoleAssignment) { $clusterActions += 'Microsoft.Resources/deployments/write' }
    if ($deployEventCollection) { $clusterActions += 'Microsoft.Insights/dataCollectionRuleAssociations/write' }
    if ($deployExtensions) { $clusterActions += 'Microsoft.AzureStackHCI/clusters/arcSettings/extensions/write' }
    if ($deployClusterRoleAssignment) { $clusterActions += 'Microsoft.Authorization/roleAssignments/write' }

    $workspaceActions = @('Microsoft.OperationalInsights/workspaces/read')
    if ($deployRoleAssignments) { $workspaceActions += 'Microsoft.Authorization/roleAssignments/write' }

    $permissionScopes = @(
        @{ Label = "monitoring ($ResourceGroupName)"; Scope = $monitoringScope; Actions = $monitoringActions }
        @{ Label = "cluster RG ($clusterResourceGroupName)"; Scope = $clusterResourceGroupId; Actions = $clusterActions }
        @{ Label = "workspace ($($workspace.name))"; Scope = $workspaceResourceId; Actions = $workspaceActions }
    )
    if ($deployRoleAssignments) {
        $permissionScopes += @{ Label = "workspace RG ($workspaceResourceGroupName)"; Scope = "/subscriptions/$workspaceSubscriptionId/resourceGroups/$workspaceResourceGroupName"; Actions = @('Microsoft.Resources/deployments/write') }
    }

    foreach ($permissionScope in $permissionScopes) {
        $missing = Get-MissingAction -Scope $permissionScope.Scope -Actions $permissionScope.Actions
        if ($missing.Count -eq 0) {
            Add-Result 'Permissions' $permissionScope.Label 'Pass' "$(@($permissionScope.Actions | Select-Object -Unique).Count) required actions allowed"
        }
        else {
            Add-Result 'Permissions' $permissionScope.Label 'Fail' "missing: $($missing -join ', ')"
        }
    }

    # ------------------------------------------------------------------------
    Write-Section 'Data flow in the workspace'
    # ------------------------------------------------------------------------

    $allNodes = @($clusterNodeMap.Values | ForEach-Object { $_ } | ForEach-Object { Get-ShortName $_ } | Sort-Object -Unique)
    $deployVmHostStateScript = Get-BoolSetting 'deployVmHostStateScript' $true
    $eventSource = Get-Setting 'vmHostStateEventSource'
    if (-not $eventSource) { $eventSource = 'AzLocalVmStateMonitor' }

    if ($SkipDataFlowChecks -or -not $hasLogAnalyticsModule) {
        Add-Result 'Data flow' 'Workspace queries' 'Info' 'skipped'
    }
    elseif ($allNodes.Count -gt 0) {
        $nodeList = ($allNodes | ForEach-Object { "'$_'" }) -join ', '
        try {
            $heartbeatRows = Invoke-WorkspaceQuery -WorkspaceCustomerId $workspaceCustomerId -Query @"
Heartbeat
| where TimeGenerated > ago(15m)
| extend NodeName = tolower(tostring(split(Computer, '.')[0]))
| where NodeName in ($nodeList)
| summarize LastHeartbeat = max(TimeGenerated) by NodeName
"@
            $nodesWithHeartbeat = @($heartbeatRows | ForEach-Object { $_.NodeName })
            $silentNodes = @($allNodes | Where-Object { $nodesWithHeartbeat -notcontains $_ })
            if ($silentNodes.Count -eq 0) {
                Add-Result 'Data flow' 'AMA heartbeat' 'Pass' 'every node sent a heartbeat in the last 15 minutes'
            }
            else {
                Add-Result 'Data flow' 'AMA heartbeat' 'Warning' "no heartbeat in the last 15 minutes from: $($silentNodes -join ', ')"
            }

            $sddcRows = Invoke-WorkspaceQuery -WorkspaceCustomerId $workspaceCustomerId -Query @"
Event
| where TimeGenerated > ago(2h)
| where EventLog == 'Microsoft-Windows-SDDC-Management/Operational' and EventID in (3000, 3003)
| summarize Events = count(), Last = max(TimeGenerated)
"@
            if (@($sddcRows).Count -gt 0 -and [int]$sddcRows[0].Events -gt 0) {
                Add-Result 'Data flow' 'SDDC Management events' 'Pass' "last received $($sddcRows[0].Last)"
            }
            else {
                Add-Result 'Data flow' 'SDDC Management events' 'Warning' 'no SDDC Management events (3000/3003) in the last 2 hours: the VM state count alert and the Insights workbooks have no data'
            }

            if ($deployVmHostStateScript) {
                $dcrName = "$namePrefix-dcr-azurelocal-cluster-events"
                $ownDcr = Invoke-Arm -Path "$monitoringResourceGroupId/providers/Microsoft.Insights/dataCollectionRules/$($dcrName)?api-version=$($ApiVersions.Dcr)"
                $monitorRows = Invoke-WorkspaceQuery -WorkspaceCustomerId $workspaceCustomerId -Query @"
Event
| where TimeGenerated > ago(30m)
| where EventLog == 'Application' and Source == '$eventSource' and EventID == 4100
| extend NodeName = tolower(tostring(split(Computer, '.')[0]))
| summarize LastRun = max(TimeGenerated) by NodeName
"@
                $reportingNodes = @($monitorRows | ForEach-Object { $_.NodeName })
                $notReporting = @($allNodes | Where-Object { $reportingNodes -notcontains $_ })

                if ($notReporting.Count -eq 0) {
                    Add-Result 'Data flow' 'VM state monitor' 'Pass' 'every node reported in the last 30 minutes'
                }
                elseif (-not $ownDcr) {
                    Add-Result 'Data flow' 'VM state monitor' 'Info' 'no events yet: expected on the first deployment, the collection DCR is created by this deployment'
                }
                elseif ($ConfigureClusterNodes) {
                    Add-Result 'Data flow' 'VM state monitor' 'Info' "not reporting on $($notReporting -join ', '): the task is (re)registered in the next step"
                }
                else {
                    Add-Result 'Data flow' 'VM state monitor' 'Warning' "not reporting on $($notReporting -join ', '): run scripts\Register-AzLocalVmStateTask.ps1 on the cluster, or rerun with -ConfigureClusterNodes"
                }
            }
        }
        catch {
            Add-Result 'Data flow' 'Workspace queries' 'Warning' "query failed (Log Analytics Reader needed): $($_.Exception.Message)"
        }
    }

    # ------------------------------------------------------------------------
    Write-Section 'Cluster node configuration'
    # ------------------------------------------------------------------------

    if (-not $ConfigureClusterNodes) {
        Add-Result 'Nodes' 'Health Service / VM state task' 'Info' 'not checked from Azure. Rerun with -ConfigureClusterNodes, or run the scripts in .\scripts on the cluster'
    }
    elseif (Test-HasFailure) {
        Add-Result 'Nodes' 'Configuration' 'Info' 'skipped because of failed checks'
    }
    elseif ($script:IsWhatIf) {
        Add-Result 'Nodes' 'Configuration' 'Info' 'would copy the node scripts, apply the Health Service settings and register the VM state task on every cluster'
    }
    else {
        $localScripts = @{}
        foreach ($scriptName in $NodeScripts) {
            $path = Join-Path (Join-Path $PSScriptRoot 'scripts') $scriptName
            if (-not (Test-Path -Path $path)) { throw "Node script not found: $path" }
            $localScripts[$scriptName] = Get-Content -Path $path -Raw
        }

        $excludedVmNames = (@(Get-Setting 'vmExcludedNames') | Where-Object { $_ }) -join ','

        foreach ($clusterName in $clusterNodeMap.Keys) {
            $targets = @($clusterNodeMap[$clusterName] | ForEach-Object {
                    if ($NodeDnsSuffix) { "$_.$NodeDnsSuffix" } else { $_ }
                })

            $sessionParameters = @{ ComputerName = $targets; ErrorAction = 'Stop' }
            if ($NodeCredential) { $sessionParameters.Credential = $NodeCredential }

            $sessions = $null
            try {
                $sessions = @(New-PSSession @sessionParameters)

                # Copy the scripts as text with Set-Content, so this does not depend on what a
                # Constrained Language Mode endpoint allows (Copy-Item -ToSession is unreliable there).
                foreach ($session in $sessions) {
                    foreach ($scriptName in $localScripts.Keys) {
                        Invoke-Command -Session $session -ScriptBlock {
                            param($Folder, $Name, $Content)
                            New-Item -ItemType Directory -Path $Folder -Force | Out-Null
                            Set-Content -Path (Join-Path $Folder $Name) -Value $Content -Encoding UTF8 -Force
                        } -ArgumentList $RemoteScriptFolder, $scriptName, $localScripts[$scriptName]
                    }
                }
                Add-Result 'Nodes' "$clusterName scripts" 'Fixed' "copied to $RemoteScriptFolder on $($targets -join ', ')"

                $primary = $sessions[0]

                $healthArguments = @{
                    VolumeCapacityWarningPercent  = $VolumeCapacityWarningPercent
                    VolumeCapacityCriticalPercent = $VolumeCapacityCriticalPercent
                }
                Invoke-Command -Session $primary -ScriptBlock {
                    param($Folder, $Arguments)
                    & (Join-Path $Folder 'Set-AzLocalHealthSettings.ps1') @Arguments
                } -ArgumentList $RemoteScriptFolder, $healthArguments | Out-Host
                Add-Result 'Nodes' "$clusterName Health Service" 'Fixed' "volume capacity $VolumeCapacityWarningPercent/$VolumeCapacityCriticalPercent %, disk tail latency fault on, SDDC cache dump 900 s"

                if ($deployVmHostStateScript) {
                    $taskArguments = @{
                        ScriptSource    = Join-Path $RemoteScriptFolder 'Watch-AzLocalVmState.ps1'
                        TargetFolder    = $RemoteScriptFolder
                        EventSource     = $eventSource
                        ExcludedVmNames = $excludedVmNames
                        SkipCopy        = $true
                    }
                    Invoke-Command -Session $primary -ScriptBlock {
                        param($Folder, $Arguments)
                        & (Join-Path $Folder 'Register-AzLocalVmStateTask.ps1') @Arguments
                    } -ArgumentList $RemoteScriptFolder, $taskArguments | Out-Host
                    Add-Result 'Nodes' "$clusterName VM state task" 'Fixed' 'clustered scheduled task registered (ClusterWide, every 5 minutes)'
                }
            }
            catch {
                Add-Result 'Nodes' $clusterName 'Fail' "remote configuration failed: $($_.Exception.Message). Check WinRM access, -NodeDnsSuffix and -NodeCredential"
            }
            finally {
                if ($sessions) { $sessions | Remove-PSSession }
            }
        }
    }

    # ------------------------------------------------------------------------
    Show-Summary
    # ------------------------------------------------------------------------

    if (Test-HasFailure) {
        throw "Prerequisite checks failed. Fix the items with status Fail and run the script again. Nothing has been deployed."
    }

    if ($script:Overrides.Count -gt 0) {
        Write-Host ''
        Write-Host 'Parameter overrides for this deployment (main.bicepparam is not changed):' -ForegroundColor Cyan
        foreach ($key in ($script:Overrides.Keys | Sort-Object)) {
            Write-Host "  $key = $($script:Overrides[$key] | ConvertTo-Json -Compress -Depth 10)"
        }
    }

    # ------------------------------------------------------------------------
    Write-Section 'Azure what-if'
    # ------------------------------------------------------------------------

    $deploymentParameters = @{}
    foreach ($key in $script:Provided.Keys) { $deploymentParameters[$key] = $script:Provided[$key] }
    foreach ($key in $script:Overrides.Keys) { $deploymentParameters[$key] = $script:Overrides[$key] }

    $deploymentRequest = @{
        ResourceGroupName       = $ResourceGroupName
        TemplateFile            = $templateJsonPath
        TemplateParameterObject = $deploymentParameters
    }

    if (-not $monitoringResourceGroupExists) {
        Write-Host '  Skipped: the resource group does not exist yet (-WhatIf).' -ForegroundColor Gray
    }
    else {
        $savedWhatIf = $WhatIfPreference
        $WhatIfPreference = $false
        try {
            Get-AzResourceGroupDeploymentWhatIfResult @deploymentRequest | Out-Host
        }
        finally {
            $WhatIfPreference = $savedWhatIf
        }
    }

    # ------------------------------------------------------------------------
    Write-Section 'Deployment'
    # ------------------------------------------------------------------------

    if (-not $PSCmdlet.ShouldProcess($ResourceGroupName, "Deploy $DeploymentName")) {
        Write-Host '  -WhatIf: nothing deployed.' -ForegroundColor Gray
        return
    }

    if (-not $Force -and -not $PSCmdlet.ShouldContinue("Deploy the changes above to resource group '$ResourceGroupName'?", 'Azure Local monitoring')) {
        Write-Host '  Deployment cancelled.' -ForegroundColor Yellow
        return
    }

    # The Log Search Alerts service checks the rule's identity when a rule is saved. A role assignment
    # that is only seconds old is not visible to it yet and the rule is rejected with "The provided
    # credentials have insufficient access to perform the requested operation". So when the identity
    # or its roles are new: phase 1 without the rules, wait, phase 2 with everything.
    $alertIdentityName = "$namePrefix-id-alert-rules"
    $alertIdentityId = "$monitoringResourceGroupId/providers/Microsoft.ManagedIdentity/userAssignedIdentities/$alertIdentityName"
    $identityRequirements = @(
        @{ Label = "Log Analytics Reader on workspace $($workspace.name)"; Scope = $workspaceResourceId; RoleId = $RoleIds.LogAnalyticsReader }
    )
    if ($deployVmStateAlert) {
        $identityRequirements += @{ Label = "Reader on resource group $clusterResourceGroupName"; Scope = $clusterResourceGroupId; RoleId = $RoleIds.Reader }
    }

    $alertIdentityPrincipalId = $null
    $roleState = @()
    $deployRules = $true

    if ($deployLogAlerts) {
        $alertIdentityPrincipalId = Get-IdentityPrincipalId -IdentityId $alertIdentityId
        if ($alertIdentityPrincipalId) {
            $roleState = @(Get-IdentityRoleState -PrincipalId $alertIdentityPrincipalId -Requirements $identityRequirements)
        }

        $identityReady = $alertIdentityPrincipalId -and @($roleState | Where-Object { -not $_.Assigned }).Count -eq 0
        if ($identityReady) {
            Write-Host "  Alert identity $alertIdentityName and its roles already exist: single deployment." -ForegroundColor Gray
        }
        else {
            $phaseOneBase = $DeploymentName
            if ($phaseOneBase.Length -gt 55) { $phaseOneBase = $phaseOneBase.Substring(0, 55) }
            $phaseOneName = "$phaseOneBase-identity"
            Write-Host "  Phase 1 of 2: $phaseOneName (alert identity and role assignments, no log search alert rules yet)" -ForegroundColor Cyan

            $phaseOneParameters = $deploymentParameters.Clone()
            $phaseOneParameters['deployLogAlertRules'] = $false
            $phaseOne = New-AzResourceGroupDeployment -ResourceGroupName $ResourceGroupName -TemplateFile $templateJsonPath -TemplateParameterObject $phaseOneParameters -Name $phaseOneName
            if ($phaseOne.ProvisioningState -ne 'Succeeded') {
                throw "Deployment $phaseOneName ended with state $($phaseOne.ProvisioningState)."
            }
            Write-Host "  Deployment $phaseOneName succeeded." -ForegroundColor Green
            $alertIdentityPrincipalId = "$($phaseOne.Outputs['alertIdentityPrincipalId'].Value)"

            # The role assignment API can lag a few seconds behind the deployment
            $listDeadline = (Get-Date).AddMinutes(2)
            do {
                $roleState = @(Get-IdentityRoleState -PrincipalId $alertIdentityPrincipalId -Requirements $identityRequirements)
                $missingRoles = @($roleState | Where-Object { -not $_.Assigned })
                if ($missingRoles.Count -eq 0 -or $script:ManualRoleAssignments) { break }
                Start-Sleep -Seconds 10
            } while ((Get-Date) -lt $listDeadline)
        }

        Write-Host "  Log search alerts run as managed identity $alertIdentityName (principal ID $alertIdentityPrincipalId)."
        foreach ($role in $roleState) {
            if ($role.Assigned) {
                Write-Host ("  [OK]      {0} (since {1:yyyy-MM-dd HH:mm} UTC)" -f $role.Label, $role.Since) -ForegroundColor Green
            }
            else {
                Write-Host "  [MISSING] $($role.Label)" -ForegroundColor Yellow
            }
        }

        if (@($roleState | Where-Object { -not $_.Assigned }).Count -gt 0) {
            # Only when the role assignments could not be part of the deployment (no rights, or disabled)
            $deployRules = $false
            Write-Host ''
            Write-Host 'The alert identity is missing roles. Ask an Owner, User Access Administrator or RBAC Administrator to run:' -ForegroundColor Yellow
            Write-RoleAssignmentCommand -PrincipalId $alertIdentityPrincipalId -RoleState $roleState
            Write-Host '  The log search alert rules are not deployed or changed until then: the service rejects a rule whose identity cannot read the workspace.' -ForegroundColor Yellow
            Write-Host "  Run this script again once the roles are assigned; it waits $RolePropagationMinutes minutes after the assignment and deploys the rules." -ForegroundColor Yellow
        }
        else {
            $newest = [datetime]::MinValue
            foreach ($role in $roleState) {
                if ($role.Since -gt $newest) { $newest = $role.Since }
            }
            $readyAt = $newest.AddMinutes($RolePropagationMinutes)
            if ($readyAt -gt (Get-Date).ToUniversalTime()) {
                Write-Host ("  Waiting until {0:HH:mm} UTC for the role assignments to propagate ({1} minutes after the newest assignment)." -f $readyAt, $RolePropagationMinutes) -ForegroundColor Cyan
                Wait-Until -UntilUtc $readyAt -Activity 'Waiting for the role assignments of the alert identity to propagate'
            }
        }
    }

    if ($deployRules) {
        if ($deployLogAlerts -and -not $identityReady) {
            Write-Host "  Phase 2 of 2: $DeploymentName (everything, including the log search alert rules)" -ForegroundColor Cyan
        }

        $attempt = 0
        while ($true) {
            $attempt++
            try {
                $deployment = New-AzResourceGroupDeployment @deploymentRequest -Name $DeploymentName
                if ($deployment.ProvisioningState -ne 'Succeeded') {
                    throw "Deployment $DeploymentName ended with state $($deployment.ProvisioningState)."
                }
                break
            }
            catch {
                $errorText = "$($_.Exception.Message) $_"
                if ($deployLogAlerts -and $attempt -lt $RuleDeployAttempts -and $errorText -match 'insufficient access|InsufficientAccess') {
                    Write-Host "  Attempt $attempt of ${RuleDeployAttempts}: the Log Search Alerts service does not see the access of $alertIdentityName yet. Retrying in $RuleRetryMinutes minutes." -ForegroundColor Yellow
                    Wait-Until -UntilUtc (Get-Date).ToUniversalTime().AddMinutes($RuleRetryMinutes) -Activity 'Waiting before the next deployment attempt'
                    continue
                }
                if ($errorText -match 'insufficient access|InsufficientAccess') {
                    Write-Host ''
                    Write-Host "The Log Search Alerts service still rejects $alertIdentityName after $attempt attempts." -ForegroundColor Yellow
                    Write-Host '  Check that the role assignments above exist in the portal (Access control (IAM) > Role assignments),' -ForegroundColor Yellow
                    Write-Host '  then run the script again with a larger -RolePropagationMinutes, for example 15.' -ForegroundColor Yellow
                }
                throw
            }
        }
        Write-Host "  Deployment $DeploymentName succeeded." -ForegroundColor Green
    }

    Write-Host ''
    Write-Host 'Next steps:' -ForegroundColor Cyan
    if (-not $ConfigureClusterNodes) {
        Write-Host '  - Run on one node per cluster: scripts\Set-AzLocalHealthSettings.ps1 and scripts\Register-AzLocalVmStateTask.ps1 (or rerun this script with -ConfigureClusterNodes)'
    }
    Write-Host '  - Validate the Resource Graph VM state query (queries\vm-state.kql) in Resource Graph Explorer'
    Write-Host '  - Rerun this script without changes after 30 minutes: the data flow checks should all pass'
}
finally {
    Remove-Item -Path $tempFolder -Recurse -Force -ErrorAction SilentlyContinue -WhatIf:$false
}
