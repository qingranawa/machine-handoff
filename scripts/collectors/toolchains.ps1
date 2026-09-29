Set-StrictMode -Version Latest

$script:MHToolchainVersionPattern = '(?i)(?<![A-Za-z0-9])v?\d+(?:\.\d+){1,3}(?:[-+][A-Za-z0-9._-]+)?'

function Get-MHToolchainField {
    param($Object, [string]$Name, $Default = $null)
    if ($null -eq $Object) { return $Default }
    if ($Object -is [System.Collections.IDictionary]) {
        foreach ($key in $Object.Keys) { if ([string]$key -ieq $Name) { return $Object[$key] } }
        return $Default
    }
    $property = $Object.PSObject.Properties[$Name]
    if ($property) { return $property.Value }
    return $Default
}

function Test-MHToolchainSafeLocalPath {
    param([AllowNull()][string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path) -or $Path.StartsWith('\\', [StringComparison]::Ordinal)) { return $false }
    try { [void](Assert-MHNoReparseAncestors -Path $Path); return $true }
    catch { return $false }
}

function New-MHToolchainContext {
    param($Context)
    $domainContext = New-MHDomainContext -Context $Context
    foreach ($name in @('toolchainFixtures', 'runtimeFixtures', 'toolchainRoots', 'toolchainCommands', 'toolchainConfigPaths', 'toolchainEnvironment')) {
        $value = Get-MHToolchainField -Object $Context -Name $name
        if ($null -ne $value) { $domainContext | Add-Member -NotePropertyName $name -NotePropertyValue $value -Force }
    }
    return $domainContext
}

function Get-MHToolchainFixture {
    param($Context, [string]$Name, [string[]]$Arguments)
    $fixtures = Get-MHToolchainField -Object $Context -Name 'toolchainFixtures'
    if ($null -eq $fixtures) { $fixtures = Get-MHToolchainField -Object $Context -Name 'runtimeFixtures' }
    if ($null -eq $fixtures) { return $null }
    $baseName = [IO.Path]::GetFileName($Name)
    $keys = @(($Name + '|' + ($Arguments -join ' ')), ($baseName + '|' + ($Arguments -join ' ')), $Name, $baseName)
    foreach ($key in $keys) {
        if ($fixtures -is [System.Collections.IDictionary]) {
            foreach ($actualKey in $fixtures.Keys) { if ([string]$actualKey -ieq $key) { return $fixtures[$actualKey] } }
        } else {
            $property = $fixtures.PSObject.Properties[$key]
            if ($property) { return $property.Value }
        }
    }
    return $null
}

function Invoke-MHToolchainProbe {
    param($Context, [string]$Name, [string[]]$Arguments = @(), [int]$TimeoutMilliseconds = 3000)
    if ((Get-MHRemainingBudgetMilliseconds -Context $Context) -le 0) {
        return [pscustomobject]@{ found = $true; started = $false; exitCode = $null; timedOut = $true; stdout = ''; stderr = ''; errorCode = 'TIMEOUT' }
    }
    $fixture = Get-MHToolchainFixture -Context $Context -Name $Name -Arguments $Arguments
    if ($null -ne $fixture) {
        if ($fixture -is [string]) { return [pscustomobject]@{ found = $true; exitCode = 0; timedOut = $false; stdout = $fixture; stderr = ''; errorCode = $null } }
        return $fixture
    }
    return Invoke-MHSafeProcess -Context $Context -Name $Name -Arguments @($Arguments) -TimeoutMilliseconds $TimeoutMilliseconds -MaxOutputBytes ([int]$Context.budgets.maxProcessOutputBytes)
}

function Get-MHToolchainProbeText {
    param($Probe)
    return (@([string](Get-MHToolchainField -Object $Probe -Name 'stdout' -Default ''), [string](Get-MHToolchainField -Object $Probe -Name 'stderr' -Default '')) -join "`n")
}

