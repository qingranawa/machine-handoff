Set-StrictMode -Version Latest

# Git/PowerShell collector.  This file is deliberately read-only: it does not
# run Git config commands, import modules, load profiles, or contact package
# repositories.

$script:MHGPSecretHelperAvailable = $null
$script:MHGPSafePathHelperAvailable = $null
$script:MHGPArtifactHelperAvailable = $null
$script:MHGPBudgetHelperAvailable = $null

function Get-MHGPContextValue {
    param(
        $Context,
        [string[]]$Names,
        $Default = $null
    )

    if ($null -eq $Context) { return $Default }
    foreach ($name in $Names) {
        if ($Context -is [System.Collections.IDictionary] -and $Context.Contains($name)) {
            return $Context[$name]
        }
        $property = $Context.PSObject.Properties[$name]
        if ($property) { return $property.Value }
    }
    return $Default
}

function Test-MHGPSecretText {
    param([AllowNull()][string]$Text)

    if ($null -eq $Text) { return $false }
    if ($null -eq $script:MHGPSecretHelperAvailable) {
        $script:MHGPSecretHelperAvailable = [bool](Get-Command -Name Test-MHSecretText -CommandType Function -ErrorAction SilentlyContinue | Select-Object -First 1)
    }
    if ($script:MHGPSecretHelperAvailable) {
        try { return [bool](Test-MHSecretText -Text $Text) } catch { return $true }
    }
    return $Text -match '(?i)(?:password|passwd|secret|token|api[_-]?key|private[_-]?key|authorization|cookie|credential)|://[^/\s:@]+:[^/\s@]+@|-----BEGIN [A-Z ]*PRIVATE KEY-----'
}

