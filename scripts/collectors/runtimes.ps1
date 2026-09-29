Set-StrictMode -Version Latest

# v1.5 运行时采集器只保留经过规范化的版本、包名、路径和状态。
# 命令的 stdout/stderr 只在本次调用的内存中使用，绝不作为结果字段返回。

$script:MHRuntimeVersionPattern = '(?<![A-Za-z0-9])v?\d+(?:\.\d+){1,3}(?:[-+][A-Za-z0-9._-]+)?'
$script:MHRuntimePackageNamePattern = '^@?[A-Za-z0-9][A-Za-z0-9._+/-]{0,199}$'
function Get-MHRuntimeProperty {
    param(
        [AllowNull()]$Object,
        [Parameter(Mandatory)][string]$Name,
        $Default = $null
    )

    if ($null -eq $Object) { return $Default }
    if ($Object -is [System.Collections.IDictionary]) {
        foreach ($key in $Object.Keys) {
            if ([string]$key -ieq $Name) { return $Object[$key] }
        }
        return $Default
    }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $Default }
    return $property.Value
}

function ConvertTo-MHRuntimeSafePath {
    param([AllowNull()][string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) { return $null }
    $value = $Path.Trim()
    if ($value.Length -gt 1024 -or $value -match '[\r\n\x00]' -or $value -match '://[^/\s:@]+:[^/\s@]+@') { return $null }
    if (Get-Command -Name Test-MHSecretText -CommandType Function -ErrorAction SilentlyContinue) {
        if (Test-MHSecretText -Text $value) { return $null }
    } elseif ($value -match '(?i)(?:api[_-]?key|token|password|passwd|authorization|cookie)\s*[=:]') {
        return $null
    }
    return $value.TrimEnd('\')
}

function ConvertTo-MHRuntimeVersion {
    param([AllowNull()][string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
    $match = [regex]::Match($Text, $script:MHRuntimeVersionPattern)
    if (-not $match.Success) { return $null }
    return $match.Value
}

function ConvertTo-MHRuntimeOutputText {
    param($Probe)

    $parts = @()
    foreach ($name in @('stdout', 'stderr', 'output')) {
        $value = Get-MHRuntimeProperty -Object $Probe -Name $name
        if ($null -ne $value -and -not [string]::IsNullOrWhiteSpace([string]$value)) { $parts += [string]$value }
    }
    return ($parts -join "`n")
}

function Get-MHRuntimeFixture {
    param(
        [Parameter(Mandatory)]$Context,
        [Parameter(Mandatory)][string]$Name,
        [string[]]$Arguments = @()
    )

    $fixtures = Get-MHRuntimeProperty -Object $Context -Name 'runtimeFixtures'
    if ($null -eq $fixtures) { return $null }
    $argumentKey = ($Arguments -join ' ')
    $keys = @(
        ($Name + '|' + $argumentKey)
        $Name
    )
    if ($fixtures -is [System.Collections.IDictionary]) {
        foreach ($key in $keys) {
            foreach ($actualKey in $fixtures.Keys) {
                if ([string]$actualKey -ieq $key) { return $fixtures[$actualKey] }
            }
        }
        return $null
    }
    foreach ($key in $keys) {
        $property = $fixtures.PSObject.Properties[$key]
        if ($null -ne $property) { return $property.Value }
    }
    return $null
}

function Invoke-MHRuntimeProbe {
    param(
        [Parameter(Mandatory)]$Context,
        [Parameter(Mandatory)][string]$Name,
        [string[]]$Arguments = @()
    )

    $fixture = Get-MHRuntimeFixture -Context $Context -Name $Name -Arguments $Arguments
    if ($null -ne $fixture) {
        if ($fixture -is [string]) {
            return [pscustomobject]@{ found = $true; started = $true; exitCode = 0; timedOut = $false; stdout = [string]$fixture; stderr = ''; errorCode = $null }
        }
        return $fixture
    }
    try {
        $result = Invoke-MHSafeProcess -Context $Context -Name $Name -Arguments @($Arguments)
        if ($null -ne $result) { return $result }
        return [pscustomobject]@{ found = $true; started = $false; exitCode = $null; timedOut = $false; stdout = ''; stderr = ''; errorCode = 'PROCESS_FAILED' }
    } catch {
        return [pscustomobject]@{
            found = $true; started = $false; exitCode = $null; timedOut = $false
            stdout = ''; stderr = ''; errorCode = 'PROCESS_FAILED'
        }
    }
}

function Get-MHRuntimeCommandPath {
    param([Parameter(Mandatory)][string]$Name)

    try {
        $command = Get-Command -Name $Name -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($null -eq $command) { return $null }
        $path = if ($command.Source) { [string]$command.Source } else { [string]$command.Path }
        return ConvertTo-MHRuntimeSafePath -Path $path
    } catch { return $null }
}

function Get-MHRuntimeProbeState {
    param($Probe)

    if ($null -eq $Probe) { return 'UNKNOWN' }
    if (-not [bool](Get-MHRuntimeProperty -Object $Probe -Name 'found' -Default $true)) { return 'ABSENT' }
    if ([bool](Get-MHRuntimeProperty -Object $Probe -Name 'timedOut' -Default $false)) { return 'UNKNOWN' }
    $errorCode = [string](Get-MHRuntimeProperty -Object $Probe -Name 'errorCode')
    if (-not [string]::IsNullOrWhiteSpace($errorCode)) { return 'UNKNOWN' }
    $exitCode = Get-MHRuntimeProperty -Object $Probe -Name 'exitCode'
    if ($null -ne $exitCode -and [int]$exitCode -ne 0) { return 'UNKNOWN' }
    if ($null -eq $exitCode -and -not [bool](Get-MHRuntimeProperty -Object $Probe -Name 'started' -Default $true)) { return 'UNKNOWN' }
    return 'PRESENT'
}

function ConvertTo-MHRuntimeErrorCode {
    param([AllowNull()][string]$Code)

    if ([string]::IsNullOrWhiteSpace($Code)) { return $null }
    $allowed = @('NOT_FOUND', 'TIMEOUT', 'PROCESS_FAILED', 'START_FAILED', 'COMMAND_FAILED', 'OUTPUT_INVALID', 'VALUE_UNAVAILABLE', 'REDACTION_BLOCKED')
    if ($allowed -contains $Code.ToUpperInvariant()) { return $Code.ToUpperInvariant() }
    return 'PROCESS_FAILED'
}

function Get-MHRuntimeProbeStatus {
    param($Probe)

    if ($null -eq $Probe) { return 'PROCESS_FAILED' }
    if (-not [bool](Get-MHRuntimeProperty -Object $Probe -Name 'found' -Default $true)) { return 'NOT_FOUND' }
    if ([bool](Get-MHRuntimeProperty -Object $Probe -Name 'timedOut' -Default $false)) { return 'TIMEOUT' }
    $errorCode = ConvertTo-MHRuntimeErrorCode -Code ([string](Get-MHRuntimeProperty -Object $Probe -Name 'errorCode'))
    if ($errorCode) { return $errorCode }
    $exitCode = Get-MHRuntimeProperty -Object $Probe -Name 'exitCode'
    if ($null -ne $exitCode -and [int]$exitCode -ne 0) { return 'COMMAND_FAILED' }
    if ($null -eq $exitCode -and -not [bool](Get-MHRuntimeProperty -Object $Probe -Name 'started' -Default $true)) { return 'PROCESS_FAILED' }
    return 'OK'
}

function New-MHRuntimeToolRecord {
    param(
        [Parameter(Mandatory)]$Context,
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)][string]$Name,
        [string[]]$Arguments = @(),
        [string]$DisplayName = $Name
    )

    $probe = Invoke-MHRuntimeProbe -Context $Context -Name $Name -Arguments @($Arguments)
    $state = Get-MHRuntimeProbeState -Probe $probe
    $status = Get-MHRuntimeProbeStatus -Probe $probe
    $version = $null
    if ($state -eq 'PRESENT') { $version = ConvertTo-MHRuntimeVersion -Text (ConvertTo-MHRuntimeOutputText -Probe $probe) }
    $fixturePath = ConvertTo-MHRuntimeSafePath -Path ([string](Get-MHRuntimeProperty -Object $probe -Name 'path'))
    $path = if ($fixturePath) { $fixturePath } else { Get-MHRuntimeCommandPath -Name $Name }
    if ($state -eq 'PRESENT' -and $null -eq $version) { $status = 'VERSION_UNAVAILABLE' }
    return [pscustomobject]@{
        id = $Id; name = $DisplayName; command = $Name; state = $state; status = $status
        version = $version; installedVersion = $version; defaultVersion = $version; path = $path
    }
}

function Get-MHRuntimePackageRecord {
    param(
        [AllowNull()][string]$Name,
        [AllowNull()][string]$Version,
        [Parameter(Mandatory)][string]$Manager,
        [string]$Scope = 'GLOBAL'
    )

    if ([string]::IsNullOrWhiteSpace($Name) -or $Name -notmatch $script:MHRuntimePackageNamePattern) { return $null }
    $safeVersion = ConvertTo-MHRuntimeVersion -Text $Version
    if (-not $safeVersion) { return $null }
    return [pscustomobject]@{ id = $Manager + ':' + $Name; name = $Name; version = $safeVersion; manager = $Manager; scope = $Scope; state = 'PRESENT' }
}

function Get-MHRuntimeNpmPackages {
    param([Parameter(Mandatory)]$Context)

    $probe = Invoke-MHRuntimeProbe -Context $Context -Name 'npm' -Arguments @('ls', '-g', '--depth=0', '--json')
    $status = Get-MHRuntimeProbeStatus -Probe $probe
    if ($status -ne 'OK') { return [pscustomobject]@{ status = $status; packages = @() } }
    $text = ConvertTo-MHRuntimeOutputText -Probe $probe
    try { $json = $text | ConvertFrom-Json -ErrorAction Stop } catch { return [pscustomobject]@{ status = 'OUTPUT_INVALID'; packages = @() } }
    $packages = @()
    $dependencies = Get-MHRuntimeProperty -Object $json -Name 'dependencies'
    if ($null -ne $dependencies) {
        foreach ($property in $dependencies.PSObject.Properties) {
            $version = Get-MHRuntimeProperty -Object $property.Value -Name 'version'
            $package = Get-MHRuntimePackageRecord -Name ([string]$property.Name) -Version ([string]$version) -Manager 'npm'
            if ($package) { $packages += $package }
        }
    }
    return [pscustomobject]@{ status = 'OK'; packages = @($packages) }
}

function Get-MHRuntimeJsonPackages {
    param(
        [Parameter(Mandatory)]$Probe,
        [Parameter(Mandatory)][string]$Manager
    )

    $status = Get-MHRuntimeProbeStatus -Probe $Probe
    if ($status -ne 'OK') { return [pscustomobject]@{ status = $status; packages = @() } }
    try { $json = (ConvertTo-MHRuntimeOutputText -Probe $Probe) | ConvertFrom-Json -ErrorAction Stop } catch { return [pscustomobject]@{ status = 'OUTPUT_INVALID'; packages = @() } }
    $packages = @()
    $nodes = @($json)
    foreach ($node in $nodes) {
        $dependencies = Get-MHRuntimeProperty -Object $node -Name 'dependencies'
        if ($null -ne $dependencies) {
            foreach ($property in $dependencies.PSObject.Properties) {
                $version = Get-MHRuntimeProperty -Object $property.Value -Name 'version'
                $package = Get-MHRuntimePackageRecord -Name ([string]$property.Name) -Version ([string]$version) -Manager $Manager
                if ($package) { $packages += $package }
            }
        }
        $name = [string](Get-MHRuntimeProperty -Object $node -Name 'name')
        $version = [string](Get-MHRuntimeProperty -Object $node -Name 'version')
        $package = Get-MHRuntimePackageRecord -Name $name -Version $version -Manager $Manager
        if ($package) { $packages += $package }
        $venvs = Get-MHRuntimeProperty -Object $node -Name 'venvs'
        if ($null -ne $venvs) {
            foreach ($venv in $venvs.PSObject.Properties) {
                $metadata = Get-MHRuntimeProperty -Object $venv.Value -Name 'metadata'
                $mainPackage = Get-MHRuntimeProperty -Object $metadata -Name 'main_package'
                $mainName = [string](Get-MHRuntimeProperty -Object $mainPackage -Name 'package')
                $mainVersion = [string](Get-MHRuntimeProperty -Object $mainPackage -Name 'package_version')
                $venvPackage = Get-MHRuntimePackageRecord -Name $mainName -Version $mainVersion -Manager $Manager -Scope 'USER'
                if ($venvPackage) { $packages += $venvPackage }
            }
        }
    }
    $unique = @($packages | Group-Object id | ForEach-Object { $_.Group[0] })
    return [pscustomobject]@{ status = 'OK'; packages = @($unique) }
}

function Get-MHRuntimeTextPackages {
    param(
        [Parameter(Mandatory)]$Probe,
        [Parameter(Mandatory)][string]$Manager
    )

    $status = Get-MHRuntimeProbeStatus -Probe $Probe
    if ($status -ne 'OK') { return [pscustomobject]@{ status = $status; packages = @() } }
    $packages = @()
    foreach ($line in @((ConvertTo-MHRuntimeOutputText -Probe $Probe) -split "`r?`n")) {
        $match = [regex]::Match($line, '(?<name>@?[A-Za-z0-9][A-Za-z0-9._-]*(?:/[A-Za-z0-9][A-Za-z0-9._-]*)?)@(?<version>\d+(?:\.\d+){1,3}(?:[-+][A-Za-z0-9._-]+)?)')
        if (-not $match.Success) {
            $match = [regex]::Match($line, '^\s*(?<simpleName>[A-Za-z0-9][A-Za-z0-9._-]{0,199})\s+v?(?<simpleVersion>\d+(?:\.\d+){1,3}(?:[-+][A-Za-z0-9._-]+)?)\s*$')
            if ($match.Success) {
                $package = Get-MHRuntimePackageRecord -Name $match.Groups['simpleName'].Value -Version $match.Groups['simpleVersion'].Value -Manager $Manager
                if ($package) { $packages += $package }
                continue
            }
        }
        if ($match.Success) {
            $package = Get-MHRuntimePackageRecord -Name $match.Groups['name'].Value -Version $match.Groups['version'].Value -Manager $Manager
            if ($package) { $packages += $package }
        }
    }
    $unique = @($packages | Group-Object id | ForEach-Object { $_.Group[0] })
    return [pscustomobject]@{ status = 'OK'; packages = @($unique) }
}

function Get-MHRuntimeManagerRecord {
    param(
        [Parameter(Mandatory)]$Context,
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)][string]$Name,
        [string[]]$Arguments = @(),
        [string]$DisplayName = $Name
    )

    $record = New-MHRuntimeToolRecord -Context $Context -Id $Id -Name $Name -Arguments @($Arguments) -DisplayName $DisplayName
    return $record
}