function Get-MHToolchainProbeStatus {
    param($Probe)
    if (-not [bool](Get-MHToolchainField -Object $Probe -Name 'found' -Default $true)) { return 'NOT_FOUND' }
    if ([bool](Get-MHToolchainField -Object $Probe -Name 'timedOut' -Default $false)) { return 'TIMEOUT' }
    $errorCode = [string](Get-MHToolchainField -Object $Probe -Name 'errorCode')
    if ($errorCode) { return $errorCode }
    $exitCode = Get-MHToolchainField -Object $Probe -Name 'exitCode'
    if ($null -ne $exitCode -and [int]$exitCode -ne 0) { return 'COMMAND_FAILED' }
    return 'OK'
}

function Get-MHToolchainDirectDirectories {
    param([string]$Path, [int]$Limit = 512)
    $items = @()
    $truncated = $false
    if (-not (Test-MHToolchainSafeLocalPath -Path $Path)) { return [pscustomobject]@{ paths = @(); truncated = $true } }
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) { return [pscustomobject]@{ paths = @(); truncated = $false } }
    try {
        foreach ($directory in [IO.Directory]::EnumerateDirectories($Path)) {
            if ($items.Count -ge $Limit) { $truncated = $true; break }
            if (-not (Test-MHToolchainSafeLocalPath -Path $directory)) { $truncated = $true; continue }
            $items += $directory
        }
    } catch { return [pscustomobject]@{ paths = @($items); truncated = $true } }
    return [pscustomobject]@{ paths = @($items); truncated = $truncated }
}

function Get-MHToolchainTool {
    param($Context, [string]$Id, [string]$Command, [string[]]$Arguments, [string]$DisplayName = $Command)
    $fixture = Get-MHToolchainFixture -Context $Context -Name $Command -Arguments $Arguments
    $probe = Invoke-MHToolchainProbe -Context $Context -Name $Command -Arguments $Arguments
    $status = Get-MHToolchainProbeStatus -Probe $probe
    $version = $null
    if ($status -eq 'OK') { $match = [regex]::Match((Get-MHToolchainProbeText -Probe $probe), $script:MHToolchainVersionPattern); if ($match.Success) { $version = $match.Value } elseif ($DisplayName -ne 'rustup') { $status = 'VERSION_UNAVAILABLE' } }
    $path = [string](Get-MHToolchainField -Object $probe -Name 'path')
    if (-not $path -and $null -eq $fixture) { $commandInfo = Get-Command -Name $Command -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1; if ($commandInfo) { $path = [string]$commandInfo.Source } }
    if ($path) { $path = ConvertTo-MHSafePath -Path $path }
    $state = if ($status -eq 'NOT_FOUND') { 'ABSENT' } elseif ($status -eq 'OK' -or ($status -eq 'VERSION_UNAVAILABLE' -and $path)) { 'PRESENT' } else { 'UNKNOWN' }
    return [pscustomobject]@{ id = $Id; name = $DisplayName; command = $Command; state = $state; status = $status; version = $version; path = $path }
}

function Get-MHToolchainEnvironmentPath {
    param([string]$Name, [string]$Override, $Context)
    $configured = Get-MHToolchainField -Object $Context -Name 'toolchainEnvironment'
    if ($null -ne $configured) { $value = Get-MHToolchainField -Object $configured -Name $Name }
    elseif ($Override) { $value = $Override }
    else { $value = [Environment]::GetEnvironmentVariable($Name) }
    if ([string]::IsNullOrWhiteSpace($value) -or (Test-MHSecretText -Text $value)) { return [pscustomobject]@{ name = $Name; state = 'ABSENT'; path = $null } }
    $path = ConvertTo-MHSafePath -Path $value
    if (-not $path) { return [pscustomobject]@{ name = $Name; state = 'UNKNOWN'; path = $null } }
    return [pscustomobject]@{ name = $Name; state = 'PRESENT'; path = $path }
}

function Get-MHToolchainConfiguredEnvironment {
    param($Context, [string]$Name)
    $overrides = Get-MHToolchainField -Object $Context -Name 'toolchainEnvironment'
    if ($null -ne $overrides) { return Get-MHToolchainField -Object $overrides -Name $Name }
    return [Environment]::GetEnvironmentVariable($Name)
}

