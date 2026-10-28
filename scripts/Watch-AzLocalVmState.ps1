#Requires -Version 5.1
<#
.SYNOPSIS
    Reports VMs on this Azure Local node that are not Running or Off, and clustered VM roles
    that are Failed, PartialOnline or Pending, to the Application event log.

.DESCRIPTION
    Meant to run as a clustered scheduled task (TaskType ClusterWide) on every node, every
    5 minutes. Register it with Register-AzLocalVmStateTask.ps1.

    - Each node reports only the VMs it owns: no remoting, no double reporting, and non-clustered
      VMs on a node are covered too.
    - A VM must be in a bad state in two samples, RecheckSeconds apart, so normal starts, stops
      and live migrations are not reported. A VM stuck in Starting/Stopping/Saving is.
    - Event 4100 (Information): run summary per node. Also the watchdog signal in Azure Monitor.
    - Event 4101 (Warning): one event per VM with a problem. The message is JSON.
    - Event 4102 (Error): the script itself failed.

    Written to also run in Constrained Language Mode (for example under a strict App Control
    policy): no .NET calls, no type casts, no classes.

.PARAMETER EventSource
    Event source in the Application log. Must match vmHostStateEventSource in the Bicep template.

.PARAMETER HealthyVmStates
    Comma-separated Hyper-V states that are considered fine.

.PARAMETER BadClusterStates
    Comma-separated cluster group states that are reported.

.PARAMETER RecheckSeconds
    Seconds between the first and the confirming sample.

.PARAMETER ExcludedVmNames
    Comma-separated VM names that are never reported.

.EXAMPLE
    .\Watch-AzLocalVmState.ps1 -Verbose
#>
[CmdletBinding()]
param(
    [string] $EventSource = 'AzLocalVmStateMonitor',
    [string] $HealthyVmStates = 'Running,Off',
    [string] $BadClusterStates = 'Failed,PartialOnline,Pending',
    [int] $RecheckSeconds = 60,
    [string] $ExcludedVmNames = ''
)

$ErrorActionPreference = 'Stop'

$nodeName = $env:COMPUTERNAME
$healthyStates = $HealthyVmStates -split ',' | Where-Object { $_ } | ForEach-Object { $_.Trim() }
$badClusterStateList = $BadClusterStates -split ',' | Where-Object { $_ } | ForEach-Object { $_.Trim() }
$excluded = $ExcludedVmNames -split ',' | Where-Object { $_ } | ForEach-Object { $_.Trim() }

# Create the event source once. New-EventLog throws when it already exists.
try {
    New-EventLog -LogName Application -Source $EventSource -ErrorAction Stop
    Write-Verbose "Created event source $EventSource"
}
catch {
    Write-Verbose "Event source $EventSource already exists"
}

function Get-VmProblemList {
    $vmByName = @{}
    foreach ($vm in (Get-VM)) {
        $vmByName[$vm.Name] = $vm
    }

    $problems = @{}

    # Hyper-V state of every VM registered on this node
    foreach ($name in $vmByName.Keys) {
        if ($excluded -contains $name) { continue }
        $vm = $vmByName[$name]
        $state = "$($vm.State)"
        if ($healthyStates -notcontains $state) {
            $problems[$name] = @{
                vmName       = $name
                vmId         = "$($vm.VMId)"
                state        = $state
                status       = "$($vm.Status)"
                clusterState = ''
                clustered    = ($vm.IsClustered -eq $true)
            }
        }
    }

    # Cluster role state of clustered VMs owned by this node
    $groups = Get-ClusterGroup -ErrorAction SilentlyContinue |
        Where-Object { "$($_.GroupType)" -eq 'VirtualMachine' -and "$($_.OwnerNode)" -eq $nodeName }

    foreach ($group in $groups) {
        $groupName = "$($group.Name)"
        $groupState = "$($group.State)"
        if ($excluded -contains $groupName) { continue }
        if ($badClusterStateList -notcontains $groupState) { continue }

        if ($problems.ContainsKey($groupName)) {
            $problems[$groupName].clusterState = $groupState
        }
        else {
            $vmState = 'NotRegistered'
            $vmStatus = ''
            $vmId = ''
            if ($vmByName.ContainsKey($groupName)) {
                $vmState = "$($vmByName[$groupName].State)"
                $vmStatus = "$($vmByName[$groupName].Status)"
                $vmId = "$($vmByName[$groupName].VMId)"
            }
            $problems[$groupName] = @{
                vmName       = $groupName
                vmId         = $vmId
                state        = $vmState
                status       = $vmStatus
                clusterState = $groupState
                clustered    = $true
            }
        }
    }

    return @{
        Problems = $problems
        Total    = $vmByName.Count
        Running  = @($vmByName.Values | Where-Object { "$($_.State)" -eq 'Running' }).Count
    }
}

try {
    $first = Get-VmProblemList
    $confirmed = @()
    $result = $first

    if ($first.Problems.Count -gt 0) {
        Write-Verbose "$($first.Problems.Count) VM(s) in a bad state, rechecking in $RecheckSeconds seconds"
        Start-Sleep -Seconds $RecheckSeconds
        $result = Get-VmProblemList
        foreach ($name in $result.Problems.Keys) {
            if ($first.Problems.ContainsKey($name)) {
                $confirmed += $result.Problems[$name]
            }
        }
    }

    foreach ($problem in $confirmed) {
        $problem.node = $nodeName
        $message = $problem | ConvertTo-Json -Compress
        Write-EventLog -LogName Application -Source $EventSource -EventId 4101 -EntryType Warning -Message $message
        Write-Verbose "Reported: $message"
    }

    $summary = @{
        node       = $nodeName
        totalVms   = $result.Total
        runningVms = $result.Running
        problemVms = $confirmed.Count
        version    = '1.0'
    }
    Write-EventLog -LogName Application -Source $EventSource -EventId 4100 -EntryType Information -Message ($summary | ConvertTo-Json -Compress)
    Write-Verbose "Summary: $($summary | ConvertTo-Json -Compress)"
}
catch {
    $errorMessage = @{
        node  = $nodeName
        error = "$($_.Exception.Message)"
    } | ConvertTo-Json -Compress
    Write-EventLog -LogName Application -Source $EventSource -EventId 4102 -EntryType Error -Message $errorMessage
    throw
}