function Get-MHRuntimeInstalledVersions {
    param(
        [Parameter(Mandatory)]$Probe,
        [string]$Pattern = $script:MHRuntimeVersionPattern
    )

    if ((Get-MHRuntimeProbeStatus -Probe $Probe) -ne 'OK') { return @() }
    $result = @()
    foreach ($match in [regex]::Matches((ConvertTo-MHRuntimeOutputText -Probe $Probe), $Pattern)) {
        $value = ConvertTo-MHRuntimeVersion -Text $match.Value
        if ($value) { $result += $value }
    }
    return @($result | Sort-Object -Unique)
}

function Get-MHRuntimeSafeValue {
    param(
        [Parameter(Mandatory)]$Probe,
        [ValidateSet('PATH', 'REGISTRY')][string]$Kind
    )

    $status = Get-MHRuntimeProbeStatus -Probe $Probe
    if ($status -ne 'OK') { return [pscustomobject]@{ status = $status; value = $null } }
    foreach ($line in @((ConvertTo-MHRuntimeOutputText -Probe $Probe) -split "`r?`n")) {
        $text = $line.Trim()
        if ([string]::IsNullOrWhiteSpace($text)) { continue }
        if ($Kind -eq 'PATH') {
            $safePath = ConvertTo-MHRuntimeSafePath -Path $text
            if ($safePath) { return [pscustomobject]@{ status = 'OK'; value = $safePath } }
        } else {
            if ($text -match '://[^/\s:@]+:[^/\s@]+@') { return [pscustomobject]@{ status = 'REDACTION_BLOCKED'; value = $null } }
            try {
                $uri = New-Object System.Uri($text)
                if ($uri.IsAbsoluteUri -and $uri.Host -and [string]::IsNullOrWhiteSpace($uri.UserInfo)) {
                    $builder = New-Object System.UriBuilder($uri.Scheme, $uri.Host, $uri.Port, $uri.AbsolutePath)
                    return [pscustomobject]@{ status = 'OK'; value = $builder.Uri.AbsoluteUri.TrimEnd('/') }
                }
            } catch { }
        }
    }
    return [pscustomobject]@{ status = 'VALUE_UNAVAILABLE'; value = $null }
}