function Get-MHToolchainConfigArtifacts {
    param($Context)
    $userHome = [Environment]::GetFolderPath([Environment+SpecialFolder]::UserProfile)
    $appData = [Environment]::GetFolderPath([Environment+SpecialFolder]::ApplicationData)
    $cargoHome = Get-MHToolchainConfiguredEnvironment -Context $Context -Name 'CARGO_HOME'
    if (-not $cargoHome) { $cargoHome = Join-Path $userHome '.cargo' }
    $rustupHome = Get-MHToolchainConfiguredEnvironment -Context $Context -Name 'RUSTUP_HOME'
    if (-not $rustupHome) { $rustupHome = Join-Path $userHome '.rustup' }
    $descriptors = @(
        @{ id = 'cargo-config'; path = (Join-Path $cargoHome 'config.toml'); sensitivity = 'PRIVATE'; policy = 'METADATA_ONLY'; format = 'UNKNOWN' },
        @{ id = 'cargo-config-legacy'; path = (Join-Path $cargoHome 'config'); sensitivity = 'PRIVATE'; policy = 'METADATA_ONLY'; format = 'UNKNOWN' },
        @{ id = 'cargo-credentials'; path = (Join-Path $cargoHome 'credentials.toml'); sensitivity = 'SENSITIVE'; policy = 'NEVER_COLLECT'; format = 'UNKNOWN' },
        @{ id = 'cargo-credentials-legacy'; path = (Join-Path $cargoHome 'credentials'); sensitivity = 'SENSITIVE'; policy = 'NEVER_COLLECT'; format = 'UNKNOWN' },
        @{ id = 'rustup-settings'; path = (Join-Path $rustupHome 'settings.toml'); sensitivity = 'PRIVATE'; policy = 'METADATA_ONLY'; format = 'UNKNOWN' },
        @{ id = 'maven-settings'; path = (Join-Path $userHome '.m2\settings.xml'); sensitivity = 'SENSITIVE'; policy = 'NEVER_COLLECT'; format = 'UNKNOWN' },
        @{ id = 'maven-settings-security'; path = (Join-Path $userHome '.m2\settings-security.xml'); sensitivity = 'SENSITIVE'; policy = 'NEVER_COLLECT'; format = 'UNKNOWN' },
        @{ id = 'gradle-properties'; path = (Join-Path $userHome '.gradle\gradle.properties'); sensitivity = 'SENSITIVE'; policy = 'NEVER_COLLECT'; format = 'UNKNOWN' },
        @{ id = 'gradle-init'; path = (Join-Path $userHome '.gradle\init.gradle'); sensitivity = 'SENSITIVE'; policy = 'NEVER_COLLECT'; format = 'UNKNOWN' },
        @{ id = 'gradle-init-kts'; path = (Join-Path $userHome '.gradle\init.gradle.kts'); sensitivity = 'SENSITIVE'; policy = 'NEVER_COLLECT'; format = 'UNKNOWN' },
        @{ id = 'nuget-config'; path = (Join-Path $appData 'NuGet\NuGet.Config'); sensitivity = 'SENSITIVE'; policy = 'NEVER_COLLECT'; format = 'UNKNOWN' }
    )
    $projectIndex = 0
    foreach ($root in @($Context.roots | Select-Object -First ([int]$Context.budgets.maxRoots))) {
        if ($root -and -not (Test-MHSecretText -Text ([string]$root))) {
            $projectIndex++
            $descriptors += @{ id = ('cargo-project-config-' + $projectIndex); path = (Join-Path $root '.cargo\config.toml'); sensitivity = 'PRIVATE'; policy = 'METADATA_ONLY'; format = 'UNKNOWN' }
            $descriptors += @{ id = ('cargo-project-config-legacy-' + $projectIndex); path = (Join-Path $root '.cargo\config'); sensitivity = 'PRIVATE'; policy = 'METADATA_ONLY'; format = 'UNKNOWN' }
        }
    }
    $pathOverrides = Get-MHToolchainField -Object $Context -Name 'toolchainConfigPaths'
    $artifacts = @()
    foreach ($descriptor in $descriptors) {
        $sourcePath = Get-MHToolchainField -Object $pathOverrides -Name $descriptor.id -Default $descriptor.path
        $safePath = ConvertTo-MHSafePath -Path ([string]$sourcePath)
        if (-not $safePath -or -not (Test-MHToolchainSafeLocalPath -Path $safePath)) { continue }
        $result = New-MHConfigArtifact -Context $Context -Id ('toolchain:' + $descriptor.id) -Domain 'toolchains' -SourcePath $safePath -TargetPathCandidate $null -ContentPolicy $descriptor.policy -Sensitivity $descriptor.sensitivity -Format $descriptor.format -ArtifactPath ('configs/toolchains/' + $descriptor.id + '.txt') -RestorePolicy 'REVIEW' -ValidationStrategy 'METADATA_ONLY'
        $artifacts += $result.artifact
    }
    return @($artifacts)
}

