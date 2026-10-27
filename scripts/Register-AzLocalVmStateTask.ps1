#Requires -Version 5.1
#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Copies Watch-AzLocalVmState.ps1 to every node of the cluster and registers it as a
    clustered scheduled task that runs on all nodes (TaskType ClusterWide).

.DESCRIPTION
    Run once on one node of the cluster, or let Deploy-AzLocalMonitoring.ps1
    -ConfigureClusterNodes run it for you. Re-run after adding a node or changing parameters;
    an existing task with the same name is replaced.

    Default target folder is local on each node (copied via the admin share). If admin shares
    are not reachable, put the script on a Cluster Shared Volume (or copy it to every node
    yourself), pass that folder as TargetFolder and use -SkipCopy.

    Written to run in Constrained Language Mode (Application Control/WDAC enforced on Azure Local).

.PARAMETER ScriptSource
    Path to Watch-AzLocalVmState.ps1.

.PARAMETER TargetFolder
    Folder on each node (or a CSV path) from which the task runs the script.

.PARAMETER TaskName
    Name of the clustered scheduled task.

.PARAMETER IntervalMinutes
    Run interval in minutes.

.PARAMETER EventSource
    Event source. Must match vmHostStateEventSource in the Bicep template.

.PARAMETER ExcludedVmNames
    Comma-separated VM names that are never reported.

.PARAMETER SkipCopy
    Do not copy the script (TargetFolder already contains it on every node).

.PARAMETER DryRun
    Only show what would be done.

.EXAMPLE
    .\Register-AzLocalVmStateTask.ps1 -DryRun

.EXAMPLE
    .\Register-AzLocalVmStateTask.ps1 -ExcludedVmNames 'template-w2022,lab-vm01'

.EXAMPLE
    .\Register-AzLocalVmStateTask.ps1 -TargetFolder 'C:\ClusterStorage\UserStorage_1\Scripts' -SkipCopy
#>
[CmdletBinding()]
param(
    [string] $ScriptSource = (Join-Path $PSScriptRoot 'Watch-AzLocalVmState.ps1'),
    [string] $TargetFolder = 'C:\ProgramData\AzLocalMonitoring',
    [string] $TaskName = 'AzLocal-VmStateMonitor',
    [ValidateRange(2, 60)]
    [int] $IntervalMinutes = 5,
    [string] $EventSource = 'AzLocalVmStateMonitor',
    [string] $ExcludedVmNames = '',
    [switch] $SkipCopy,
    [switch] $DryRun
)

$ErrorActionPreference = 'Stop'

$prefix = ''
if ($DryRun) { $prefix = '[DryRun] ' }

if (-not (Test-Path -Path $ScriptSource)) {
    throw "Script not found: $ScriptSource"
}

$cluster = Get-Cluster
$nodes = Get-ClusterNode
Write-Host "Cluster $($cluster.Name), nodes: $(($nodes | ForEach-Object { $_.Name }) -join ', ')" -ForegroundColor Cyan

# 1. Copy the script to every node
if (-not $SkipCopy) {
    foreach ($node in $nodes) {
        $uncFolder = "\\$($node.Name)\$($TargetFolder.Replace(':', '$'))"
        if (-not $DryRun) {
            New-Item -ItemType Directory -Path $uncFolder -Force | Out-Null
            Copy-Item -Path $ScriptSource -Destination $uncFolder -Force
        }
        Write-Host "  ${prefix}Copied Watch-AzLocalVmState.ps1 to $uncFolder" -ForegroundColor Green
    }
}

# 2. Register the clustered scheduled task
$scriptPath = Join-Path $TargetFolder 'Watch-AzLocalVmState.ps1'
$arguments = "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$scriptPath`" -EventSource `"$EventSource`""
if ($ExcludedVmNames) {
    $arguments += " -ExcludedVmNames `"$ExcludedVmNames`""
}

$action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $arguments
$trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).Date -RepetitionInterval (New-TimeSpan -Minutes $IntervalMinutes)
$settings = New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes ($IntervalMinutes - 1))

$existing = Get-ClusteredScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
if ($existing) {
    if (-not $DryRun) {
        Unregister-ClusteredScheduledTask -TaskName $TaskName
    }
    Write-Host "  ${prefix}Removed existing task $TaskName"
}

if (-not $DryRun) {
    Register-ClusteredScheduledTask -TaskName $TaskName -TaskType ClusterWide -Action $action -Trigger $trigger -Settings $settings -Description 'Reports Azure Local VMs that are not Running or Off to the Application event log (Azure Monitor alerting).' | Out-Null
}
Write-Host "  ${prefix}Registered $TaskName (ClusterWide, every $IntervalMinutes minutes): powershell.exe $arguments" -ForegroundColor Green

Write-Host ''
Write-Host 'Next steps:' -ForegroundColor Cyan
Write-Host "  - Test once by hand on a node: & '$scriptPath' -Verbose"
Write-Host "  - Check Event Viewer > Windows Logs > Application, source $EventSource (4100 every run, 4101 per VM with a problem)"
Write-Host '  - Check in Task Scheduler under which account the task runs; it needs local admin rights (Get-VM, event source).'