function Get-MHRuntimeNodePackageManagerFacts {
    param(
        [Parameter(Mandatory)]$Context,
        [Parameter(Mandatory)]$Managers,
        [ref]$Warnings
    )

    $facts = @()
    $definitions = @(
        @{ managerId = 'node:npm'; name = 'npm'; kind = 'REGISTRY'; id = 'npm:registry'; args = @('config', 'get', 'registry') },
        @{ managerId = 'node:npm'; name = 'npm'; kind = 'PATH'; id = 'npm:global-root'; args = @('root', '--global') },
        @{ managerId = 'node:npm'; name = 'npm'; kind = 'PATH'; id = 'npm:global-prefix'; args = @('prefix', '--global') },
        @{ managerId = 'node:pnpm'; name = 'pnpm'; kind = 'PATH'; id = 'pnpm:store'; args = @('store', 'path') },
        @{ managerId = 'node:pnpm'; name = 'pnpm'; kind = 'PATH'; id = 'pnpm:global-bin'; args = @('bin', '--global') },
        @{ managerId = 'node:yarn'; name = 'yarn'; kind = 'PATH'; id = 'yarn:global-dir'; args = @('global', 'dir') },
        @{ managerId = 'node:bun'; name = 'bun'; kind = 'PATH'; id = 'bun:global-bin'; args = @('pm', 'bin', '--global') }
    )
    foreach ($definition in $definitions) {
        $manager = $Managers | Where-Object { $_.id -eq $definition.managerId } | Select-Object -First 1
        if ($null -eq $manager -or $manager.state -ne 'PRESENT') { continue }
        $probe = Invoke-MHRuntimeProbe -Context $Context -Name $definition.name -Arguments @($definition.args)
        $value = Get-MHRuntimeSafeValue -Probe $probe -Kind $definition.kind
        $facts += [pscustomobject]@{ id = $definition.id; manager = $definition.name; kind = $definition.kind; state = $(if ($value.value) { 'PRESENT' } else { 'UNKNOWN' }); status = $value.status; value = $value.value; source = 'READ_ONLY_COMMAND' }
        if ($value.status -notin @('OK', 'NOT_FOUND') -and $value.status) { $Warnings.Value += 'RUNTIME_NODE_' + $definition.id.Replace(':', '_').ToUpperInvariant() + '_' + $value.status }
    }
    return @($facts)
}

function Get-MHRuntimeDefaultVersion {
    param([Parameter(Mandatory)]$Probe)

    if ((Get-MHRuntimeProbeStatus -Probe $Probe) -ne 'OK') { return $null }
    foreach ($line in @((ConvertTo-MHRuntimeOutputText -Probe $Probe) -split "`r?`n")) {
        if ($line -match '(?i)(?:\*|current|default|active)') {
            $version = ConvertTo-MHRuntimeVersion -Text $line
            if ($version) { return $version }
        }
    }
    return $null
}

function Get-MHRuntimeNodeManagers {
    param([Parameter(Mandatory)]$Context)

    $definitions = @(
        @{ id = 'node:npm'; name = 'npm'; args = @('--version') },
        @{ id = 'node:pnpm'; name = 'pnpm'; args = @('--version') },
        @{ id = 'node:yarn'; name = 'yarn'; args = @('--version') },
        @{ id = 'node:bun'; name = 'bun'; args = @('--version') },
        @{ id = 'node:corepack'; name = 'corepack'; args = @('--version') },
        @{ id = 'node:fnm'; name = 'fnm'; args = @('--version') },
        @{ id = 'node:nvm'; name = 'nvm'; args = @('version') },
        @{ id = 'node:volta'; name = 'volta'; args = @('--version') },
        @{ id = 'node:nvs'; name = 'nvs'; args = @('--version') }
    )
    $records = @()
    foreach ($definition in $definitions) {
        $records += Get-MHRuntimeManagerRecord -Context $Context -Id $definition.id -Name $definition.name -Arguments @($definition.args)
    }
    return @($records)
}