function Get-MHToolchainRustItem {
    param($Context)
    $tools = @(
        (Get-MHToolchainTool -Context $Context -Id 'rustc' -Command 'rustc' -Arguments @('--version')),
        (Get-MHToolchainTool -Context $Context -Id 'cargo' -Command 'cargo' -Arguments @('--version'))
    )
    $rustup = Get-MHToolchainTool -Context $Context -Id 'rustup' -Command 'rustup' -Arguments @('--version') -DisplayName 'rustup'
    $toolchains = @(); $targets = @(); $components = @(); $defaultToolchain = $null
    $warnings = @()
    $maxListItems = [Math]::Max(1, [Math]::Min(512, [int]$Context.budgets.maxDiscoveredItems))
    if ($rustup.state -eq 'PRESENT') {
        $probe = Invoke-MHToolchainProbe -Context $Context -Name 'rustup' -Arguments @('toolchain', 'list', '-v')
        if ((Get-MHToolchainProbeStatus $probe) -eq 'OK') {
            foreach ($line in @((Get-MHToolchainProbeText $probe) -split "`r?`n")) {
                $match = [regex]::Match($line, '^(?<name>[A-Za-z0-9_.+-]{1,100})(?<default>\s+\(default\))?')
                if ($match.Success) { $toolchains += $match.Groups['name'].Value; if ($match.Groups['default'].Success) { $defaultToolchain = $match.Groups['name'].Value } }
                if ($toolchains.Count -ge $maxListItems) { $warnings += 'RUSTUP_TOOLCHAIN_LIMIT_REACHED'; break }
            }
        } else { $warnings += 'RUSTUP_TOOLCHAINS_' + (Get-MHToolchainProbeStatus $probe) }
        foreach ($query in @(@{ name = 'target'; args = @('target', 'list', '--installed') }, @{ name = 'component'; args = @('component', 'list', '--installed') })) {
            $probe = Invoke-MHToolchainProbe -Context $Context -Name 'rustup' -Arguments $query.args
            if ((Get-MHToolchainProbeStatus $probe) -eq 'OK') {
                $values = @((Get-MHToolchainProbeText $probe) -split "`r?`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ -match '^[A-Za-z0-9_.+-]{1,120}$' } | Sort-Object -Unique | Select-Object -First $maxListItems)
                if ($query.name -eq 'target') { $targets = $values } else { $components = $values }
            } else { $warnings += ('RUSTUP_' + $query.name.ToUpperInvariant() + '_' + (Get-MHToolchainProbeStatus $probe)) }
        }
    }
    $installed = @()
    if ($tools[1].state -eq 'PRESENT') {
        $probe = Invoke-MHToolchainProbe -Context $Context -Name 'cargo' -Arguments @('install', '--list')
        if ((Get-MHToolchainProbeStatus $probe) -eq 'OK') { $installed = @(([regex]::Matches((Get-MHToolchainProbeText $probe), '(?m)^([A-Za-z0-9_.+-]{1,100}) v\d+(?:\.\d+){0,3}:$') | ForEach-Object { $_.Groups[1].Value }) | Sort-Object -Unique | Select-Object -First $maxListItems) }
        else { $warnings += 'CARGO_INSTALLED_TOOLS_' + (Get-MHToolchainProbeStatus $probe) }
    }
    $homes = @((Get-MHToolchainEnvironmentPath -Name 'CARGO_HOME' -Context $Context), (Get-MHToolchainEnvironmentPath -Name 'RUSTUP_HOME' -Context $Context))
    return [pscustomobject]@{ id = 'rust'; state = $(if ($tools.state -contains 'PRESENT' -or $rustup.state -eq 'PRESENT') { 'PRESENT' } elseif ($tools.state -contains 'UNKNOWN' -or $rustup.state -eq 'UNKNOWN') { 'UNKNOWN' } else { 'ABSENT' }); tools = $tools; rustup = [pscustomobject]@{ state = $rustup.state; status = $rustup.status; toolchains = @($toolchains); defaultToolchain = $defaultToolchain; targets = @($targets); components = @($components) }; cargoInstalledTools = @($installed); homes = $homes; warnings = @($warnings) }
}

function Get-MHToolchainJavaItem {
    param($Context)
    $tools = @(
        (Get-MHToolchainTool $Context 'java' 'java' @('-version')),
        (Get-MHToolchainTool $Context 'javac' 'javac' @('-version')),
        (Get-MHToolchainTool $Context 'maven' 'mvn' @('-version')),
        (Get-MHToolchainTool $Context 'gradle' 'gradle' @('--version'))
    )
    $roots = @( (Join-Path $env:ProgramFiles 'Java'), (Join-Path $env:ProgramFiles 'Eclipse Adoptium'), (Join-Path $env:ProgramFiles 'Microsoft') )
    $fixtureRoot = Get-MHToolchainField -Object $Context -Name 'toolchainRoots'
    $overridden = Get-MHToolchainField -Object $fixtureRoot -Name 'javaHomes'
    if ($null -ne $overridden) { $roots = @($overridden) }
    $installs = @(); $warnings = @()
    $limit = [Math]::Max(1, [Math]::Min(128, [int]$Context.budgets.maxDiscoveredItems))
        foreach ($root in $roots) {
            $remaining = $limit - $installs.Count
            if ($remaining -le 0) { break }
            $listed = Get-MHToolchainDirectDirectories -Path $root -Limit ([Math]::Min(128, $remaining))
        foreach ($path in $listed.paths) { $installs += [pscustomobject]@{ name = [IO.Path]::GetFileName($path); path = ConvertTo-MHSafePath $path; state = 'PRESENT' } }
        if ($listed.truncated) { $warnings += 'JAVA_INSTALLATION_LIMIT_REACHED' }
    }
    $javaHome = Get-MHToolchainConfiguredEnvironment -Context $Context -Name 'JAVA_HOME'
    $homeFact = Get-MHToolchainEnvironmentPath -Name 'JAVA_HOME' -Override ([string]$javaHome) -Context $Context
    return [pscustomobject]@{ id = 'java'; state = $(if ($tools.state -contains 'PRESENT' -or $installs.Count -gt 0) { 'PRESENT' } elseif ($tools.state -contains 'UNKNOWN') { 'UNKNOWN' } else { 'ABSENT' }); tools = $tools; home = $homeFact; installations = @($installs | Sort-Object path -Unique); warnings = @($warnings) }
}

function Get-MHToolchainGoItem {
    param($Context)
    $go = Get-MHToolchainTool $Context 'go' 'go' @('version')
    $goEnvironment = @(); $tools = @(); $warnings = @()
    $maxToolCount = [Math]::Max(1, [Math]::Min(512, [int]$Context.budgets.maxDiscoveredItems))
    if ($go.state -eq 'PRESENT') {
        $probe = Invoke-MHToolchainProbe $Context 'go' @('env', 'GOPATH', 'GOROOT')
        if ((Get-MHToolchainProbeStatus $probe) -eq 'OK') {
            $values = @((Get-MHToolchainProbeText $probe) -split "`r?`n" | Where-Object { $_ })
            for ($index = 0; $index -lt [Math]::Min(2, $values.Count); $index++) { if ($values[$index] -match '^[A-Za-z]:\\[^\r\n]{0,1024}$') { $goEnvironment += [pscustomobject]@{ name = @('GOPATH', 'GOROOT')[$index]; path = ConvertTo-MHSafePath $values[$index]; state = 'PRESENT' } } }
        }
        $toolProbe = Invoke-MHToolchainProbe $Context 'go' @('tool')
        if ((Get-MHToolchainProbeStatus $toolProbe) -eq 'OK') { $tools = @((Get-MHToolchainProbeText $toolProbe) -split "`r?`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ -match '^[A-Za-z0-9_.+-]{1,100}$' } | Sort-Object -Unique | Select-Object -First $maxToolCount) }
    }
    $gobin = Get-MHToolchainConfiguredEnvironment -Context $Context -Name 'GOBIN'
    $gopath = Get-MHToolchainConfiguredEnvironment -Context $Context -Name 'GOPATH'
    $toolDirectories = @(); $warnings = @()
    if ($gobin) { $toolDirectories += $gobin }
    if ($gopath) { foreach ($path in @($gopath -split ';')) { if ($path) { $toolDirectories += (Join-Path $path 'bin') } } }
    foreach ($directory in $toolDirectories) {
        if ($tools.Count -ge $maxToolCount) { $warnings += 'GO_TOOL_LIMIT_REACHED'; break }
        if (-not (Test-MHToolchainSafeLocalPath -Path $directory)) { $warnings += 'GO_TOOL_PATH_UNSAFE'; continue }
        if (-not (Test-Path -LiteralPath $directory -PathType Container)) { continue }
        try {
            foreach ($file in [IO.Directory]::EnumerateFiles($directory, '*.exe', [IO.SearchOption]::TopDirectoryOnly)) {
                if ($tools.Count -ge [int]$Context.budgets.maxDiscoveredItems) { $warnings += 'GO_TOOL_LIMIT_REACHED'; break }
                if (-not (Test-MHToolchainSafeLocalPath -Path $file)) { $warnings += 'GO_TOOL_PATH_UNSAFE'; continue }
                $name = [IO.Path]::GetFileNameWithoutExtension($file)
                if ($name -match '^[A-Za-z0-9_.+-]{1,100}$') { $tools += $name }
            }
        } catch { }
    }
    $tools = @($tools | Sort-Object -Unique)
    return [pscustomobject]@{ id = 'go'; state = $go.state; status = $(if ($warnings.Count) { 'PARTIAL' } else { 'OK' }); warnings = @($warnings | Sort-Object -Unique); tools = @($go); environment = @((Get-MHToolchainEnvironmentPath 'GOPATH' $null $Context), (Get-MHToolchainEnvironmentPath 'GOROOT' $null $Context)); goEnvironment = $goEnvironment; installedTools = $tools }
}

function Get-MHToolchainNativeItem {
    param($Context)
    $definitions = @(
        @{ id = 'cmake'; command = 'cmake'; args = @('--version') }, @{ id = 'ninja'; command = 'ninja'; args = @('--version') },
        @{ id = 'clang'; command = 'clang'; args = @('--version') }, @{ id = 'clang-cl'; command = 'clang-cl'; args = @('--version') },
        @{ id = 'mingw-gcc'; command = 'gcc'; args = @('--version') }, @{ id = 'vcpkg'; command = 'vcpkg'; args = @('version') },
        @{ id = 'conan'; command = 'conan'; args = @('--version') }
    )
    $tools = @(); foreach ($definition in $definitions) { $tools += Get-MHToolchainTool $Context $definition.id $definition.command $definition.args }
    $sdkRoot = Join-Path ${env:ProgramFiles(x86)} 'Windows Kits\10\Include'
    $fixtureRoot = Get-MHToolchainField -Object $Context -Name 'toolchainRoots'
    $override = Get-MHToolchainField -Object $fixtureRoot -Name 'windowsSdkRoot'
    if ($override) { $sdkRoot = $override }
    $sdks = @(); $warnings = @()
    $sdkDirectories = Get-MHToolchainDirectDirectories -Path $sdkRoot -Limit ([Math]::Min(128, [int]$Context.budgets.maxDiscoveredItems))
    foreach ($dir in $sdkDirectories.paths) { $version = [IO.Path]::GetFileName($dir); if ($version -match '^\d+(?:\.\d+){1,3}$') { $sdks += $version } }
    if ($sdkDirectories.truncated) { $warnings += 'WINDOWS_SDK_LIMIT_REACHED' }
    return [pscustomobject]@{ id = 'native'; state = $(if ($tools.state -contains 'PRESENT' -or $sdks.Count -gt 0) { 'PRESENT' } elseif ($tools.state -contains 'UNKNOWN') { 'UNKNOWN' } else { 'ABSENT' }); tools = $tools; windowsSdks = @($sdks | Sort-Object -Unique); msvc = @(); warnings = @($warnings) }
}

function Get-MHToolchainVisualStudioItem {
    param($Context)
    $commandOverrides = Get-MHToolchainField -Object $Context -Name 'toolchainCommands'
    $path = Get-MHToolchainField -Object $commandOverrides -Name 'vswhere.exe'
    if ($null -eq $commandOverrides) {
        if (-not $path) { $command = Get-Command -Name 'vswhere.exe' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1; if ($command) { $path = [string]$command.Source } }
        if (-not $path -and ${env:ProgramFiles(x86)}) {
            $candidate = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
            if (Test-Path -LiteralPath $candidate -PathType Leaf) { $path = $candidate }
        }
    }
    if (-not $path) { return [pscustomobject]@{ id = 'visual-studio'; state = 'ABSENT'; status = 'NOT_FOUND'; instances = @(); warnings = @() } }
    $probe = Invoke-MHToolchainProbe $Context $path @('-all', '-products', '*', '-format', 'json', '-include', 'packages', '-utf8')
    $status = Get-MHToolchainProbeStatus $probe
    if ($status -eq 'NOT_FOUND') { return [pscustomobject]@{ id = 'visual-studio'; state = 'ABSENT'; status = 'NOT_FOUND'; instances = @(); warnings = @() } }
    if ($status -ne 'OK') { return [pscustomobject]@{ id = 'visual-studio'; state = 'UNKNOWN'; status = $status; instances = @(); warnings = @('VSWHERE_' + $status) } }
    try { $records = ConvertFrom-Json -InputObject ([string](Get-MHToolchainField -Object $probe -Name 'stdout' -Default '')) -ErrorAction Stop }
    catch { return [pscustomobject]@{ id = 'visual-studio'; state = 'UNKNOWN'; status = 'OUTPUT_INVALID'; instances = @(); warnings = @('VSWHERE_OUTPUT_INVALID') } }
    $instances = @()
    $warnings = @()
    $instanceLimit = [Math]::Max(1, [Math]::Min(512, [int]$Context.budgets.maxDiscoveredItems))
    foreach ($record in @($records)) {
        if ($instances.Count -ge $instanceLimit) { $warnings += 'VISUAL_STUDIO_INSTANCE_LIMIT_REACHED'; break }
        $instanceId = [string]$record.instanceId; $installPath = ConvertTo-MHSafePath ([string]$record.installationPath)
        if (-not $installPath -or $instanceId -notmatch '^[A-Za-z0-9-]{1,120}$') { continue }
        $packages = @()
        foreach ($package in @(Get-MHToolchainField -Object $record -Name 'packages' -Default @() | Select-Object -First 512)) { $id = [string](Get-MHToolchainField -Object $package -Name 'id'); if ($id -match '^Microsoft\.VisualStudio\.(?:Workload|Component)\.[A-Za-z0-9_.-]{1,160}$') { $packages += $id } }
        $vcRoot = Join-Path $installPath 'VC\Tools\MSVC'
        $toolsets = @()
        if (Test-Path -LiteralPath $vcRoot -PathType Container) {
            $listedToolsets = Get-MHToolchainDirectDirectories -Path $vcRoot -Limit ([int]$Context.budgets.maxDiscoveredItems)
            foreach ($toolset in $listedToolsets.paths) { $toolsets += [pscustomobject]@{ version = [IO.Path]::GetFileName($toolset); path = ConvertTo-MHSafePath $toolset; state = 'PRESENT' } }
        }
        $msvcState = if ($toolsets.Count -gt 0 -or @($packages | Where-Object { $_ -match '\.Component\.VC\.Tools\.' }).Count -gt 0) { 'PRESENT' } else { 'UNKNOWN' }
        $instances += [pscustomobject]@{ id = $instanceId; path = $installPath; version = $(if ([string]$record.installationVersion -match '^\d+(?:\.\d+){1,3}$') { [string]$record.installationVersion } else { $null }); productId = $(if ([string]$record.productId -match '^Microsoft\.VisualStudio\.[A-Za-z0-9_.-]{1,100}$') { [string]$record.productId } else { $null }); workloadsAndComponents = @($packages | Sort-Object -Unique); msvc = [pscustomobject]@{ state = $msvcState; toolsets = @($toolsets) } }
    }
    $state = if ($instances.Count -gt 0) { 'PRESENT' } else { 'UNKNOWN' }
    return [pscustomobject]@{ id = 'visual-studio'; state = $state; status = $(if ($warnings.Count) { 'PARTIAL' } elseif ($state -eq 'PRESENT') { 'OK' } else { 'NO_VALID_INSTANCES' }); instances = $instances; warnings = @($warnings) }
}

function Get-MHToolchainCollection {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Context)
    try {
        $domainContext = New-MHToolchainContext -Context $Context
        $groups = @(
            (Get-MHToolchainRustItem -Context $domainContext),
            (Get-MHToolchainJavaItem -Context $domainContext),
            (Get-MHToolchainGoItem -Context $domainContext),
            (Get-MHToolchainNativeItem -Context $domainContext),
            (Get-MHToolchainVisualStudioItem -Context $domainContext)
        )
        $warnings = @()
        foreach ($group in $groups) {
            foreach ($warning in @(Get-MHToolchainField -Object $group -Name 'warnings' -Default @())) { $warnings += $warning }
            foreach ($tool in @(Get-MHToolchainField -Object $group -Name 'tools' -Default @())) { if ($tool.state -eq 'UNKNOWN') { $warnings += ($tool.id.ToUpperInvariant() + '_' + $tool.status) } }
        }
        $artifacts = @(Get-MHToolchainConfigArtifacts -Context $domainContext)
        foreach ($artifact in $artifacts) { if ($artifact.captureState -eq 'BLOCKED') { $warnings += ($artifact.id.ToUpperInvariant().Replace(':', '_') + '_' + $artifact.errorCode) } }
        $status = if ($warnings.Count -gt 0) { 'PARTIAL' } elseif (@($groups | Where-Object state -eq 'UNKNOWN').Count -gt 0) { 'PARTIAL' } else { 'OK' }
        return New-MHDomainResult -Domain 'toolchains' -Status $status -Items $groups -Warnings @($warnings | Sort-Object -Unique) -Provenance 'READ_ONLY_LOCAL_QUERY' -ConfigArtifacts $artifacts
    } catch {
        return New-MHDomainResult -Domain 'toolchains' -Status 'ERROR' -Items @() -Warnings @('TOOLCHAIN_COLLECTION_FAILED') -ErrorCode 'TOOLCHAIN_COLLECTION_FAILED' -Provenance 'READ_ONLY_LOCAL_QUERY' -ConfigArtifacts @()
    }
}
