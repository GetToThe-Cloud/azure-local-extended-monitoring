# Azure Local extended monitoring (Bicep)

A Bicep baseline that deploys the alerting around one or more Azure Local clusters:

- routing of the built-in health alerts;
- metric alerts per cluster;
- extra event collection with log search alerts;
- a node heartbeat alert;
- a Resource Health alert on the Arc resource bridge;
- alerts on the state of every VM on the cluster, both Azure Local VMs and plain Hyper-V VMs.

The background and the design choices are explained in the blog post [Azure Local | Extended Monitoring](https://www.gettothe.cloud/azure-local-extended-monitoring/).

## What gets deployed

| Component | Resource | Purpose | Severity |
|---|---|---|---|
| Action group | `Microsoft.Insights/actionGroups` | Email receivers, common alert schema | n/a |
| Health alert routing | `Microsoft.AlertsManagement/actionRules` | Sends health alerts (AzureEdgeAlerts) and the cluster metric alerts to the action group | follows the alert |
| Maintenance window (optional) | `Microsoft.AlertsManagement/actionRules` | Suppresses notifications during patch night | n/a |
| Metric alerts per cluster | `Microsoft.Insights/metricAlerts` | CPU, memory (high and N-1), available memory, Storage Degraded, CSV read/write latency, VHD latency, VM memory pressure | 1 to 3 |
| Extra event collection | `Microsoft.Insights/dataCollectionRules` + associations on all nodes | Failover clustering (System log) and Hyper-V worker events to the workspace | n/a |
| Cluster event alerts | `Microsoft.Insights/scheduledQueryRules` | Sev1: 1135, 1177, 5120, 5142. Sev2: 1069, 1205, 1254, 18590 | 1 / 2 |
| Node heartbeat | `Microsoft.Insights/scheduledQueryRules` | A node no longer sends an AMA heartbeat, also when it disappears from the workspace completely | 1 |
| Arc resource bridge | `Microsoft.Insights/activityLogAlerts` (Resource Health) | Bridge Unavailable or Degraded | n/a |
| Alert identity | `Microsoft.ManagedIdentity/userAssignedIdentities` + 2 role assignments | One identity that every log search alert runs its query as: Log Analytics Reader on the workspace, Reader on the cluster resource group (for Resource Graph) | n/a |
| VM state (Azure Local VMs) | `Microsoft.Insights/scheduledQueryRules` | Arc VMs in Stopped/Unknown/Paused/Saved, failed provisioning, optionally guest agent not Connected | 2 |
| VM state per node (all VMs) | `Microsoft.Insights/scheduledQueryRules` | Number of VMs per node in Failed/Paused/Suspended/Unknown, from SDDC event 3000 (no installation, no VM names) | 2 |
| VM state per VM (all VMs) | `Microsoft.Insights/scheduledQueryRules` + extra XPath in the DCR | Every VM that is not Running or Off, or a cluster role in Failed/PartialOnline/Pending, with the VM name. Requires the clustered scheduled task | 2 |
| VM state monitor watchdog | `Microsoft.Insights/scheduledQueryRules` | The scheduled task no longer reports on a node | 3 |
| Cluster extensions (optional) | `Microsoft.AzureStackHCI/clusters/arcSettings/extensions` | Azure Monitor Agent and/or AzureEdgeAlerts | n/a |

## Structure

```
Deploy-AzLocalMonitoring.ps1       Checks and fixes the prerequisites, then what-if and deployment
Test-AzLocalAlertRules.ps1         Shows why a log search alert does or does not fire
main.bicep                         Orchestration, types, parameters
main.bicepparam                    Example values
modules/
  action-group.bicep
  health-alert-routing.bicep       Alert processing rules (routing + maintenance window)
  cluster-metric-alerts.bicep      Metric alerts per cluster
  event-collection.bicep           Supplemental DCR
  dcr-association.bicep            DCR association per node (scope: cluster resource group)
  event-log-alerts.bicep           Log search alerts on cluster events
  heartbeat-alert.bicep
  resource-health-alert.bicep
  alert-identity.bicep             User-assigned identity for all log search alerts
  vm-state-alert.bicep             Resource Graph alert (Azure Local VMs)
  vm-host-state-alerts.bicep       VM state on the hosts (all VMs): SDDC counts, per-VM events, watchdog
  role-assignment-rg.bicep
  role-assignment-workspace.bicep
  cluster-extensions.bicep         Optional: AMA and AzureEdgeAlerts
queries/                           KQL, loaded with loadTextContent()
scripts/
  Set-AzLocalHealthSettings.ps1    Health Service thresholds + SDDC cache dump interval
  Watch-AzLocalVmState.ps1         Writes VMs that are not Running/Off to the Application log
  Register-AzLocalVmStateTask.ps1  Copies the script to all nodes and registers the clustered task
```

## Prerequisites

- Insights is enabled on the clusters: AMA on the nodes, the `AzureStackHCI-` DCR and a Log Analytics workspace. Enable it in the portal or with the Azure Policy initiative for Insights.
- The `AzureEdgeTelemetryAndDiagnostics` extension is installed. It is Azure-managed and present by default, and it provides the platform metrics.
- Health alerts are enabled on the clusters (Capabilities > Health alerts), or use `deployHealthAlertsExtension` (see below).
- Permissions:
  - Contributor on the monitoring resource group and on the cluster resource group (DCR associations, extensions);
  - Monitoring Contributor on the workspace;
  - for the two role assignments of the alert identity, also Owner, User Access Administrator or Role Based Access Control Administrator on the workspace and on the cluster resource group. Without those, the deploy script leaves out the role assignments and prints the commands for someone who has them.
- Az PowerShell (Az.Accounts, Az.Resources, and Az.OperationalInsights for the data flow checks) and the Bicep CLI. Or Azure CLI 2.53 or later with Bicep for a manual deployment.

`Deploy-AzLocalMonitoring.ps1` checks all of these and fixes what it can (see below).

## Deploy with Deploy-AzLocalMonitoring.ps1 (recommended)

First fill in `main.bicepparam`: the workspace, the cluster resource group, the clusters with their node names, and the email addresses. Then run from a management workstation:

```powershell
Connect-AzAccount
# Check only: no changes, but with the Azure what-if
.\Deploy-AzLocalMonitoring.ps1 -ResourceGroupName rg-monitoring -WhatIf

# Check, fix and deploy (asks for confirmation after the what-if)
.\Deploy-AzLocalMonitoring.ps1 -ResourceGroupName rg-monitoring

# Including the cluster-side configuration over PowerShell remoting (WinRM to the nodes)
.\Deploy-AzLocalMonitoring.ps1 -ResourceGroupName rg-monitoring -ConfigureClusterNodes -NodeDnsSuffix corp.contoso.com
```

What the script does:

| Area | Check | Automatic fix |
|---|---|---|
| Tooling | Az modules, Bicep CLI | Bicep CLI via `az bicep install` when Azure CLI is present |
| Parameters | `main.bicep` and `main.bicepparam` compile, no example values left | n/a (Fail) |
| Clusters | Cluster exists and is connected | n/a (Warning) |
| Node list | `nodeNames` matches the nodes the cluster reports | The deployment uses the cluster's list |
| Arc machines | Every node exists as an Arc machine and is Connected | n/a |
| Insights | Insights DCR (`AzureStackHCI-`) associated with every node | n/a (Fail: enable Insights in the portal or with Policy) |
| Workspace | `workspaceResourceId` is the Insights workspace | The deployment uses the Insights workspace when all clusters use the same one |
| Telemetry extension | `AzureEdgeTelemetryAndDiagnostics` Succeeded | n/a (Fail when metric alerts are enabled) |
| Azure Monitor Agent | AMA extension on the cluster | Installed with Bicep on the clusters that miss it |
| Health alerts | `AzureEdgeAlerts` on every cluster | Installed with Bicep, with publisher and type from the parameters or copied from a cluster that already has it |
| Arc resource bridge | Present and Running | n/a (Warning) |
| Monitoring resource group | Exists | Created in the workspace region (or `-Location`) |
| Resource providers | `Microsoft.Insights`, `Microsoft.AlertsManagement`, `Microsoft.OperationalInsights`, `Microsoft.ManagedIdentity` | Registered |
| Permissions | Effective permissions (including groups and PIM) per scope, based on which components are enabled | Without `roleAssignments/write`, the role assignments of the alert identity are left out and the script prints the commands for an Owner. It then stops before the log search alert rules (see below) |
| Data flow | Heartbeat from all nodes, SDDC events, events from the VM state monitor | n/a (Warning) |
| Cluster nodes | Only with `-ConfigureClusterNodes` | Health Service settings and the VM state task over remoting |

Statuses: **Pass**, **Fixed** (fixed, or fixed by the deployment), **Info**, **Warning** (the deployment continues) and **Fail** (nothing is deployed). Corrections to parameters only apply to that deployment; `main.bicepparam` is not changed. The script lists them in the summary, so you can update the parameter file.

The script then shows the Azure what-if and asks for confirmation. `-Force` deploys without asking, for example from a pipeline.

The first time, or as long as the alert identity is missing roles, the script deploys in two phases:

| Phase | What | Time |
|---|---|---|
| 1 (`<DeploymentName>-identity`) | Everything except the log search alert rules: action group, routing, metric alerts, DCR, the identity `<namePrefix>-id-alert-rules` and its role assignments | 2 to 4 minutes |
| Wait | Until the newest role assignment is `-RolePropagationMinutes` old (default 5), with a progress bar | about 5 minutes |
| 2 (`<DeploymentName>`) | The full template, including the log search alert rules. On "insufficient access" it tries twice more, three minutes apart | 2 to 4 minutes |

Why: when a rule is saved, the Log Search Alerts service checks whether the identity of that rule can read the workspace. A role assignment that is only seconds old is not visible to the service yet, and the rule fails with *The provided credentials have insufficient access to perform the requested operation*. `skipQueryValidation` does not prevent that. When the identity and its roles already exist, the script skips phase 1 and the wait.

Without the rights to assign roles, the script stops after phase 1. It prints the `New-AzRoleAssignment` commands for someone with Owner, User Access Administrator or RBAC Administrator. Run the script again once the roles are in place; until then the existing rules stay unchanged.

Notes:
- The permission check uses the Azure permissions API. Deny assignments are not taken into account.
- `-ConfigureClusterNodes` copies the scripts as text to `C:\ProgramData\AzLocalMonitoring` on every node. That way it does not depend on what an endpoint in Constrained Language Mode allows; `Copy-Item -ToSession` is not reliable there.
- The node scripts use `-DryRun` instead of `-WhatIf`, so they do not depend on `$PSCmdlet.ShouldProcess` when PowerShell runs in Constrained Language Mode.

## Deploy manually with Azure CLI

1. Fill in `main.bicepparam`: the workspace, the cluster resource group, the clusters with their node names (the Arc machine names), and the email addresses.
2. Build and lint:
   ```bash
   az bicep build --file main.bicep
   az bicep lint --file main.bicep
   ```
3. What-if against the resource group for the alert rules (for example the monitoring resource group):
   ```bash
   az deployment group what-if \
     --resource-group rg-monitoring \
     --template-file main.bicep \
     --parameters main.bicepparam
   ```
4. Deploy, the first time in two steps (see the explanation with the deploy script):
   ```bash
   # Step 1: identity and role assignments, no log search alert rules yet
   az deployment group create \
     --resource-group rg-monitoring \
     --template-file main.bicep \
     --parameters main.bicepparam \
     --parameters deployLogAlertRules=false

   # Wait 5 to 10 minutes, then deploy everything
   az deployment group create \
     --resource-group rg-monitoring \
     --template-file main.bicep \
     --parameters main.bicepparam
   ```
   If step 2 fails with *insufficient access*, wait a few more minutes and run it again.

## After the deployment

1. **Health Service settings.** These cannot be set from Azure; `Deploy-AzLocalMonitoring.ps1 -ConfigureClusterNodes` does it for you. Otherwise run this on one node per cluster, first with `-DryRun`:
   ```powershell
   .\scripts\Set-AzLocalHealthSettings.ps1 -DryRun
   .\scripts\Set-AzLocalHealthSettings.ps1
   ```
   This sets the volume capacity thresholds and enables the tail latency fault for physical disks, which is disabled by default. It also lowers the SDDC cache dump interval to 900 seconds.
2. **Test the VM state query.** Run the query from `queries/vm-state.kql` in Resource Graph Explorer, without the `arg("").` prefix and with the placeholders filled in. Check that `properties.status.powerState` is populated. If `properties.instanceView.vmAgent` is populated as well, you can set `vmAlertOnGuestAgent = true`.
3. **Check the event collection** after about 30 minutes:
   ```kusto
   Event
   | where TimeGenerated > ago(1h)
   | where Source == "Microsoft-Windows-FailoverClustering" or EventLog == "Microsoft-Windows-Hyper-V-Worker-Admin"
   | summarize count() by Computer, EventID
   ```
   No rows is normal when nothing happened. In that case, check the DCR association on the nodes (Arc machine > Extensions/Data collection rules).
4. **Install the VM state monitor** (for `deployVmHostStateScript`). Run this on one node per cluster:
   ```powershell
   .\scripts\Register-AzLocalVmStateTask.ps1 -DryRun
   .\scripts\Register-AzLocalVmStateTask.ps1 -ExcludedVmNames 'template-w2022,lab-vm01'
   ```
   This copies `Watch-AzLocalVmState.ps1` to `C:\ProgramData\AzLocalMonitoring` on every node and registers a clustered scheduled task (ClusterWide, every 5 minutes). Test the script once by hand (`-Verbose`). The task runs as SYSTEM: clustered scheduled tasks always run under that account, so you do not need a service account. After about 15 minutes:
   ```kusto
   Event
   | where TimeGenerated > ago(1h)
   | where EventLog == "Application" and Source == "AzLocalVmStateMonitor"
   | project TimeGenerated, Computer, EventID, RenderedDescription
   ```
5. **Check the SDDC VM counts.** Run the query from `queries/vm-host-state-sddc.kql` in the workspace, with `{{INCLUDE_TRANSITIONAL}}` replaced by `false`, and compare the result with `Get-VM` on the nodes.
6. **Test the routing.** Temporarily lower a metric alert threshold, or trigger a health fault in a test environment (for example a volume above the warning threshold). For the VM state: pause a test VM and wait 10 to 15 minutes. After a new deployment of the log search alert rules, give the first alert up to half an hour.

## When an alert does not fire

`Test-AzLocalAlertRules.ps1` puts side by side what the alert service works with, per log search alert rule. It is read-only, apart from the canary switches below:

```powershell
.\Test-AzLocalAlertRules.ps1 -ResourceGroupName rg-monitoring -RuleName azl-vm-host-state
```

| Check | What it tells you |
|---|---|
| Deployments | Whether the latest deployments succeeded |
| Configuration and identity | Enabled, frequency, window, which identity, and whether that identity has a read role on the workspace (with the age of the assignment) |
| Resource health | The health status of the rule. It lags behind: Unknown on a rule that has fired can be ignored |
| Alerts | What the rule fired in the last 24 hours, and whether an alert processing rule suppressed the notifications |
| Query | The rule's own query over the rule's window, evaluated against the threshold and dimensions, and the same query over 24 hours |
| Events | Per node, how old the last 4100/4101 is, on the node clock and on arrival in the workspace |
| Workspace, action groups | Table plan of `Event`, network access for queries, status of the email receivers |

If the data meets the condition while the rule fires nothing, the alert service does not evaluate the rule successfully. Create a canary rule that cannot miss, with the same workspace, identity and action group:

```powershell
.\Test-AzLocalAlertRules.ps1 -ResourceGroupName rg-monitoring -RuleName azl-vm-host-state -CreateCanaryRule
# after a mail, or after 15 minutes
.\Test-AzLocalAlertRules.ps1 -ResourceGroupName rg-monitoring -RemoveCanaryRule
```

When the canary fires, the service, the identity and the action group work, and the problem is in the rule or its data. When it does not, the alert service cannot query the workspace with that identity.

## VM state on the hosts: which source for what

The state of a VM on Azure Local is visible in three places. They complement each other:

| Source | What you get | Limitation |
|---|---|---|
| Resource Graph (`virtualMachineInstances`) | State of Azure Local VMs (Arc), as the portal shows it | Only VMs created through Azure. Plain Hyper-V VMs are missing |
| SDDC Management event 3000/3003 (`Microsoft-Windows-SDDC-Management/Operational`) | Per node, the number of VMs per state: Running, Stopped, Failed, Paused, Suspended, Unknown, Starting, Stopping, Saving, Pausing, Resuming, Snapshotting. Insights already collects this | Counts only, no VM names. Only as fresh as the cache dump interval (60 minutes by default) |
| `Watch-AzLocalVmState.ps1` (Application log, source `AzLocalVmStateMonitor`) | Per VM: the Hyper-V state (including `PausedCritical`, `Saved`, stuck `Starting`/`Stopping`) and the state of the cluster role | Requires a clustered scheduled task on the cluster |

Hyper-V itself does not write an event that says "this VM has been Paused for 10 minutes". The event logs (`Hyper-V-Worker-Admin`, `Hyper-V-VMMS-Admin`, `FailoverClustering`) contain transitions, not state. That is the reason for the script. The cluster event alerts (1069, 1205, 1254) stay useful: their event text contains the name of the VM role.

## Design choices

- **One routing path for cluster alerts.** Health alerts have no alert rule of their own. The only way to notify on them is an alert processing rule on the cluster resource. That is why the metric alert rules deliberately have no action group: the same processing rule routes them, so there are no duplicate mails. The log, heartbeat, VM state and Resource Health alerts do have a direct action group, because they target the workspace or the bridge.
- **One managed identity for all log search alerts.** A log search alert without an identity runs with the permissions of whoever last saved it. When a PIM activation expires, a colleague leaves or the pipeline principal changes, the rules stop working without notice. That is why every log search alert runs as the user-assigned identity `<namePrefix>-id-alert-rules`, with Log Analytics Reader on the workspace and Reader on the cluster resource group. When a rule is saved, the service checks whether the identity can reach the workspace, also with `skipQueryValidation`. That is why the deploy script deploys the identity and its roles first, and the rules only when the roles are a few minutes old. The rules skip only the syntax check of the query; the test steps above catch a broken query.
- **A separate DCR instead of changing the Insights DCR.** AMA supports more than one DCR per machine. The `AzureStackHCI-` DCR stays as Insights manages it. It also prevents an Insights update from overwriting your changes, or Insights from showing "Needs update".
- **N-1 memory.** With `memoryPercentNMinusOne = 0`, the template calculates the threshold as (N-1)/N × 100. That is 50% for 2 nodes, 66% for 3 and 75% for 4. Above that value the cluster can no longer absorb a node failure or a drain for patching without overcommitting. It is a warning with a one-hour window, next to the hard 90% alert.
- **Latency in seconds.** The Azure Local metrics report latency in seconds. The template converts the milliseconds from the parameters. Microsoft's recommended alert uses 500 ms; this template uses 50 ms for CSVs by default.
- **Maintenance window.** `RemoveAllActionGroups` takes precedence over all action groups, including the ones on the alert rule itself. Alerts are still created, so you can review them afterwards. On the shared workspace it only suppresses alerts whose rule name contains `<namePrefix>-`.

## Things to know

- **AzureEdgeAlerts publisher and type.** The publisher and type of the health alerts extension are not publicly documented. That is why `deployHealthAlertsExtension` is off by default. Enable health alerts once in the portal and read the values:
  ```bash
  az stack-hci extension show \
    --resource-group <cluster-rg> \
    --cluster-name <cluster> \
    --arc-setting-name default \
    --name AzureEdgeAlerts \
    --query "extensionParameters.{publisher:publisher, type:type}"
  ```
  Put them in `healthAlertsExtensionPublisher` and `healthAlertsExtensionType`, and you can deploy the extension to the next clusters with Bicep.
- **Event IDs.** The cluster events (1069, 1135, 1177, 1205, 1254, 5120, 5142) are standard Windows Server failover clustering events. Check 18590 (guest OS crash, Hyper-V-Worker-Admin) on your own nodes before you page on it. All IDs are parameters.
- **Node names.** The heartbeat alert and the event alerts compare on the short host name (`Computer` up to the first dot, lowercase). Use the Arc machine names in `nodeNames`. On Azure Local they are the same as the host names.
- **Application Control (WDAC).** New Azure Local deployments run Application Control in Enforced mode. Microsoft's base policy currently has script enforcement disabled, but a stricter policy of your own can put unsigned PowerShell in Constrained Language Mode. `Watch-AzLocalVmState.ps1` and `Register-AzLocalVmStateTask.ps1` therefore avoid .NET method calls, type casts and classes. To run the scripts in Full Language Mode, sign them with a certificate your App Control policy allows.
- **SDDC event structure.** The query on event 3000 assumes the JSON structure Microsoft documents (`m_servers[].m_vm.m_totalVms<State>`). Check the query in your own workspace first. The Hyper-V state "Saved" probably shows up in these counts as Suspended.
- **Upgrading from an earlier version.** Earlier versions only gave `azl-vm-state` a system-assigned identity. After this deployment, its role assignments are left behind as "Identity not found" on the workspace and the cluster resource group (the description starts with `Azure Local VM state alert:`). You can remove them under **Access control (IAM) > Role assignments**. In your own `main.bicepparam`, `deployVmStateRoleAssignments` is now called `deployAlertRoleAssignments`; the old name still works.
- **Resource Graph in log search alerts.** A rule with `arg("")` requires a managed identity. One identity supports up to 50 of these rules. Cross-service queries return at most 1,000 rows.
- **Testing.** The template has been deployed and tested in one lab environment. Test it against your own Azure Local release and hardware, and always start with the what-if.