function Get-MHRuntimeNode {
    param(
        [Parameter(Mandatory)]$Context,
        [ref]$Warnings,
        [ref]$Artifacts
    )

    $node = New-MHRuntimeToolRecord -Context $Context -Id 'runtime:node' -Name 'node' -Arguments @('--version') -DisplayName 'Node.js'
    $managers = @(Get-MHRuntimeNodeManagers -Context $Context)
    $packages = @()
    foreach ($manager in $managers) {
        if ($manager.state -ne 'PRESENT') { continue }
        if ($manager.id -eq 'node:npm') {
            $list = Get-MHRuntimeNpmPackages -Context $Context
            $packages += @($list.packages)
            $manager | Add-Member -NotePropertyName globalPackages -NotePropertyValue @($list.packages) -Force
            if ($list.status -ne 'OK') { $Warnings.Value += 'RUNTIME_NODE_NPM_' + $list.status }
        } elseif ($manager.id -eq 'node:pnpm') {
            $probe = Invoke-MHRuntimeProbe -Context $Context -Name 'pnpm' -Arguments @('list', '--global', '--depth=0', '--json')
            $list = Get-MHRuntimeJsonPackages -Probe $probe -Manager 'pnpm'
            $packages += @($list.packages)
            $manager | Add-Member -NotePropertyName globalPackages -NotePropertyValue @($list.packages) -Force
            if ($list.status -ne 'OK') { $Warnings.Value += 'RUNTIME_NODE_PNPM_' + $list.status }
        } elseif ($manager.id -eq 'node:yarn') {
            $probe = Invoke-MHRuntimeProbe -Context $Context -Name 'yarn' -Arguments @('global', 'list', '--json')
            $list = Get-MHRuntimeTextPackages -Probe $probe -Manager 'yarn'
            $packages += @($list.packages)
            $manager | Add-Member -NotePropertyName globalPackages -NotePropertyValue @($list.packages) -Force
            if ($list.status -ne 'OK') { $Warnings.Value += 'RUNTIME_NODE_YARN_' + $list.status }
        } elseif ($manager.id -eq 'node:bun') {
            $probe = Invoke-MHRuntimeProbe -Context $Context -Name 'bun' -Arguments @('pm', 'ls', '--global')
            $list = Get-MHRuntimeTextPackages -Probe $probe -Manager 'bun'
            $packages += @($list.packages)
            $manager | Add-Member -NotePropertyName globalPackages -NotePropertyValue @($list.packages) -Force
            if ($list.status -ne 'OK') { $Warnings.Value += 'RUNTIME_NODE_BUN_' + $list.status }
        }
    }

    $versionLists = @()
    $versionCommands = @(
        @{ managerId = 'node:fnm'; name = 'fnm'; args = @('list') },
        @{ managerId = 'node:nvm'; name = 'nvm'; args = @('list') },
        @{ managerId = 'node:volta'; name = 'volta'; args = @('list', '--format', 'plain') },
        @{ managerId = 'node:nvs'; name = 'nvs'; args = @('ls') }
    )
    foreach ($versionCommand in $versionCommands) {
        $manager = $managers | Where-Object { $_.id -eq $versionCommand.managerId } | Select-Object -First 1
        if ($null -eq $manager -or $manager.state -ne 'PRESENT') { continue }
        $probe = Invoke-MHRuntimeProbe -Context $Context -Name $versionCommand.name -Arguments @($versionCommand.args)
        $versions = @(Get-MHRuntimeInstalledVersions -Probe $probe)
        $defaultVersion = Get-MHRuntimeDefaultVersion -Probe $probe
        $versionLists += @($versions)
        if ((Get-MHRuntimeProbeStatus -Probe $probe) -ne 'OK') { $Warnings.Value += 'RUNTIME_NODE_' + $versionCommand.managerId.Split(':')[1].ToUpperInvariant() + '_LIST_' + (Get-MHRuntimeProbeStatus -Probe $probe) }
        $manager | Add-Member -NotePropertyName installedVersions -NotePropertyValue $versions -Force
        $manager | Add-Member -NotePropertyName defaultVersion -NotePropertyValue $(if ($defaultVersion) { $defaultVersion } elseif ($versions.Count -gt 0) { $versions[0] } else { $null }) -Force
    }
    foreach ($manager in $managers) {
        if ($null -eq (Get-MHRuntimeProperty -Object $manager -Name 'installedVersions')) { $manager | Add-Member -NotePropertyName installedVersions -NotePropertyValue @() -Force }
        if ($null -eq (Get-MHRuntimeProperty -Object $manager -Name 'defaultVersion')) { $manager | Add-Member -NotePropertyName defaultVersion -NotePropertyValue $null -Force }
        if ($null -eq (Get-MHRuntimeProperty -Object $manager -Name 'globalPackages')) { $manager | Add-Member -NotePropertyName globalPackages -NotePropertyValue @() -Force }
    }
    $installed = @($versionLists + @($node.version) | Where-Object { $_ } | Sort-Object -Unique)
    $packageManagerFacts = @(Get-MHRuntimeNodePackageManagerFacts -Context $Context -Managers $managers -Warnings $Warnings)
    $managerDefault = $managers | Where-Object { $_.defaultVersion } | Select-Object -First 1
    if (-not $node.defaultVersion -and $managerDefault) {
        $node | Add-Member -NotePropertyName defaultVersion -NotePropertyValue $managerDefault.defaultVersion -Force
        $node | Add-Member -NotePropertyName installedVersion -NotePropertyValue $managerDefault.defaultVersion -Force
    }
    $node | Add-Member -NotePropertyName installedVersions -NotePropertyValue $installed -Force
    $node | Add-Member -NotePropertyName managers -NotePropertyValue @($managers) -Force
    $node | Add-Member -NotePropertyName globalPackages -NotePropertyValue @($packages | Group-Object id | ForEach-Object { $_.Group[0] }) -Force
    $node | Add-Member -NotePropertyName globalTools -NotePropertyValue @($packages | Group-Object id | ForEach-Object { $_.Group[0] }) -Force
    $node | Add-Member -NotePropertyName toolchain -NotePropertyValue 'node' -Force
    $node | Add-Member -NotePropertyName pathFacts -NotePropertyValue @(Get-MHRuntimePathFacts -Runtime 'node') -Force
    $node | Add-Member -NotePropertyName registryFacts -NotePropertyValue @(Get-MHRuntimeRegistryFacts -Runtime 'node') -Force
    $node | Add-Member -NotePropertyName packageManagerFacts -NotePropertyValue $packageManagerFacts -Force
    $node | Add-Member -NotePropertyName registries -NotePropertyValue @($packageManagerFacts | Where-Object kind -eq 'REGISTRY') -Force
    $node | Add-Member -NotePropertyName managerPaths -NotePropertyValue @($packageManagerFacts | Where-Object kind -eq 'PATH') -Force
    $node | Add-Member -NotePropertyName configArtifacts -NotePropertyValue @() -Force
    return $node
}

function Get-MHRuntimePythonManagers {
    param([Parameter(Mandatory)]$Context)

    $definitions = @(
        @{ id = 'python:python'; name = 'python'; args = @('--version') },
        @{ id = 'python:python3'; name = 'python3'; args = @('--version') },
        @{ id = 'python:launcher'; name = 'py'; args = @('--version') },
        @{ id = 'python:pip'; name = 'pip'; args = @('--version') },
        @{ id = 'python:pip3'; name = 'pip3'; args = @('--version') },
        @{ id = 'python:pipx'; name = 'pipx'; args = @('--version') },
        @{ id = 'python:uv'; name = 'uv'; args = @('--version') },
        @{ id = 'python:poetry'; name = 'poetry'; args = @('--version') },
        @{ id = 'python:conda'; name = 'conda'; args = @('--version') },
        @{ id = 'python:pyenv-win'; name = 'pyenv'; args = @('--version') }
    )
    $records = @()
    foreach ($definition in $definitions) {
        $records += Get-MHRuntimeManagerRecord -Context $Context -Id $definition.id -Name $definition.name -Arguments @($definition.args)
    }
    return @($records)
}

function Get-MHRuntimePipPackages {
    param(
        [Parameter(Mandatory)]$Context,
        [Parameter(Mandatory)][string]$Command
    )

    $arguments = @('-m', 'pip', 'list', '--format=json', '--user')
    $probe = Invoke-MHRuntimeProbe -Context $Context -Name $Command -Arguments @($arguments)
    $status = Get-MHRuntimeProbeStatus -Probe $probe
    if ($status -ne 'OK') { return [pscustomobject]@{ status = $status; packages = @() } }
    try { $json = (ConvertTo-MHRuntimeOutputText -Probe $probe) | ConvertFrom-Json -ErrorAction Stop } catch { return [pscustomobject]@{ status = 'OUTPUT_INVALID'; packages = @() } }
    $packages = @()
    foreach ($entry in @($json)) {
        $package = Get-MHRuntimePackageRecord -Name ([string](Get-MHRuntimeProperty -Object $entry -Name 'name')) -Version ([string](Get-MHRuntimeProperty -Object $entry -Name 'version')) -Manager 'pip' -Scope 'USER'
        if ($package) { $packages += $package }
    }
    return [pscustomobject]@{ status = 'OK'; packages = @($packages) }
}

function Get-MHRuntimePipxPackages {
    param([Parameter(Mandatory)]$Context)

    $probe = Invoke-MHRuntimeProbe -Context $Context -Name 'pipx' -Arguments @('list', '--json')
    return Get-MHRuntimeJsonPackages -Probe $probe -Manager 'pipx'
}

function Get-MHRuntimeUvPackages {
    param([Parameter(Mandatory)]$Context)

    $probe = Invoke-MHRuntimeProbe -Context $Context -Name 'uv' -Arguments @('tool', 'list')
    $list = Get-MHRuntimeTextPackages -Probe $probe -Manager 'uv'
    if ($list.status -eq 'OK' -and @($list.packages).Count -eq 0 -and (Get-MHRuntimeProbeStatus -Probe $probe) -eq 'OK') {
        $jsonProbe = Invoke-MHRuntimeProbe -Context $Context -Name 'uv' -Arguments @('tool', 'list', '--show-paths')
        $jsonList = Get-MHRuntimeTextPackages -Probe $jsonProbe -Manager 'uv'
        if (@($jsonList.packages).Count -gt 0) { return $jsonList }
    }
    return $list
}

