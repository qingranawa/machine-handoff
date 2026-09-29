Set-StrictMode -Version Latest

function Get-MHDeepWslProperty {
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

function Get-MHDeepWslConfigPath {
    param([Parameter(Mandatory)]$Context)
    $explicitPath = [string](Get-MHDeepWslProperty -Object $Context -Name 'wslDeepConfigPath')
    if (-not [string]::IsNullOrWhiteSpace($explicitPath)) {
        if ($explicitPath.StartsWith('\\', [StringComparison]::Ordinal)) { return $null }
        return $explicitPath
    }
    $profile = [string](Get-MHDeepWslProperty -Object $Context -Name 'userProfile')
    if ([string]::IsNullOrWhiteSpace($profile)) { $profile = [Environment]::GetEnvironmentVariable('USERPROFILE') }
    if ([string]::IsNullOrWhiteSpace($profile) -or $profile.StartsWith('\\', [StringComparison]::Ordinal)) { return $null }
    return Join-Path $profile '.wslconfig'
}

function Test-MHDeepWslConfigPathSafe {
    param([Parameter(Mandatory)][string]$Path)
    $guard = Get-Command -Name Assert-MHNoReparseAncestors -CommandType Function -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($guard) {
        try { [void](Assert-MHNoReparseAncestors -Path $Path); return $true }
        catch { return $false }
    }

    try {
        $fullPath = [IO.Path]::GetFullPath($Path)
        $root = [IO.Path]::GetPathRoot($fullPath)
        $current = $root
        foreach ($segment in @($fullPath.Substring($root.Length) -split '[\\/]+' | Where-Object { $_ })) {
            $current = Join-Path $current $segment
            try { $attributes = [IO.File]::GetAttributes($current) }
            catch [System.IO.FileNotFoundException] { break }
            catch [System.IO.DirectoryNotFoundException] { break }
            catch { return $false }
            if (($attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { return $false }
        }
        return $true
    } catch { return $false }
}

function Get-MHDeepWslGlobalConfig {
    param([Parameter(Mandatory)]$Context)
    $path = Get-MHDeepWslConfigPath -Context $Context
    if ([string]::IsNullOrWhiteSpace($path)) { return [pscustomobject]@{ state = 'UNKNOWN'; safeSettings = @() } }
    if (-not (Test-MHDeepWslConfigPathSafe -Path $path)) { return [pscustomobject]@{ state = 'UNKNOWN'; safeSettings = @() } }
    try { $file = Get-Item -LiteralPath $path -ErrorAction Stop }
    catch {
        if ($_.CategoryInfo.Category -eq [System.Management.Automation.ErrorCategory]::ObjectNotFound) { return [pscustomobject]@{ state = 'ABSENT'; safeSettings = @() } }
        return [pscustomobject]@{ state = 'UNKNOWN'; safeSettings = @() }
    }
    if ($file.PSIsContainer) { return [pscustomobject]@{ state = 'UNKNOWN'; safeSettings = @() } }
    $maxBytes = [int](Get-MHDeepWslProperty -Object $Context.budgets -Name 'maxConfigBytes' -Default 262144)
    if ($file.Length -gt $maxBytes) { return [pscustomobject]@{ state = 'UNKNOWN'; safeSettings = @() } }
    $settings = @()
    $section = ''
    try {
        $configText = Read-MHBoundedUtf8Text -Path $path -MaxBytes $maxBytes
        foreach ($line in ($configText -split "`r?`n")) {
            if ($line -match '^\s*(?<section>\[[^]]+\])\s*$') { $section = $Matches.section.ToLowerInvariant(); continue }
            if ($section -ne '[wsl2]' -or $line -notmatch '^\s*(?<name>[A-Za-z]+)\s*=\s*(?<value>[^#;\s]+)\s*$') { continue }
            $name = $Matches.name
            $value = $Matches.value
            if ($name -match '^(?i:memory|swap)$' -and $value -match '^\d+(?:\.\d+)?(?:[KMG]B?)?$') { $settings += [pscustomobject]@{ name = $name.ToLowerInvariant(); value = $value.ToUpperInvariant() } }
            elseif ($name -match '^(?i:processors)$' -and $value -match '^\d{1,3}$') { $settings += [pscustomobject]@{ name = 'processors'; value = [int]$value } }
            elseif ($name -match '^(?i:localhostForwarding|dnsTunneling|guiApplications)$' -and $value -match '^(?i:true|false)$') { $settings += [pscustomobject]@{ name = $name.Substring(0,1).ToLowerInvariant() + $name.Substring(1); value = $value.ToLowerInvariant() } }
            elseif ($name -match '^(?i:networkingMode)$' -and $value -match '^(?i:nat|mirrored|virtioproxy)$') { $settings += [pscustomobject]@{ name = 'networkingMode'; value = $value.ToLowerInvariant() } }
        }
        return [pscustomobject]@{ state = 'PRESENT'; safeSettings = @($settings) }
    } catch { return [pscustomobject]@{ state = 'UNKNOWN'; safeSettings = @() } }
}

function Get-MHDeepWslProbeCommand {
    # 仅输出白名单线索；SSH/GPG 文件及认证配置始终不读取。
    $parts = @(
        'printf "user="; id -un 2>/dev/null; printf "shell="; basename "${SHELL:-unknown}"',
        'printf "packageManager="; for p in apt-get dnf yum pacman zypper apk; do command -v "$p" >/dev/null 2>&1 && { printf "%s" "$p"; break; }; done',
        'printf "\ntoolchain="; for p in git node npm pnpm python3 python pip3 dotnet rustc cargo go; do command -v "$p" >/dev/null 2>&1 && printf "%s," "$p"; done',
        'printf "\ngitVersion="; git --version 2>/dev/null | head -n 1',
        'printf "\ndocker="; if command -v docker >/dev/null 2>&1; then docker --version 2>/dev/null | head -n 1; else printf "NOT_FOUND"; fi',
        'printf "\nsshDir="; if test -d "$HOME/.ssh"; then printf "PRESENT"; else printf "ABSENT"; fi',
        'printf "\ndotfiles="; for f in .bashrc .zshrc .profile .gitconfig .config; do test -e "$HOME/$f" && printf "%s," "$f"; done',
        'printf "\nworkRoot="; for d in /work /workspace /src "$HOME/Projects" "$HOME/work"; do test -d "$d" && { printf "%s" "$d"; break; }; done',
        'if test -f /etc/wsl.conf && test -r /etc/wsl.conf; then printf "\nwslconf\n"; cat /etc/wsl.conf 2>/dev/null; elif test -f /etc/wsl.conf; then printf "\nwslconf-unreadable\n"; else printf "\nwslconf-absent\n"; fi'
    )
    return $parts -join '; '
}
function ConvertFrom-MHDeepWslProbe {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Text)
    $fields = @{}
    foreach ($line in ($Text -replace "`0", '') -split "`r?`n") {
        if ($line -match '^(?<key>user|shell|packageManager|toolchain|gitVersion|docker|sshDir|dotfiles|workRoot)=(?<value>.*)$') { $fields[$Matches.key] = $Matches.value.Trim() }
        elseif ($line -eq 'wslconf') { $fields.wslconfState = 'PRESENT' }
        elseif ($line -eq 'wslconf-unreadable') { $fields.wslconfState = 'UNKNOWN' }
        elseif ($line -eq 'wslconf-absent') { $fields.wslconfState = 'ABSENT' }
        elseif ($line -match '^(?<name>(?:\[(?:automount|interop|network)\])\.[A-Za-z]+)=(?<value>[^\s;#]{1,240})$') { $fields['wslconf:' + $Matches.name] = $Matches.value }
    }
    $clues = @()
    foreach ($name in @('user', 'shell', 'packageManager', 'toolchain', 'gitVersion', 'docker', 'sshDir', 'dotfiles', 'workRoot')) {
        $value = if ($fields.ContainsKey($name)) { [string]$fields[$name] } else { '' }
        if ([string]::IsNullOrWhiteSpace($value)) { $clues += [pscustomobject]@{ name = $name; state = 'UNKNOWN'; value = $null }; continue }
        if ($name -eq 'user') { $safe = if ($value -match '^[A-Za-z0-9._-]{1,64}$') { $value } else { $null } }
        elseif ($name -eq 'toolchain') { $safe = @($value -split ',' | Where-Object { $_ -match '^[a-z0-9._+-]{1,40}$' } | Sort-Object -Unique) }
        elseif ($name -eq 'dotfiles') { $safe = @($value -split ',' | Where-Object { $_ -match '^\.[A-Za-z0-9._-]{1,60}$' } | Sort-Object -Unique) }
        elseif ($name -eq 'workRoot') { $safe = if ($value -match '^/[A-Za-z0-9_./-]{1,240}$' -and $value -notmatch '\.\.') { $value } else { $null } }
        elseif ($name -eq 'sshDir') { $safe = if ($value -in @('PRESENT', 'ABSENT')) { $value } else { $null } }
        elseif ($name -eq 'docker') {
            if ($value -eq 'NOT_FOUND') { $safe = $value }
            elseif ($value -match '(?i)^Docker version (?<version>\d+(?:\.\d+){1,3})') { $safe = $Matches.version }
            else { $safe = $null }
        }
        else { $safe = if ($value.Length -le 120 -and $value -match '^[A-Za-z0-9._+/-]{1,120}$') { $value } else { $null } }
        $isAbsent = $name -eq 'docker' -and $safe -eq 'NOT_FOUND' -or $name -eq 'sshDir' -and $safe -eq 'ABSENT' -or $name -in @('toolchain', 'dotfiles') -and @($safe).Count -eq 0
        $clues += [pscustomobject]@{ name = $name; state = $(if ($null -eq $safe) { 'UNKNOWN' } elseif ($isAbsent) { 'ABSENT' } else { 'PRESENT' }); value = $safe }
    }
    $wslSettings = @()
    foreach ($key in @($fields.Keys | Where-Object { $_ -like 'wslconf:*' } | Sort-Object)) {
        $name = $key.Substring('wslconf:'.Length)
        $value = [string]$fields[$key]
        $normalized = $null
        if ($name -match '\.(enabled|appendwindowspath|generateresolvconf|generatehosts)$' -and $value -match '^(?i:true|false)$') { $normalized = $value.ToLowerInvariant() }
        elseif ($name -eq '[automount].root' -and $value -match '^/[A-Za-z0-9_./-]{1,160}$' -and $value -notmatch '\.\.') { $normalized = $value }
        elseif ($name -eq '[automount].options' -and $value -match '^(?i:metadata|umask=[0-7]{3,4}|fmask=[0-7]{3,4}|dmask=[0-7]{3,4}|case=dir)(,(?i:metadata|umask=[0-7]{3,4}|fmask=[0-7]{3,4}|dmask=[0-7]{3,4}|case=dir))*$') { $normalized = $value }
        if ($null -ne $normalized) { $wslSettings += [pscustomobject]@{ name = $name; value = $normalized } }
    }
    return [pscustomobject]@{ clues = @($clues); wslConfigState = $(if ($fields.ContainsKey('wslconfState')) { $fields.wslconfState } else { 'UNKNOWN' }); wslConfigSettings = @($wslSettings) }
}

function Get-MHDeepWslCollection {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Context)

    $warnings = [System.Collections.Generic.List[string]]::new()
    $config = Get-MHDeepWslGlobalConfig -Context $Context
    if ($config.state -eq 'UNKNOWN') { $warnings.Add('GLOBAL_WSL_CONFIG_UNREADABLE') }
    $distributions = @()
    $version = $null
    $defaultDistribution = $null
    $defaultVersion = $null
    if ([bool](Get-MHDeepWslProperty -Object $Context -Name 'safeMode' -Default $false)) {
        $warnings.Add('WSL_SAFE_MODE_NOT_TESTED')
        $payload = [pscustomobject]@{ id = 'wslDeep'; state = 'UNKNOWN'; version = $null; defaultVersion = $null; defaultDistribution = $null; globalConfig = $config; distributions = @() }
        return New-MHDomainResult -Domain 'wslDeep' -Status 'PARTIAL' -Items @($payload) -Warnings @($warnings.ToArray() | Sort-Object -Unique)
    }
    $remaining = Get-MHRemainingBudgetMilliseconds -Context $Context
    if ($remaining -le 0) { return New-MHDomainResult -Domain 'wslDeep' -Status 'PARTIAL' -Items @([pscustomobject]@{ id = 'wslDeep'; version = $null; defaultVersion = $null; defaultDistribution = $null; globalConfig = $config; distributions = @() }) -Warnings @('PROCESS_BUDGET_EXHAUSTED') }

    $versionProbe = Invoke-MHSafeProcess -Name 'wsl.exe' -Arguments @('--version') -TimeoutMilliseconds ([Math]::Min(4000, $remaining)) -MaxOutputBytes 8192 -Context $Context
    if ($versionProbe.found -and -not $versionProbe.timedOut -and -not $versionProbe.errorCode -and $versionProbe.exitCode -eq 0 -and $versionProbe.stdout -match '(?im)^WSL version:\s*(?<version>\d+(?:\.\d+){1,3})') { $version = $Matches.version }
    else { $warnings.Add('WSL_VERSION_UNKNOWN') }

    $remaining = Get-MHRemainingBudgetMilliseconds -Context $Context
    if ($remaining -le 0) { $warnings.Add('PROCESS_BUDGET_EXHAUSTED'); return New-MHDomainResult -Domain 'wslDeep' -Status 'PARTIAL' -Items @([pscustomobject]@{ id = 'wslDeep'; version = $version; defaultVersion = $null; defaultDistribution = $null; globalConfig = $config; distributions = @() }) -Warnings @($warnings.ToArray() | Sort-Object -Unique) }
    $statusProbe = Invoke-MHSafeProcess -Name 'wsl.exe' -Arguments @('--status') -TimeoutMilliseconds ([Math]::Min(4000, $remaining)) -MaxOutputBytes 8192 -Context $Context
    if ($statusProbe.found -and -not $statusProbe.timedOut -and -not $statusProbe.errorCode -and $statusProbe.exitCode -eq 0) {
        $statusText = ([string](Get-MHDeepWslProperty -Object $statusProbe -Name 'stdout' -Default '')) + "`n" + ([string](Get-MHDeepWslProperty -Object $statusProbe -Name 'stderr' -Default ''))
        if ($statusText -match '(?im)default distribution\s*:\s*(?<name>[A-Za-z0-9._-]{1,100})') { $defaultDistribution = $Matches.name }
        if ($statusText -match '(?im)default version\s*:\s*(?<version>[12])') { $defaultVersion = [int]$Matches.version }
    }
    if ($null -eq $defaultVersion) { $warnings.Add('WSL_DEFAULT_VERSION_UNKNOWN') }

    $remaining = Get-MHRemainingBudgetMilliseconds -Context $Context
    if ($remaining -le 0) { $warnings.Add('PROCESS_BUDGET_EXHAUSTED'); return New-MHDomainResult -Domain 'wslDeep' -Status 'PARTIAL' -Items @([pscustomobject]@{ id = 'wslDeep'; version = $version; defaultVersion = $defaultVersion; defaultDistribution = $defaultDistribution; globalConfig = $config; distributions = @() }) -Warnings @($warnings.ToArray() | Sort-Object -Unique) }
    $listProbe = Invoke-MHSafeProcess -Name 'wsl.exe' -Arguments @('--list', '--verbose') -TimeoutMilliseconds ([Math]::Min(8000, $remaining)) -MaxOutputBytes 32768 -Context $Context
    if (-not $listProbe.found) { return New-MHDomainResult -Domain 'wslDeep' -Status 'UNAVAILABLE' -Items @([pscustomobject]@{ id = 'wslDeep'; version = $version; defaultVersion = $defaultVersion; defaultDistribution = $defaultDistribution; globalConfig = $config; distributions = @() }) -Warnings @('WSL_COMMAND_NOT_FOUND') }
    if ($listProbe.timedOut -or $listProbe.errorCode -or $listProbe.exitCode -ne 0) { return New-MHDomainResult -Domain 'wslDeep' -Status 'PARTIAL' -Items @([pscustomobject]@{ id = 'wslDeep'; version = $version; defaultVersion = $defaultVersion; defaultDistribution = $defaultDistribution; globalConfig = $config; distributions = @() }) -Warnings @('WSL_DISTRIBUTION_LIST_UNKNOWN') }

    $lines = @(($listProbe.stdout -replace "`0", '') -split "`r?`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    $maxItems = [Math]::Max(0, [int]$Context.budgets.maxDiscoveredItems)
    $seenCount = 0
    foreach ($line in $lines) {
        if ($line -match '^(?<default>\*)?\s*(?<name>[A-Za-z0-9._-]{1,100})\s+(?<state>Running|Stopped)\s+(?<version>[12])\s*$') {
            if ($seenCount -ge $maxItems) { $warnings.Add('WSL_DISTRIBUTION_LIMIT_REACHED'); break }
            $seenCount++
            $name = $Matches.name
            $stateText = $Matches.state
            $distroVersion = [int]$Matches.version
            if ($line.StartsWith('*') -and -not $defaultDistribution) { $defaultDistribution = $name }
            $running = $stateText -match '^(?i:Running)$'
            if (-not $running) {
                $distributions += [pscustomobject]@{ id = 'wsl:' + $name; name = $name; running = $false; version = $distroVersion; probeStatus = 'NOT_TESTED_NOT_RUNNING'; wslConfigState = 'NOT_TESTED_NOT_RUNNING'; wslConfigSettings = @(); clues = @() }
                continue
            }
            $remaining = Get-MHRemainingBudgetMilliseconds -Context $Context
            if ($remaining -le 0) {
                $partial = $true
                $warnings.Add('RUNNING_DISTRIBUTION_RECHECK_UNKNOWN')
                $distributions += [pscustomobject]@{ id = 'wsl:' + $name; name = $name; running = $true; version = $distroVersion; probeStatus = 'UNKNOWN'; wslConfigState = 'UNKNOWN'; wslConfigSettings = @(); clues = @() }
                continue
            }
            $runningListProbe = Invoke-MHSafeProcess -Name 'wsl.exe' -Arguments @('--list', '--running', '--quiet') -TimeoutMilliseconds ([Math]::Min(4000, $remaining)) -MaxOutputBytes 8192 -Context $Context
            if (-not $runningListProbe.found -or $runningListProbe.timedOut -or $runningListProbe.errorCode -or $runningListProbe.exitCode -ne 0) {
                $partial = $true
                $warnings.Add('RUNNING_DISTRIBUTION_RECHECK_UNKNOWN')
                $distributions += [pscustomobject]@{ id = 'wsl:' + $name; name = $name; running = $true; version = $distroVersion; probeStatus = 'UNKNOWN'; wslConfigState = 'UNKNOWN'; wslConfigSettings = @(); clues = @() }
                continue
            }
            $runningNames = @(($runningListProbe.stdout -replace "`0", '') -split "`r?`n" | ForEach-Object { ($_ -replace '^\*\s*', '').Trim() } | Where-Object { $_ -match '^[A-Za-z0-9._-]{1,100}$' } | Sort-Object -Unique)
            if ($runningNames -notcontains $name) {
                $partial = $true
                $warnings.Add('DISTRIBUTION_STOPPED_BEFORE_PROBE')
                $distributions += [pscustomobject]@{ id = 'wsl:' + $name; name = $name; running = $false; version = $distroVersion; probeStatus = 'NOT_TESTED_NOT_RUNNING'; wslConfigState = 'NOT_TESTED_NOT_RUNNING'; wslConfigSettings = @(); clues = @() }
                continue
            }
            $remaining = Get-MHRemainingBudgetMilliseconds -Context $Context
            if ($remaining -le 0) { $warnings.Add('PROCESS_BUDGET_EXHAUSTED'); $distributions += [pscustomobject]@{ id = 'wsl:' + $name; name = $name; running = $true; version = $distroVersion; probeStatus = 'UNKNOWN'; wslConfigState = 'UNKNOWN'; wslConfigSettings = @(); clues = @() }; continue }
            $probe = Invoke-MHSafeProcess -Name 'wsl.exe' -Arguments @('-d', $name, '--', 'sh', '-c', (Get-MHDeepWslProbeCommand)) -TimeoutMilliseconds ([Math]::Min(8000, $remaining)) -MaxOutputBytes ([Math]::Min(32768, [int]$Context.budgets.maxProcessOutputBytes)) -Context $Context
            if ($probe.found -and -not $probe.timedOut -and -not $probe.errorCode -and $probe.exitCode -eq 0) {
                $parsed = ConvertFrom-MHDeepWslProbe -Text ([string]$probe.stdout)
                $probeStatus = 'OK'
            } else {
                $parsed = [pscustomobject]@{ clues = @(); wslConfigState = 'UNKNOWN'; wslConfigSettings = @() }
                $probeStatus = 'UNKNOWN'
                $warnings.Add('RUNNING_DISTRIBUTION_PROBE_UNKNOWN')
            }
            $distributions += [pscustomobject]@{ id = 'wsl:' + $name; name = $name; running = $true; version = $distroVersion; probeStatus = $probeStatus; wslConfigState = $parsed.wslConfigState; wslConfigSettings = @($parsed.wslConfigSettings); clues = @($parsed.clues) }
        } elseif ($line -notmatch '^(?i:NAME)\s+STATE\s+VERSION$') { $warnings.Add('WSL_DISTRIBUTION_ROW_UNPARSEABLE') }
    }
    if ($distributions.Count -eq 0 -and $lines.Count -gt 0) { $warnings.Add('WSL_DISTRIBUTION_LIST_UNPARSEABLE') }
    $status = if ($warnings.Count) { 'PARTIAL' } else { 'OK' }
    $payload = [pscustomobject]@{ id = 'wslDeep'; state = $(if ($status -eq 'OK') { 'PRESENT' } else { 'PARTIAL' }); version = $version; defaultVersion = $defaultVersion; defaultDistribution = $defaultDistribution; globalConfig = $config; distributions = @($distributions) }
    return New-MHDomainResult -Domain 'wslDeep' -Status $status -Items @($payload) -Warnings @($warnings.ToArray() | Sort-Object -Unique)
}

function Get-MHWslDeepFacts {
    param([Parameter(Mandatory)]$Context)
    return Get-MHDeepWslCollection -Context $Context
}
