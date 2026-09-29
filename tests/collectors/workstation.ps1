[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$repositoryRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
. (Join-Path $repositoryRoot 'scripts\lib\model.ps1')
. (Join-Path $repositoryRoot 'scripts\collectors\workstation.ps1')

function Assert-Workstation {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw ('Workstation collector test failed: ' + $Message) }
    Write-Output ('PASS: ' + $Message)
}

$script:winHttpResult = [pscustomobject]@{ found = $true; exitCode = 0; timedOut = $false; errorCode = $null; stdout = 'Proxy Server(s) : http://bob:password@proxy.example:8888/path' }
$script:optionalFeatureResult = [pscustomobject]@{ found = $true; exitCode = 0; timedOut = $false; errorCode = $null; stdout = 'Enabled' }
$script:processCalls = @()
function Invoke-MHSafeProcess {
    param([string]$Name, [string[]]$Arguments = @(), [int]$TimeoutMilliseconds = 5000, [int]$MaxOutputBytes = 65536, $Context)
    $script:processCalls += [pscustomobject]@{ name = $Name; arguments = @($Arguments); timeout = $TimeoutMilliseconds; hasContext = ($null -ne $Context) }
    if ($Name -eq 'netsh.exe') { return $script:winHttpResult }
    if ($Name -eq 'powershell.exe') { return $script:optionalFeatureResult }
    return [pscustomobject]@{ found = $false; exitCode = $null; timedOut = $false; errorCode = 'NOT_FOUND'; stdout = '' }
}

$script:cimCalls = @()
function Get-CimInstance {
    param([string]$ClassName, [string]$Filter, [string[]]$Property, [uint32]$OperationTimeoutSec, [string]$ErrorAction)
    $script:cimCalls += [pscustomobject]@{ className = $ClassName; timeout = $OperationTimeoutSec }
    switch ($ClassName) {
        'Win32_Processor' { return @([pscustomobject]@{ Name = 'Bounded Fixture CPU'; NumberOfCores = 4 }) }
        'Win32_PhysicalMemory' { return @([pscustomobject]@{ Capacity = 8589934592L }) }
        'Win32_VideoController' { return @([pscustomobject]@{ Name = 'Bounded Fixture GPU'; AdapterRAM = 2147483648 }) }
        'Win32_LogicalDisk' { return @([pscustomobject]@{ DeviceID = 'C:'; Size = 50000000000L; FreeSpace = 10000000000L }) }
        default { return @() }
    }
}
function Get-ItemProperty {
    param([string]$LiteralPath, [string]$Name, [string]$ErrorAction)
    $value = switch ($Name) {
        'AllowDevelopmentWithoutDevLicense' { 1 }
        'LongPathsEnabled' { 1 }
        'ProxyEnable' { 0 }
        'ProxyServer' { '' }
        default { $null }
    }
    return [pscustomobject]@{ $Name = $value }
}
function Get-AppxPackage {
    param([string]$Name, [string]$ErrorAction)
    return @([pscustomobject]@{ Version = '1.0.0.0' })
}

$fixture = [pscustomobject]@{
    architecture = 'AMD64'
    cpu = @([pscustomobject]@{ name = 'Fixture CPU'; cores = 8 })
    memoryBytes = 17179869184L
    gpu = @([pscustomobject]@{ name = 'Fixture GPU'; memoryBytes = 4294967296L })
    storage = @([pscustomobject]@{ name = 'C:'; sizeBytes = 100000000000L; freeBytes = 25000000000L })
    optionalFeatures = @(
        [pscustomobject]@{ featureName = 'Microsoft-Windows-Subsystem-Linux'; state = 'Enabled' },
        [pscustomobject]@{ featureName = 'VirtualMachinePlatform'; state = 'Enabled' },
        [pscustomobject]@{ featureName = 'Microsoft-Hyper-V-All'; state = 'Disabled' },
        [pscustomobject]@{ featureName = 'Containers-DisposableClientVM'; state = 'Enabled' }
    )
    developerMode = 1
    longPathsEnabled = 1
    userProxyEnable = 1
    userProxyServer = 'http://alice:secret@proxy.example:8080/path?token=hidden'
    powerToys = [pscustomobject]@{ state = 'PRESENT'; version = '0.90.0' }
    windowsTerminal = [pscustomobject]@{ state = 'PRESENT'; version = '1.22.0' }
}
$context = New-MHCollectionContext
$context | Add-Member -NotePropertyName workstationFixture -NotePropertyValue $fixture
$result = Get-MHWorkstationCollection -Context $context
$payload = $result.items[0]
$serialized = ConvertTo-Json -InputObject $result -Depth 10 -Compress
Assert-Workstation ($result.domain -eq 'workstation' -and $result.status -eq 'OK') 'synthetic workstation facts use the shared domain result'
Assert-Workstation ($payload.cpu[0].name -eq 'Fixture CPU' -and $payload.memoryBytes -eq 17179869184L) 'CPU and RAM summary is retained'
Assert-Workstation (@($payload.optionalFeatures).Count -eq 4) 'only fixed optional-feature inventory is returned'
Assert-Workstation ($serialized -notmatch 'alice|secret|bob|password|token=hidden|/path') 'proxy output removes credentials, path, and query'
Assert-Workstation ($payload.proxy.user.state -eq 'ENABLED' -and $payload.proxy.winHttp.state -eq 'CONFIGURED') 'proxy status is retained without auth material'