function Get-MHRuntimePyLauncherVersions {
    param([Parameter(Mandatory)]$Context)

    $probe = Invoke-MHRuntimeProbe -Context $Context -Name 'py' -Arguments @('-0p')
    $status = Get-MHRuntimeProbeStatus -Probe $probe
    if ($status -ne 'OK') { return [pscustomobject]@{ status = $status; versions = @(); interpreters = @() } }
    $versions = @()
    $interpreters = @()
    foreach ($line in @((ConvertTo-MHRuntimeOutputText -Probe $probe) -split "`r?`n")) {
        $version = ConvertTo-MHRuntimeVersion -Text $line
        if ($version) { $versions += $version }
        $pathMatch = [regex]::Match($line, '(?<path>[A-Za-z]:\\[^\r\n]+(?:python(?:\.exe)?|pypy(?:\.exe)?))\s*$')
        if ($pathMatch.Success) {
            $safePath = ConvertTo-MHRuntimeSafePath -Path $pathMatch.Groups['path'].Value.Trim()
            if ($safePath) { $interpreters += [pscustomobject]@{ path = $safePath; version = $version; state = 'PRESENT' } }
        }
    }
    return [pscustomobject]@{ status = 'OK'; versions = @($versions | Sort-Object -Unique); interpreters = @($interpreters) }
}

function Get-MHRuntimePyenvVersions {
    param([Parameter(Mandatory)]$Context)

    $probe = Invoke-MHRuntimeProbe -Context $Context -Name 'pyenv' -Arguments @('versions', '--bare')
    $status = Get-MHRuntimeProbeStatus -Probe $probe
    if ($status -ne 'OK') { return [pscustomobject]@{ status = $status; versions = @() } }
    $versions = @()
    foreach ($line in @((ConvertTo-MHRuntimeOutputText -Probe $probe) -split "`r?`n")) {
        $value = $line.Trim().TrimStart('*').Trim()
        if ($value -and $value -notmatch '[\r\n\s]' -and $value -notmatch '(?i)system|global' -and $value -match '^[A-Za-z0-9._-]{1,80}$') { $versions += $value }
    }
    return [pscustomobject]@{ status = 'OK'; versions = @($versions | Sort-Object -Unique) }
}

function Get-MHRuntimeCondaEnvironments {
    param([Parameter(Mandatory)]$Context)

    $probe = Invoke-MHRuntimeProbe -Context $Context -Name 'conda' -Arguments @('env', 'list')
    $status = Get-MHRuntimeProbeStatus -Probe $probe
    if ($status -ne 'OK') { return [pscustomobject]@{ status = $status; environments = @() } }
    $environments = @()
    foreach ($line in @((ConvertTo-MHRuntimeOutputText -Probe $probe) -split "`r?`n")) {
        if ($line -match '^\s*(?<name>[A-Za-z0-9._-]{1,80})(?<default>\s+\*)?\s+(?<path>[A-Za-z]:\\[^\r\n]+)\s*$') {
            $safePath = ConvertTo-MHRuntimeSafePath -Path $Matches.path.Trim()
            $isDefault = $false
            if ($Matches.ContainsKey('default')) { $isDefault = -not [string]::IsNullOrWhiteSpace([string]$Matches.default) }
            if ($safePath) { $environments += [pscustomobject]@{ name = $Matches.name; path = $safePath; default = $isDefault; state = 'PRESENT' } }
        }
    }
    return [pscustomobject]@{ status = 'OK'; environments = @($environments) }
}

function Get-MHRuntimePython {
    param(
        [Parameter(Mandatory)]$Context,
        [ref]$Warnings,
        [ref]$Artifacts
    )

    $python = New-MHRuntimeToolRecord -Context $Context -Id 'runtime:python' -Name 'python' -Arguments @('--version') -DisplayName 'Python'
    $managers = @(Get-MHRuntimePythonManagers -Context $Context)
    if ($python.state -ne 'PRESENT') {
        foreach ($fallbackName in @('python3', 'py')) {
            $fallback = $managers | Where-Object { $_.command -eq $fallbackName -and $_.state -eq 'PRESENT' } | Select-Object -First 1
            if ($null -eq $fallback) { continue }
            foreach ($propertyName in @('command', 'state', 'status', 'version', 'installedVersion', 'defaultVersion', 'path')) {
                $propertyValue = Get-MHRuntimeProperty -Object $fallback -Name $propertyName
                $python | Add-Member -NotePropertyName $propertyName -NotePropertyValue $propertyValue -Force
            }
            break
        }
    }
    $launcher = $managers | Where-Object { $_.id -eq 'python:launcher' } | Select-Object -First 1
    $launcherVersions = [pscustomobject]@{ status = 'NOT_TESTED'; versions = @(); interpreters = @() }
    if ($launcher -and $launcher.state -eq 'PRESENT') { $launcherVersions = Get-MHRuntimePyLauncherVersions -Context $Context }
    $pyenvVersions = [pscustomobject]@{ status = 'NOT_TESTED'; versions = @() }
    $pyenv = $managers | Where-Object { $_.id -eq 'python:pyenv-win' } | Select-Object -First 1
    if ($pyenv -and $pyenv.state -eq 'PRESENT') {
        $pyenvVersions = Get-MHRuntimePyenvVersions -Context $Context
        $pyenvDefaultProbe = Invoke-MHRuntimeProbe -Context $Context -Name 'pyenv' -Arguments @('version-name')
        if ((Get-MHRuntimeProbeStatus -Probe $pyenvDefaultProbe) -eq 'OK') {
            $pyenvDefault = ((ConvertTo-MHRuntimeOutputText -Probe $pyenvDefaultProbe) -split "`r?`n" | Where-Object { $_.Trim() } | Select-Object -First 1)
            if ($pyenvDefault -and $pyenvDefault.Trim() -match '^[A-Za-z0-9._/-]{1,100}$') { $pyenv | Add-Member -NotePropertyName defaultVersion -NotePropertyValue $pyenvDefault.Trim() -Force }
        }
    }
    $condaEnvironments = [pscustomobject]@{ status = 'NOT_TESTED'; environments = @() }
    $conda = $managers | Where-Object { $_.id -eq 'python:conda' } | Select-Object -First 1
    if ($conda -and $conda.state -eq 'PRESENT') { $condaEnvironments = Get-MHRuntimeCondaEnvironments -Context $Context }

    $defaultCommand = $null
    foreach ($candidate in @('python', 'python3', 'py')) {
        $candidateManager = $managers | Where-Object { $_.command -eq $candidate } | Select-Object -First 1
        if ($candidateManager -and $candidateManager.state -eq 'PRESENT') { $defaultCommand = $candidate; break }
    }
    $packages = @()
    if ($defaultCommand) {
        $pipList = Get-MHRuntimePipPackages -Context $Context -Command $defaultCommand
        $packages += @($pipList.packages)
        $pipManager = $managers | Where-Object { $_.command -eq $defaultCommand } | Select-Object -First 1
        if ($pipManager) { $pipManager | Add-Member -NotePropertyName globalPackages -NotePropertyValue @($pipList.packages) -Force }
        if ($pipList.status -ne 'OK') { $Warnings.Value += 'RUNTIME_PYTHON_PIP_' + $pipList.status }
    }
    $pipx = $managers | Where-Object { $_.id -eq 'python:pipx' } | Select-Object -First 1
    if ($pipx -and $pipx.state -eq 'PRESENT') {
        $pipxList = Get-MHRuntimePipxPackages -Context $Context
        foreach ($package in @($pipxList.packages)) { $package.scope = 'USER'; $packages += $package }
        $pipx | Add-Member -NotePropertyName globalPackages -NotePropertyValue @($pipxList.packages) -Force
        if ($pipxList.status -ne 'OK') { $Warnings.Value += 'RUNTIME_PYTHON_PIPX_' + $pipxList.status }
    }
    $uv = $managers | Where-Object { $_.id -eq 'python:uv' } | Select-Object -First 1
    if ($uv -and $uv.state -eq 'PRESENT') {
        $uvList = Get-MHRuntimeUvPackages -Context $Context
        foreach ($package in @($uvList.packages)) { $package.scope = 'USER'; $packages += $package }
        $uv | Add-Member -NotePropertyName globalPackages -NotePropertyValue @($uvList.packages) -Force
        if ($uvList.status -ne 'OK') { $Warnings.Value += 'RUNTIME_PYTHON_UV_' + $uvList.status }
    }
    $installed = @($python.version, $launcherVersions.versions, $pyenvVersions.versions | Where-Object { $_ } | Sort-Object -Unique)
    $python | Add-Member -NotePropertyName installedVersions -NotePropertyValue $installed -Force
    $python | Add-Member -NotePropertyName launcher -NotePropertyValue ([pscustomobject]@{ status = $launcherVersions.status; interpreters = @($launcherVersions.interpreters) }) -Force
    $python | Add-Member -NotePropertyName managers -NotePropertyValue @($managers) -Force
    $python | Add-Member -NotePropertyName globalPackages -NotePropertyValue @($packages | Group-Object id | ForEach-Object { $_.Group[0] }) -Force
    $python | Add-Member -NotePropertyName globalTools -NotePropertyValue @($packages | Where-Object { $_.manager -in @('pipx', 'uv') } | Group-Object id | ForEach-Object { $_.Group[0] }) -Force
    foreach ($manager in $managers) {
        if ($null -eq (Get-MHRuntimeProperty -Object $manager -Name 'globalPackages')) { $manager | Add-Member -NotePropertyName globalPackages -NotePropertyValue @() -Force }
    }
    $python | Add-Member -NotePropertyName condaEnvironments -NotePropertyValue @($condaEnvironments.environments) -Force
    $python | Add-Member -NotePropertyName pyenvVersions -NotePropertyValue @($pyenvVersions.versions) -Force
    $python | Add-Member -NotePropertyName pathFacts -NotePropertyValue @(Get-MHRuntimePathFacts -Runtime 'python') -Force
    $python | Add-Member -NotePropertyName registryFacts -NotePropertyValue @(Get-MHRuntimeRegistryFacts -Runtime 'python') -Force
    $python | Add-Member -NotePropertyName packageManagerFacts -NotePropertyValue @() -Force
    $python | Add-Member -NotePropertyName registries -NotePropertyValue @() -Force
    $python | Add-Member -NotePropertyName managerPaths -NotePropertyValue @() -Force
    $python | Add-Member -NotePropertyName configArtifacts -NotePropertyValue @() -Force
    $python | Add-Member -NotePropertyName toolchain -NotePropertyValue 'python' -Force
    return $python
}

