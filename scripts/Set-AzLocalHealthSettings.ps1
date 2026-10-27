#Requires -Version 5.1
#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Configures the Azure Local Health Service and SDDC Management settings that cannot be set from Azure.

.DESCRIPTION
    Run once on one node of each Azure Local cluster (settings are cluster-wide), or let
    Deploy-AzLocalMonitoring.ps1 -ConfigureClusterNodes run it for you.

    - Volume capacity thresholds for the Health Service (feeds the health alerts in Azure Monitor).
    - Enables the physical disk tail-latency fault, which is disabled by default.
    - Lowers the SDDC Management cache dump interval so the Insights workbooks and
      log alerts get fresher data (default 3600 seconds, minimum 900 seconds).

    Shows current and new values. Use -DryRun to only show what would change.
    Written to run in Constrained Language Mode (Application Control/WDAC enforced on Azure Local).

.PARAMETER VolumeCapacityWarningPercent
    Health Service warning threshold for volume capacity. Microsoft default: 80.

.PARAMETER VolumeCapacityCriticalPercent
    Health Service critical threshold for volume capacity. Microsoft default: 90.

.PARAMETER EnableDiskTailLatencyFault
    Enables fault Microsoft.Health.FaultType.PhysicalDisk.HighLatency.AverageIO.

.PARAMETER SddcCacheDumpIntervalSeconds
    Interval for SDDC Management events (Event IDs 3000-3004). Minimum 900.

.PARAMETER DryRun
    Only show what would change.

.EXAMPLE
    .\Set-AzLocalHealthSettings.ps1 -DryRun

.EXAMPLE
    .\Set-AzLocalHealthSettings.ps1 -VolumeCapacityWarningPercent 75 -VolumeCapacityCriticalPercent 85
#>
[CmdletBinding()]
param(
    [ValidateRange(1, 99)]
    [int] $VolumeCapacityWarningPercent = 80,

    [ValidateRange(1, 99)]
    [int] $VolumeCapacityCriticalPercent = 90,

    [bool] $EnableDiskTailLatencyFault = $true,

    [ValidateRange(900, 86400)]
    [int] $SddcCacheDumpIntervalSeconds = 900,

    [switch] $DryRun
)

$ErrorActionPreference = 'Stop'

if ($VolumeCapacityWarningPercent -ge $VolumeCapacityCriticalPercent) {
    throw "VolumeCapacityWarningPercent ($VolumeCapacityWarningPercent) must be lower than VolumeCapacityCriticalPercent ($VolumeCapacityCriticalPercent)."
}

$subSystem = Get-StorageSubSystem -FriendlyName 'Cluster*'
if (-not $subSystem) {
    throw 'No clustered storage subsystem found. Run this script on an Azure Local node.'
}

$healthSettings = @(
    @{ Name = 'System.Storage.Volume.CapacityThreshold.Enabled'; Value = 'True' }
    @{ Name = 'System.Storage.Volume.CapacityThreshold.Warning'; Value = "$VolumeCapacityWarningPercent" }
    @{ Name = 'System.Storage.Volume.CapacityThreshold.Critical'; Value = "$VolumeCapacityCriticalPercent" }
    @{ Name = 'System.Storage.PhysicalDisk.HighLatency.Threshold.Tail.Enabled'; Value = "$EnableDiskTailLatencyFault" }
)

$prefix = ''
if ($DryRun) { $prefix = '[DryRun] ' }

Write-Host "${prefix}Health Service settings on $($subSystem.FriendlyName)" -ForegroundColor Cyan
foreach ($setting in $healthSettings) {
    $current = ($subSystem | Get-StorageHealthSetting -Name $setting.Name -ErrorAction SilentlyContinue).Value

    if ("$current" -eq $setting.Value) {
        Write-Host "  $($setting.Name) = $($setting.Value) (unchanged)"
        continue
    }

    if (-not $DryRun) {
        $subSystem | Set-StorageHealthSetting -Name $setting.Name -Value $setting.Value
    }
    Write-Host "  ${prefix}$($setting.Name): '$current' -> '$($setting.Value)'" -ForegroundColor Green
}

Write-Host ''
Write-Host "${prefix}SDDC Management cache dump interval" -ForegroundColor Cyan
$sddc = Get-ClusterResource -Name 'SDDC Management'
$currentInterval = ($sddc | Get-ClusterParameter -Name 'CacheDumpIntervalInSeconds').Value

if ($currentInterval -eq $SddcCacheDumpIntervalSeconds) {
    Write-Host "  CacheDumpIntervalInSeconds = $SddcCacheDumpIntervalSeconds (unchanged)"
}
else {
    if (-not $DryRun) {
        $sddc | Set-ClusterParameter -Name 'CacheDumpIntervalInSeconds' -Value $SddcCacheDumpIntervalSeconds
    }
    Write-Host "  ${prefix}CacheDumpIntervalInSeconds: $currentInterval -> $SddcCacheDumpIntervalSeconds" -ForegroundColor Green
}

Write-Host ''
Write-Host 'Current health faults:' -ForegroundColor Cyan
$faults = Get-HealthFault
if ($faults) {
    $faults | Format-Table PerceivedSeverity, FaultType, FaultingObjectDescription, Reason -AutoSize
}
else {
    Write-Host '  None'
}