$script:winHttpResult = [pscustomobject]@{ found = $false; exitCode = $null; timedOut = $false; errorCode = 'NOT_FOUND'; stdout = '' }
$failedProxy = Get-MHWorkstationCollection -Context $context
Assert-Workstation ($failedProxy.status -eq 'PARTIAL' -and $failedProxy.items[0].proxy.winHttp.state -eq 'UNKNOWN' -and $failedProxy.warnings -contains 'WINHTTP_PROXY_STATE_UNKNOWN') 'missing WinHTTP probe only downgrades local collector state'

$partialContext = New-MHCollectionContext
$partialContext | Add-Member -NotePropertyName workstationFixture -NotePropertyValue ([pscustomobject]@{ architecture = $null; cpu = @(); memoryBytes = $null; gpu = @(); storage = @(); optionalFeatures = @(); developerMode = $null; longPathsEnabled = $null; userProxyEnable = $null; userProxyServer = $null; powerToys = [pscustomobject]@{ state = 'UNKNOWN'; version = $null }; windowsTerminal = [pscustomobject]@{ state = 'UNKNOWN'; version = $null } })
$partialResult = Get-MHWorkstationCollection -Context $partialContext
Assert-Workstation ($partialResult.status -eq 'PARTIAL' -and @($partialResult.warnings).Count -gt 0) 'missing fixture facts become partial with fixed warnings'
$featureContext = New-MHCollectionContext -Profile Standard
$feature = [pscustomobject]@{ id = 'WSL'; featureName = 'Microsoft-Windows-Subsystem-Linux' }
$script:optionalFeatureResult = [pscustomobject]@{ found = $true; exitCode = 0; timedOut = $false; errorCode = $null; stdout = 'Enabled' }
$featureState = Get-MHWorkstationFeatureState -Context $featureContext -Definition $feature
$featureCall = @($script:processCalls | Where-Object name -eq 'powershell.exe' | Select-Object -Last 1)[0]
Assert-Workstation ($featureState -eq 'Enabled' -and $featureCall.arguments -contains '-NoProfile' -and $featureCall.arguments -contains '-NonInteractive' -and $featureCall.hasContext) 'Optional Feature probes are bounded in a no-profile child process'
$script:optionalFeatureResult = [pscustomobject]@{ found = $true; exitCode = $null; timedOut = $true; errorCode = 'TIMEOUT'; stdout = '' }
$timedOutFeature = Get-MHWorkstationFeatureState -Context $featureContext -Definition $feature
Assert-Workstation ($timedOutFeature -eq 'UNKNOWN') 'Optional Feature timeout stays local and does not claim a state'
$script:optionalFeatureResult = [pscustomobject]@{ found = $true; exitCode = 0; timedOut = $false; errorCode = $null; stdout = 'Enabled' }
$script:cimCalls = @()
$hostContext = New-MHCollectionContext -Profile Standard
$hostResult = Get-MHWorkstationCollection -Context $hostContext
Assert-Workstation (@($script:cimCalls).Count -eq 4 -and @($script:cimCalls | Where-Object { $_.timeout -gt 0 }).Count -eq 4) 'hardware CIM queries carry operation timeouts'
Assert-Workstation ($hostResult.status -in @('OK', 'PARTIAL')) 'bounded host query path returns a localized status'
Write-Output 'Workstation collector tests passed.'