function Get-MHRuntimeDotnetEntries {
    param(
        [Parameter(Mandatory)]$Probe,
        [ValidateSet('sdk', 'runtime')][string]$Kind
    )

    $status = Get-MHRuntimeProbeStatus -Probe $Probe
    if ($status -ne 'OK') { return [pscustomobject]@{ status = $status; entries = @() } }
    $entries = @()
    foreach ($line in @((ConvertTo-MHRuntimeOutputText -Probe $Probe) -split "`r?`n")) {
        $pattern = if ($Kind -eq 'runtime') {
            '^\s*(?<name>[A-Za-z0-9_.-]+)\s+(?<version>v?\d+(?:\.\d+){1,3}(?:[-+][A-Za-z0-9._-]+)?)\s+\[(?<path>[^\]]+)\]'
        } else {
            '^\s*(?<version>v?\d+(?:\.\d+){1,3}(?:[-+][A-Za-z0-9._-]+)?)\s+\[(?<path>[^\]]+)\]'
        }
        $match = [regex]::Match($line, $pattern)
        if (-not $match.Success) { continue }
        $safePath = ConvertTo-MHRuntimeSafePath -Path $match.Groups['path'].Value.Trim()
        if (-not $safePath) { continue }
        $entries += [pscustomobject]@{ kind = $Kind; name = $match.Groups['name'].Value; version = $match.Groups['version'].Value; path = $safePath; state = 'PRESENT' }
    }
    return [pscustomobject]@{ status = 'OK'; entries = @($entries) }
}

function Get-MHRuntimeDotnetWorkloads {
    param([Parameter(Mandatory)]$Probe)

    $status = Get-MHRuntimeProbeStatus -Probe $Probe
    if ($status -ne 'OK') { return [pscustomobject]@{ status = $status; items = @() } }
    $items = @()
    foreach ($line in @((ConvertTo-MHRuntimeOutputText -Probe $Probe) -split "`r?`n")) {
        $match = [regex]::Match($line, '^\s*(?<name>[A-Za-z0-9_.-]+)\s+(?<version>\d+(?:\.\d+){1,3}(?:[-+][A-Za-z0-9._-]+)?(?:/\d+(?:\.\d+){1,3})?)(?:\s+.*)?$')
        if ($match.Success) { $items += [pscustomobject]@{ id = 'dotnet-workload:' + $match.Groups['name'].Value; name = $match.Groups['name'].Value; version = $match.Groups['version'].Value; state = 'PRESENT' } }
    }
    return [pscustomobject]@{ status = 'OK'; items = @($items | Group-Object id | ForEach-Object { $_.Group[0] }) }
}

function Get-MHRuntimeDotnetTools {
    param([Parameter(Mandatory)]$Probe)

    $status = Get-MHRuntimeProbeStatus -Probe $Probe
    if ($status -ne 'OK') { return [pscustomobject]@{ status = $status; packages = @() } }
    $packages = @()
    foreach ($line in @((ConvertTo-MHRuntimeOutputText -Probe $Probe) -split "`r?`n")) {
        $match = [regex]::Match($line, '^\s*(?<name>[A-Za-z0-9_.-]+)\s+(?<version>\d+(?:\.\d+){1,3}(?:[-+][A-Za-z0-9._-]+)?)(?:\s+.*)?$')
        if ($match.Success) {
            $package = Get-MHRuntimePackageRecord -Name $match.Groups['name'].Value -Version $match.Groups['version'].Value -Manager 'dotnet' -Scope 'USER'
            if ($package) { $packages += $package }
        }
    }
    return [pscustomobject]@{ status = 'OK'; packages = @($packages | Group-Object id | ForEach-Object { $_.Group[0] }) }
}

function Get-MHRuntimeDotnet {
    param(
        [Parameter(Mandatory)]$Context,
        [ref]$Warnings,
        [ref]$Artifacts
    )

    $dotnet = New-MHRuntimeToolRecord -Context $Context -Id 'runtime:dotnet' -Name 'dotnet' -Arguments @('--version') -DisplayName '.NET'
    $sdksProbe = Invoke-MHRuntimeProbe -Context $Context -Name 'dotnet' -Arguments @('--list-sdks')
    $runtimesProbe = Invoke-MHRuntimeProbe -Context $Context -Name 'dotnet' -Arguments @('--list-runtimes')
    $workloadProbe = Invoke-MHRuntimeProbe -Context $Context -Name 'dotnet' -Arguments @('workload', 'list')
    $toolsProbe = Invoke-MHRuntimeProbe -Context $Context -Name 'dotnet' -Arguments @('tool', 'list', '--global')
    $sdks = Get-MHRuntimeDotnetEntries -Probe $sdksProbe -Kind 'sdk'
    $runtimes = Get-MHRuntimeDotnetEntries -Probe $runtimesProbe -Kind 'runtime'
    $workloads = Get-MHRuntimeDotnetWorkloads -Probe $workloadProbe
    $tools = Get-MHRuntimeDotnetTools -Probe $toolsProbe
    foreach ($entry in @(
        [pscustomobject]@{ name = 'sdks'; status = $sdks.status },
        [pscustomobject]@{ name = 'runtimes'; status = $runtimes.status },
        [pscustomobject]@{ name = 'workloads'; status = $workloads.status },
        [pscustomobject]@{ name = 'tools'; status = $tools.status }
    )) {
        if ($entry.status -notin @('OK', 'NOT_FOUND') -and $entry.status) { $Warnings.Value += 'RUNTIME_DOTNET_' + $entry.name.ToUpperInvariant() + '_' + $entry.status }
    }
    $sdkVersions = @($sdks.entries | ForEach-Object { Get-MHRuntimeProperty -Object $_ -Name 'version' } | Where-Object { $_ } | Sort-Object -Unique)
    $dotnet | Add-Member -NotePropertyName installedVersions -NotePropertyValue $sdkVersions -Force
    $dotnet | Add-Member -NotePropertyName sdks -NotePropertyValue @($sdks.entries) -Force
    $dotnet | Add-Member -NotePropertyName runtimes -NotePropertyValue @($runtimes.entries) -Force
    $dotnet | Add-Member -NotePropertyName workloads -NotePropertyValue @($workloads.items) -Force
    $dotnet | Add-Member -NotePropertyName managers -NotePropertyValue @([pscustomobject]@{ id = 'dotnet:cli'; name = 'dotnet'; command = 'dotnet'; state = (Get-MHRuntimeProperty -Object $dotnet -Name 'state'); status = (Get-MHRuntimeProperty -Object $dotnet -Name 'status'); version = (Get-MHRuntimeProperty -Object $dotnet -Name 'version'); path = (Get-MHRuntimeProperty -Object $dotnet -Name 'path'); globalPackages = @($tools.packages) }) -Force
    $dotnet | Add-Member -NotePropertyName globalPackages -NotePropertyValue @($tools.packages) -Force
    $dotnet | Add-Member -NotePropertyName globalTools -NotePropertyValue @($tools.packages) -Force
    $dotnet | Add-Member -NotePropertyName pathFacts -NotePropertyValue @(Get-MHRuntimePathFacts -Runtime 'dotnet') -Force
    $dotnet | Add-Member -NotePropertyName registryFacts -NotePropertyValue @(Get-MHRuntimeRegistryFacts -Runtime 'dotnet') -Force
    $dotnet | Add-Member -NotePropertyName packageManagerFacts -NotePropertyValue @() -Force
    $dotnet | Add-Member -NotePropertyName registries -NotePropertyValue @() -Force
    $dotnet | Add-Member -NotePropertyName managerPaths -NotePropertyValue @() -Force
    $dotnet | Add-Member -NotePropertyName configArtifacts -NotePropertyValue @() -Force
    $dotnet | Add-Member -NotePropertyName toolchain -NotePropertyValue 'dotnet' -Force
    return $dotnet
}

