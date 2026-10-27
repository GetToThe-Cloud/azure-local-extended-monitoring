metadata description = 'Metric alert rules for one Azure Local cluster (Microsoft.AzureStackHCI/clusters platform metrics).'

@description('Prefix for resource names.')
param namePrefix string

@description('Name of the Azure Local cluster.')
param clusterName string

@description('Resource ID of the Azure Local cluster.')
param clusterId string

@description('Number of nodes in the cluster (used for the N-1 memory threshold).')
@minValue(1)
param nodeCount int

@description('Threshold object, see thresholdsType in main.bicep.')
param thresholds object

@description('Tags.')
param tags object = {}

var metricNamespace = 'Microsoft.AzureStackHCI/clusters'

// N-1: aggregate VM memory must fit on the remaining nodes when one node fails or is drained.
var nMinusOneAuto = ((nodeCount - 1) * 100) / nodeCount
var nMinusOneMemoryPercent = thresholds.memoryPercentNMinusOne > 0 ? thresholds.memoryPercentNMinusOne : nMinusOneAuto

// Latency metrics are reported in seconds. Bicep has no decimal literals, so convert ms to a decimal via json().
var volumeLatencySeconds = json('${thresholds.volumeLatencyMs / 1000}.${padLeft(string(thresholds.volumeLatencyMs % 1000), 3, '0')}')
var vhdLatencySeconds = json('${thresholds.vhdLatencyMs / 1000}.${padLeft(string(thresholds.vhdLatencyMs % 1000), 3, '0')}')

var availableMemoryBytes = thresholds.availableMemoryGB * 1073741824

var splitByNode = [
  {
    name: 'ClusterNodeName'
    operator: 'Include'
    values: [
      '*'
    ]
  }
]

var splitByVolume = [
  {
    name: 'LUN'
    operator: 'Include'
    values: [
      '*'
    ]
  }
]

var splitByInstance = [
  {
    name: 'Instance'
    operator: 'Include'
    values: [
      '*'
    ]
  }
]

