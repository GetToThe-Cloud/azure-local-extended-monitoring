# Azure Local monitoring baseline (Bicep)

Bicep-set die de alerting rond een of meer Azure Local clusters neerzet: routing van de ingebouwde health alerts, metric alerts per cluster, extra event-collectie met log alerts, een node-heartbeat alert, een Resource Health alert op de Arc resource bridge en alerts op de status van alle VM's op het cluster (Azure Local VM's én gewone Hyper-V VM's).

## Wat wordt er uitgerold

| Onderdeel | Resource | Doel | Severity |
|---|---|---|---|
| Action group | `Microsoft.Insights/actionGroups` | E-mail ontvangers, common alert schema | n.v.t. |
| Health-alert routing | `Microsoft.AlertsManagement/actionRules` | Stuurt health alerts (AzureEdgeAlerts) en de cluster metric alerts naar de action group | volgt alert |
| Onderhoudsvenster (optioneel) | `Microsoft.AlertsManagement/actionRules` | Onderdrukt notificaties tijdens patch-nacht | n.v.t. |
| Metric alerts per cluster | `Microsoft.Insights/metricAlerts` | CPU, geheugen (hoog en N-1), beschikbaar geheugen, Storage Degraded, CSV-latency read/write, VHD-latency, VM memory pressure | 1 t/m 3 |
| Extra event-collectie | `Microsoft.Insights/dataCollectionRules` + associations op alle nodes | Failover clustering (System log) en Hyper-V worker events naar de workspace | n.v.t. |
| Cluster event alerts | `Microsoft.Insights/scheduledQueryRules` | Sev1: 1135, 1177, 5120, 5142. Sev2: 1069, 1205, 1254, 18590 | 1 / 2 |
| Node heartbeat | `Microsoft.Insights/scheduledQueryRules` | Node stuurt geen AMA-heartbeat meer (ook als een node helemaal uit de workspace verdwijnt) | 1 |
| Arc resource bridge | `Microsoft.Insights/activityLogAlerts` (Resource Health) | Bridge Unavailable of Degraded | n.v.t. |
| Alert identity | `Microsoft.ManagedIdentity/userAssignedIdentities` + 2 role assignments | Eén identity waarmee alle log search alerts hun query draaien: Log Analytics Reader op de workspace, Reader op de cluster-RG (voor Resource Graph) | n.v.t. |
| VM state (Azure Local VM's) | `Microsoft.Insights/scheduledQueryRules` | Arc-VM's in Stopped/Unknown/Paused/Saved, Failed provisioning, optioneel guest agent niet Connected | 2 |
| VM state per node (alle VM's) | `Microsoft.Insights/scheduledQueryRules` | Aantal VM's per node in Failed/Paused/Suspended/Unknown, uit SDDC-event 3000 (geen installatie, geen VM-namen) | 2 |
| VM state per VM (alle VM's) | `Microsoft.Insights/scheduledQueryRules` + extra XPath in de DCR | Elke VM die niet Running of Off is, of een cluster-rol in Failed/PartialOnline/Pending, met VM-naam. Vereist de clustered scheduled task | 2 |
| VM state monitor watchdog | `Microsoft.Insights/scheduledQueryRules` | De scheduled task rapporteert niet meer op een node | 3 |
| Cluster extensions (optioneel) | `Microsoft.AzureStackHCI/clusters/arcSettings/extensions` | Azure Monitor Agent en/of AzureEdgeAlerts | n.v.t. |

## Structuur

```
Deploy-AzLocalMonitoring.ps1       Checkt en herstelt de vereisten, daarna what-if en deployment
main.bicep                         Orchestratie, types, parameters
main.bicepparam                    Voorbeeldwaarden
modules/
  action-group.bicep
  health-alert-routing.bicep       Alert processing rules (routing + onderhoudsvenster)
  cluster-metric-alerts.bicep      Metric alerts per cluster
  event-collection.bicep           Aanvullende DCR
  dcr-association.bicep            DCR-koppeling per node (scope: cluster-RG)
  event-log-alerts.bicep           Log alerts op cluster events
  heartbeat-alert.bicep
  resource-health-alert.bicep
  alert-identity.bicep             User-assigned identity voor alle log search alerts
  vm-state-alert.bicep             Resource Graph alert (Azure Local VM's)
  vm-host-state-alerts.bicep       VM state op de hosts (alle VM's): SDDC-telling, per-VM events, watchdog
  role-assignment-rg.bicep
  role-assignment-workspace.bicep
  cluster-extensions.bicep         Optioneel: AMA en AzureEdgeAlerts
queries/                           KQL, ingeladen met loadTextContent()
scripts/
  Set-AzLocalHealthSettings.ps1    Health Service thresholds + SDDC cache dump interval
  Watch-AzLocalVmState.ps1         Schrijft VM's die niet Running/Off zijn naar het Application log
  Register-AzLocalVmStateTask.ps1  Kopieert het script naar alle nodes en registreert de clustered task
```

## Vereisten

- Insights staat aan op de clusters (AMA op de nodes, `AzureStackHCI-` DCR, Log Analytics workspace). Inschakelen via de portal of de Azure Policy-initiative voor Insights.
- De `AzureEdgeTelemetryAndDiagnostics` extension is geïnstalleerd (Azure-managed, standaard aanwezig). Die levert de platform metrics.
- Health alerts staan aan op de clusters (Capabilities > Health alerts), of gebruik `deployHealthAlertsExtension` (zie hieronder).
- Rechten: Contributor op de monitoring-RG en de cluster-RG (DCR-koppelingen, extensions) en Monitoring Contributor op de workspace. Voor de twee role assignments van de alert identity ook Owner, User Access Administrator of Role Based Access Control Administrator op de workspace en de cluster-RG. Heb je die niet, dan zet het deploy-script de role assignments uit en print het de commando's voor iemand die ze wel heeft.
- Az PowerShell (Az.Accounts, Az.Resources, voor de data flow-checks ook Az.OperationalInsights) en de Bicep CLI. Of Azure CLI 2.53 of nieuwer met Bicep voor handmatig uitrollen.

`Deploy-AzLocalMonitoring.ps1` controleert al deze vereisten en herstelt wat automatisch kan (zie hieronder).

## Uitrollen met Deploy-AzLocalMonitoring.ps1 (aanbevolen)

Vul eerst `main.bicepparam` in: workspace, cluster-RG, clusters met hun node-namen en e-mailadressen. Draai daarna vanaf een beheerwerkplek:

```powershell
Connect-AzAccount
# Alleen controleren: geen wijzigingen, wel de Azure what-if
.\Deploy-AzLocalMonitoring.ps1 -ResourceGroupName rg-monitoring -WhatIf

# Controleren, herstellen en uitrollen (vraagt bevestiging na de what-if)
.\Deploy-AzLocalMonitoring.ps1 -ResourceGroupName rg-monitoring

# Inclusief configuratie op het cluster via PowerShell remoting (WinRM naar de nodes)
.\Deploy-AzLocalMonitoring.ps1 -ResourceGroupName rg-monitoring -ConfigureClusterNodes -NodeDnsSuffix corp.contoso.com
```

Wat het script doet:

| Onderdeel | Controle | Automatisch herstel |
|---|---|---|
| Tooling | Az-modules, Bicep CLI | Bicep CLI via `az bicep install` als Azure CLI aanwezig is |
| Parameters | `main.bicep` en `main.bicepparam` compileren, geen voorbeeldwaarden meer | n.v.t. (Fail) |
| Clusters | Cluster bestaat en is verbonden | n.v.t. (Warning) |
| Node-lijst | `nodeNames` komt overeen met de nodes die het cluster rapporteert | Deployment gebruikt de lijst van het cluster |
| Arc machines | Elke node bestaat als Arc machine en is Connected | n.v.t. |
| Insights | Insights-DCR (`AzureStackHCI-`) gekoppeld aan elke node | n.v.t. (Fail: Insights aanzetten via portal of Policy) |
| Workspace | `workspaceResourceId` is de workspace van Insights | Deployment gebruikt de Insights-workspace als alle clusters dezelfde gebruiken |
| Telemetry extension | `AzureEdgeTelemetryAndDiagnostics` Succeeded | n.v.t. (Fail als metric alerts aan staan) |
| Azure Monitor Agent | AMA-extension op het cluster | Geïnstalleerd via Bicep op de clusters waar hij ontbreekt |
| Health alerts | `AzureEdgeAlerts` op elk cluster | Geïnstalleerd via Bicep, met publisher/type uit de parameters of overgenomen van een cluster dat hem al heeft |
| Arc resource bridge | Aanwezig en Running | n.v.t. (Warning) |
| Monitoring-RG | Bestaat | Aangemaakt in de regio van de workspace (of `-Location`) |
| Resource providers | `Microsoft.Insights`, `Microsoft.AlertsManagement`, `Microsoft.OperationalInsights` | Geregistreerd |
| Rechten | Effectieve rechten (ook via groepen en PIM) per scope, op basis van welke onderdelen aan staan | Geen `roleAssignments/write`: de role assignments van de alert identity gaan uit en het script print daarna de commando's voor een Owner. Tot die zijn uitgevoerd gaat geen enkele log search alert af |
| Data flow | Heartbeat van alle nodes, SDDC-events, events van de VM state monitor | n.v.t. (Warning) |
| Cluster nodes | Alleen met `-ConfigureClusterNodes` | Health Service-instellingen en de VM state task via remoting |

Statussen: **Pass**, **Fixed** (hersteld of wordt hersteld door de deployment), **Info**, **Warning** (deployment gaat door) en **Fail** (er wordt niets uitgerold). Correcties op parameters gelden alleen voor die deployment, `main.bicepparam` wordt niet aangepast. Het script toont ze in de samenvatting, zodat je het parameterbestand kunt bijwerken.

Daarna toont het script de Azure what-if en vraagt het om bevestiging. Met `-Force` wordt zonder vraag uitgerold, bijvoorbeeld vanuit een pipeline.

Opmerkingen:
- De rechtencheck gebruikt de Azure permissions-API. Deny assignments worden niet meegenomen.
- `-ConfigureClusterNodes` kopieert de scripts als tekst naar `C:\ProgramData\AzLocalMonitoring` op elke node. Zo hangt het niet af van wat een endpoint in Constrained Language Mode toestaat; `Copy-Item -ToSession` is daar niet betrouwbaar.
- De node-scripts gebruiken `-DryRun` in plaats van `-WhatIf`. Zo zijn ze niet afhankelijk van `$PSCmdlet.ShouldProcess` als PowerShell in Constrained Language Mode draait.

## Handmatig uitrollen met Azure CLI

1. Vul `main.bicepparam` in: workspace, cluster-RG, clusters met hun node-namen (de Arc machine-namen) en e-mailadressen.
2. Build en lint:
   ```bash
   az bicep build --file main.bicep
   az bicep lint --file main.bicep
   ```
3. What-if tegen de resource group waar de alert rules in komen (bijvoorbeeld de monitoring-RG):
   ```bash
   az deployment group what-if \
     --resource-group rg-monitoring \
     --template-file main.bicep \
     --parameters main.bicepparam
   ```
4. Deployen:
   ```bash
   az deployment group create \
     --resource-group rg-monitoring \
     --template-file main.bicep \
     --parameters main.bicepparam
   ```

## Na de deployment

1. **Health Service instellingen** (niet via Azure in te stellen, `Deploy-AzLocalMonitoring.ps1 -ConfigureClusterNodes` doet dit voor je). Draai op één node per cluster, eerst met `-DryRun`:
   ```powershell
   .\scripts\Set-AzLocalHealthSettings.ps1 -DryRun
   .\scripts\Set-AzLocalHealthSettings.ps1
   ```
   Dit zet de volume capacity thresholds en zet de tail-latency fault voor fysieke disks aan (die staat standaard uit). Ook verlaagt het het SDDC cache dump-interval naar 900 seconden.
2. **VM state query testen.** Draai de query uit `queries/vm-state.kql` in Resource Graph Explorer (zonder het `arg("").`-prefix en met de placeholders ingevuld). Controleer dat `properties.status.powerState` gevuld is. Is `properties.instanceView.vmAgent` ook gevuld, dan kun je `vmAlertOnGuestAgent = true` zetten.
3. **Event-collectie controleren** na ongeveer 30 minuten:
   ```kusto
   Event
   | where TimeGenerated > ago(1h)
   | where Source == "Microsoft-Windows-FailoverClustering" or EventLog == "Microsoft-Windows-Hyper-V-Worker-Admin"
   | summarize count() by Computer, EventID
   ```
   Geen rijen is normaal als er niets is gebeurd. Controleer in dat geval de DCR-koppeling op de nodes (Arc machine > Extensions/Data collection rules).
4. **VM state monitor installeren** (voor `deployVmHostStateScript`). Draai op één node per cluster:
   ```powershell
   .\scripts\Register-AzLocalVmStateTask.ps1 -DryRun
   .\scripts\Register-AzLocalVmStateTask.ps1 -ExcludedVmNames 'template-w2022,lab-vm01'
   ```
   Dit kopieert `Watch-AzLocalVmState.ps1` naar `C:\ProgramData\AzLocalMonitoring` op elke node en registreert een clustered scheduled task (ClusterWide, elke 5 minuten). Test het script één keer met de hand (`-Verbose`). De taak zelf draait als SYSTEM: clustered scheduled tasks draaien altijd onder dat account, dus je hebt geen serviceaccount nodig. Na ongeveer 15 minuten:
   ```kusto
   Event
   | where TimeGenerated > ago(1h)
   | where EventLog == "Application" and Source == "AzLocalVmStateMonitor"
   | project TimeGenerated, Computer, EventID, RenderedDescription
   ```
5. **SDDC VM-telling controleren.** Draai de query uit `queries/vm-host-state-sddc.kql` (met `{{INCLUDE_TRANSITIONAL}}` vervangen door `false`) in de workspace en vergelijk met `Get-VM` op de nodes.
6. **Test de routing**: zet tijdelijk een metric alert-threshold laag, of trigger een health fault in een testomgeving (bijvoorbeeld een volume boven de warning-threshold). Voor de VM state: zet een test-VM op Pause en wacht 10 tot 15 minuten.

## VM-status op de hosts: welke bron waarvoor

Er zijn drie plekken waar de status van een VM op Azure Local zichtbaar is. Ze vullen elkaar aan:

| Bron | Wat je krijgt | Beperking |
|---|---|---|
| Resource Graph (`virtualMachineInstances`) | Status van Azure Local VM's (Arc) zoals de portal die toont | Alleen VM's die via Azure zijn gemaakt. Gewone Hyper-V VM's ontbreken |
| SDDC Management event 3000/3003 (`Microsoft-Windows-SDDC-Management/Operational`) | Per node het aantal VM's per status: Running, Stopped, Failed, Paused, Suspended, Unknown, Starting, Stopping, Saving, Pausing, Resuming, Snapshotting. Insights verzamelt dit al | Alleen aantallen, geen VM-namen. Zo vers als het cache dump-interval (standaard 60 minuten) |
| `Watch-AzLocalVmState.ps1` (Application log, bron `AzLocalVmStateMonitor`) | Per VM: Hyper-V-status (ook `PausedCritical`, `Saved`, vastgelopen `Starting`/`Stopping`) en de status van de cluster-rol | Vereist een clustered scheduled task op het cluster |

Hyper-V schrijft zelf geen event "VM staat al 10 minuten op Paused". De event logs (`Hyper-V-Worker-Admin`, `Hyper-V-VMMS-Admin`, `FailoverClustering`) bevatten overgangen, geen toestand. Dat is de reden voor het script. De bestaande cluster event alerts (1069, 1205, 1254) blijven nuttig: daarin staat de naam van de VM-rol in de eventtekst.

## Ontwerpkeuzes

- **Eén routingpad voor cluster-alerts.** Health alerts hebben geen eigen alert rule. Je kunt er alleen op notificeren via een alert processing rule op de cluster-resource. Daarom hebben de metric alert rules bewust geen eigen action group: dezelfde processing rule routeert ze, dus geen dubbele mails. Log-, heartbeat-, VM state- en Resource Health-alerts hebben wel een directe action group, want die targeten de workspace of de bridge.
- **Eén managed identity voor alle log search alerts.** Een log search alert zonder identity draait met de rechten van degene die hem het laatst heeft opgeslagen. Verloopt een PIM-activatie, vertrekt een collega of verandert de pipeline-principal, dan stoppen de rules zonder melding. Daarom draaien alle log search alerts als de user-assigned identity `<namePrefix>-id-alert-rules`, met Log Analytics Reader op de workspace en Reader op de cluster-RG. De rules slaan de query-validatie bij het aanmaken over, omdat een nieuwe role assignment een paar minuten nodig heeft om actief te worden. De testprocedure hieronder vangt een foute query op.
- **Aparte DCR in plaats van de Insights-DCR aanpassen.** AMA ondersteunt meerdere DCR's per machine. De `AzureStackHCI-` DCR blijft zo zoals Insights hem beheert. Je voorkomt ook dat een Insights-update je wijzigingen overschrijft of dat Insights "Needs update" gaat tonen.
- **N-1 geheugen.** Met `memoryPercentNMinusOne = 0` berekent de template de drempel als (N-1)/N × 100. Dat is 50% bij 2 nodes, 66% bij 3 en 75% bij 4. Boven die waarde kan het cluster een node-uitval of een drain voor patching niet meer opvangen zonder overcommit. Het is een warning met een venster van 1 uur, naast de harde 90%-alert.
- **Latency in seconden.** De Azure Local metrics rapporteren latency in seconden. De template rekent de milliseconden uit de parameters om. Microsofts recommended alert gebruikt 500 ms; deze template gebruikt standaard 50 ms voor CSV's.
- **Onderhoudsvenster.** `RemoveAllActionGroups` gaat boven alle action groups, ook die op de alert rule zelf. Alerts worden nog wel aangemaakt, je ziet ze dus achteraf terug. Op de gedeelde workspace onderdrukt het alleen alerts waarvan de naam met `<namePrefix>-` begint.

## Aandachtspunten

- **AzureEdgeAlerts publisher/type.** De publisher en het type van de health alerts extension zijn niet publiek gedocumenteerd. Daarom staat `deployHealthAlertsExtension` standaard uit. Zet health alerts één keer aan via de portal en lees de waarden uit:
  ```bash
  az stack-hci extension show \
    --resource-group <cluster-rg> \
    --cluster-name <cluster> \
    --arc-setting-name default \
    --name AzureEdgeAlerts \
    --query "extensionParameters.{publisher:publisher, type:type}"
  ```
  Vul die in bij `healthAlertsExtensionPublisher` en `healthAlertsExtensionType`, dan kun je de extension voor volgende clusters via Bicep uitrollen.
- **Event ID's.** De cluster events (1069, 1135, 1177, 1205, 1254, 5120, 5142) zijn standaard Windows Server failover cluster events. Controleer 18590 (guest OS crash, Hyper-V-Worker-Admin) op je eigen nodes voordat je er op pagineert. Alle ID's zijn parameters.
- **Node-namen.** De heartbeat-alert en de event-alerts vergelijken op de korte hostnaam (`Computer` tot de eerste punt, lowercase). Gebruik in `nodeNames` de Arc machine-namen. Die zijn bij Azure Local gelijk aan de hostnamen.
- **Application Control (WDAC).** Nieuwe Azure Local-deployments draaien Application Control in Enforced mode. De base policy van Microsoft heeft script enforcement op dit moment uitgeschakeld, maar een strengere eigen policy kan onondertekende PowerShell in Constrained Language Mode zetten. `Watch-AzLocalVmState.ps1` en `Register-AzLocalVmStateTask.ps1` gebruiken daarom geen .NET-aanroepen, type casts of classes. Wil je het script in Full Language Mode draaien, onderteken het dan met een certificaat dat je App Control-policy toestaat.
- **SDDC-event structuur.** De query op event 3000 gaat uit van de JSON-structuur die Microsoft documenteert (`m_servers[].m_vm.m_totalVms<Status>`). Controleer de query eerst in je workspace. Hyper-V's status "Saved" komt in deze telling vermoedelijk terug als Suspended.
- **Overstap van een eerdere versie.** Eerdere versies gaven alleen `azl-vm-state` een system-assigned identity. Na deze deployment blijven de role assignments daarvan achter als "Identity not found" op de workspace en de cluster-RG (beschrijving begint met `Azure Local VM state alert:`). Die kun je verwijderen onder **Access control (IAM) > Role assignments**. In je eigen `main.bicepparam` heet `deployVmStateRoleAssignments` nu `deployAlertRoleAssignments`; de oude naam werkt nog.
- **Resource Graph in log alerts.** Een rule met `arg("")` vereist een managed identity. Per identity kunnen maximaal 50 van dit soort rules draaien. Cross-service queries geven maximaal 1.000 rijen terug.
- **Validatie.** De template is niet tegen een live omgeving uitgerold. Draai altijd eerst `what-if`.