function ConvertTo-MHGPSafePath {
    param([AllowNull()][string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) { return $null }
    $text = $Path.Trim()
    if ($text.Length -gt 1024 -or (Test-MHGPSecretText -Text $text)) { return $null }
    if ($null -eq $script:MHGPSafePathHelperAvailable) {
        $script:MHGPSafePathHelperAvailable = [bool](Get-Command -Name ConvertTo-MHSafePath -CommandType Function -ErrorAction SilentlyContinue | Select-Object -First 1)
    }
    if ($script:MHGPSafePathHelperAvailable) {
        try { return ConvertTo-MHSafePath -Path $text } catch { return $null }
    }
    if ($text -match '[\r\n]') { return $null }
    if ($text -match '^[A-Za-z]:\\$') { return $text }
    return $text.TrimEnd('\')
}

function Resolve-MHGPPath {
    param(
        [AllowNull()][string]$Path,
        [AllowNull()][string]$UserHome
    )

    $safe = ConvertTo-MHGPSafePath -Path $Path
    if ($null -eq $safe) { return $null }
    $resolved = $safe
    if ($resolved -match '^~(?:[\\/]|$)' -and -not [string]::IsNullOrWhiteSpace($UserHome)) {
        $tail = $resolved.Substring(1).TrimStart('\', '/')
        $resolved = Join-Path $UserHome $tail
    }
    try { $resolved = [Environment]::ExpandEnvironmentVariables($resolved) } catch { }
    return ConvertTo-MHGPSafePath -Path $resolved
}

function Get-MHGPHome {
    param($Context)

    $candidate = Get-MHGPContextValue -Context $Context -Names @('userHome', 'home', 'userProfile', 'Home')
    if ([string]::IsNullOrWhiteSpace([string]$candidate)) { $candidate = $env:USERPROFILE }
    if ([string]::IsNullOrWhiteSpace([string]$candidate)) { $candidate = $env:HOME }
    return ConvertTo-MHGPSafePath -Path ([string]$candidate)
}

function Get-MHGPOperatingLimit {
    param(
        $Context,
        [string]$Name,
        [int]$Default
    )

    $budgets = Get-MHGPContextValue -Context $Context -Names @('budgets')
    $value = Get-MHGPContextValue -Context $budgets -Names @($Name)
    if ($null -eq $value) { return $Default }
    try { return [Math]::Max(1, [int]$value) } catch { return $Default }
}

function Get-MHGPRemainingBudget {
    param($Context)

    if ($null -eq $Context) { return [int]::MaxValue }
    if ($null -eq $script:MHGPBudgetHelperAvailable) {
        $script:MHGPBudgetHelperAvailable = [bool](Get-Command -Name Get-MHRemainingBudgetMilliseconds -CommandType Function -ErrorAction SilentlyContinue | Select-Object -First 1)
    }
    if ($script:MHGPBudgetHelperAvailable) {
        try { return [int](Get-MHRemainingBudgetMilliseconds -Context $Context) } catch { return 0 }
    }
    $deadline = Get-MHGPContextValue -Context $Context -Names @('domainDeadline', 'deadline')
    if ($deadline) {
        try { return [Math]::Max(0, [int][Math]::Floor(([DateTimeOffset]$deadline - [DateTimeOffset]::UtcNow).TotalMilliseconds)) } catch { }
    }
    return [int]::MaxValue
}

function Get-MHGPCommandPath {
    param([Parameter(Mandatory)][string]$Name)

    try {
        $command = Get-Command -Name $Name -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($command) {
            $source = if ($command.Source) { [string]$command.Source } else { [string]$command.Path }
            return ConvertTo-MHGPSafePath -Path $source
        }
    } catch { }
    return $null
}

function Invoke-MHGPProcess {
    param(
        [Parameter(Mandatory)][string]$Name,
        [string[]]$Arguments = @(),
        $Context,
        [int]$TimeoutMilliseconds = 5000
    )

    $runner = Get-Command -Name Invoke-MHSafeProcess -CommandType Function -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $runner) {
        return [pscustomobject]@{ found = $false; started = $false; exitCode = $null; timedOut = $false; stdout = ''; stderr = ''; errorCode = 'PROCESS_HELPER_UNAVAILABLE' }
    }

    $parameters = [ordered]@{ Name = $Name; Arguments = @($Arguments); TimeoutMilliseconds = $TimeoutMilliseconds }
    $parameterMap = $runner.Parameters
    if ($parameterMap -and $parameterMap.ContainsKey('Context')) { $parameters.Context = $Context }
    if ($parameterMap -and $parameterMap.ContainsKey('MaxOutputBytes')) { $parameters.MaxOutputBytes = (Get-MHGPOperatingLimit -Context $Context -Name 'maxProcessOutputBytes' -Default 65536) }
    try {
        $result = & $runner @parameters
        if ($null -eq $result) {
            return [pscustomobject]@{ found = $true; started = $false; exitCode = $null; timedOut = $false; stdout = ''; stderr = ''; errorCode = 'EMPTY_PROCESS_RESULT' }
        }
        $stdout = [string](Get-MHGPContextValue -Context $result -Names @('stdout') -Default '')
        $stderr = [string](Get-MHGPContextValue -Context $result -Names @('stderr') -Default '')
        return [pscustomobject]@{
            found = [bool](Get-MHGPContextValue -Context $result -Names @('found') -Default $true)
            started = [bool](Get-MHGPContextValue -Context $result -Names @('started') -Default $true)
            exitCode = Get-MHGPContextValue -Context $result -Names @('exitCode')
            timedOut = [bool](Get-MHGPContextValue -Context $result -Names @('timedOut') -Default $false)
            stdout = $stdout
            stderr = $stderr
            errorCode = Get-MHGPContextValue -Context $result -Names @('errorCode')
        }
    } catch {
        return [pscustomobject]@{ found = $true; started = $false; exitCode = $null; timedOut = $false; stdout = ''; stderr = ''; errorCode = 'PROCESS_FAILED' }
    }
}

function ConvertTo-MHGPRedactedUrl {
    param([AllowNull()][string]$Url)

    if ([string]::IsNullOrWhiteSpace($Url)) { return $null }
    $text = $Url.Trim()
    if ($text -match '^(?<prefix>[A-Za-z][A-Za-z0-9+.-]*://)(?<authority>[^/?#]*)(?<suffix>.*)$') {
        $authority = [string]$Matches.authority
        $authority = $authority -replace '^[^@]*@', '<redacted>@'
        $text = [string]$Matches.prefix + $authority + [string]$Matches.suffix
    } elseif ($text -match '^(?<user>[^@\s/:]+)@(?<host>[^:\s]+):(?<path>.*)$') {
        $text = 'git@' + $Matches.host + ':' + $Matches.path
    }
    $text = [regex]::Replace($text, '(?i)([?&](?:access[_-]?token|api[_-]?key|password|passwd|secret|token|auth|credential)=)[^&#\s]+', '$1<redacted>')
    if (Test-MHGPSecretText -Text $text) { return 'REDACTED_URL' }
    if ($text.Length -gt 2048) { return $text.Substring(0, 2048) }
    return $text
}

function Get-MHGPConfigPaths {
    param($Context, [string]$UserHome)

    $paths = @()
    $explicit = Get-MHGPContextValue -Context $Context -Names @('gitConfigPaths', 'configPaths')
    if ($explicit) { $paths += @($explicit) }
    $single = Get-MHGPContextValue -Context $Context -Names @('gitConfigPath')
    if ($single) { $paths += $single }
    if (-not $explicit -and -not $single) {
        if (-not [string]::IsNullOrWhiteSpace($env:GIT_CONFIG_GLOBAL)) { $paths += $env:GIT_CONFIG_GLOBAL }
        if (-not [string]::IsNullOrWhiteSpace($UserHome)) { $paths += (Join-Path $UserHome '.gitconfig') }
        if (-not [string]::IsNullOrWhiteSpace($env:XDG_CONFIG_HOME)) { $paths += (Join-Path $env:XDG_CONFIG_HOME 'git\config') }
        if (-not [string]::IsNullOrWhiteSpace($UserHome)) { $paths += (Join-Path $UserHome '.config\git\config') }
    }

    $seen = @{}
    $result = @()
    foreach ($path in @($paths)) {
        $safe = Resolve-MHGPPath -Path ([string]$path) -UserHome $UserHome
        if ($null -eq $safe) { continue }
        $key = $safe.ToLowerInvariant()
        if ($seen.ContainsKey($key)) { continue }
        $seen[$key] = $true
        $result += $safe
    }
    return @($result)
}

function Get-MHGPConfigData {
    param(
        [Parameter(Mandatory)][string]$Path,
        [int]$MaxBytes = 262144
    )

    $entries = @()
    $includeRules = @()
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf) -and -not (Test-Path -LiteralPath $Path -PathType Leaf -ErrorAction SilentlyContinue)) {
        return [pscustomobject]@{ state = 'NOT_FOUND'; entries = @(); includeRules = @(); warning = $null }
    }
    try {
        $reparseGuard = Get-Command -Name Assert-MHNoReparseAncestors -CommandType Function -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($reparseGuard) { [void](Assert-MHNoReparseAncestors -Path $Path) }
        $file = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
        if (($file.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            return [pscustomobject]@{ state = 'BLOCKED'; entries = @(); includeRules = @(); warning = 'GIT_CONFIG_PATH_BLOCKED' }
        }
        if ([int64]$file.Length -gt $MaxBytes) {
            return [pscustomobject]@{ state = 'TOO_LARGE'; entries = @(); includeRules = @(); warning = 'GIT_CONFIG_TOO_LARGE' }
        }
        $text = Read-MHBoundedUtf8Text -Path $Path -MaxBytes $MaxBytes
    } catch {
        return [pscustomobject]@{ state = 'ERROR'; entries = @(); includeRules = @(); warning = 'GIT_CONFIG_READ_FAILED' }
    }

    $section = ''
    foreach ($line in @($text -split "`r?`n")) {
        if ($line -match '^\s*[#;]') { continue }
        if ($line -match '^\s*\[(?<section>[^\]]+)\]\s*$') {
            $sectionText = $Matches.section.Trim()
            if ($sectionText -match '^(?<name>[^\s"]+)\s+"(?<sub>.*)"$') {
                $section = $Matches.name.ToLowerInvariant() + '.' + $Matches.sub
            } else { $section = $sectionText.ToLowerInvariant() }
            continue
        }
        if ($line -notmatch '^\s*(?<key>[^=\s]+)\s*=\s*(?<value>.*)$') { continue }
        $key = $Matches.key.Trim().ToLowerInvariant()
        $value = $Matches.value.Trim()
        if ($value.Length -ge 2 -and (($value.StartsWith('"') -and $value.EndsWith('"')) -or ($value.StartsWith("'") -and $value.EndsWith("'")))) {
            $value = $value.Substring(1, $value.Length - 2)
        }
        $fullKey = if ($section) { $section + '.' + $key } else { $key }
        if ($section -eq 'include' -or $section -like 'includeif.*') {
            if ($key -eq 'path') {
                $condition = $null
                $kind = 'include'
                if ($section -like 'includeif.*') {
                    $kind = 'includeIf'
                    $condition = $section.Substring(9)
                    if (Test-MHGPSecretText -Text $condition) { $condition = 'REDACTED'; $value = '' }
                }
                $safeIncludePath = ConvertTo-MHGPSafePath -Path $value
                $includeState = 'RECORDED_ONLY'
                if (-not $safeIncludePath) { $safeIncludePath = 'REDACTED'; $includeState = 'REDACTED' }
                $includeRules += [pscustomobject]@{
                    type = $kind
                    condition = $condition
                    path = $safeIncludePath
                    sourcePath = ConvertTo-MHGPSafePath -Path $Path
                    followed = $false
                    state = $includeState
                }
            }
        }
        $entries += [pscustomobject]@{ scope = 'global'; origin = $Path; section = $section; key = $key; name = $fullKey; value = $value }
    }
    return [pscustomobject]@{ state = 'PRESENT'; entries = @($entries); includeRules = @($includeRules); warning = $null }
}

function ConvertTo-MHGPBoolean {
    param([AllowNull()][string]$Value)

    if ($null -eq $Value) { return 'UNKNOWN' }
    if ($Value -match '(?i)^(true|yes|on|1)$') { return 'true' }
    if ($Value -match '(?i)^(false|no|off|0)$') { return 'false' }
    return 'UNKNOWN'
}

function ConvertTo-MHGPSettingValue {
    param([AllowNull()][string]$Value)

    if ($null -eq $Value -or $Value.Length -gt 512 -or $Value -match '[\r\n]' -or (Test-MHGPSecretText -Text $Value)) { return $null }
    return $Value
}

function Get-MHGPHelperType {
    param([AllowNull()][string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) { return 'empty' }
    $first = ($Value.Trim() -split '\s+')[0]
    if ($first.StartsWith('!')) { return 'custom' }
    if ($first -match '(?i)^(manager-core|manager|wincred|store|cache|osxkeychain|libsecret|secretservice|gh)$') { return $first.ToLowerInvariant() }
    if ($first -match '^[A-Za-z0-9_.-]{1,80}$') { return $first }
    return 'custom'
}

function ConvertTo-MHGPSystemValue {
    param([string]$Key, [AllowNull()][string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value) -or $Value.Length -gt 512 -or $Value -match '[\r\n]' -or (Test-MHGPSecretText -Text $Value)) { return $null }
    $keyName = $Key.ToLowerInvariant()
    if ($keyName -in @('core.filemode', 'core.ignorecase', 'core.longpaths', 'core.safecrlf', 'fetch.prune', 'push.autosetupremote', 'rebase.autostash', 'commit.gpgsign', 'tag.gpgsign')) {
        $boolean = ConvertTo-MHGPBoolean -Value $Value
        if ($boolean -ne 'UNKNOWN') { return $boolean }
        return $null
    }
    switch ($keyName) {
        'core.autocrlf' { if ($Value -match '^(?i:true|false|input)$') { return $Value.ToLowerInvariant() }; return $null }
        'core.eol' { if ($Value -match '^(?i:lf|crlf|native)$') { return $Value.ToLowerInvariant() }; return $null }
        'pull.ff' { if ($Value -match '^(?i:true|false|only)$') { return $Value.ToLowerInvariant() }; return $null }
        'pull.rebase' { if ($Value -match '^(?i:true|false|merges|interactive)$') { return $Value.ToLowerInvariant() }; return $null }
        'push.default' { if ($Value -match '^(?i:nothing|current|upstream|simple|matching)$') { return $Value.ToLowerInvariant() }; return $null }
        'init.defaultbranch' { if ($Value -match '^[A-Za-z0-9][A-Za-z0-9._/-]{0,199}$') { return $Value }; return $null }
        'gpg.format' { if ($Value -match '^(?i:openpgp|ssh|x509)$') { return $Value.ToLowerInvariant() }; return $null }
        'core.editor' { return $Value }
        default { return (ConvertTo-MHGPSettingValue -Value $Value) }
    }
}

function Get-MHGPGitSystemFacts {
    param($Context, [string[]]$AllowedBoolean, [string[]]$AllowedValue)

    $warnings = @()
    $settings = @()
    $credentialHelpers = @()
    $includeRules = @()
    $aliases = @()
    $systemIgnorePaths = @()
    $configFiles = @()
    $gitName = if (Get-MHGPCommandPath -Name 'git.exe') { 'git.exe' } else { 'git' }
    $listResult = Invoke-MHGPProcess -Name $gitName -Arguments @('config', '--system', '--no-includes', '--null', '--name-only', '--list', '--show-origin') -Context $Context -TimeoutMilliseconds (Get-MHGPOperatingLimit -Context $Context -Name 'processTimeoutMs' -Default 5000)
    if (-not $listResult.found) {
        return [pscustomobject]@{ status = 'UNAVAILABLE'; warnings = @('GIT_SYSTEM_CONFIG_NOT_TESTED'); settings = @(); credentialHelpers = @(); includeRules = @(); configFiles = @(); systemIgnorePaths = @(); signing = [pscustomobject]@{ commitGpgSign = 'UNKNOWN'; tagGpgSign = 'UNKNOWN'; format = $null; keyConfigured = $false; programConfigured = $false } }
    }
    if ($listResult.exitCode -ne 0 -or $listResult.errorCode -or $listResult.timedOut) {
        $warning = if ($listResult.timedOut) { 'GIT_SYSTEM_CONFIG_TIMEOUT' } else { 'GIT_SYSTEM_CONFIG_UNAVAILABLE' }
        return [pscustomobject]@{ status = 'PARTIAL'; warnings = @($warning); settings = @(); credentialHelpers = @(); includeRules = @(); configFiles = @(); systemIgnorePaths = @(); signing = [pscustomobject]@{ commitGpgSign = 'UNKNOWN'; tagGpgSign = 'UNKNOWN'; format = $null; keyConfigured = $false; programConfigured = $false } }
    }

    $tokens = @(([string]$listResult.stdout -split [char]0) | Where-Object { $_ })
    if (($tokens.Count % 2) -ne 0) { $warnings += 'GIT_SYSTEM_CONFIG_ORIGIN_PARSE_PARTIAL' }
    $entries = @()
    for ($index = 0; $index + 1 -lt $tokens.Count; $index += 2) {
        $originText = [string]$tokens[$index]
        $key = [string]$tokens[$index + 1]
        $isCredentialHelperKey = $key -match '^credential(?:\..+)?\.helper$'
        if ($originText -notmatch '^file:' -or [string]::IsNullOrWhiteSpace($key) -or $key.Length -gt 512 -or $key -match '[\r\n\x00]' -or ((Test-MHGPSecretText -Text $key) -and -not $isCredentialHelperKey)) { continue }
        $originPath = ConvertTo-MHGPSafePath -Path $originText.Substring(5)
        if (-not $originPath) { continue }
        $configFiles += [pscustomobject]@{ scope = 'system'; path = $originPath; state = 'PRESENT' }
        $entries += [pscustomobject]@{ key = $key.ToLowerInvariant(); origin = $originPath }
    }
    $configFiles = @($configFiles | Sort-Object path -Unique)

    $queryKeys = @($AllowedBoolean + $AllowedValue + @('credential.helper', 'user.signingkey', 'gpg.program', 'gpg.ssh.program', 'core.excludesfile'))
    $queryKeys += @($entries | ForEach-Object key | Where-Object { $_ -match '^credential\..+\.helper$|^remote\.[A-Za-z0-9_.-]+\.(url|pushurl)$|^include\.path$|^includeif\..+\.path$|^alias\..+$' })
    $queryKeys = @($queryKeys | Sort-Object -Unique)
    $maxQueries = [Math]::Min(512, (Get-MHGPOperatingLimit -Context $Context -Name 'maxDiscoveredItems' -Default 512))
    if ($queryKeys.Count -gt $maxQueries) {
        $queryKeys = @($queryKeys | Select-Object -First $maxQueries)
        $warnings += 'GIT_SYSTEM_SETTINGS_LIMIT_REACHED'
    }
    $signingKeyConfigured = $false
    $signingProgramConfigured = $false
    $systemSigning = [ordered]@{ commitGpgSign = 'UNKNOWN'; tagGpgSign = 'UNKNOWN'; format = $null }
    foreach ($key in $queryKeys) {
        if (@($entries | Where-Object key -eq $key).Count -eq 0) { continue }
        $valuesResult = Invoke-MHGPProcess -Name $gitName -Arguments @('config', '--system', '--no-includes', '--null', '--show-origin', '--get-all', $key) -Context $Context -TimeoutMilliseconds (Get-MHGPOperatingLimit -Context $Context -Name 'processTimeoutMs' -Default 5000)
        if ($valuesResult.exitCode -eq 1 -and -not $valuesResult.errorCode) { continue }
        if ($valuesResult.exitCode -ne 0 -or $valuesResult.errorCode -or $valuesResult.timedOut) { $warnings += 'GIT_SYSTEM_SETTING_UNAVAILABLE'; continue }
        $values = @(([string]$valuesResult.stdout -split [char]0) | Where-Object { $_ -ne '' })
        if (($values.Count % 2) -ne 0) { $warnings += 'GIT_SYSTEM_SETTING_ORIGIN_PARSE_PARTIAL'; continue }
        for ($valueIndex = 0; $valueIndex + 1 -lt $values.Count; $valueIndex += 2) {
            $originToken = [string]$values[$valueIndex]
            $value = [string]$values[$valueIndex + 1]
            if ($originToken -notmatch '^file:' -or $originToken.Length -gt 4096) { $warnings += 'GIT_SYSTEM_SETTING_ORIGIN_UNAVAILABLE'; continue }
            $origin = ConvertTo-MHGPSafePath -Path $originToken.Substring(5)
            if (-not $origin) { $warnings += 'GIT_SYSTEM_SETTING_ORIGIN_UNAVAILABLE'; continue }
            if ($key -eq 'credential.helper' -or $key -match '^credential\..+\.helper$') {
                $credentialHelpers += [pscustomobject]@{ scope = 'system'; type = (Get-MHGPHelperType -Value $value); configured = $true; origin = $origin }
                continue
            }
            if ($key -match '^alias\.(?<alias>.+)$') {
                $aliasName = [string]$Matches.alias
                if ($aliasName -match '^[A-Za-z0-9_.-]{1,80}$' -and -not (Test-MHGPSecretText -Text $aliasName)) {
                    $isShellAlias = $value.TrimStart().StartsWith('!')
                    $aliasValue = if ($isShellAlias -or (Test-MHGPSecretText -Text $value)) { $null } else { $value }
                    $aliases += [pscustomobject]@{ scope = 'system'; origin = $origin; name = $aliasName; commandType = if ($isShellAlias) { 'SHELL' } else { 'GIT_ALIAS' }; value = $aliasValue; state = if ($aliasValue) { 'PRESENT' } else { 'METADATA_ONLY' }; execution = 'NEVER_RUN'; restorePolicy = 'REVIEW' }
                }
                continue
            }
            if ($key -match '^include\.path$|^includeif\..+\.path$') {
                $safeInclude = ConvertTo-MHGPSafePath -Path $value
                if ($safeInclude) {
                    $kind = if ($key -eq 'include.path') { 'include' } else { 'includeIf' }
                    $condition = if ($kind -eq 'includeIf') { ($key -replace '^includeif\.', '' -replace '\.path$', '') } else { $null }
                    $includeRules += [pscustomobject]@{ type = $kind; condition = $condition; path = $safeInclude; sourcePath = $origin; followed = $false; state = 'RECORDED_ONLY'; scope = 'system' }
                } else { $warnings += 'GIT_SYSTEM_INCLUDE_REDACTED' }
                continue
            }
            if ($key -match '^remote\.(?<remote>[A-Za-z0-9_.-]+)\.(url|pushurl)$') {
                $safeUrl = ConvertTo-MHGPRedactedUrl -Url $value
                if ($safeUrl) { $settings += [pscustomobject]@{ scope = 'system'; origin = $origin; key = $key; value = $safeUrl; valueState = 'REDACTED_OR_SAFE' } }
                continue
            }
            if ($key -eq 'user.signingkey') { $signingKeyConfigured = $true; continue }
            if ($key -eq 'gpg.program' -or $key -eq 'gpg.ssh.program') { $signingProgramConfigured = $true; continue }
            if ($key -eq 'commit.gpgsign') { $systemSigning.commitGpgSign = ConvertTo-MHGPBoolean -Value $value; continue }
            if ($key -eq 'tag.gpgsign') { $systemSigning.tagGpgSign = ConvertTo-MHGPBoolean -Value $value; continue }
            if ($key -eq 'gpg.format') { $systemSigning.format = if ($value -match '(?i)^(openpgp|ssh|x509)$') { $value.ToLowerInvariant() } else { $null }; continue }
            if ($key -eq 'core.excludesfile') {
                $safeIgnore = Resolve-MHGPPath -Path $value -UserHome (Get-MHGPHome -Context $Context)
            if ($safeIgnore) { $systemIgnorePaths += $safeIgnore }
            continue
            }
            $normalizedValue = ConvertTo-MHGPSystemValue -Key $key -Value $value
            if ($normalizedValue) { $settings += [pscustomobject]@{ scope = 'system'; origin = $origin; key = $key; value = $normalizedValue; valueState = 'SAFE' } }
        }
    }
    $signing = [pscustomobject]@{
        commitGpgSign = $systemSigning.commitGpgSign
        tagGpgSign = $systemSigning.tagGpgSign
        format = $systemSigning.format
        keyConfigured = $signingKeyConfigured
        programConfigured = $signingProgramConfigured
        privateKeyState = 'NOT_COLLECTED'
        restorePolicy = 'REVIEW'
    }
    return [pscustomobject]@{ status = if ($warnings.Count -gt 0) { 'PARTIAL' } else { 'OK' }; warnings = @($warnings | Sort-Object -Unique); settings = @($settings); aliases = @($aliases); credentialHelpers = @($credentialHelpers); includeRules = @($includeRules); configFiles = @($configFiles); systemIgnorePaths = @($systemIgnorePaths | Sort-Object -Unique); signing = $signing }
}

function Get-MHGPGitSummary {
    param($Context, [string]$UserHome)

    $warnings = @()
    $configPaths = @(Get-MHGPConfigPaths -Context $Context -UserHome $UserHome)
    $allEntries = @()
    $includeRules = @()
    $configStates = @()
    foreach ($path in $configPaths) {
        $data = Get-MHGPConfigData -Path $path -MaxBytes (Get-MHGPOperatingLimit -Context $Context -Name 'maxConfigBytes' -Default 262144)
        $configStates += [pscustomobject]@{ path = $path; state = $data.state }
        if ($data.warning) { $warnings += $data.warning }
        $allEntries += @($data.entries)
        $includeRules += @($data.includeRules)
    }

    $settings = @()
    $credentialHelpers = @()
    $aliases = @()
    $remoteNames = @()
    $ignorePaths = @()
    $signing = [ordered]@{
        commitGpgSign = 'UNKNOWN'
        tagGpgSign = 'UNKNOWN'
        format = $null
        keyConfigured = $false
        programConfigured = $false
        privateKeyState = 'NOT_COLLECTED'
        restorePolicy = 'REVIEW'
    }
    $allowedBoolean = @('core.filemode', 'core.ignorecase', 'core.longpaths', 'core.safecrlf', 'fetch.prune', 'push.autosetupremote', 'rebase.autostash', 'commit.gpgsign', 'tag.gpgsign', 'difftool.prompt', 'mergetool.prompt')
    $allowedValue = @('core.autocrlf', 'core.eol', 'core.editor', 'init.defaultbranch', 'pull.ff', 'pull.rebase', 'push.default', 'user.name', 'user.email', 'diff.tool', 'diff.guitool', 'merge.tool', 'merge.guitool', 'gpg.format')
    foreach ($entry in @($allEntries)) {
        $name = [string]$entry.name
        $value = [string]$entry.value
        if ($name -eq 'credential.helper' -or $name -match '^credential\..+\.helper$') {
            $credentialHelpers += [pscustomobject]@{ scope = 'global'; origin = $entry.origin; type = (Get-MHGPHelperType -Value $value); configured = $true }
            continue
        }
        if ($name -match '^alias\.(?<alias>.+)$') {
            $aliasName = [string]$Matches.alias
            if ($aliasName -match '^[A-Za-z0-9_.-]{1,80}$' -and -not (Test-MHGPSecretText -Text $aliasName)) {
                $isShellAlias = $value.TrimStart().StartsWith('!')
                $aliasValue = if ($isShellAlias -or (Test-MHGPSecretText -Text $value)) { $null } else { $value }
                $aliases += [pscustomobject]@{ scope = 'global'; origin = $entry.origin; name = $aliasName; commandType = if ($isShellAlias) { 'SHELL' } else { 'GIT_ALIAS' }; value = $aliasValue; state = if ($aliasValue) { 'PRESENT' } else { 'METADATA_ONLY' }; execution = 'NEVER_RUN'; restorePolicy = 'REVIEW' }
            }
            continue
        }
        if ($name -match '^remote\.(?<remote>[^.]+)\.(?<remoteKey>url|pushurl)$') {
            $remoteName = [string]$Matches.remote
            $remoteKey = [string]$Matches.remoteKey
            $safeRemoteName = if ($remoteName -match '^[A-Za-z0-9_.-]{1,80}$' -and -not (Test-MHGPSecretText -Text $remoteName)) { $remoteName } else { '<redacted>' }
            if ($safeRemoteName -ne '<redacted>') { $remoteNames += $safeRemoteName }
            $redactedUrl = ConvertTo-MHGPRedactedUrl -Url $value
            if ($redactedUrl) { $settings += [pscustomobject]@{ scope = 'global'; origin = $entry.origin; key = ('remote.' + $safeRemoteName + '.' + $remoteKey); value = $redactedUrl; valueState = 'REDACTED_OR_SAFE'; restorePolicy = 'REVIEW' } }
            continue
        }
        if ($name -eq 'core.excludesfile') {
            $safeIgnore = Resolve-MHGPPath -Path $value -UserHome $UserHome
            if ($safeIgnore) { $ignorePaths += $safeIgnore }
            continue
        }
        if ($name -eq 'commit.gpgsign') { $signing.commitGpgSign = ConvertTo-MHGPBoolean -Value $value; continue }
        if ($name -eq 'tag.gpgsign') { $signing.tagGpgSign = ConvertTo-MHGPBoolean -Value $value; continue }
        if ($name -eq 'gpg.format') {
            if ($value -match '(?i)^(openpgp|ssh|x509)$') { $signing.format = $value.ToLowerInvariant() }
            continue
        }
        if ($name -eq 'user.signingkey') { $signing.keyConfigured = $true; continue }
        if ($name -eq 'gpg.program' -or $name -eq 'gpg.ssh.program') { $signing.programConfigured = $true; continue }
        if ($allowedBoolean -contains $name) {
            $normalized = ConvertTo-MHGPBoolean -Value $value
            if ($normalized -ne 'UNKNOWN') { $settings += [pscustomobject]@{ scope = 'global'; origin = $entry.origin; key = $name; value = $normalized; valueState = 'SAFE'; restorePolicy = 'REVIEW' } }
            continue
        }
        if ($allowedValue -contains $name) {
            $safeValue = ConvertTo-MHGPSettingValue -Value $value
            if ($safeValue) { $settings += [pscustomobject]@{ scope = 'global'; origin = $entry.origin; key = $name; value = $safeValue; valueState = 'SAFE'; restorePolicy = 'REVIEW' } }
        }
    }

    $globalConfigPaths = @($configStates | Where-Object { $_.state -eq 'PRESENT' } | ForEach-Object { $_.path })
    $hasGlobalConfig = @($configStates | Where-Object { $_.state -eq 'PRESENT' }).Count -gt 0
    $systemConfig = Get-MHGPGitSystemFacts -Context $Context -AllowedBoolean $allowedBoolean -AllowedValue $allowedValue
    $settings += @($systemConfig.settings)
    $aliases += @($systemConfig.aliases)
    $credentialHelpers += @($systemConfig.credentialHelpers)
    $includeRules += @($systemConfig.includeRules)
    $configStates += @($systemConfig.configFiles)
    $ignorePaths += @($systemConfig.systemIgnorePaths)
    $warnings += @($systemConfig.warnings)

    $globalIgnore = [ordered]@{ state = 'ABSENT'; path = $null; source = $null; contentPolicy = 'REDACTED_COPY'; captureState = 'NOT_TESTED'; redactionStatus = 'NOT_TESTED'; restorePolicy = 'REVIEW' }
    foreach ($ignorePath in @($ignorePaths | Sort-Object -Unique)) {
        $ignoreState = 'UNKNOWN'
        try { $ignoreState = if (Test-Path -LiteralPath $ignorePath -PathType Leaf) { 'PRESENT' } else { 'ABSENT' } } catch { }
        $globalIgnore = [ordered]@{ state = $ignoreState; path = (ConvertTo-MHGPSafePath -Path $ignorePath); source = 'core.excludesFile'; contentPolicy = 'REDACTED_COPY'; captureState = 'NOT_TESTED'; redactionStatus = 'NOT_TESTED'; restorePolicy = 'REVIEW' }
        break
    }

    $gitProcess = Invoke-MHGPProcess -Name 'git.exe' -Arguments @('--version') -Context $Context -TimeoutMilliseconds (Get-MHGPOperatingLimit -Context $Context -Name 'processTimeoutMs' -Default 5000)
    if (-not $gitProcess.found) { $gitProcess = Invoke-MHGPProcess -Name 'git' -Arguments @('--version') -Context $Context -TimeoutMilliseconds (Get-MHGPOperatingLimit -Context $Context -Name 'processTimeoutMs' -Default 5000) }
    $gitPath = Get-MHGPCommandPath -Name 'git.exe'
    if (-not $gitPath) { $gitPath = Get-MHGPCommandPath -Name 'git' }
    $version = $null
    $output = ([string]$gitProcess.stdout + "`n" + [string]$gitProcess.stderr)
    if ($gitProcess.exitCode -eq 0 -and $output -match '(?i)git version\s+(?<version>v?\d+(?:\.\d+){1,3}(?:[-+][A-Za-z0-9._-]+)?)') { $version = $Matches.version }
    $hasConfig = $hasGlobalConfig -or @($systemConfig.configFiles | Where-Object { $_.state -eq 'PRESENT' }).Count -gt 0
    $gitState = if ($gitPath -or $hasConfig) { 'PRESENT' } elseif ($gitProcess.errorCode -eq 'PROCESS_HELPER_UNAVAILABLE') { 'UNKNOWN' } else { 'ABSENT' }
    if ($gitProcess.timedOut) { $warnings += 'GIT_VERSION_TIMEOUT' }
    if ($gitProcess.errorCode -and $gitProcess.errorCode -notin @('NOT_FOUND', 'PROCESS_HELPER_UNAVAILABLE')) { $warnings += 'GIT_VERSION_UNAVAILABLE' }
    if (@($configStates | Where-Object { $_.state -in @('ERROR', 'TOO_LARGE') }).Count -gt 0) { $warnings += 'GIT_CONFIG_PARTIAL' }

    return [pscustomobject]@{
        item = [pscustomobject]@{
            id = 'git:global'
            state = $gitState
            scope = 'global'
            version = $version
            path = $gitPath
            settings = @($settings | Sort-Object key, scope, origin -Unique)
            includeRules = @($includeRules)
            credentialHelpers = @($credentialHelpers)
            aliases = @($aliases)
            signing = [pscustomobject]$signing
            systemConfigState = $systemConfig.status
            systemConfigFiles = @($systemConfig.configFiles)
            systemSettings = @($systemConfig.settings)
            systemCredentialHelpers = @($systemConfig.credentialHelpers)
            systemSigning = $systemConfig.signing
            globalIgnore = [pscustomobject]$globalIgnore
            remoteNames = @($remoteNames | Sort-Object -Unique)
            configFiles = @($configStates)
            configState = if ($hasGlobalConfig) { 'PRESENT' } elseif (@($configStates).Count -gt 0) { 'ABSENT' } else { 'NOT_FOUND' }
            restorePolicy = 'REVIEW'
        }
        configPaths = $globalConfigPaths
        systemConfigPaths = @($systemConfig.configFiles | Where-Object { $_.state -eq 'PRESENT' } | ForEach-Object { $_.path })
        warnings = @($warnings | Where-Object { $_ } | Sort-Object -Unique)
    }
}

function Get-MHGPVersionEntry {
    param(
        [Parameter(Mandatory)][string]$Name,
        [string[]]$Arguments,
        $Context
    )

    $path = Get-MHGPCommandPath -Name $Name
    if (-not $path) { return [pscustomobject]@{ id = $Name; state = 'ABSENT'; status = 'NOT_FOUND'; version = $null; path = $null } }
    $result = Invoke-MHGPProcess -Name $Name -Arguments $Arguments -Context $Context -TimeoutMilliseconds (Get-MHGPOperatingLimit -Context $Context -Name 'processTimeoutMs' -Default 5000)
    $output = ([string]$result.stdout + "`n" + [string]$result.stderr)
    $version = $null
    if ($result.exitCode -eq 0 -and $output -match '(?<![A-Za-z])v?(?<version>\d+(?:\.\d+){1,4}(?:[-+][A-Za-z0-9._-]+)?)') { $version = $Matches.version }
    return [pscustomobject]@{
        id = $Name
        state = if ($version) { 'PRESENT' } else { 'UNKNOWN' }
        status = if ($result.timedOut) { 'TIMEOUT' } elseif ($result.errorCode) { [string]$result.errorCode } elseif ($version) { 'OK' } else { 'VERSION_UNAVAILABLE' }
        version = $version
        path = $path
    }
}

function Get-MHGPModules {
    param($Context)

    $modules = @()
    $roots = @()
    try {
        foreach ($root in @(([string]$env:PSModulePath) -split [IO.Path]::PathSeparator)) {
            $safeRoot = ConvertTo-MHGPSafePath -Path $root.Trim()
            if ($safeRoot -and (Test-Path -LiteralPath $safeRoot -PathType Container)) { $roots += $safeRoot }
        }
    } catch { }
    if ($roots.Count -eq 0) { return [pscustomobject]@{ state = 'UNKNOWN'; items = @(); warning = 'POWERSHELL_MODULES_UNAVAILABLE' } }
    $maxDirectories = [Math]::Min(512, (Get-MHGPOperatingLimit -Context $Context -Name 'maxDirectories' -Default 2000))
    $visited = 0
    $budgetLimited = $false
    try {
        foreach ($root in @($roots | Sort-Object -Unique)) {
            if ($root -match '^\\\\') { continue }
            foreach ($moduleDirectory in @(Get-ChildItem -LiteralPath $root -Directory -Force -ErrorAction Stop)) {
                if ((Get-MHGPRemainingBudget -Context $Context) -le 0) { $budgetLimited = $true; break }
                $visited++
                if ($visited -gt $maxDirectories) { break }
                $name = [string]$moduleDirectory.Name
                if ($name -notmatch '^[A-Za-z0-9_.-]{1,160}$' -or (Test-MHGPSecretText -Text $name)) { continue }
                $versionDirectories = @()
                try { $versionDirectories = @(Get-ChildItem -LiteralPath $moduleDirectory.FullName -Directory -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^\d+(?:\.\d+){0,3}(?:[-+][A-Za-z0-9_.-]+)?$' }) } catch { }
                if ($versionDirectories.Count -gt 0) {
                    foreach ($versionDirectory in $versionDirectories) {
                        $moduleFile = $null
                        try { $moduleFile = Get-ChildItem -LiteralPath $versionDirectory.FullName -File -Force -ErrorAction SilentlyContinue | Where-Object { $_.Extension -in @('.psd1', '.psm1', '.dll') } | Select-Object -First 1 } catch { }
                        $modulePath = if ($moduleFile) { ConvertTo-MHGPSafePath -Path $moduleFile.FullName } else { ConvertTo-MHGPSafePath -Path $versionDirectory.FullName }
                        $modules += [pscustomobject]@{ name = $name; version = $versionDirectory.Name; path = $modulePath; state = 'PRESENT'; loaded = $false }
                        if ($modules.Count -ge $maxDirectories) { break }
                    }
                } else {
                    $moduleFile = $null
                    try { $moduleFile = Get-ChildItem -LiteralPath $moduleDirectory.FullName -File -Force -ErrorAction SilentlyContinue | Where-Object { $_.Extension -in @('.psd1', '.psm1', '.dll') } | Select-Object -First 1 } catch { }
                    $modulePath = if ($moduleFile) { ConvertTo-MHGPSafePath -Path $moduleFile.FullName } else { ConvertTo-MHGPSafePath -Path $moduleDirectory.FullName }
                    $modules += [pscustomobject]@{ name = $name; version = $null; path = $modulePath; state = 'PRESENT'; loaded = $false }
                }
            }
            if ($budgetLimited -or $visited -ge $maxDirectories -or $modules.Count -ge $maxDirectories) { break }
        }
        return [pscustomobject]@{ state = 'PRESENT'; items = @($modules | Sort-Object name, version, path -Unique); warning = if ($budgetLimited) { 'POWERSHELL_MODULES_BUDGET' } else { $null } }
    } catch {
        return [pscustomobject]@{ state = 'UNKNOWN'; items = @(); warning = 'POWERSHELL_MODULES_UNAVAILABLE' }
    }
}

function Get-MHGPRepositories {
    param($Context)

    if ((Get-MHGPRemainingBudget -Context $Context) -le 0) { return [pscustomobject]@{ state = 'UNKNOWN'; items = @(); warning = 'POWERSHELL_REPOSITORIES_BUDGET' } }
    try {
        $command = Get-Command -Name Get-PSRepository -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $command) { return [pscustomobject]@{ state = 'UNKNOWN'; items = @(); warning = 'POWERSHELL_REPOSITORIES_UNAVAILABLE' } }
        $items = @()
        foreach ($repository in @(Get-PSRepository -ErrorAction Stop)) {
            $name = [string]$repository.Name
            if ($name -notmatch '^[A-Za-z0-9_.-]{1,160}$' -or (Test-MHGPSecretText -Text $name)) { continue }
            $source = ConvertTo-MHGPRedactedUrl -Url ([string]$repository.SourceLocation)
            $items += [pscustomobject]@{ name = $name; source = $source; installationPolicy = [string]$repository.InstallationPolicy; state = 'PRESENT' }
        }
        return [pscustomobject]@{ state = 'PRESENT'; items = @($items | Sort-Object name -Unique); warning = $null }
    } catch {
        return [pscustomobject]@{ state = 'UNKNOWN'; items = @(); warning = 'POWERSHELL_REPOSITORIES_UNAVAILABLE' }
    }
}

function Get-MHGPExecutionPolicies {
    try {
        $command = Get-Command -Name Get-ExecutionPolicy -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $command) { throw 'missing' }
        $items = @()
        foreach ($policy in @(Get-ExecutionPolicy -List -ErrorAction Stop)) {
            $scope = [string]$policy.Scope
            $value = [string]$policy.ExecutionPolicy
            if ($scope -notmatch '^[A-Za-z]{1,80}$' -or $value -notmatch '^[A-Za-z]{1,80}$') { continue }
            $items += [pscustomobject]@{ scope = $scope; policy = $value; state = 'PRESENT' }
        }
        return [pscustomobject]@{ state = 'PRESENT'; items = @($items); warning = $null }
    } catch {
        return [pscustomobject]@{ state = 'UNKNOWN'; items = @(); warning = 'POWERSHELL_EXECUTION_POLICY_UNAVAILABLE' }
    }
}

function Get-MHGPProfileDescriptors {
    param($Context)

    $explicit = Get-MHGPContextValue -Context $Context -Names @('profilePaths', 'profiles')
    $descriptors = @()
    if ($explicit) {
        if ($explicit -is [System.Collections.IDictionary]) {
            foreach ($key in $explicit.Keys) { $descriptors += [pscustomobject]@{ name = [string]$key; path = [string]$explicit[$key] } }
        } else {
            foreach ($entry in @($explicit)) {
                $path = Get-MHGPContextValue -Context $entry -Names @('path', 'sourcePath')
                $name = Get-MHGPContextValue -Context $entry -Names @('name', 'id')
                if ($path) { $descriptors += [pscustomobject]@{ name = [string]$name; path = [string]$path } }
            }
        }
    }
    if ($descriptors.Count -eq 0) {
        $profileObject = Get-Variable -Name PROFILE -ValueOnly -ErrorAction SilentlyContinue
        foreach ($name in @('CurrentUserAllHosts', 'CurrentUserCurrentHost', 'AllUsersAllHosts', 'AllUsersCurrentHost')) {
            $path = $null
            if ($profileObject) {
                $property = $profileObject.PSObject.Properties[$name]
                if ($property) { $path = [string]$property.Value }
            }
            if ($path) { $descriptors += [pscustomobject]@{ name = $name; path = $path } }
        }
    }
    $seen = @{}
    $result = @()
    foreach ($descriptor in @($descriptors)) {
        $name = [string]$descriptor.name
        if ([string]::IsNullOrWhiteSpace($name)) { $name = 'Profile' + ($result.Count + 1) }
        $path = ConvertTo-MHGPSafePath -Path ([string]$descriptor.path)
        if ($null -eq $path) { continue }
        $key = $name.ToLowerInvariant() + '|' + $path.ToLowerInvariant()
        if ($seen.ContainsKey($key)) { continue }
        $seen[$key] = $true
        $present = $false
        try { $present = Test-Path -LiteralPath $path -PathType Leaf } catch { }
        $result += [pscustomobject]@{
            id = 'shell:powershell-profile:' + $name
            name = $name
            path = $path
            state = if ($present) { 'PRESENT' } else { 'ABSENT' }
            executable = $true
            contentPolicy = 'REDACTED_COPY'
            captureState = 'NOT_TESTED'
            redactionStatus = 'NOT_TESTED'
            execution = 'NEVER_RUN'
            restorePolicy = 'REVIEW'
        }
    }
    return @($result)
}

function Get-MHGPTextArtifactFormat {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][ValidateSet('Profile', 'GlobalIgnore')][string]$Kind,
        $Context
    )

    # Only UTF-8, printable text is eligible for REDACTED_COPY.  The shared
    # artifact helper repeats the size, encoding, reparse, and secret checks;
    # this preflight prevents binary or executable-shaped files from reaching
    # the text redactor at all.
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf -ErrorAction SilentlyContinue)) { return 'TEXT' }
    if ($Kind -eq 'Profile' -and [IO.Path]::GetExtension($Path) -ine '.ps1') { return 'UNKNOWN' }
    if ($Kind -eq 'GlobalIgnore') {
        $extension = [IO.Path]::GetExtension($Path).ToLowerInvariant()
        if ($extension -notin @('', '.txt', '.ignore', '.list')) { return 'UNKNOWN' }
    }
    try {
        $guard = Get-Command -Name Assert-MHNoReparseAncestors -CommandType Function -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($guard) { [void](Assert-MHNoReparseAncestors -Path $Path) }
        $file = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
        if (($file.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { return 'UNKNOWN' }
        $maxBytes = Get-MHGPOperatingLimit -Context $Context -Name 'maxConfigBytes' -Default 262144
        if ([int64]$file.Length -gt $maxBytes) { return 'UNKNOWN' }
        $text = Read-MHBoundedUtf8Text -Path $Path -MaxBytes $maxBytes
        foreach ($character in $text.ToCharArray()) {
            $code = [int][char]$character
            if ($code -eq 0 -or ([char]::IsControl($character) -and $code -notin @(9, 10, 13))) { return 'UNKNOWN' }
        }
        return 'TEXT'
    } catch {
        return 'UNKNOWN'
    }
}

function Get-MHGPProfileArtifacts {
    param($Context, [object[]]$Profiles)

    $artifacts = @()
    $userHome = Get-MHGPHome -Context $Context
    foreach ($profile in @($Profiles)) {
        if ($profile.state -ne 'PRESENT') { continue }
        $profileName = ([string]$profile.name -replace '[^A-Za-z0-9_.-]', '_')
        $profileArtifactPath = 'configs/shell/powershell-profile-' + $profileName + '.metadata.json'
        $profileTarget = '%USERPROFILE%\Documents\PowerShell\' + [IO.Path]::GetFileName([string]$profile.path)
        if ($userHome) {
            $homePrefix = $userHome.TrimEnd('\') + '\'
            if ([string]$profile.path -like ($homePrefix + '*')) {
                $relativeProfilePath = ([string]$profile.path).Substring($userHome.Length).TrimStart('\')
                if ($relativeProfilePath -and $relativeProfilePath -notmatch '[\r\n]') { $profileTarget = '%USERPROFILE%\' + $relativeProfilePath }
            }
        }
        $profileFormat = Get-MHGPTextArtifactFormat -Path ([string]$profile.path) -Kind Profile -Context $Context
        $artifacts += New-MHGPConfigArtifact -Context $Context -Id ([string]$profile.id) -Domain 'shell' -SourcePath ([string]$profile.path) -TargetPathCandidate $profileTarget -ContentPolicy 'REDACTED_COPY' -Sensitivity 'SENSITIVE' -Format $profileFormat -ArtifactPath $profileArtifactPath -RestorePolicy 'REVIEW' -ValidationStrategy 'DO_NOT_EXECUTE_MANUAL_REVIEW'
    }
    return @($artifacts)
}

function Get-MHGPConfigArtifacts {
    param($Context, [object[]]$ConfigPaths, [string[]]$SystemConfigPaths = @(), $GlobalIgnore)

    $artifacts = @()
    $index = 0
    foreach ($path in @($ConfigPaths | Sort-Object -Unique)) {
        $leaf = [IO.Path]::GetFileName($path)
        if ([string]::IsNullOrWhiteSpace($leaf)) { $leaf = 'config' }
        $safeLeaf = ($leaf -replace '[^A-Za-z0-9_.-]', '_')
        $id = 'git:global-config:' + $safeLeaf
        if (@($artifacts | Where-Object id -eq $id).Count -gt 0) { $index++; $id += ':' + $index }
        $artifactLeaf = ($id -replace '[^A-Za-z0-9_.-]', '_')
        $artifactPath = 'configs/git/' + $artifactLeaf + '.metadata.json'
        $artifacts += New-MHGPConfigArtifact -Context $Context -Id $id -Domain 'git' -SourcePath $path -TargetPathCandidate '%USERPROFILE%\.gitconfig' -ContentPolicy 'METADATA_ONLY' -Sensitivity 'SENSITIVE' -Format 'INI' -ArtifactPath $artifactPath -RestorePolicy 'REVIEW' -ValidationStrategy 'ALLOWLIST_KEYS_ONLY'
    }
    foreach ($path in @($SystemConfigPaths | Sort-Object -Unique)) {
        $leaf = [IO.Path]::GetFileName($path)
        if ([string]::IsNullOrWhiteSpace($leaf)) { $leaf = 'system-config' }
        $safeLeaf = ($leaf -replace '[^A-Za-z0-9_.-]', '_')
        $artifacts += New-MHGPConfigArtifact -Context $Context -Id ('git:system-config:' + $safeLeaf) -Domain 'git' -SourcePath $path -TargetPathCandidate $null -ContentPolicy 'METADATA_ONLY' -Sensitivity 'SENSITIVE' -Format 'INI' -ArtifactPath ('configs/git/system-' + $safeLeaf + '.metadata.json') -RestorePolicy 'REVIEW' -ValidationStrategy 'ALLOWLIST_KEYS_ONLY'
    }
    $ignorePath = Get-MHGPContextValue -Context $GlobalIgnore -Names @('path')
    if ($ignorePath -and (Get-MHGPContextValue -Context $GlobalIgnore -Names @('state')) -eq 'PRESENT') {
        $ignoreFormat = Get-MHGPTextArtifactFormat -Path ([string]$ignorePath) -Kind GlobalIgnore -Context $Context
        $artifacts += New-MHGPConfigArtifact -Context $Context -Id 'git:global-ignore' -Domain 'git' -SourcePath ([string]$ignorePath) -TargetPathCandidate '%USERPROFILE%\.config\git\ignore' -ContentPolicy 'REDACTED_COPY' -Sensitivity 'PRIVATE' -Format $ignoreFormat -ArtifactPath 'configs/git/global-ignore.metadata.json' -RestorePolicy 'REVIEW' -ValidationStrategy 'MANUAL_REVIEW'
    }
    return @($artifacts)
}

function New-MHGPConfigArtifact {
    param(
        $Context,
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)][string]$Domain,
        [Parameter(Mandatory)][string]$SourcePath,
        [string]$TargetPathCandidate,
        [Parameter(Mandatory)][string]$ContentPolicy,
        [Parameter(Mandatory)][string]$Sensitivity,
        [Parameter(Mandatory)][string]$Format,
        [AllowNull()][string]$ArtifactPath,
        [Parameter(Mandatory)][string]$RestorePolicy,
        [Parameter(Mandatory)][string]$ValidationStrategy
    )

    $artifactCommand = Get-Command -Name New-MHConfigArtifact -CommandType Function -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($artifactCommand) {
        try {
            $parameters = [ordered]@{
                Context = $Context; Id = $Id; Domain = $Domain; SourcePath = $SourcePath
                TargetPathCandidate = $TargetPathCandidate; ContentPolicy = $ContentPolicy
                Sensitivity = $Sensitivity; Format = $Format; ArtifactPath = $ArtifactPath
                RestorePolicy = $RestorePolicy; ValidationStrategy = $ValidationStrategy
            }
            return & $artifactCommand @parameters
        } catch { }
    }

    $isPresent = Test-Path -LiteralPath $SourcePath -PathType Leaf
    $captureState = if ($ContentPolicy -eq 'REDACTED_COPY') { 'BLOCKED' } elseif ($isPresent) { 'METADATA_ONLY' } else { 'NOT_FOUND' }
    $artifact = [pscustomobject]@{
        id = $Id; domain = $Domain; sourceLocator = $SourcePath; targetPathCandidate = $TargetPathCandidate
        contentPolicy = $ContentPolicy; sensitivity = $Sensitivity; captureState = $captureState
        redactionStatus = if ($ContentPolicy -eq 'REDACTED_COPY') { 'BLOCKED' } else { 'NOT_APPLICABLE' }; artifactPath = $null; artifactSha256 = $null
        restorePolicy = $RestorePolicy; dependsOn = @(); validationStrategy = $ValidationStrategy; errorCode = if ($ContentPolicy -eq 'REDACTED_COPY') { 'CONFIG_ARTIFACT_HELPER_UNAVAILABLE' } else { $null }
    }
    return [pscustomobject]@{ artifact = $artifact; content = $null }
}

function Get-MHGPowershellSummary {
    param($Context)

    $warnings = @()
    $versions = @()
    $runtimeVersion = $null
    try { $runtimeVersion = $PSVersionTable.PSVersion.ToString() } catch { }
    $runtimePath = $null
    try { $runtimePath = ConvertTo-MHGPSafePath -Path ((Get-Process -Id $PID -ErrorAction Stop).Path) } catch { }
    $versions += [pscustomobject]@{ id = 'current'; state = if ($runtimeVersion) { 'PRESENT' } else { 'UNKNOWN' }; status = if ($runtimeVersion) { 'OK' } else { 'VERSION_UNAVAILABLE' }; version = $runtimeVersion; path = $runtimePath }
    foreach ($name in @('pwsh', 'powershell.exe')) {
        $entry = Get-MHGPVersionEntry -Name $name -Arguments @('-NoProfile', '-NonInteractive', '-Command', '$PSVersionTable.PSVersion.ToString()') -Context $Context
        if (-not (@($versions | Where-Object path -eq $entry.path | Where-Object { $_.path }).Count -gt 0)) { $versions += $entry }
    }

    $moduleResult = Get-MHGPModules -Context $Context
    if ($moduleResult.warning) { $warnings += $moduleResult.warning }
    $repositoryResult = Get-MHGPRepositories -Context $Context
    if ($repositoryResult.warning) { $warnings += $repositoryResult.warning }
    $policyResult = Get-MHGPExecutionPolicies
    if ($policyResult.warning) { $warnings += $policyResult.warning }
    $profiles = @(Get-MHGPProfileDescriptors -Context $Context)
    $promptTools = @()
    foreach ($tool in @('oh-my-posh', 'starship', 'fzf', 'zoxide', 'gitui')) {
        $path = Get-MHGPCommandPath -Name $tool
        $promptTools += [pscustomobject]@{ id = $tool; state = if ($path) { 'PRESENT' } else { 'ABSENT' }; path = $path; detection = 'COMMAND_METADATA_ONLY' }
    }
    $poshGit = @($moduleResult.items | Where-Object { $_.name -ieq 'posh-git' } | Select-Object -First 1)
    $promptTools += [pscustomobject]@{ id = 'posh-git'; state = if ($poshGit.Count -gt 0) { 'PRESENT' } else { 'ABSENT' }; path = if ($poshGit.Count -gt 0) { $poshGit[0].path } else { $null }; detection = 'MODULE_METADATA_ONLY' }

    $shellState = if ($runtimeVersion) { 'PRESENT' } else { 'UNKNOWN' }
    return [pscustomobject]@{
        item = [pscustomobject]@{
            id = 'shell:powershell'
            state = $shellState
            versions = @($versions)
            modules = @($moduleResult.items)
            repositories = @($repositoryResult.items)
            executionPolicies = @($policyResult.items)
            profiles = @($profiles)
            promptTools = @($promptTools)
            currentVersion = $runtimeVersion
            restorePolicy = 'REVIEW'
        }
        profiles = @($profiles)
        warnings = @($warnings | Where-Object { $_ } | Sort-Object -Unique)
    }
}

function Get-MHGPArtifactRecord {
    param($ArtifactResult)

    return Get-MHGPContextValue -Context $ArtifactResult -Names @('artifact') -Default $ArtifactResult
}

function Set-MHGPArtifactMetadata {
    param(
        [Parameter(Mandatory)]$Target,
        [Parameter(Mandatory)]$ArtifactResult
    )

    $record = Get-MHGPArtifactRecord -ArtifactResult $ArtifactResult
    if ($null -eq $record) { return }
    foreach ($name in @('contentPolicy', 'captureState', 'redactionStatus', 'artifactPath', 'artifactSha256', 'errorCode', 'validationStrategy')) {
        $value = Get-MHGPContextValue -Context $record -Names @($name)
        $Target | Add-Member -NotePropertyName $name -NotePropertyValue $value -Force
    }
    $captureState = [string](Get-MHGPContextValue -Context $record -Names @('captureState'))
    $Target | Add-Member -NotePropertyName migrationAction -NotePropertyValue $(if ($captureState -eq 'CAPTURED') { 'RESTORE_REVIEW' } else { 'MANUAL_TRANSFER' }) -Force
}

function Get-MHGitPowerShellCollection {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Context)

    try {
        $userHomePath = Get-MHGPHome -Context $Context
        $git = Get-MHGPGitSummary -Context $Context -UserHome $userHomePath
        $shell = Get-MHGPowershellSummary -Context $Context
        $artifacts = @()
        $artifacts += Get-MHGPConfigArtifacts -Context $Context -ConfigPaths $git.configPaths -SystemConfigPaths $git.systemConfigPaths -GlobalIgnore $git.item.globalIgnore
        $artifacts += Get-MHGPProfileArtifacts -Context $Context -Profiles $shell.profiles
        $gitArtifacts = @()
        $shellArtifacts = @()
        foreach ($artifactResult in @($artifacts)) {
            $artifactRecord = Get-MHGPContextValue -Context $artifactResult -Names @('artifact') -Default $artifactResult
            $artifactDomain = [string](Get-MHGPContextValue -Context $artifactRecord -Names @('domain'))
            if ($artifactDomain -eq 'git') { $gitArtifacts += $artifactResult }
            elseif ($artifactDomain -eq 'shell') { $shellArtifacts += $artifactResult }
        }
        foreach ($profile in @($shell.item.profiles)) {
            $profileArtifact = @($shellArtifacts | Where-Object {
                $record = Get-MHGPArtifactRecord -ArtifactResult $_
                [string](Get-MHGPContextValue -Context $record -Names @('id')) -eq [string]$profile.id
            } | Select-Object -First 1)
            if ($profileArtifact.Count -gt 0) { Set-MHGPArtifactMetadata -Target $profile -ArtifactResult $profileArtifact[0] }
        }
        $ignoreArtifact = @($gitArtifacts | Where-Object {
            $record = Get-MHGPArtifactRecord -ArtifactResult $_
            [string](Get-MHGPContextValue -Context $record -Names @('id')) -eq 'git:global-ignore'
        } | Select-Object -First 1)
        if ($ignoreArtifact.Count -gt 0) { Set-MHGPArtifactMetadata -Target $git.item.globalIgnore -ArtifactResult $ignoreArtifact[0] }
        $git.item | Add-Member -NotePropertyName configArtifacts -NotePropertyValue @($gitArtifacts) -Force
        $shell.item | Add-Member -NotePropertyName configArtifacts -NotePropertyValue @($shellArtifacts) -Force
        $warnings = @($git.warnings) + @($shell.warnings)
        $status = if ($warnings.Count -gt 0) { 'PARTIAL' } elseif ($git.item.state -eq 'UNKNOWN' -and $shell.item.state -eq 'UNKNOWN') { 'UNAVAILABLE' } else { 'OK' }
        $items = @($git.item, $shell.item)

        $domainCommand = Get-Command -Name New-MHDomainResult -CommandType Function -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($domainCommand) {
            return & $domainCommand -Domain 'git-powershell' -Status $status -Items $items -Warnings @($warnings | Sort-Object -Unique) -Provenance 'READ_ONLY_LOCAL_QUERY' -ConfigArtifacts @($artifacts)
        }
        return [pscustomobject]@{
            domain = 'git-powershell'; status = $status; items = $items; warnings = @($warnings | Sort-Object -Unique)
            errorCode = $null; provenance = 'READ_ONLY_LOCAL_QUERY'; collectedAt = [DateTimeOffset]::Now.ToString('o'); configArtifacts = @($artifacts)
        }
    } catch {
        $domainCommand = Get-Command -Name New-MHDomainResult -CommandType Function -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($domainCommand) {
            return & $domainCommand -Domain 'git-powershell' -Status 'ERROR' -Items @() -Warnings @('GIT_POWERSHELL_COLLECTION_FAILED') -ErrorCode 'GIT_POWERSHELL_COLLECTION_FAILED' -Provenance 'READ_ONLY_LOCAL_QUERY' -ConfigArtifacts @()
        }
        return [pscustomobject]@{ domain = 'git-powershell'; status = 'ERROR'; items = @(); warnings = @('GIT_POWERSHELL_COLLECTION_FAILED'); errorCode = 'GIT_POWERSHELL_COLLECTION_FAILED'; provenance = 'READ_ONLY_LOCAL_QUERY'; collectedAt = [DateTimeOffset]::Now.ToString('o'); configArtifacts = @() }
    }
}
