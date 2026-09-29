Set-StrictMode -Version Latest

$script:MHWorkstationFeatureDefinitions = @(
    [pscustomobject]@{ id = 'WSL'; featureName = 'Microsoft-Windows-Subsystem-Linux' },
    [pscustomobject]@{ id = 'VirtualMachinePlatform'; featureName = 'VirtualMachinePlatform' },
    [pscustomobject]@{ id = 'Hyper-V'; featureName = 'Microsoft-Hyper-V-All' },
    [pscustomobject]@{ id = 'WindowsSandbox'; featureName = 'Containers-DisposableClientVM' }
)

function Get-MHWorkstationProperty {
    param([AllowNull()]$Object, [Parameter(Mandatory)][string]$Name, $Default = $null)
    if ($null -eq $Object) { return $Default }
    if ($Object -is [System.Collections.IDictionary]) {
        foreach ($key in $Object.Keys) { if ([string]$key -ieq $Name) { return $Object[$key] } }
        return $Default
    }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $Default }
    return $property.Value
}

function Get-MHWorkstationFixture {
    param([Parameter(Mandatory)]$Context)
    return Get-MHWorkstationProperty -Object $Context -Name 'workstationFixture'
}

function Get-MHWorkstationRegistryValue {
    param([Parameter(Mandatory)]$Context, [string]$Name, [string]$Path, [string]$ValueName)
    $fixture = Get-MHWorkstationFixture -Context $Context
    if ($null -ne $fixture) { return Get-MHWorkstationProperty -Object $fixture -Name $Name }
    try { return (Get-ItemProperty -LiteralPath $Path -Name $ValueName -ErrorAction Stop).$ValueName }
    catch { return $null }
}