var rules = [
  {
    key: 'cpu-high'
    deploy: true
    severity: 2
    description: 'Azure Local ${clusterName}: node CPU above ${thresholds.cpuPercent}% (15 min average).'
    metricName: 'Hyper-V Hypervisor Logical Processor\\% Total Run Time'
    timeAggregation: 'Average'
    operator: 'GreaterThan'
    threshold: thresholds.cpuPercent
    windowSize: 'PT15M'
    evaluationFrequency: 'PT5M'
    dimensions: splitByNode
  }
  {
    key: 'memory-high'
    deploy: true
    severity: 1
    description: 'Azure Local ${clusterName}: node memory above ${thresholds.memoryPercentHigh}% (15 min average).'
    metricName: 'ClusterNode Memory Usage'
    timeAggregation: 'Average'
    operator: 'GreaterThan'
    threshold: thresholds.memoryPercentHigh
    windowSize: 'PT15M'
    evaluationFrequency: 'PT5M'
    dimensions: splitByNode
  }
  {
    key: 'memory-n-minus-1'
    deploy: nodeCount > 1
    severity: 2
    description: 'Azure Local ${clusterName}: node memory above ${nMinusOneMemoryPercent}% for 1 hour. The cluster can no longer absorb a node failure or drain without overcommitting memory.'
    metricName: 'ClusterNode Memory Usage'
    timeAggregation: 'Average'
    operator: 'GreaterThan'
    threshold: nMinusOneMemoryPercent
    windowSize: 'PT1H'
    evaluationFrequency: 'PT15M'
    dimensions: splitByNode
  }
  {
    key: 'memory-available-low'
    deploy: true
    severity: 1
    description: 'Azure Local ${clusterName}: available memory on a node below ${thresholds.availableMemoryGB} GB.'
    metricName: 'Memory\\Available Bytes'
    timeAggregation: 'Minimum'
    operator: 'LessThan'
    threshold: availableMemoryBytes
    windowSize: 'PT15M'
    evaluationFrequency: 'PT5M'
    dimensions: splitByNode
  }
  {
    key: 'storage-degraded'
    deploy: true
    severity: 1
    description: 'Azure Local ${clusterName}: failed or missing drives in the storage pool.'
    metricName: 'Cluster Node Storage Degraded'
    timeAggregation: 'Maximum'
    operator: 'GreaterThan'
    threshold: 0
    windowSize: 'PT5M'
    evaluationFrequency: 'PT1M'
    dimensions: []
  }
  {
    key: 'volume-latency-read'
    deploy: true
    severity: 2
    description: 'Azure Local ${clusterName}: CSV read latency above ${thresholds.volumeLatencyMs} ms (15 min average).'
    metricName: 'Cluster CSVFS\\Avg. sec/Read'
    timeAggregation: 'Average'
    operator: 'GreaterThan'
    threshold: volumeLatencySeconds
    windowSize: 'PT15M'
    evaluationFrequency: 'PT5M'
    dimensions: splitByVolume
  }
  {
    key: 'volume-latency-write'
    deploy: true
    severity: 2
    description: 'Azure Local ${clusterName}: CSV write latency above ${thresholds.volumeLatencyMs} ms (15 min average).'
    metricName: 'Cluster CSVFS\\Avg. sec/Write'
    timeAggregation: 'Average'
    operator: 'GreaterThan'
    threshold: volumeLatencySeconds
    windowSize: 'PT15M'
    evaluationFrequency: 'PT5M'
    dimensions: splitByVolume
  }
  {
    key: 'vhd-latency'
    deploy: true
    severity: 3
    description: 'Azure Local ${clusterName}: VHD latency above ${thresholds.vhdLatencyMs} ms (15 min average). Points to a storage-starved or noisy VM.'
    metricName: 'Hyper-V Virtual Storage Device\\Latency'
    timeAggregation: 'Average'
    operator: 'GreaterThan'
    threshold: vhdLatencySeconds
    windowSize: 'PT15M'
    evaluationFrequency: 'PT5M'
    dimensions: splitByInstance
  }
  {
    key: 'vm-memory-pressure'
    deploy: true
    severity: 3
    description: 'Azure Local ${clusterName}: Hyper-V dynamic memory pressure of a VM above ${thresholds.vmMemoryPressurePercent}% (30 min average).'
    metricName: 'Hyper-V Dynamic Memory VM\\Current Pressure'
    timeAggregation: 'Average'
    operator: 'GreaterThan'
    threshold: thresholds.vmMemoryPressurePercent
    windowSize: 'PT30M'
    evaluationFrequency: 'PT5M'
    dimensions: splitByInstance
  }
]

// No action groups on purpose: these alerts target the cluster resource and are routed by
// the alert processing rule in health-alert-routing.bicep, together with the health alerts.
resource metricAlerts 'Microsoft.Insights/metricAlerts@2018-03-01' = [
  for rule in rules: if (rule.deploy) {
    name: '${namePrefix}-${clusterName}-${rule.key}'
    location: 'global'
    tags: tags
    properties: {
      description: rule.description
      severity: rule.severity
      enabled: true
      scopes: [
        clusterId
      ]
      evaluationFrequency: rule.evaluationFrequency
      windowSize: rule.windowSize
      autoMitigate: true
      criteria: {
        'odata.type': 'Microsoft.Azure.Monitor.SingleResourceMultipleMetricCriteria'
        allOf: [
          {
            criterionType: 'StaticThresholdCriterion'
            name: rule.key
            metricNamespace: metricNamespace
            metricName: rule.metricName
            dimensions: rule.dimensions
            operator: rule.operator
            threshold: rule.threshold
            timeAggregation: rule.timeAggregation
            // Some series (for example dynamic memory pressure) only exist once a matching VM runs.
            skipMetricValidation: true
          }
        ]
      }
      actions: []
    }
  }
]