function Get-MHRuntimePathFacts {
    param([ValidateSet('node', 'python', 'dotnet')][string]$Runtime)

    $groups = @{
        node = @('NVM_HOME', 'NVM_SYMLINK', 'FNM_DIR', 'VOLTA_HOME', 'NVS_HOME', 'COREPACK_HOME', 'PNPM_HOME', 'YARN_GLOBAL_FOLDER', 'BUN_INSTALL', 'NPM_CONFIG_USERCONFIG')
        python = @('PYTHONHOME', 'PYTHONPATH', 'VIRTUAL_ENV', 'PIP_CONFIG_FILE', 'PIPX_HOME', 'UV_TOOL_DIR', 'POETRY_HOME', 'CONDA_PREFIX', 'CONDA_EXE', 'CONDA_ROOT', 'PYENV', 'PYENV_ROOT')
        dotnet = @('DOTNET_ROOT', 'DOTNET_ROOT_X64', 'NUGET_PACKAGES', 'NUGET_HTTP_CACHE_PATH', 'MSBuildSDKsPath')
    }
    $facts = @()
    foreach ($name in $groups[$Runtime]) {
        $raw = [Environment]::GetEnvironmentVariable($name, [EnvironmentVariableTarget]::Process)
        if ([string]::IsNullOrWhiteSpace($raw)) {
            $facts += [pscustomobject]@{ name = $name; state = 'ABSENT'; value = $null; source = 'PROCESS_ENVIRONMENT' }
            continue
        }
        $values = @()
        foreach ($part in ([string]$raw -split ';')) {
            $safe = ConvertTo-MHRuntimeSafePath -Path $part
            if ($safe) { $values += $safe }
        }
        if ($values.Count -gt 0) { $facts += [pscustomobject]@{ name = $name; state = 'PRESENT'; value = @($values | Sort-Object -Unique); source = 'PROCESS_ENVIRONMENT' } }
        else { $facts += [pscustomobject]@{ name = $name; state = 'UNKNOWN'; value = $null; source = 'PROCESS_ENVIRONMENT' } }
    }
    return @($facts)
}

function Get-MHRuntimeRegistryFacts {
    param([ValidateSet('node', 'python', 'dotnet')][string]$Runtime)

    $specs = @{
        node = @(
            @{ id = 'node-user'; path = 'HKCU:\Software\Node.js'; values = @('InstallPath', 'Version') },
            @{ id = 'node-machine'; path = 'HKLM:\SOFTWARE\Node.js'; values = @('InstallPath', 'Version') },
            @{ id = 'node-machine-32'; path = 'HKLM:\SOFTWARE\WOW6432Node\Node.js'; values = @('InstallPath', 'Version') }
        )
        python = @(
            @{ id = 'python-user'; path = 'HKCU:\Software\Python'; values = @() },
            @{ id = 'python-machine'; path = 'HKLM:\SOFTWARE\Python'; values = @() },
            @{ id = 'python-machine-32'; path = 'HKLM:\SOFTWARE\WOW6432Node\Python'; values = @() }
        )
        dotnet = @(
            @{ id = 'dotnet-machine'; path = 'HKLM:\SOFTWARE\dotnet\Setup\InstalledVersions\x64'; values = @() },
            @{ id = 'dotnet-machine-32'; path = 'HKLM:\SOFTWARE\dotnet\Setup\InstalledVersions\x86'; values = @() }
        )
    }
    $facts = @()
    foreach ($spec in $specs[$Runtime]) {
        try {
            $key = Get-Item -LiteralPath $spec.path -ErrorAction Stop
            $safeValues = [ordered]@{}
            foreach ($name in @($spec.values)) {
                try {
                    $value = (Get-ItemProperty -LiteralPath $spec.path -Name $name -ErrorAction Stop).$name
                    $text = [string]$value
                    if ($name -match '(?i)path') { $text = ConvertTo-MHRuntimeSafePath -Path $text }
                    elseif ($text -notmatch $script:MHRuntimeVersionPattern) { $text = $null }
                    if ($text) { $safeValues[$name] = $text }
                } catch { }
            }
            $facts += [pscustomobject]@{ id = $spec.id; path = $spec.path; state = 'PRESENT'; values = [pscustomobject]$safeValues }
        } catch {
            $facts += [pscustomobject]@{ id = $spec.id; path = $spec.path; state = 'ABSENT'; values = [pscustomobject]@{} }
        }
    }
    return @($facts)
}