function ConvertTo-MHWorkstationProxyEndpoint {
    param([AllowNull()][string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
    $value = $Text.Trim()
    if ($value -match '^(?i:https?|socks)://') {
        try {
            $uri = [Uri]$value
            if (-not $uri.IsAbsoluteUri -or -not $uri.Host) { return $null }
            return [pscustomobject]@{ scheme = $uri.Scheme.ToLowerInvariant(); host = $uri.Host; port = $(if ($uri.IsDefaultPort) { $null } else { [int]$uri.Port }) }
        } catch { return $null }
    }
    if ($value -match '^(?<host>[A-Za-z0-9._-]{1,253})(?::(?<port>\d{1,5}))?$') {
        $port = $null
        if ($Matches.port) { $port = [int]$Matches.port; if ($port -lt 1 -or $port -gt 65535) { return $null } }
        return [pscustomobject]@{ scheme = $null; host = $Matches.host; port = $port }
    }
    return $null
}

function Get-MHWorkstationFeatureState {
    param([Parameter(Mandatory)]$Context, [Parameter(Mandatory)]$Definition)
    $fixture = Get-MHWorkstationFixture -Context $Context
    if ($null -ne $fixture) {
        $features = @(Get-MHWorkstationProperty -Object $fixture -Name 'optionalFeatures' -Default @())
        $match = @($features | Where-Object { (Get-MHWorkstationProperty -Object $_ -Name 'id') -eq $Definition.id -or (Get-MHWorkstationProperty -Object $_ -Name 'featureName') -eq $Definition.featureName } | Select-Object -First 1)
        if ($match.Count -eq 0) { return 'UNKNOWN' }
        return [string](Get-MHWorkstationProperty -Object $match[0] -Name 'state' -Default 'UNKNOWN')
    }
    if ([string]$Definition.featureName -notmatch '^[A-Za-z0-9-]{1,120}$') { return 'UNKNOWN' }
    $remaining = Get-MHRemainingBudgetMilliseconds -Context $Context
    if ($remaining -le 0) { return 'UNKNOWN' }
    $commandText = "Import-Module Dism -ErrorAction Stop; `$feature = Get-WindowsOptionalFeature -Online -FeatureName '$($Definition.featureName)' -ErrorAction Stop; [Console]::Out.Write([string]`$feature.State)"
    $probe = Invoke-MHSafeProcess -Name 'powershell.exe' -Arguments @('-NoProfile', '-NonInteractive', '-Command', $commandText) -TimeoutMilliseconds ([Math]::Min(3000, $remaining)) -MaxOutputBytes 4096 -Context $Context
    if (-not $probe.found -or $probe.timedOut -or $probe.errorCode -or $probe.exitCode -ne 0) { return 'UNKNOWN' }
    $state = ([string]$probe.stdout).Trim()
    if ($state -in @('Enabled', 'Disabled', 'EnablePending', 'DisablePending', 'PartiallyInstalled', 'Removed')) { return $state }
    return 'UNKNOWN'
}

function Get-MHWorkstationCimTimeoutSeconds {
    param([Parameter(Mandatory)]$Context)
    $remaining = Get-MHRemainingBudgetMilliseconds -Context $Context
    if ($remaining -le 0) { throw 'COLLECTION_BUDGET_EXHAUSTED' }
    return [uint32][Math]::Max(1, [Math]::Min(4, [Math]::Ceiling($remaining / 1000.0)))
}

function Get-MHWorkstationAppSummary {
    param([Parameter(Mandatory)]$Context, [string]$Name, [string]$PackagePattern)
    $fixture = Get-MHWorkstationFixture -Context $Context
    if ($null -ne $fixture) {
        $item = Get-MHWorkstationProperty -Object $fixture -Name $Name
        if ($null -eq $item) { return [pscustomobject]@{ state = 'UNKNOWN'; version = $null } }
        return [pscustomobject]@{ state = [string](Get-MHWorkstationProperty -Object $item -Name 'state' -Default 'UNKNOWN'); version = (Get-MHWorkstationProperty -Object $item -Name 'version') }
    }
    try {
        $package = @(Get-AppxPackage -Name $PackagePattern -ErrorAction Stop | Select-Object -First 1)
        if ($package.Count -eq 0) { return [pscustomobject]@{ state = 'ABSENT'; version = $null } }
        return [pscustomobject]@{ state = 'PRESENT'; version = [string]$package[0].Version }
    } catch { return [pscustomobject]@{ state = 'UNKNOWN'; version = $null } }
}

function Get-MHWorkstationFacts {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Context)

    $warnings = [System.Collections.Generic.List[string]]::new()
    $fixture = Get-MHWorkstationFixture -Context $Context
    $cpu = @()
    $memoryBytes = $null
    $gpu = @()
    $storage = @()
    $architecture = $null

    if ($null -ne $fixture) {
        $architecture = Get-MHWorkstationProperty $fixture 'architecture'
        $cpu = @(Get-MHWorkstationProperty $fixture 'cpu' -Default @())
        $memoryBytes = Get-MHWorkstationProperty $fixture 'memoryBytes'
        $gpu = @(Get-MHWorkstationProperty $fixture 'gpu' -Default @())
        $storage = @(Get-MHWorkstationProperty $fixture 'storage' -Default @())
    } else {
        try { $architecture = [Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString() } catch { $warnings.Add('OS_ARCHITECTURE_UNKNOWN') }
        try {
            $cpuTimeout = Get-MHWorkstationCimTimeoutSeconds -Context $Context
            $cpu = @(Get-CimInstance -ClassName Win32_Processor -OperationTimeoutSec $cpuTimeout -Property Name, NumberOfCores -ErrorAction Stop | ForEach-Object { [pscustomobject]@{ name = [string]$_.Name; cores = $(if ($null -ne $_.NumberOfCores) { [int]$_.NumberOfCores } else { $null }) } } | Where-Object { $_.name })
            if ($cpu.Count -eq 0) { $warnings.Add('CPU_SUMMARY_UNKNOWN') }
        } catch { $warnings.Add('CPU_SUMMARY_UNKNOWN') }
        try {
            $memoryTimeout = Get-MHWorkstationCimTimeoutSeconds -Context $Context
            $sum = (Get-CimInstance -ClassName Win32_PhysicalMemory -OperationTimeoutSec $memoryTimeout -Property Capacity -ErrorAction Stop | Measure-Object -Property Capacity -Sum).Sum
            if ($sum) { $memoryBytes = [long]$sum } else { $warnings.Add('RAM_SUMMARY_UNKNOWN') }
        } catch { $warnings.Add('RAM_SUMMARY_UNKNOWN') }
        try {
            $gpuTimeout = Get-MHWorkstationCimTimeoutSeconds -Context $Context
            $gpu = @(Get-CimInstance -ClassName Win32_VideoController -OperationTimeoutSec $gpuTimeout -Property Name, AdapterRAM -ErrorAction Stop | ForEach-Object { [pscustomobject]@{ name = [string]$_.Name; memoryBytes = $(if ($_.AdapterRAM) { [long]$_.AdapterRAM } else { $null }) } } | Where-Object { $_.name })
            if ($gpu.Count -eq 0) { $warnings.Add('GPU_SUMMARY_UNKNOWN') }
        } catch { $warnings.Add('GPU_SUMMARY_UNKNOWN') }
        try {
            $storageTimeout = Get-MHWorkstationCimTimeoutSeconds -Context $Context
            $storage = @(Get-CimInstance -ClassName Win32_LogicalDisk -Filter 'DriveType=3' -OperationTimeoutSec $storageTimeout -Property DeviceID, Size, FreeSpace -ErrorAction Stop | ForEach-Object { [pscustomobject]@{ name = [string]$_.DeviceID; sizeBytes = $(if ($_.Size) { [long]$_.Size } else { $null }); freeBytes = $(if ($_.FreeSpace) { [long]$_.FreeSpace } else { $null }) } })
            if ($storage.Count -eq 0) { $warnings.Add('STORAGE_SUMMARY_UNKNOWN') }
        } catch { $warnings.Add('STORAGE_SUMMARY_UNKNOWN') }
    }

    $featureItems = @()
    foreach ($definition in $script:MHWorkstationFeatureDefinitions) {
        $state = Get-MHWorkstationFeatureState -Context $Context -Definition $definition
        if ($state -eq 'UNKNOWN') { $warnings.Add('OPTIONAL_FEATURE_STATE_UNKNOWN') }
        $featureItems += [pscustomobject]@{ id = $definition.id; state = $state }
    }
    $developerMode = Get-MHWorkstationRegistryValue -Context $Context -Name 'developerMode' -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\AppModelUnlock' -ValueName 'AllowDevelopmentWithoutDevLicense'
    $longPaths = Get-MHWorkstationRegistryValue -Context $Context -Name 'longPathsEnabled' -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem' -ValueName 'LongPathsEnabled'
    $userProxyEnable = Get-MHWorkstationRegistryValue -Context $Context -Name 'userProxyEnable' -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' -ValueName 'ProxyEnable'
    $userProxyServer = Get-MHWorkstationRegistryValue -Context $Context -Name 'userProxyServer' -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' -ValueName 'ProxyServer'
    $developerState = if ($null -eq $developerMode) { 'UNKNOWN' } elseif ([int]$developerMode -eq 1) { 'ENABLED' } else { 'DISABLED' }
    $longPathsState = if ($null -eq $longPaths) { 'UNKNOWN' } elseif ([int]$longPaths -eq 1) { 'ENABLED' } else { 'DISABLED' }
    if ($developerState -eq 'UNKNOWN' -or $longPathsState -eq 'UNKNOWN') { $warnings.Add('REGISTRY_SETTING_UNKNOWN') }

    $userProxyEndpoint = ConvertTo-MHWorkstationProxyEndpoint -Text ([string]$userProxyServer)
    $userProxyState = if ($null -eq $userProxyEnable) { 'UNKNOWN' } elseif ([int]$userProxyEnable -eq 1) { 'ENABLED' } else { 'DISABLED' }
    if ($userProxyState -eq 'ENABLED' -and $null -eq $userProxyEndpoint) { $warnings.Add('USER_PROXY_ENDPOINT_UNKNOWN') }
    $winHttpEndpoint = $null
    $winHttpState = 'UNKNOWN'
    $remaining = Get-MHRemainingBudgetMilliseconds -Context $Context
    if ($remaining -gt 0) {
        $probe = Invoke-MHSafeProcess -Name 'netsh.exe' -Arguments @('winhttp', 'show', 'proxy') -TimeoutMilliseconds ([Math]::Min(4000, $remaining)) -MaxOutputBytes 8192 -Context $Context
        $output = ([string](Get-MHWorkstationProperty -Object $probe -Name 'stdout' -Default '')) + "`n" + ([string](Get-MHWorkstationProperty -Object $probe -Name 'stderr' -Default ''))
        if ($probe.found -and -not $probe.timedOut -and -not $probe.errorCode -and $probe.exitCode -eq 0) {
            if ($output -match '(?im)proxy\s+server(?:\(s\))?\s*:\s*(?<endpoint>https?://[^\s;]+|[A-Za-z0-9._-]+(?::\d+)?)') {
                $winHttpEndpoint = ConvertTo-MHWorkstationProxyEndpoint -Text $Matches.endpoint
                $winHttpState = if ($winHttpEndpoint) { 'CONFIGURED' } else { 'UNKNOWN' }
            } elseif ($output -match '(?i)(direct access|直接访问|no proxy)') { $winHttpState = 'DIRECT' }
        } else { $warnings.Add('WINHTTP_PROXY_STATE_UNKNOWN') }
    } else { $warnings.Add('PROCESS_BUDGET_EXHAUSTED') }

    $apps = [pscustomobject]@{
        powerToys = Get-MHWorkstationAppSummary -Context $Context -Name 'powerToys' -PackagePattern 'Microsoft.PowerToys*'
        windowsTerminal = Get-MHWorkstationAppSummary -Context $Context -Name 'windowsTerminal' -PackagePattern 'Microsoft.WindowsTerminal*'
    }
    foreach ($name in @('powerToys', 'windowsTerminal')) { if ($apps.$name.state -eq 'UNKNOWN') { $warnings.Add('APP_PACKAGE_STATE_UNKNOWN') } }
    if ($null -eq $architecture) { $warnings.Add('OS_ARCHITECTURE_UNKNOWN') }
    if ($cpu.Count -eq 0) { $warnings.Add('CPU_SUMMARY_UNKNOWN') }
    if ($null -eq $memoryBytes) { $warnings.Add('RAM_SUMMARY_UNKNOWN') }
    if ($gpu.Count -eq 0) { $warnings.Add('GPU_SUMMARY_UNKNOWN') }
    if ($storage.Count -eq 0) { $warnings.Add('STORAGE_SUMMARY_UNKNOWN') }
    if ($userProxyState -eq 'UNKNOWN') { $warnings.Add('USER_PROXY_STATE_UNKNOWN') }
    $payload = [pscustomobject]@{
        id = 'workstation'; state = $(if ($warnings.Count) { 'PARTIAL' } else { 'PRESENT' })
        architecture = $architecture; cpu = @($cpu); memoryBytes = $memoryBytes; gpu = @($gpu); storage = @($storage)
        optionalFeatures = @($featureItems)
        settings = [pscustomobject]@{ developerMode = $developerState; longPaths = $longPathsState }
        proxy = [pscustomobject]@{
            user = [pscustomobject]@{ state = $userProxyState; endpoint = $(if ($userProxyState -eq 'ENABLED') { $userProxyEndpoint } else { $null }) }
            winHttp = [pscustomobject]@{ state = $winHttpState; endpoint = $winHttpEndpoint }
        }
        applications = $apps
    }
    return New-MHDomainResult -Domain 'workstation' -Status $(if ($warnings.Count) { 'PARTIAL' } else { 'OK' }) -Items @($payload) -Warnings @($warnings | Sort-Object -Unique)
}

function Get-MHWorkstationCollection {
    param([Parameter(Mandatory)]$Context)
    return Get-MHWorkstationFacts -Context $Context
}