function Get-MHRuntimeConfigCandidates {
    param([Parameter(Mandatory)]$Context)

    $userHome = [Environment]::GetEnvironmentVariable('USERPROFILE', [EnvironmentVariableTarget]::Process)
    $appDataRoot = [Environment]::GetEnvironmentVariable('APPDATA', [EnvironmentVariableTarget]::Process)
    $candidates = @()
    if ($userHome) {
        $candidates += @{ id = 'node:npmrc'; domain = 'node'; path = (Join-Path $userHome '.npmrc'); target = '%USERPROFILE%\.npmrc'; format = 'INI'; contentPolicy = 'REDACTED_COPY'; sensitivity = 'PRIVATE' }
        $candidates += @{ id = 'node:yarnrc'; domain = 'node'; path = (Join-Path $userHome '.yarnrc'); target = '%USERPROFILE%\.yarnrc'; format = 'TEXT' }
        $candidates += @{ id = 'node:yarnrc-yml'; domain = 'node'; path = (Join-Path $userHome '.yarnrc.yml'); target = '%USERPROFILE%\.yarnrc.yml'; format = 'TEXT' }
        $candidates += @{ id = 'python:pip-user'; domain = 'python'; path = (Join-Path $userHome 'pip\pip.ini'); target = '%USERPROFILE%\pip\pip.ini'; format = 'INI'; contentPolicy = 'REDACTED_COPY'; sensitivity = 'PRIVATE' }
        $candidates += @{ id = 'python:pip-config'; domain = 'python'; path = (Join-Path $userHome '.config\pip\pip.conf'); target = '%USERPROFILE%\.config\pip\pip.conf'; format = 'INI'; contentPolicy = 'REDACTED_COPY'; sensitivity = 'PRIVATE' }
        $candidates += @{ id = 'python:poetry'; domain = 'python'; path = (Join-Path $userHome 'AppData\Roaming\pypoetry\config.toml'); target = '%USERPROFILE%\AppData\Roaming\pypoetry\config.toml'; format = 'TEXT' }
        $candidates += @{ id = 'python:condarc'; domain = 'python'; path = (Join-Path $userHome '.condarc'); target = '%USERPROFILE%\.condarc'; format = 'TEXT' }
        $candidates += @{ id = 'dotnet:nuget'; domain = 'dotnet'; path = (Join-Path $userHome '.nuget\NuGet\NuGet.Config'); target = '%USERPROFILE%\.nuget\NuGet\NuGet.Config'; format = 'TEXT' }
        $candidates += @{ id = 'dotnet:global-json'; domain = 'dotnet'; path = (Join-Path $userHome 'global.json'); target = '%USERPROFILE%\global.json'; format = 'JSON'; contentPolicy = 'SAFE_COPY'; sensitivity = 'PUBLIC' }
    }
    if ($appDataRoot) {
        $candidates += @{ id = 'python:pip-appdata'; domain = 'python'; path = (Join-Path $appDataRoot 'pip\pip.ini'); target = '%APPDATA%\pip\pip.ini'; format = 'INI'; contentPolicy = 'REDACTED_COPY'; sensitivity = 'PRIVATE' }
        $candidates += @{ id = 'dotnet:nuget-appdata'; domain = 'dotnet'; path = (Join-Path $appDataRoot 'NuGet\NuGet.Config'); target = '%APPDATA%\NuGet\NuGet.Config'; format = 'TEXT' }
    }
    $roots = Get-MHRuntimeProperty -Object $Context -Name 'roots' -Default @()
    foreach ($root in @($roots)) {
        $safeRoot = ConvertTo-MHRuntimeSafePath -Path ([string]$root)
        if (-not $safeRoot) { continue }
        $candidate = Join-Path $safeRoot 'global.json'
        $candidates += @{ id = 'dotnet:global-json:' + $safeRoot.ToLowerInvariant(); domain = 'dotnet'; path = $candidate; target = '%SELECTED_ROOT%\global.json'; format = 'JSON'; contentPolicy = 'SAFE_COPY'; sensitivity = 'PUBLIC' }
    }
    $explicit = Get-MHRuntimeProperty -Object $Context -Name 'runtimeConfigPaths' -Default @()
    foreach ($path in @($explicit)) {
        $safePath = ConvertTo-MHRuntimeSafePath -Path ([string]$path)
        if ($safePath) {
            $extension = [IO.Path]::GetExtension($safePath).ToLowerInvariant()
            $format = switch ($extension) {
                '.json' { 'JSON'; break }
                '.jsonc' { 'JSONC'; break }
                '.ini' { 'INI'; break }
                '.toml' { 'TEXT'; break }
                '.yaml' { 'TEXT'; break }
                '.yml' { 'TEXT'; break }
                '.xml' { 'TEXT'; break }
                default { 'UNKNOWN' }
            }
            $candidates += @{ id = 'runtime:config:' + $safePath.ToLowerInvariant(); domain = 'runtime'; path = $safePath; target = '%SELECTED%\' + [IO.Path]::GetFileName($safePath); format = $format }
        }
    }
    return @($candidates | Group-Object { [string]$_.path } | ForEach-Object { $_.Group[0] })
}

function Get-MHRuntimeConfigArtifacts {
    param(
        [Parameter(Mandatory)]$Context,
        [ref]$Warnings
    )

    $helper = Get-Command -Name New-MHConfigArtifact -CommandType Function -ErrorAction SilentlyContinue
    if ($null -eq $helper) { return @() }
    $artifacts = @()
    foreach ($candidate in @(Get-MHRuntimeConfigCandidates -Context $Context)) {
        if (-not (Test-Path -LiteralPath $candidate.path -PathType Leaf)) { continue }
        $safePath = ConvertTo-MHRuntimeSafePath -Path ([string]$candidate.path)
        if (-not $safePath) { $Warnings.Value += 'RUNTIME_CONFIG_PATH_BLOCKED'; continue }
        try {
            $artifactPath = 'configs/runtimes/' + ([string]$candidate.id).Replace(':', '_').Replace('\\', '_').Replace('/', '_')
            $contentPolicy = [string](Get-MHRuntimeProperty -Object $candidate -Name 'contentPolicy' -Default 'METADATA_ONLY')
            $sensitivity = [string](Get-MHRuntimeProperty -Object $candidate -Name 'sensitivity' -Default 'PRIVATE')
            $artifact = New-MHConfigArtifact -Context $Context -Id ([string]$candidate.id) -Domain ([string]$candidate.domain) -SourcePath $safePath -TargetPathCandidate ([string]$candidate.target) -ContentPolicy $contentPolicy -Sensitivity $sensitivity -Format ([string]$candidate.format) -ArtifactPath $artifactPath -RestorePolicy 'REVIEW' -ValidationStrategy 'NORMALIZED_CONFIG'
            if ($null -ne $artifact) { $artifacts += $artifact }
        } catch { $Warnings.Value += 'RUNTIME_CONFIG_ARTIFACT_FAILED' }
    }
    return @($artifacts)
}

function Get-MHRuntimeCollection {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Context)

    $warnings = @()
    try {
        $deadline = Get-MHRuntimeProperty -Object $Context -Name 'deadline'
        if ($deadline -and (Get-Command -Name Get-MHRemainingBudgetMilliseconds -CommandType Function -ErrorAction SilentlyContinue)) {
            if ((Get-MHRemainingBudgetMilliseconds -Context $Context) -le 0) {
                return New-MHDomainResult -Domain 'runtimes' -Status 'UNAVAILABLE' -Items @() -Warnings @('COLLECTION_BUDGET_EXHAUSTED') -ErrorCode 'COLLECTION_BUDGET_EXHAUSTED' -Provenance 'READ_ONLY_LOCAL_QUERY' -ConfigArtifacts @()
            }
        }
        $artifacts = @(Get-MHRuntimeConfigArtifacts -Context $Context -Warnings ([ref]$warnings))
        $node = Get-MHRuntimeNode -Context $Context -Warnings ([ref]$warnings) -Artifacts ([ref]$artifacts)
        $python = Get-MHRuntimePython -Context $Context -Warnings ([ref]$warnings) -Artifacts ([ref]$artifacts)
        $dotnet = Get-MHRuntimeDotnet -Context $Context -Warnings ([ref]$warnings) -Artifacts ([ref]$artifacts)
        $items = @($node, $python, $dotnet)
        $unknownItem = @($items | Where-Object { $_.state -eq 'UNKNOWN' }).Count -gt 0
        $unknownManager = @($items | ForEach-Object { @($_.managers) } | Where-Object { $_.state -eq 'UNKNOWN' }).Count -gt 0
        $status = if (@($warnings).Count -gt 0 -or $unknownItem -or $unknownManager) { 'PARTIAL' } else { 'OK' }
        foreach ($item in $items) {
            $itemArtifacts = @($artifacts | Where-Object {
                $artifactObject = Get-MHRuntimeProperty -Object $_ -Name 'artifact'
                $artifactId = [string](Get-MHRuntimeProperty -Object $artifactObject -Name 'id')
                $artifactId -like ([string]$item.id.Replace('runtime:', '') + ':*')
            })
            $item.configArtifacts = @($itemArtifacts)
        }
        $uniqueWarnings = @($warnings | Where-Object { $_ } | Sort-Object -Unique)
        return New-MHDomainResult -Domain 'runtimes' -Status $status -Items $items -Warnings $uniqueWarnings -Provenance 'READ_ONLY_LOCAL_QUERY' -ConfigArtifacts @($artifacts)
    } catch {
        return New-MHDomainResult -Domain 'runtimes' -Status 'ERROR' -Items @() -Warnings @('RUNTIME_COLLECTION_FAILED') -ErrorCode 'RUNTIME_COLLECTION_FAILED'
    }
}
