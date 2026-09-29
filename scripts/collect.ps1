Set-StrictMode -Version Latest

$script:MHPathVariables = @('CARGO_HOME', 'DOTNET_ROOT', 'DOTNET_ROOT_X64', 'GOPATH', 'GOROOT', 'JAVA_HOME', 'NVM_HOME', 'PNPM_HOME', 'PYTHONHOME', 'RUSTUP_HOME', 'VIRTUAL_ENV')
$script:MHSecretName = '(?i)(API[_-]?KEY|TOKEN|SECRET|PASSWORD|PASSWD|COOKIE|CREDENTIAL|AUTHORIZATION|BITLOCKER|PRIVATE[_-]?KEY)'
$script:MHSecretValue = @(
    '(?i)["'']?(?:api[ _-]?key|access[ _-]?token|refresh[ _-]?token|password|passwd|pwd|username|user[ _-]?id|uid|client_secret|authorization|cookie|private[ _-]?key|bitlocker[ _-]?key)\s*["'']?\s*[:=]\s*["'']?[^"''\s,;\}\]]+',
    '(?i)\bbearer\s+[A-Za-z0-9._~+/-]{12,}',
    '(?i)://[^/\s:@]+:[^/\s@]+@',
    '\b(?:gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|AKIA[0-9A-Z]{16})\b',
    '\beyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\b',
    '-----BEGIN [A-Z ]*PRIVATE KEY-----'
)

function Test-MHSecretName {
    param([Parameter(Mandatory)][string]$Name)
    return $Name -match $script:MHSecretName
}

function Test-MHSecretText {
    param([AllowNull()][string]$Text)
    if ($null -eq $Text) { return $false }
    foreach ($pattern in $script:MHSecretValue) {
        if ($Text -match $pattern) { return $true }
    }
    return $false
}

function ConvertTo-MHSafePath {
    param([AllowNull()][string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path) -or (Test-MHSecretText -Text $Path)) { return $null }
    $safePath = $Path.Trim()
    if ($safePath.Length -gt 1024) { return $null }
    if ($safePath -match '^[A-Za-z]:\\$') { return $safePath }
    return $safePath.TrimEnd('\')
}

function Get-MHVersionFact {
    param([string]$Name, [string[]]$Arguments = @('--version'), [string]$VersionPattern = '(?i)(?<![\w])v?\d+(?:\.\d+){1,3}(?:[-+][\w.-]+)?', $Context)
    $result = Invoke-MHSafeProcess -Name $Name -Arguments $Arguments -Context $Context
    if (-not $result.found) { return [pscustomobject]@{ id = $Name; state = 'ABSENT'; status = 'NOT_FOUND'; version = $null; path = $null } }
    if ($result.timedOut) { return [pscustomobject]@{ id = $Name; state = 'UNKNOWN'; status = 'TIMEOUT'; version = $null; path = $null } }
    if ($result.errorCode) { return [pscustomobject]@{ id = $Name; state = 'UNKNOWN'; status = $result.errorCode; version = $null; path = $null } }

    $version = $null
    if ($result.exitCode -eq 0 -and $result.stdout -match $VersionPattern) { $version = $Matches[0] }
    $cmd = Get-Command -Name $Name -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    $path = if ($cmd) { ConvertTo-MHSafePath -Path $cmd.Source } else { $null }
    $state = if ($null -ne $version) { 'PRESENT' } else { 'UNKNOWN' }
    $status = if ($version) { 'OK' } else { 'VERSION_UNAVAILABLE' }
    return [pscustomobject]@{ id = $Name; state = $state; status = $status; version = $version; path = $path }
}

function Get-MHSystemFacts {
    $productName = $null
    $build = [Environment]::OSVersion.Version.Build
    try {
        $os = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction Stop
        if (-not (Test-MHSecretText -Text ([string]$os.ProductName))) { $productName = [string]$os.ProductName }
        if ($os.CurrentBuildNumber -match '^\d{1,8}$') { $build = [int]$os.CurrentBuildNumber }
    } catch { }

    $volumes = @()
    try {
        foreach ($drive in [System.IO.DriveInfo]::GetDrives()) {
            if ($drive.DriveType -eq [System.IO.DriveType]::Fixed) {
                $volumes += [pscustomobject]@{ name = $drive.Name; ready = [bool]$drive.IsReady }
            }
        }
    } catch { }

    $settings = [ordered]@{}
    $checks = @(
        @{ id = 'longPathsEnabled'; path = 'HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem'; name = 'LongPathsEnabled' },
        @{ id = 'developerMode'; path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\AppModelUnlock'; name = 'AllowDevelopmentWithoutDevLicense' }
    )
    foreach ($check in $checks) {
        try {
            $value = (Get-ItemProperty -LiteralPath $check.path -Name $check.name -ErrorAction Stop).($check.name)
            $settings[$check.id] = [pscustomobject]@{ state = 'PRESENT'; value = [int]$value }
        } catch { $settings[$check.id] = [pscustomobject]@{ state = 'UNKNOWN'; value = $null } }
    }

    return [pscustomobject]@{
        id = 'system'
        state = 'PRESENT'
        computerLabel = [Environment]::MachineName
        userProfile = ConvertTo-MHSafePath -Path $env:USERPROFILE
        windows = [pscustomobject]@{ productName = $productName; version = [Environment]::OSVersion.Version.ToString(); build = $build; is64Bit = [Environment]::Is64BitOperatingSystem }
        volumes = @($volumes)
        settings = $settings
    }
}

function Get-MHEnvironmentFacts {
    $scopes = @(
        [pscustomobject]@{ name = 'USER'; registryPath = 'HKCU:\Environment' },
        [pscustomobject]@{ name = 'MACHINE'; registryPath = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Environment' }
    )
    $variables = @()
    $pathScopes = [ordered]@{}
    foreach ($scope in $scopes) {
        $scopeName = $scope.name
        try { $registryKey = Get-Item -LiteralPath $scope.registryPath -ErrorAction Stop; $names = @($registryKey.GetValueNames()) } catch { $registryKey = $null; $names = @() }
        foreach ($name in @($names | Sort-Object)) {
            $nameText = [string]$name
            if ([string]::IsNullOrWhiteSpace($nameText)) { continue }
            $isSecret = Test-MHSecretName -Name $nameText
            $safeValue = $null
            if (-not $isSecret -and $script:MHPathVariables -contains $nameText.ToUpperInvariant() -and $registryKey) {
                try {
                    $candidate = [string]$registryKey.GetValue($nameText, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
                    if ($candidate -and -not (Test-MHSecretText -Text $candidate) -and ($candidate -match '^(?:[A-Za-z]:\\|\\\\|%[A-Za-z_][A-Za-z0-9_]*%\\)')) { $safeValue = $candidate }
                } catch { }
            }
            $variables += [pscustomobject]@{ scope = $scopeName; name = $nameText; present = $true; value = $safeValue; isSecret = $isSecret }
        }

        $pathValue = $null
        if ($registryKey -and @($names | Where-Object { $_ -ieq 'Path' }).Count -gt 0) {
            try { $pathValue = [string]$registryKey.GetValue('Path', $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames) } catch { }
        }
        $segments = @()
        foreach ($segment in @(([string]$pathValue) -split ';')) {
            $candidate = $segment.Trim()
            if ($candidate -and $candidate.Length -le 1024 -and -not (Test-MHSecretText -Text $candidate) -and $candidate -match '^(?:[A-Za-z]:\\|\\\\|%[A-Za-z_][A-Za-z0-9_]*%\\)') { $segments += $candidate.TrimEnd('\') }
        }
        $pathScopes[$scopeName] = @($segments)
    }
    return [pscustomobject]@{ id = 'env'; state = 'PRESENT'; variables = @($variables); path = $pathScopes }
}

function Get-MHUninstallFacts {
    $entries = @()
    $registryRoots = @(
        'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    foreach ($root in $registryRoots) {
        try {
            foreach ($app in @(Get-ItemProperty -Path $root -ErrorAction SilentlyContinue)) {
                $name = [string]$app.DisplayName
                if ([string]::IsNullOrWhiteSpace($name) -or (Test-MHSecretText -Text $name)) { continue }
                $key = [string]$app.PSChildName
                if ([string]::IsNullOrWhiteSpace($key)) { $key = $name }
                $version = [string]$app.DisplayVersion
                $location = ConvertTo-MHSafePath -Path ([string]$app.InstallLocation)
                $entries += [pscustomobject]@{ id = ('arp:' + $key); name = $name; version = $version; source = 'UNINSTALL_REGISTRY'; category = 'UNMATCHED_CANDIDATE'; state = 'PRESENT'; installLocation = $location; restorePolicy = 'REVIEW' }
            }
        } catch { }
    }
    return @($entries | Sort-Object id -Unique)
}

function Get-MHWingetFacts {
    param([switch]$SafeMode, $Context)
    $winget = Get-Command -Name 'winget.exe' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $winget) { return [pscustomobject]@{ state = 'ABSENT'; status = 'NOT_FOUND'; packages = @() } }
    if ($SafeMode) { return [pscustomobject]@{ state = 'PRESENT'; status = 'NOT_TESTED'; packages = @() } }

    $tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('machine-handoff-' + [guid]::NewGuid().ToString('N'))
    $manifestPath = Join-Path $tempRoot 'winget-export.json'
    try {
        [void](New-Item -ItemType Directory -Path $tempRoot -ErrorAction Stop)
        $result = Invoke-MHSafeProcess -Name 'winget.exe' -Arguments @('export', '--output', $manifestPath, '--disable-interactivity') -TimeoutMilliseconds 30000 -Context $Context
        if (-not $result.found -or $result.timedOut -or $result.errorCode -or $result.exitCode -ne 0 -or -not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
            return [pscustomobject]@{ state = 'PRESENT'; status = 'EXPORT_UNAVAILABLE'; packages = @() }
        }
        $maxExportBytes = [long](Get-MHField -Object (Get-MHField -Object $Context -Name 'budgets') -Name 'maxPackageBytes' -Default 10485760)
        $manifestText = Read-MHBoundedUtf8Text -Path $manifestPath -MaxBytes $maxExportBytes
        $data = ConvertFrom-Json -InputObject $manifestText -ErrorAction Stop
        $packages = @()
        foreach ($package in @($data.Packages)) {
            $id = [string]$package.PackageIdentifier
            if ($id -notmatch '^[A-Za-z0-9_.+-]{2,160}$') { continue }
            $packages += [pscustomobject]@{ id = ('winget:' + $id); name = $id; packageId = $id; version = [string]$package.Version; source = 'WINGET'; category = 'WINGET'; state = 'PRESENT'; restorePolicy = 'REVIEW' }
        }
        return [pscustomobject]@{ state = 'PRESENT'; status = 'OK'; packages = @($packages) }
    } catch {
        return [pscustomobject]@{ state = 'PRESENT'; status = 'EXPORT_UNAVAILABLE'; packages = @() }
    } finally {
        if ((Test-Path -LiteralPath $tempRoot -PathType Container) -and $tempRoot.StartsWith([IO.Path]::GetFullPath([IO.Path]::GetTempPath()), [StringComparison]::OrdinalIgnoreCase)) {
            Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

function Get-MHSoftwareFacts {
    param([switch]$SafeMode, [string[]]$Roots = @(), $Context)
    $arp = @(Get-MHUninstallFacts)
    $winget = Get-MHWingetFacts -SafeMode:$SafeMode -Context $Context
    $packages = @($arp + @($winget.packages) | Sort-Object id -Unique)
    foreach ($root in $Roots) {
        if ((Split-Path -Leaf $root) -notmatch '(?i)^(PortableApps|Portable|Apps)$') { continue }
        try {
            foreach ($file in [IO.Directory]::EnumerateFiles($root, '*.exe', [IO.SearchOption]::TopDirectoryOnly)) {
                $name = [IO.Path]::GetFileNameWithoutExtension($file)
                $safePath = ConvertTo-MHSafePath -Path $file
                if ($name -and $safePath -and -not (Test-MHSecretText -Text $name)) {
                    $packages += [pscustomobject]@{ id = 'portable:' + $safePath.ToLowerInvariant(); name = $name; version = $null; source = 'PORTABLE_CANDIDATE'; category = 'PORTABLE_CANDIDATE'; state = 'PRESENT'; installLocation = $safePath; restorePolicy = 'REVIEW' }
                }
            }
        } catch { }
    }
    return [pscustomobject]@{ id = 'software'; state = 'PRESENT'; wingetStatus = $winget.status; packages = $packages }
}

function Get-MHDevFacts {
    param($Context)
    $tools = @(
        @{ name = 'git'; args = @('--version') }, @{ name = 'node'; args = @('--version') },
        @{ name = 'npm'; args = @('--version') }, @{ name = 'pnpm'; args = @('--version') },
        @{ name = 'yarn'; args = @('--version') }, @{ name = 'bun'; args = @('--version') },
        @{ name = 'python'; args = @('--version') }, @{ name = 'py'; args = @('--version') },
        @{ name = 'pip'; args = @('--version') }, @{ name = 'pipx'; args = @('--version') },
        @{ name = 'uv'; args = @('--version') }, @{ name = 'dotnet'; args = @('--version') },
        @{ name = 'java'; args = @('-version') }, @{ name = 'rustc'; args = @('--version') },
        @{ name = 'cargo'; args = @('--version') }, @{ name = 'go'; args = @('version') },
        @{ name = 'cmake'; args = @('--version') }, @{ name = 'pwsh'; args = @('--version') }
    )
    $items = @()
    foreach ($tool in $tools) { $items += Get-MHVersionFact -Name $tool.name -Arguments $tool.args -Context $Context }
    $items += [pscustomobject]@{ id = 'powershell'; state = 'PRESENT'; status = 'OK'; version = $PSVersionTable.PSVersion.ToString(); path = (Get-Process -Id $PID).Path }
    return @($items)
}

function Get-MHShellFacts {
    param($Context)
    $terminalSettings = Join-Path $env:LOCALAPPDATA 'Packages\Microsoft.WindowsTerminal_8wekyb3d8bbwe\LocalState\settings.json'
    $profile = $PROFILE.CurrentUserAllHosts
    $facts = @(
        [pscustomobject]@{ id = 'windows-terminal-settings'; state = $(if (Test-Path -LiteralPath $terminalSettings) { 'PRESENT' } else { 'ABSENT' }); path = (ConvertTo-MHSafePath -Path $terminalSettings) },
        [pscustomobject]@{ id = 'powershell-profile'; state = $(if (Test-Path -LiteralPath $profile) { 'PRESENT' } else { 'ABSENT' }); path = (ConvertTo-MHSafePath -Path $profile) }
    )
    $command = Get-MHVersionFact -Name 'wt.exe' -Arguments @('--version') -Context $Context
    return [pscustomobject]@{ id = 'shell'; state = 'PRESENT'; currentPowerShell = $PSVersionTable.PSVersion.ToString(); terminal = $command; config = $facts }
}

function Get-MHEditorFacts {
    param($Context)
    $items = @()
    $definitions = @(
        @{ id = 'vscode'; commands = @('code.exe', 'code.cmd', 'code'); extensionPath = (Join-Path $env:USERPROFILE '.vscode\extensions'); userPath = (Join-Path $env:APPDATA 'Code\User') },
        @{ id = 'cursor'; commands = @('cursor.exe', 'cursor.cmd', 'cursor'); extensionPath = (Join-Path $env:USERPROFILE '.cursor\extensions'); userPath = (Join-Path $env:APPDATA 'Cursor\User') }
    )
    foreach ($definition in $definitions) {
        $command = $null
        foreach ($name in $definition.commands) {
            $command = Get-Command -Name $name -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($command) { break }
        }
        $extensions = @()
        if (Test-Path -LiteralPath $definition.extensionPath -PathType Container) {
            try {
                foreach ($extension in [IO.Directory]::EnumerateDirectories($definition.extensionPath)) {
                    $extensionName = [IO.Path]::GetFileName($extension)
                    if ($extensionName -match '^[A-Za-z0-9._+-]{2,160}$' -and -not (Test-MHSecretText -Text $extensionName)) { $extensions += $extensionName }
                }
            } catch { }
        }
        $configFiles = @()
        $profiles = @()
        foreach ($relative in @('settings.json', 'keybindings.json', 'snippets')) {
            $candidate = Join-Path $definition.userPath $relative
            if (Test-Path -LiteralPath $candidate) { $configFiles += [pscustomobject]@{ name = $relative; path = ConvertTo-MHSafePath -Path $candidate; state = 'PRESENT'; enablement = 'UNKNOWN' } }
        }
        $profileRoot = Join-Path $definition.userPath 'profiles'
        if (Test-Path -LiteralPath $profileRoot -PathType Container) {
            try { foreach ($profile in [IO.Directory]::EnumerateDirectories($profileRoot)) { $profiles += [pscustomobject]@{ name = [IO.Path]::GetFileName($profile); path = ConvertTo-MHSafePath -Path $profile; state = 'PRESENT' } } } catch { }
        }
        $configPresent = (Test-Path -LiteralPath $definition.userPath -PathType Container) -or (Test-Path -LiteralPath $definition.extensionPath -PathType Container)
        $items += [pscustomobject]@{ id = 'editor:' + $definition.id; state = $(if ($command) { 'PRESENT' } elseif ($configPresent) { 'UNKNOWN' } else { 'ABSENT' }); status = $(if ($command) { 'FOUND' } elseif ($configPresent) { 'CONFIG_ONLY' } else { 'NOT_FOUND' }); path = $(if ($command) { ConvertTo-MHSafePath -Path $command.Source } else { $null }); extensions = @($extensions | Sort-Object -Unique); extensionRoot = $(if (Test-Path -LiteralPath $definition.extensionPath -PathType Container) { ConvertTo-MHSafePath -Path $definition.extensionPath } else { $null }); configFiles = @($configFiles); profiles = @($profiles); launchStatus = 'NOT_TESTED' }
    }
    foreach ($name in @('devenv.exe', 'idea64.exe', 'pycharm64.exe', 'rider64.exe')) {
        $command = Get-Command -Name $name -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        $items += [pscustomobject]@{ id = 'editor:' + $name; state = $(if ($command) { 'PRESENT' } else { 'ABSENT' }); status = $(if ($command) { 'FOUND' } else { 'NOT_FOUND' }); path = $(if ($command) { ConvertTo-MHSafePath -Path $command.Source } else { $null }); extensions = @(); configFiles = @(); profiles = @(); launchStatus = 'NOT_TESTED' }
    }
    return @($items)
}

function Get-MHAgentFacts {
    param([string]$UserHome = $env:USERPROFILE)
    $definitions = @(
        @{ id = 'codex'; commands = @('codex'); paths = @((Join-Path $UserHome '.codex'), (Join-Path $UserHome '.agents\skills')); subdirs = @('skills', 'rules', 'plugins', 'hooks') },
        @{ id = 'claude-code'; commands = @('claude'); paths = @((Join-Path $UserHome '.claude')); subdirs = @('skills', 'rules', 'hooks', 'plugins') },
        @{ id = 'gemini-cli'; commands = @('gemini'); paths = @((Join-Path $UserHome '.gemini')); subdirs = @('skills', 'rules', 'extensions') },
        @{ id = 'opencode'; commands = @('opencode'); paths = @((Join-Path $UserHome '.config\opencode'), (Join-Path $UserHome '.opencode')); subdirs = @('skills', 'plugins') },
        @{ id = 'cursor-agent'; commands = @('cursor-agent', 'cursor'); paths = @((Join-Path $env:APPDATA 'Cursor\User'), (Join-Path $UserHome '.cursor')); subdirs = @('skills', 'rules', 'hooks', 'plugins') }
    )
    $items = @()
    foreach ($definition in $definitions) {
        $presentPaths = @($definition.paths | Where-Object { Test-Path -LiteralPath $_ -PathType Container } | ForEach-Object { ConvertTo-MHSafePath -Path $_ })
        $cli = $null
        foreach ($commandName in $definition.commands) {
            $cli = Get-Command -Name $commandName -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($cli) { break }
        }
        $state = if ($presentPaths.Count -gt 0 -or $cli) { 'PRESENT' } else { 'ABSENT' }
        $items += [pscustomobject]@{ id = 'agent:' + $definition.id; state = $state; configPaths = @($presentPaths); cliName = $(if ($cli) { $cli.Name } else { $null }); cliStatus = $(if ($cli) { 'FOUND' } else { 'NOT_FOUND' }); cliPath = $(if ($cli -and $cli.Source) { ConvertTo-MHSafePath -Path $cli.Source } else { $null }); terminalIntegration = 'UNKNOWN'; auth = 'REAUTHENTICATE' }
    }
    $knownFiles = @('AGENTS.md', 'CLAUDE.md', 'GEMINI.md', 'config.toml', 'settings.json', 'mcp.json', 'hooks.json', 'permissions.json')
    $configManifest = @()
    foreach ($definition in $definitions) {
        foreach ($root in $definition.paths) {
            foreach ($name in $knownFiles) {
                $candidate = Join-Path $root $name
                if (Test-Path -LiteralPath $candidate -PathType Leaf) { $configManifest += [pscustomobject]@{ agent = $definition.id; name = $name; path = ConvertTo-MHSafePath -Path $candidate; state = 'PRESENT'; enablement = 'UNKNOWN' } }
            }
        }
        foreach ($base in $definition.paths) {
            foreach ($subdir in $definition.subdirs) {
                $candidateDir = Join-Path $base $subdir
                if (Test-Path -LiteralPath $candidateDir -PathType Container) { $configManifest += [pscustomobject]@{ agent = $definition.id; name = $subdir.ToUpperInvariant(); path = ConvertTo-MHSafePath -Path $candidateDir; state = 'PRESENT'; enablement = 'UNKNOWN' } }
            }
        }
    }
    $skillRoots = @(
        @{ agent = 'codex'; path = (Join-Path $UserHome '.agents\skills') },
        @{ agent = 'codex'; path = (Join-Path $UserHome '.codex\skills') },
        @{ agent = 'claude-code'; path = (Join-Path $UserHome '.claude\skills') },
        @{ agent = 'gemini-cli'; path = (Join-Path $UserHome '.gemini\skills') },
        @{ agent = 'opencode'; path = (Join-Path $UserHome '.config\opencode\skills') },
        @{ agent = 'cursor-agent'; path = (Join-Path $UserHome '.cursor\skills') }
    )
    foreach ($skillRoot in $skillRoots) {
        if (-not (Test-Path -LiteralPath $skillRoot.path -PathType Container)) { continue }
        try {
            foreach ($skillDir in [IO.Directory]::EnumerateDirectories($skillRoot.path)) {
                $name = [IO.Path]::GetFileName($skillDir)
                if ($name -eq '.system' -or $name -match '[\r\n]') { continue }
                $configManifest += [pscustomobject]@{ agent = $skillRoot.agent; name = 'SKILL:' + $name; path = ConvertTo-MHSafePath -Path $skillDir; state = 'PRESENT'; enablement = 'UNKNOWN' }
            }
        } catch { }
    }
    $additionalConfigs = @(
        @{ agent = 'claude-code'; name = 'CLAUDE_GLOBAL_CONFIG'; path = (Join-Path $UserHome '.claude.json') },
        @{ agent = 'cursor-agent'; name = 'CURSOR_RULES'; path = (Join-Path $UserHome '.cursorrules') }
    )
    foreach ($candidate in $additionalConfigs) {
        if (Test-Path -LiteralPath $candidate.path -PathType Leaf) { $configManifest += [pscustomobject]@{ agent = $candidate.agent; name = $candidate.name; path = ConvertTo-MHSafePath -Path $candidate.path; state = 'PRESENT'; enablement = 'UNKNOWN' } }
    }
    return [pscustomobject]@{ id = 'agents'; state = 'PRESENT'; items = @($items); configFiles = @($configManifest) }
}

function ConvertTo-MHSafeWslSettings {
    param([string]$Text)
    $section = ''
    $settings = @()
    foreach ($line in @($Text -split "`r?`n")) {
        if ($line -match '^\s*\[(?<section>[A-Za-z]+)\]\s*(?:[#;].*)?$') { $section = $Matches.section.ToLowerInvariant(); continue }
        if ($line -notmatch '^\s*(?<key>[A-Za-z]+)\s*=\s*(?<value>[^#;]+?)\s*(?:[#;].*)?$') { continue }
        $key = $Matches.key.ToLowerInvariant()
        $value = $Matches.value.Trim().Trim('"').Trim("'")
        $settingName = $null
        $safeValue = $null
        if ($section -in @('automount', 'interop', 'network') -and $key -in @('enabled', 'appendwindowspath', 'generateresolvconf', 'generatehosts') -and $value -match '(?i)^(true|false)$') {
            $settingName = $section + '.' + $key
            $safeValue = $value.ToLowerInvariant()
        } elseif ($section -eq 'automount' -and $key -eq 'root' -and $value -match '^/[A-Za-z0-9_./-]{1,160}$' -and $value -notmatch '\.\.') {
            $settingName = 'automount.root'
            $safeValue = $value
        } elseif ($section -eq 'automount' -and $key -eq 'options' -and $value -match '^(?:metadata|umask=[0-7]{3,4}|fmask=[0-7]{3,4}|dmask=[0-7]{3,4}|case=dir)(?:,(?:metadata|umask=[0-7]{3,4}|fmask=[0-7]{3,4}|dmask=[0-7]{3,4}|case=dir))*$') {
            $settingName = 'automount.options'
            $safeValue = $value
        }
        if ($settingName -and -not (Test-MHSecretText -Text $safeValue)) { $settings += [pscustomobject]@{ name = $settingName; value = $safeValue } }
    }
    return @($settings)
}

function Get-MHWslFacts {
    param([switch]$SafeMode, $Context)
    $wsl = Get-Command -Name 'wsl.exe' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    $wslProfile = [string](Get-MHField -Object $Context -Name 'userProfile' -Default $env:USERPROFILE)
    $isUncProfile = $wslProfile.StartsWith('\\', [StringComparison]::Ordinal)
    $configPath = if ($wslProfile -and -not $isUncProfile) { Join-Path $wslProfile '.wslconfig' } else { $null }
    $configState = if ($isUncProfile) { 'UNKNOWN' } else { 'ABSENT' }
    $safeSettings = @()
    if ($configPath -and (Test-Path -LiteralPath $configPath -PathType Leaf)) {
        $allowed = 'memory|processors|swap|localhostForwarding|dnsTunneling|networkingMode|guiApplications'
        try {
            [void](Assert-MHNoReparseAncestors -Path $configPath)
            $configFile = Get-Item -LiteralPath $configPath -Force -ErrorAction Stop
            if (($configFile.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'PATH_REPARSE_BLOCKED' }
            $maxConfigBytes = [long](Get-MHField -Object $Context.budgets -Name 'maxConfigBytes' -Default 262144)
            if ([long]$configFile.Length -gt $maxConfigBytes) { throw 'CONFIG_SIZE_LIMIT' }
            $configText = Read-MHBoundedUtf8Text -Path $configPath -MaxBytes $maxConfigBytes
            foreach ($line in ($configText -split "`r?`n")) {
                if ($line -match "^\s*(?<key>$allowed)\s*=\s*(?<value>[^;#\s]+)\s*$") {
                    $settingName = $Matches.key
                    $settingValue = $Matches.value
                    if ($settingValue -match '(?i)^(?:true|false|\d+(?:\.\d+)?(?:KB?|MB?|GB?)?|nat|mirrored|virtioproxy)$') {
                        $safeSettings += [pscustomobject]@{ name = $settingName; value = $settingValue }
                    }
                }
            }
            $configState = 'PRESENT'
        } catch { $safeSettings = @(); $configState = 'UNKNOWN' }
    }
    $hasConfig = $configState -ne 'ABSENT'
    $globalConfig = [pscustomobject]@{ id = 'wsl:global-config'; name = '.wslconfig'; state = $(if ($configState -eq 'ABSENT') { 'ABSENT' } elseif ($configState -eq 'PRESENT') { 'PRESENT' } else { 'UNKNOWN' }); version = $null; running = $null; configPath = $(if ($hasConfig) { ConvertTo-MHSafePath -Path $configPath } else { $null }); configState = $configState; safeSettings = @($safeSettings); restorePolicy = 'REVIEW' }
    if (-not $wsl) { return [pscustomobject]@{ id = 'wsl'; state = 'ABSENT'; status = 'NOT_FOUND'; configPath = $globalConfig.configPath; configState = $globalConfig.configState; safeSettings = @($safeSettings); items = @($globalConfig) } }
    if ($SafeMode) { return [pscustomobject]@{ id = 'wsl'; state = 'PRESENT'; status = 'NOT_TESTED'; configPath = $globalConfig.configPath; configState = $globalConfig.configState; safeSettings = @($safeSettings); items = @($globalConfig) } }
    $verboseResult = Invoke-MHSafeProcess -Name 'wsl.exe' -Arguments @('--list', '--verbose') -TimeoutMilliseconds 10000 -Context $Context
    $quietResult = Invoke-MHSafeProcess -Name 'wsl.exe' -Arguments @('--list', '--quiet') -TimeoutMilliseconds 10000 -Context $Context
    $verboseReady = -not $verboseResult.errorCode -and -not $verboseResult.timedOut -and $verboseResult.exitCode -eq 0
    $quietReady = -not $quietResult.errorCode -and -not $quietResult.timedOut -and $quietResult.exitCode -eq 0
    if (-not $verboseReady -and -not $quietReady) {
        $globalConfig.configState = 'UNKNOWN'
        return [pscustomobject]@{ id = 'wsl'; state = 'UNKNOWN'; status = 'LIST_UNAVAILABLE'; configPath = $globalConfig.configPath; configState = $globalConfig.configState; safeSettings = @($safeSettings); items = @($globalConfig) }
    }
    $partial = -not $verboseReady -or -not $quietReady
    $verboseLines = @()
    if ($verboseReady) { $verboseLines = @(($verboseResult.stdout -replace "`0", '') -split "`r?`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ }) }
    $verboseNames = @()
    foreach ($line in $verboseLines) {
        if ($line -match '^\*?\s*(?<name>[^\s]+)\s+.+\s+[12]\s*$' -and $Matches.name -notmatch '^(?i:NAME)$' -and $Matches.name -ne '名称') { $verboseNames += $Matches.name }
    }
    $names = @()
    if ($quietReady) {
        $names = @(($quietResult.stdout -replace "`0", '') -split "`r?`n" | ForEach-Object { ($_ -replace '^\*\s*', '').Trim() } | Where-Object { $_ -and $_ -notmatch '^(?i:NAME)$' -and $_ -notmatch '^名称$' })
        if ($names.Count -eq 0 -and $verboseNames.Count -gt 0) { $names = $verboseNames; $partial = $true }
        if ($verboseReady -and @($verboseNames | Where-Object { $names -notcontains $_ }).Count -gt 0) { $partial = $true }
    } elseif ($verboseReady) {
        $names = $verboseNames
    }
    $names = @($names | Sort-Object -Unique)
    $distributions = @()
    foreach ($name in $names) {
        if (Test-MHSecretText -Text $name) { $partial = $true; continue }
        $isRunning = $null
        $distributionVersion = $null
        $configState = 'UNKNOWN'
        $configSettings = @()
        $matchingLine = @($verboseLines | Where-Object { $_ -match ('^\*?\s*' + [regex]::Escape($name) + '\s+(?<state>.+?)\s+(?<version>[12])\s*$') } | Select-Object -First 1)
        if ($matchingLine.Count -gt 0) {
            $line = [string]$matchingLine[0]
            $null = $line -match ('^\*?\s*' + [regex]::Escape($name) + '\s+(?<state>.+?)\s+(?<version>[12])\s*$')
            $stateText = $Matches.state.Trim()
            $distributionVersion = [int]$Matches.version
            if ($stateText -match '(?i)^(Running|正在运行|运行中)$') { $isRunning = $true }
            elseif ($stateText -match '(?i)^(Stopped|已停止|未运行)$') { $isRunning = $false }
            else { $partial = $true }
        } else { $partial = $true }
        if ($isRunning -eq $false) { $configState = 'NOT_TESTED_NOT_RUNNING' }
        elseif ($isRunning -eq $true) {
            $configResult = Invoke-MHSafeProcess -Name 'wsl.exe' -Arguments @('-d', $name, '--', 'cat', '/etc/wsl.conf') -TimeoutMilliseconds 8000 -Context $Context
            if ($configResult.exitCode -eq 0 -and -not $configResult.timedOut -and -not $configResult.errorCode) { $configState = 'PRESENT'; $configSettings = @(ConvertTo-MHSafeWslSettings -Text $configResult.stdout) }
            else { $configState = 'UNKNOWN' }
        }
        $distributions += [pscustomobject]@{ id = 'wsl:' + $name; name = $name; state = 'PRESENT'; running = $isRunning; version = $distributionVersion; configState = $configState; safeSettings = @($configSettings); restorePolicy = 'REVIEW' }
    }
    $items = @($globalConfig) + @($distributions)
    return [pscustomobject]@{ id = 'wsl'; state = 'PRESENT'; status = $(if ($partial) { 'PARTIAL' } else { 'OK' }); configPath = $globalConfig.configPath; configState = $globalConfig.configState; safeSettings = @($safeSettings); items = @($items) }
}

function Get-MHDataRoots {
    param([string]$UserHome, [string[]]$Roots, [switch]$SkipDefaultRoots, [int]$MaxRoots = 16)
    $candidates = @()
    $candidates += $Roots
    if (-not $SkipDefaultRoots) {
        $candidates += (Join-Path $UserHome 'Documents'), (Join-Path $UserHome 'Desktop')
        foreach ($name in @('Projects', 'Source', 'Repos', 'workspace', 'dev')) { $candidates += (Join-Path $UserHome $name) }
        $candidates += (Join-Path $UserHome 'Documents\Obsidian Vault')
    }
    $selected = @()
    $skippedReparseCount = 0
    $skippedBudgetCount = 0
    $seen = @{}
    foreach ($candidate in @($candidates | Where-Object { $_ })) {
        try {
            $fullPath = [IO.Path]::GetFullPath($candidate)
            if ($seen.ContainsKey($fullPath.ToLowerInvariant())) { continue }
            $seen[$fullPath.ToLowerInvariant()] = $true
            [void](Assert-MHNoReparseAncestors -Path $fullPath)
            $item = Get-Item -LiteralPath $fullPath -Force -ErrorAction Stop
            if (-not $item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or (Test-MHSecretText -Text $fullPath)) { continue }
            if ($selected.Count -ge $MaxRoots) { $skippedBudgetCount++; continue }
            $selected += $fullPath
        } catch { if ($_.Exception.Message -eq 'PATH_REPARSE_BLOCKED') { $skippedReparseCount++ } }
    }
    return [pscustomobject]@{ roots = @($selected); skippedReparseCount = $skippedReparseCount; skippedBudgetCount = $skippedBudgetCount }
}

function Get-MHGitFact {
    param([Parameter(Mandatory)][string]$Path, $Context)
    $fsmonitor = Invoke-MHSafeProcess -Name 'git.exe' -Arguments @('-C', $Path, 'config', '--get', 'core.fsmonitor') -Context $Context
    if (-not $fsmonitor.found -or $fsmonitor.timedOut -or $fsmonitor.errorCode -or ($fsmonitor.exitCode -ne 0 -and $fsmonitor.exitCode -ne 1)) {
        return [pscustomobject]@{ checked = $false; errorCode = 'GIT_FSMONITOR_CONFIG_UNAVAILABLE'; dirtyCount = $null; untrackedCount = $null; branch = $null; upstream = 'UNKNOWN'; ahead = $null; behind = $null }
    }
    if ($fsmonitor.exitCode -eq 0) {
        $fsmonitorValue = [string]$fsmonitor.stdout
        if ($fsmonitorValue.Trim() -and $fsmonitorValue.Trim() -notin @('false', 'no', 'off', '0')) {
            return [pscustomobject]@{ checked = $false; errorCode = 'GIT_FSMONITOR_HOOK_SKIPPED'; dirtyCount = $null; untrackedCount = $null; branch = $null; upstream = 'UNKNOWN'; ahead = $null; behind = $null }
        }
    }
    $status = Invoke-MHSafeProcess -Name 'git.exe' -Arguments @('-C', $Path, 'status', '--porcelain=v1', '--branch', '--untracked-files=all') -Context $Context
    if (-not $status.found) { return [pscustomobject]@{ checked = $false; errorCode = 'NOT_FOUND'; dirtyCount = $null; untrackedCount = $null; branch = $null; upstream = 'UNKNOWN'; ahead = $null; behind = $null } }
    if ($status.exitCode -ne 0 -or $status.timedOut -or $status.errorCode) { return [pscustomobject]@{ checked = $false; errorCode = 'GIT_STATUS_UNAVAILABLE'; dirtyCount = $null; untrackedCount = $null; branch = $null; upstream = 'UNKNOWN'; ahead = $null; behind = $null } }
    $lines = @($status.stdout -split "`r?`n" | Where-Object { $_ })
    $header = @($lines | Where-Object { $_ -match '^## ' } | Select-Object -First 1)
    $branch = $null
    $ahead = $null
    $behind = $null
    $branchResult = Invoke-MHSafeProcess -Name 'git.exe' -Arguments @('-C', $Path, 'branch', '--show-current') -Context $Context
    if ($branchResult.exitCode -eq 0 -and -not $branchResult.errorCode -and -not $branchResult.timedOut -and $branchResult.stdout.Trim() -match '^[A-Za-z0-9._/-]{1,200}$') { $branch = $branchResult.stdout.Trim() }
    if ($header.Count -gt 0 -and $header[0] -match '\[ahead (?<ahead>\d+), behind (?<behind>\d+)\]') { $ahead = [int]$Matches.ahead; $behind = [int]$Matches.behind }
    elseif ($header.Count -gt 0 -and $header[0] -match '\[ahead (?<ahead>\d+)\]') { $ahead = [int]$Matches.ahead; $behind = 0 }
    elseif ($header.Count -gt 0 -and $header[0] -match '\[behind (?<behind>\d+)\]') { $ahead = 0; $behind = [int]$Matches.behind }
    $changes = @($lines | Where-Object { $_ -notmatch '^## ' })
    $untracked = @($changes | Where-Object { $_.StartsWith('??') }).Count
    $dirty = $changes.Count - $untracked
    $remote = Invoke-MHSafeProcess -Name 'git.exe' -Arguments @('-C', $Path, 'remote') -Context $Context
    $remoteNames = if ($remote.exitCode -eq 0 -and -not $remote.errorCode -and -not $remote.timedOut) { @($remote.stdout -split "`r?`n" | Where-Object { $_ -match '^[A-Za-z0-9_.-]{1,80}$' }) } else { @() }
    return [pscustomobject]@{ checked = $true; errorCode = $null; dirtyCount = $dirty; untrackedCount = $untracked; branch = $branch; upstream = $(if ($null -ne $ahead) { 'KNOWN_LOCAL_TRACKING_REF' } else { 'UNKNOWN' }); ahead = $ahead; behind = $behind; remotes = @($remoteNames) }
}

function Find-MHRepositories {
    param([string[]]$Roots, [int]$MaxDepth = 3, [string[]]$Excludes = @(), [int]$MaxDirectories = 2000, $Context)
    $repos = @()
    $truncated = $false
    $excludeRoots = @($Excludes | Where-Object { $_ } | ForEach-Object { try { [IO.Path]::GetFullPath($_).TrimEnd('\') } catch { $null } } | Where-Object { $_ })
    foreach ($root in $Roots) {
        $queue = New-Object System.Collections.Queue
        $queue.Enqueue([pscustomobject]@{ path = $root; depth = 0 })
        $visited = 0
        while ($queue.Count -gt 0 -and $visited -lt $MaxDirectories -and (Get-MHRemainingBudgetMilliseconds -Context $Context) -gt 0) {
            $entry = $queue.Dequeue()
            $visited++
            if (@($excludeRoots | Where-Object { $entry.path.Equals($_, [StringComparison]::OrdinalIgnoreCase) -or $entry.path.StartsWith(($_ + '\'), [StringComparison]::OrdinalIgnoreCase) }).Count -gt 0) { continue }
            $gitDir = Join-Path $entry.path '.git'
            if (Test-Path -LiteralPath $gitDir) {
                $probe = Invoke-MHSafeProcess -Name 'git.exe' -Arguments @('-C', $entry.path, 'rev-parse', '--is-inside-work-tree') -Context $Context
                if (-not $probe.found) { $probe = Invoke-MHSafeProcess -Name 'git' -Arguments @('-C', $entry.path, 'rev-parse', '--is-inside-work-tree') -Context $Context }
                if ($probe.found -and -not $probe.errorCode -and -not $probe.timedOut -and $probe.exitCode -eq 0 -and $probe.stdout.Trim() -eq 'true') { $repos += $entry.path }
                else { $truncated = $true }
                continue
            }
            if ($entry.depth -ge $MaxDepth) { continue }
            try {
                foreach ($child in [IO.Directory]::EnumerateDirectories($entry.path)) {
                    try {
                        $attributes = [IO.File]::GetAttributes($child)
                        if (($attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { continue }
                        $leaf = [IO.Path]::GetFileName($child)
                        if ($leaf -in @('.git', 'node_modules', '.venv', 'venv', 'bin', 'obj', 'vendor', 'target', '.cache')) { continue }
                        if (Test-MHSecretText -Text $child) { continue }
                        $queue.Enqueue([pscustomobject]@{ path = $child; depth = $entry.depth + 1 })
                    } catch { }
                }
            } catch { }
        }
        if ($queue.Count -gt 0) { $truncated = $true }
        if ((Get-MHRemainingBudgetMilliseconds -Context $Context) -le 0) { $truncated = $true; break }
    }
    return [pscustomobject]@{ repositories = @($repos | Sort-Object -Unique); truncated = $truncated }
}

function Get-MHDataFacts {
    param([string]$UserHome, [string[]]$Roots, [string[]]$Excludes, [int]$MaxDepth, [switch]$SkipDefaultRoots, $Context)
    $rootDiscovery = Get-MHDataRoots -UserHome $UserHome -Roots $Roots -SkipDefaultRoots:$SkipDefaultRoots -MaxRoots ([int]$Context.budgets.maxRoots)
    $selectedRoots = @($rootDiscovery.roots)
    $locations = @()
    $candidates = @()
    foreach ($root in $selectedRoots) {
        $type = if ((Split-Path -Leaf $root) -eq 'Documents') { 'DOCUMENTS' } elseif ((Split-Path -Leaf $root) -eq 'Desktop') { 'DESKTOP' } elseif ($root -match '(?i)(OneDrive|Dropbox|Google Drive)') { 'CLOUD_SYNC' } else { 'WORK_ROOT' }
        if ((Split-Path -Leaf $root) -eq 'Obsidian Vault') { $type = 'OBSIDIAN_VAULT' }
        $readability = 'UNKNOWN'
        if ($type -notin @('CLOUD_SYNC') -and $root -notmatch '(?i)^\\\\wsl(?:\.localhost)?\\') {
            try { $enumerator = [IO.Directory]::EnumerateFileSystemEntries($root).GetEnumerator(); [void]$enumerator.MoveNext(); $readability = 'PASS' } catch { $readability = 'FAIL' }
        }
        $targetCandidate = switch ($type) {
            'DOCUMENTS' { '%USERPROFILE%\Documents' }
            'DESKTOP' { '%USERPROFILE%\Desktop' }
            'OBSIDIAN_VAULT' { '%USERPROFILE%\Documents\Obsidian Vault' }
            'CLOUD_SYNC' { '%OneDrive%' }
            default { $null }
        }
        $locations += [pscustomobject]@{ id = 'path:' + $root.ToLowerInvariant(); type = $type; state = 'PRESENT'; sourcePath = $root; targetPathCandidate = $targetCandidate; ownership = 'USER'; backupEvidence = 'UNKNOWN'; transferAction = 'REVIEW'; verification = 'NOT_TESTED'; readability = $readability; git = $null }
        if ($root -match '(?i)^\\\\wsl(?:\.localhost)?\\') {
            $candidates += [pscustomobject]@{ path = $root; reason = 'WSL path was recorded but not traversed during collection'; evidence = 'NOT_TESTED'; status = 'CANDIDATE' }
        } elseif ($type -ne 'CLOUD_SYNC') {
            $candidates += [pscustomobject]@{ path = $root; reason = 'Backup destination or parity has not been verified'; evidence = 'UNKNOWN'; status = 'CANDIDATE' }
        }
    }
    $oneDrive = ConvertTo-MHSafePath -Path $env:OneDrive
    if ($oneDrive -and (Test-Path -LiteralPath $oneDrive -PathType Container) -and $selectedRoots -notcontains $oneDrive) {
        $locations += [pscustomobject]@{ id = 'path:' + $oneDrive.ToLowerInvariant(); type = 'CLOUD_SYNC'; state = 'PRESENT'; sourcePath = $oneDrive; targetPathCandidate = '%OneDrive%'; ownership = 'USER'; backupEvidence = 'UNKNOWN'; transferAction = 'SYNC'; verification = 'NOT_TESTED'; readability = 'UNKNOWN'; git = $null }
    }
    $scanRoots = @($selectedRoots | Where-Object { $_ -notmatch '(?i)^\\\\wsl(?:\.localhost)?\\' })
    $discovery = Get-MHDataDiscovery -Context $Context -Roots $scanRoots -UserHome $UserHome
    $repositories = @($discovery.items | Where-Object type -eq 'GIT_REPOSITORY' | ForEach-Object sourcePath)
    foreach ($repository in $repositories) {
        $git = Get-MHGitFact -Path $repository -Context $Context
        $repoId = 'git:' + $repository.ToLowerInvariant()
        $repoName = Split-Path -Leaf $repository
        $targetCandidate = if (Test-MHSecretText -Text $repoName) { $null } else { '%USERPROFILE%\Projects\' + $repoName }
        $locations += [pscustomobject]@{ id = $repoId; type = 'GIT_REPOSITORY'; state = 'PRESENT'; sourcePath = $repository; targetPathCandidate = $targetCandidate; ownership = 'USER'; backupEvidence = 'UNKNOWN'; transferAction = 'REVIEW'; verification = 'NOT_TESTED'; readability = $(if ($git.checked) { 'PASS' } else { 'UNKNOWN' }); git = $git }
        $reason = if (-not $git.checked) { 'Git state could not be checked; backup state remains unknown' } elseif ($git.dirtyCount -gt 0 -or $git.untrackedCount -gt 0 -or $git.ahead -gt 0) { 'Git state contains local or unpushed changes; external backup parity is unverified' } else { 'Repository is clean, but no external backup copy or parity was verified' }
        $candidates += [pscustomobject]@{ path = $repository; reason = $reason; evidence = $git; status = 'CANDIDATE' }
    }
    foreach ($item in @($discovery.items | Where-Object type -ne 'GIT_REPOSITORY')) {
        $sourcePath = [string]$item.sourcePath
        $existingLocation = @($locations | Where-Object { ([string]$_.sourcePath).TrimEnd('\') -ieq $sourcePath.TrimEnd('\') } | Select-Object -First 1)
        if ($existingLocation.Count -gt 0) {
            if ($item.type -in @('NON_GIT_PROJECT', 'OBSIDIAN_VAULT') -and $existingLocation[0].type -in @('WORK_ROOT', 'DOCUMENTS', 'DESKTOP')) { $existingLocation[0].type = [string]$item.type }
            elseif ($item.type -notin @('COMPOSE_PROJECT', 'EDITOR_WORKSPACE')) { continue }
        }
        $targetCandidate = if ($item.type -eq 'OBSIDIAN_VAULT') { '%USERPROFILE%\Documents\' + (Split-Path -Leaf $sourcePath) } else { $null }
        $isFile = Test-Path -LiteralPath $sourcePath -PathType Leaf
        $locations += [pscustomobject]@{ id = [string]$item.id; type = [string]$item.type; state = [string]$item.state; sourcePath = $sourcePath; targetPathCandidate = $targetCandidate; ownership = 'USER'; backupEvidence = 'UNKNOWN'; transferAction = 'REVIEW'; verification = 'NOT_TESTED'; readability = $(if ($isFile) { 'UNKNOWN' } else { 'PASS' }); git = $null; evidence = [string]$item.evidence }
        $candidates += [pscustomobject]@{ path = $sourcePath; reason = [string]$item.reason; evidence = [string]$item.evidence; status = 'CANDIDATE' }
    }
    $repositoryRoots = @($repositories | ForEach-Object { $_.TrimEnd('\') })
    $candidates = @($candidates | Where-Object { $_.reason -notlike 'Backup destination or parity*' -or $repositoryRoots -notcontains ([string]$_.path).TrimEnd('\') })
    $scanTruncated = $discovery.status -ne 'OK'
    $status = if ($scanTruncated -or $rootDiscovery.skippedReparseCount -gt 0 -or $rootDiscovery.skippedBudgetCount -gt 0 -or $Context.rootsTruncated) { 'PARTIAL' } else { 'OK' }
    return [pscustomobject]@{ id = 'data'; state = 'PRESENT'; status = $status; roots = @($selectedRoots); repositories = @($repositories.Count); scanTruncated = [bool]$scanTruncated; skippedRootCount = [int]$rootDiscovery.skippedReparseCount; skippedBudgetRootCount = [int]$rootDiscovery.skippedBudgetCount; rootsTruncated = [bool]$Context.rootsTruncated; discoveryWarnings = @($discovery.warnings); locations = @($locations); unbackedCandidates = @($candidates) }
}

function Get-MHCollectorResult {
    param([string]$Domain, [scriptblock]$Collector, [Parameter(Mandatory)]$Context)
    $domainContext = New-MHDomainContext -Context $Context
    if ((Get-MHRemainingBudgetMilliseconds -Context $domainContext) -le 0) {
        return [pscustomobject]@{ domain = $Domain; status = 'UNAVAILABLE'; value = $null; warnings = @('COLLECTION_BUDGET_EXHAUSTED'); provenance = 'READ_ONLY_LOCAL_QUERY'; collectedAt = [DateTimeOffset]::Now.ToString('o') }
    }
    try {
        $value = & $Collector $domainContext
        $status = Get-MHField -Object $value -Name 'status' -Default 'OK'
        if ($status -notin @('OK', 'PARTIAL', 'UNAVAILABLE', 'ERROR')) { $status = 'OK' }
        $warnings = @(Get-MHField -Object $value -Name 'warnings' -Default @())
        $provenance = Get-MHField -Object $value -Name 'provenance' -Default 'READ_ONLY_LOCAL_QUERY'
        return [pscustomobject]@{ domain = $Domain; status = $status; value = $value; warnings = $warnings; provenance = $provenance; collectedAt = [DateTimeOffset]::Now.ToString('o') }
    } catch {
        return [pscustomobject]@{ domain = $Domain; status = 'ERROR'; value = $null; warnings = @('COLLECTOR_FAILED'); provenance = 'READ_ONLY_LOCAL_QUERY'; collectedAt = [DateTimeOffset]::Now.ToString('o') }
    }
}

function New-MHFallbackDomainValue {
    param([Parameter(Mandatory)][string]$Domain, [string]$UserHome)
    switch ($Domain) {
        'system' { return [pscustomobject]@{ id = 'system'; state = 'UNKNOWN'; computerLabel = [Environment]::MachineName; userProfile = $UserHome; windows = $null; volumes = @(); settings = @{} } }
        'env' { return [pscustomobject]@{ id = 'env'; state = 'UNKNOWN'; variables = @(); path = [ordered]@{ USER = @(); MACHINE = @() } } }
        'software' { return [pscustomobject]@{ id = 'software'; state = 'UNKNOWN'; wingetStatus = 'UNKNOWN'; packages = @() } }
        'dev' { return @() }
        'shell' { return [pscustomobject]@{ id = 'shell'; state = 'UNKNOWN'; currentPowerShell = $null; terminal = $null; config = @() } }
        'editors' { return @() }
        'agents' { return [pscustomobject]@{ id = 'agents'; state = 'UNKNOWN'; items = @(); configFiles = @() } }
        'workstation' { return @([pscustomobject]@{ id = 'workstation'; state = 'UNKNOWN'; architecture = $null; cpu = @(); memoryBytes = $null; gpu = @(); storage = @(); optionalFeatures = @(); settings = @{}; proxy = @{}; applications = @{} }) }
        'wsl' { return [pscustomobject]@{ id = 'wsl'; state = 'UNKNOWN'; status = 'ERROR'; items = @() } }
        'git' { return @() }
        'data' { return [pscustomobject]@{ id = 'data'; state = 'UNKNOWN'; roots = @(); repositories = 0; scanTruncated = $false; skippedRootCount = 0; locations = @(); unbackedCandidates = @() } }
    }
    throw 'UNKNOWN_COLLECTOR_DOMAIN'
}

function ConvertTo-MHSnapshotItem {
    param([Parameter(Mandatory)]$Item)
    $copy = [ordered]@{}
    foreach ($property in $Item.PSObject.Properties) {
        if ($property.Name -in @('configArtifacts', 'content', 'artifactPayloads')) { continue }
        $copy[$property.Name] = $property.Value
    }
    return [pscustomobject]$copy
}

function Merge-MHCollectionStatus {
    param($Base, $Additional, [string]$CoverageKey)
    if (-not $Additional) { return $Base }
    $statusRank = @{ OK = 0; PARTIAL = 1; UNAVAILABLE = 2; ERROR = 3 }
    $baseStatus = [string](Get-MHField -Object $Base -Name 'status' -Default 'UNKNOWN')
    $extraStatus = [string](Get-MHField -Object $Additional -Name 'status' -Default 'UNKNOWN')
    if (-not $statusRank.ContainsKey($baseStatus)) { $baseStatus = 'PARTIAL' }
    if (-not $statusRank.ContainsKey($extraStatus)) { $extraStatus = 'PARTIAL' }
    $status = if ($statusRank[$extraStatus] -gt $statusRank[$baseStatus]) { $extraStatus } else { $baseStatus }
    $warnings = @((Get-MHField -Object $Base -Name 'warnings' -Default @())) + @((Get-MHField -Object $Additional -Name 'warnings' -Default @()))
    $metadata = [ordered]@{}
    $baseMetadata = Get-MHField -Object $Base -Name 'metadata'
    if ($baseMetadata) {
        if ($baseMetadata -is [System.Collections.IDictionary]) { foreach ($key in $baseMetadata.Keys) { $metadata[$key] = $baseMetadata[$key] } }
        else { foreach ($property in $baseMetadata.PSObject.Properties) { $metadata[$property.Name] = $property.Value } }
    }
    $metadata[$CoverageKey] = $extraStatus
    return [pscustomobject]@{
        status = $status
        warnings = @($warnings | Where-Object { $_ } | Sort-Object -Unique)
        provenance = Get-MHField -Object $Base -Name 'provenance' -Default (Get-MHField -Object $Additional -Name 'provenance' -Default 'READ_ONLY_LOCAL_QUERY')
        collectedAt = Get-MHField -Object $Base -Name 'collectedAt' -Default (Get-MHField -Object $Additional -Name 'collectedAt')
        metadata = [pscustomobject]$metadata
    }
}

function New-MHDomainStatusEntry {
    param(
        [string]$Status,
        [string[]]$Warnings = @(),
        [string]$Provenance = 'READ_ONLY_LOCAL_QUERY',
        [string]$CollectedAt
    )

    if ($Status -notin @('OK', 'PARTIAL', 'UNAVAILABLE', 'ERROR')) { $Status = 'PARTIAL' }
    return [pscustomobject]@{
        status = $Status
        warnings = @($Warnings | Where-Object { $_ } | Sort-Object -Unique)
        provenance = $Provenance
        collectedAt = if ($CollectedAt) { $CollectedAt } else { [DateTimeOffset]::Now.ToString('o') }
        metadata = [pscustomobject]@{}
    }
}

function Collect-MachineHandoff {
    [CmdletBinding()]
    param(
        [string[]]$Roots = @(),
        [string[]]$Excludes = @(),
        [ValidateRange(0, 12)][int]$MaxDepth = 3,
        [switch]$SafeMode,
        [switch]$SkipDefaultRoots,
        [ValidateSet('Standard', 'Deep')][string]$Profile = 'Standard',
        $Context,
        [switch]$AsCollectionResult,
        [ValidateSet('SOURCE', 'DESTINATION')][string]$Role = 'SOURCE',
        [string]$SourceId
    )
    if (-not $Context) { $Context = New-MHCollectionContext -Profile $Profile -Roots $Roots -Excludes $Excludes -MaxDepth $MaxDepth -SafeMode:$SafeMode -SkipDefaultRoots:$SkipDefaultRoots }
    $Profile = $Context.profile
    $Roots = @($Context.roots)
    $Excludes = @($Context.excludes)
    $MaxDepth = [int]$Context.maxDepth
    $SafeMode = [bool]$Context.safeMode
    $SkipDefaultRoots = [bool]$Context.skipDefaultRoots
    $userHome = ConvertTo-MHSafePath -Path $env:USERPROFILE
    $domainResults = [ordered]@{}
    $collectors = [ordered]@{
        system = { param($domainContext) Get-MHSystemFacts }
        workstation = { param($domainContext) Get-MHWorkstationCollection -Context $domainContext }
        env = { param($domainContext) Get-MHEnvironmentFacts }
        software = { param($domainContext) Get-MHSoftwareFacts -SafeMode:$SafeMode -Roots $Roots -Context $domainContext }
        dev = { param($domainContext) Get-MHDevFacts -Context $domainContext }
        shell = { param($domainContext) Get-MHShellFacts -Context $domainContext }
        editors = { param($domainContext) Get-MHEditorFacts -Context $domainContext }
        agents = { param($domainContext) Get-MHAgentFacts -UserHome $userHome }
        wsl = { param($domainContext) Get-MHWslFacts -SafeMode:$SafeMode -Context $domainContext }
        data = { param($domainContext) Get-MHDataFacts -UserHome $userHome -Roots $Roots -Excludes $Excludes -MaxDepth $MaxDepth -SkipDefaultRoots:$SkipDefaultRoots -Context $domainContext }
    }
    foreach ($entry in $collectors.GetEnumerator()) { $domainResults[$entry.Key] = Get-MHCollectorResult -Domain $entry.Key -Collector $entry.Value -Context $Context }
    foreach ($domain in $collectors.Keys) {
        $result = $domainResults[$domain]
        if ($result.status -eq 'ERROR' -or $null -eq $result.value) {
            if ($result.status -ne 'ERROR') { $result.status = 'ERROR'; $result.warnings = @($result.warnings) + 'EMPTY_COLLECTOR_RESULT' }
            $result.value = New-MHFallbackDomainValue -Domain $domain -UserHome $userHome
        }
    }
    $deepResults = [ordered]@{}
    if ($Profile -eq 'Deep') {
        $deepCollectors = [ordered]@{
            gitPowerShell = { param($domainContext) Get-MHGitPowerShellCollection -Context $domainContext }
            editorsAgents = { param($domainContext) Get-MHEditorAgentCollection -Context $domainContext }
            runtimes = { param($domainContext) Get-MHRuntimeCollection -Context $domainContext }
            wslDeep = { param($domainContext) Get-MHDeepWslCollection -Context $domainContext }
            toolchains = { param($domainContext) Get-MHToolchainCollection -Context $domainContext }
            platformTools = { param($domainContext) Get-MHPlatformToolsCollection -Context $domainContext }
        }
        foreach ($entry in $deepCollectors.GetEnumerator()) {
            $deepResults[$entry.Key] = Get-MHCollectorResult -Domain $entry.Key -Collector $entry.Value -Context $Context
            if ($deepResults[$entry.Key].status -eq 'ERROR' -or $null -eq $deepResults[$entry.Key].value) {
                if ($deepResults[$entry.Key].status -ne 'ERROR') { $deepResults[$entry.Key].status = 'ERROR'; $deepResults[$entry.Key].warnings += 'EMPTY_COLLECTOR_RESULT' }
                $deepResults[$entry.Key].value = New-MHDomainResult -Domain $entry.Key -Status 'ERROR' -Items @() -Warnings @('COLLECTOR_FAILED')
            }
        }
    }
    $snapshotId = [guid]::NewGuid().ToString()
    if ([string]::IsNullOrWhiteSpace($SourceId)) { $SourceId = [guid]::NewGuid().ToString() }
    $dataValue = Get-MHField -Object $domainResults.data -Name 'value'
    $workstationItems = @(Get-MHField -Object $domainResults.workstation.value -Name 'items' -Default @())
    if ($workstationItems.Count -gt 0 -and $domainResults.system.value) {
        $domainResults.system.value | Add-Member -NotePropertyName workstation -NotePropertyValue $workstationItems[0] -Force
    }
    $domainStatus = [ordered]@{}
    foreach ($entry in $domainResults.GetEnumerator()) {
        $result = $entry.Value
        $metadata = [ordered]@{}
        $warnings = @($result.warnings)
        if ($entry.Key -eq 'software' -and $result.value) {
            $metadata.wingetStatus = $result.value.wingetStatus
            if ($result.value.wingetStatus -ne 'OK') { $warnings += [string]$result.value.wingetStatus }
        }
        if ($entry.Key -eq 'data' -and $result.value) {
            $metadata.repositoryCount = $result.value.repositories
            $metadata.scanTruncated = $result.value.scanTruncated
            $metadata.skippedRootCount = $result.value.skippedRootCount
            $metadata.skippedBudgetRootCount = $result.value.skippedBudgetRootCount
            $metadata.rootsTruncated = $result.value.rootsTruncated
            $metadata.discoveryWarnings = @($result.value.discoveryWarnings)
            if ($result.value.scanTruncated) { $warnings += 'SCAN_LIMIT_REACHED' }
            if ($result.value.skippedRootCount -gt 0) { $result.status = 'PARTIAL'; $warnings += 'REPARSE_ROOT_SKIPPED' }
            if ($result.value.skippedBudgetRootCount -gt 0 -or $result.value.rootsTruncated) { $result.status = 'PARTIAL'; $warnings += 'ROOT_LIMIT_REACHED' }
            if ($result.value.status -ne 'OK') { $result.status = 'PARTIAL'; $warnings += @($result.value.discoveryWarnings) }
        }
        if ($entry.Key -eq 'wsl' -and $result.value) {
            $metadata.status = $result.value.status
            if ($result.value.status -ne 'OK') { $warnings += [string]$result.value.status }
        }
        $domainStatus[$entry.Key] = [pscustomobject]@{ status = $result.status; warnings = @($warnings | Where-Object { $_ } | Sort-Object -Unique); provenance = $result.provenance; collectedAt = $result.collectedAt; metadata = $metadata }
    }
    if ($Profile -eq 'Deep') {
        $gitPowerShellResult = $deepResults.gitPowerShell
        $editorAgentResult = $deepResults.editorsAgents
        $runtimeResult = $deepResults.runtimes
        $wslDeepResult = $deepResults.wslDeep
        $toolchainResult = $deepResults.toolchains
        $platformToolsResult = $deepResults.platformTools
        $platformToolItems = @(Get-MHField -Object $platformToolsResult.value -Name 'items' -Default @())
        $platformPayload = if ($platformToolItems.Count -gt 0) { $platformToolItems[0] } else { $null }
        $domainStatus.git = [pscustomobject]@{ status = $gitPowerShellResult.status; warnings = @($gitPowerShellResult.warnings); provenance = $gitPowerShellResult.provenance; collectedAt = $gitPowerShellResult.collectedAt; metadata = [pscustomobject]@{} }
        $domainStatus.wslDeep = New-MHDomainStatusEntry -Status $wslDeepResult.status -Warnings $wslDeepResult.warnings -Provenance $wslDeepResult.provenance -CollectedAt $wslDeepResult.collectedAt
        $domainStatus.toolchains = New-MHDomainStatusEntry -Status $toolchainResult.status -Warnings $toolchainResult.warnings -Provenance $toolchainResult.provenance -CollectedAt $toolchainResult.collectedAt
        $domainStatus.platformTools = New-MHDomainStatusEntry -Status $platformToolsResult.status -Warnings $platformToolsResult.warnings -Provenance $platformToolsResult.provenance -CollectedAt $platformToolsResult.collectedAt
        $domainStatus.shell = Merge-MHCollectionStatus -Base $domainStatus.shell -Additional $gitPowerShellResult.value -CoverageKey 'gitPowerShell'
        $domainStatus.editors = Merge-MHCollectionStatus -Base $domainStatus.editors -Additional $editorAgentResult.value -CoverageKey 'deepInventory'
        $domainStatus.agents = Merge-MHCollectionStatus -Base $domainStatus.agents -Additional $editorAgentResult.value -CoverageKey 'deepInventory'
        $domainStatus.dev = Merge-MHCollectionStatus -Base $domainStatus.dev -Additional $runtimeResult.value -CoverageKey 'runtimeManifests'
        $domainStatus.dev = Merge-MHCollectionStatus -Base $domainStatus.dev -Additional $toolchainResult.value -CoverageKey 'toolchains'
        $domainStatus.wsl = Merge-MHCollectionStatus -Base $domainStatus.wsl -Additional $wslDeepResult.value -CoverageKey 'deepInventory'
        if ($platformPayload) {
            $domainStatus.editors = Merge-MHCollectionStatus -Base $domainStatus.editors -Additional $platformPayload.jetbrains -CoverageKey 'jetBrains'
            $domainStatus.dev = Merge-MHCollectionStatus -Base $domainStatus.dev -Additional $platformPayload.containers -CoverageKey 'containers'
            $domainStatus.containers = New-MHDomainStatusEntry -Status $platformPayload.containers.status -Provenance $platformToolsResult.provenance -CollectedAt $platformToolsResult.collectedAt
            $domainStatus.ssh = New-MHDomainStatusEntry -Status $platformPayload.ssh.status -Provenance $platformToolsResult.provenance -CollectedAt $platformToolsResult.collectedAt
            $domainStatus.gpg = New-MHDomainStatusEntry -Status $platformPayload.gpg.status -Provenance $platformToolsResult.provenance -CollectedAt $platformToolsResult.collectedAt
        } else {
            $domainStatus.containers = New-MHDomainStatusEntry -Status 'UNKNOWN' -Warnings @('PLATFORM_TOOLS_UNAVAILABLE')
            $domainStatus.ssh = New-MHDomainStatusEntry -Status 'UNKNOWN' -Warnings @('PLATFORM_TOOLS_UNAVAILABLE')
            $domainStatus.gpg = New-MHDomainStatusEntry -Status 'UNKNOWN' -Warnings @('PLATFORM_TOOLS_UNAVAILABLE')
        }
    }
    $agentValue = Get-MHField -Object $domainResults.agents -Name 'value'
    $agentItems = @(Get-MHField -Object $agentValue -Name 'items' -Default @())
    $agentConfigFiles = @(Get-MHField -Object $agentValue -Name 'configFiles' -Default @())
    foreach ($agent in $agentItems) {
        $files = @($agentConfigFiles | Where-Object { $_.agent -eq $agent.id.Replace('agent:', '') })
        $agent | Add-Member -NotePropertyName configFiles -NotePropertyValue $files -Force
    }
    $baseDev = @(Get-MHField -Object $domainResults.dev -Name 'value' -Default @())
    $baseEditors = @(Get-MHField -Object $domainResults.editors -Name 'value' -Default @())
    $wslItems = @(Get-MHField -Object $domainResults.wsl.value -Name 'items' -Default @())
    $manualItems = @()
    $gitItems = @()
    $configArtifactResults = @()
    if ($Profile -eq 'Deep') {
        $gitPowerShellItems = @(Get-MHField -Object $deepResults.gitPowerShell.value -Name 'items' -Default @())
        $gitItems = @($gitPowerShellItems | Where-Object { $_.domain -eq 'git' } | ForEach-Object { ConvertTo-MHSnapshotItem -Item $_ })
        $powerShellItems = @($gitPowerShellItems | Where-Object { $_.domain -eq 'shell' })
        if ($powerShellItems.Count -gt 0) { $baseShell = $domainResults.shell.value; $baseShell | Add-Member -NotePropertyName powerShell -NotePropertyValue (ConvertTo-MHSnapshotItem -Item $powerShellItems[0]) -Force }

        $editorAgentItems = @(Get-MHField -Object $deepResults.editorsAgents.value -Name 'items' -Default @())
        $deepEditorItems = @($editorAgentItems | Where-Object { $_.domain -eq 'editors' })
        $deepAgentItems = @($editorAgentItems | Where-Object { $_.domain -eq 'agents' })
        if ($deepEditorItems.Count -gt 0) { $baseEditors = @($deepEditorItems | ForEach-Object { ConvertTo-MHSnapshotItem -Item $_ }) }
        if ($deepAgentItems.Count -gt 0) { $agentItems = @($deepAgentItems | ForEach-Object { ConvertTo-MHSnapshotItem -Item $_ }) }

        $runtimeItems = @(Get-MHField -Object $deepResults.runtimes.value -Name 'items' -Default @())
        if ($runtimeItems.Count -gt 0) {
            $managedRuntimeNames = @('node', 'npm', 'pnpm', 'yarn', 'bun', 'python', 'py', 'pip', 'pip3', 'pipx', 'uv', 'dotnet')
            $baseDev = @($baseDev | Where-Object { $_.id -notin $managedRuntimeNames }) + @($runtimeItems | ForEach-Object { ConvertTo-MHSnapshotItem -Item $_ })
        }
        $toolchainItems = @(Get-MHField -Object $deepResults.toolchains.value -Name 'items' -Default @())
        if ($toolchainItems.Count -gt 0) { $baseDev += @($toolchainItems | ForEach-Object { ConvertTo-MHSnapshotItem -Item $_ }) }
        if ($platformPayload) {
            if ($platformPayload.jetbrains) {
                $jetBrainsItem = ConvertTo-MHSnapshotItem -Item $platformPayload.jetbrains
                $jetBrainsItem.id = 'editors:jetbrains'
                $baseEditors += $jetBrainsItem
            }
            foreach ($item in @($platformPayload.containers, $platformPayload.ssh, $platformPayload.gpg)) {
                if ($null -eq $item) { continue }
                $snapshotItem = ConvertTo-MHSnapshotItem -Item $item
                if (-not $snapshotItem.id.Contains(':')) { $snapshotItem.id = 'platform:' + $snapshotItem.id }
                $baseDev += $snapshotItem
            }
            foreach ($manual in @(Get-MHField -Object $platformPayload -Name 'manualItems' -Default @())) {
                $manualId = 'manual:' + [string]$manual.domain + ':' + [string]$manual.fileName
                $manualItems += [pscustomobject]@{ id = $manualId; domain = $manual.domain; fileName = $manual.fileName; status = 'MANUAL_TRANSFER_REQUIRED'; safety = 'MANUAL' }
            }
        }
        $wslDeepItems = @(Get-MHField -Object $deepResults.wslDeep.value -Name 'items' -Default @())
        if ($wslDeepItems.Count -gt 0) {
            $wslDeepSnapshotItem = ConvertTo-MHSnapshotItem -Item $wslDeepItems[0]
            $wslDeepSnapshotItem.id = 'wsl:deep-summary'
            $wslDeepSnapshotItem.state = if ((Get-MHField -Object $wslDeepItems[0] -Name 'state') -in @('PRESENT', 'ABSENT', 'UNKNOWN')) { [string]$wslDeepItems[0].state } elseif ($deepResults.wslDeep.status -in @('OK', 'PARTIAL')) { 'PRESENT' } else { 'UNKNOWN' }
            $wslDeepSnapshotItem | Add-Member -NotePropertyName collectionStatus -NotePropertyValue $deepResults.wslDeep.status -Force
            $wslItems += $wslDeepSnapshotItem
        }
        $configArtifactResults += @($gitPowerShellResult.value.configArtifacts)
        $configArtifactResults += @($editorAgentResult.value.configArtifacts)
        $configArtifactResults += @($runtimeResult.value.configArtifacts)
        $configArtifactResults += @($deepResults.toolchains.value.configArtifacts)
        $configArtifactResults += @($deepResults.platformTools.value.configArtifacts)
    }
    $artifactMetadata = @($configArtifactResults | ForEach-Object { Get-MHField -Object $_ -Name 'artifact' -Default $_ })

    $legacySnapshot = [pscustomobject]@{
        schemaVersion = 1
        snapshotId = $snapshotId
        sourceId = $SourceId
        role = $Role
        collectedAt = [DateTimeOffset]::Now.ToString('o')
        platform = 'windows'
        collection = [pscustomobject]@{ roots = @(Get-MHField -Object $dataValue -Name 'roots' -Default @()); excludes = @($Excludes); maxDepth = $MaxDepth; safeMode = [bool]$SafeMode; domainStatus = $domainStatus }
        system = $domainResults.system.value
        env = $domainResults.env.value
        software = @(Get-MHField -Object $domainResults.software -Name 'value' | ForEach-Object { Get-MHField -Object $_ -Name 'packages' -Default @() })
        dev = @($baseDev)
        shell = Get-MHField -Object $domainResults.shell -Name 'value'
        editors = @($baseEditors)
        agents = @($agentItems)
        git = @($gitItems)
        wsl = @($wslItems)
        dataLocations = @(Get-MHField -Object (Get-MHField -Object $domainResults.data -Name 'value') -Name 'locations' -Default @())
        unbackedDataCandidates = @(Get-MHField -Object (Get-MHField -Object $domainResults.data -Name 'value') -Name 'unbackedCandidates' -Default @())
        manualItems = @($manualItems)
    }
    $snapshot = ConvertTo-MHV2Snapshot -Snapshot $legacySnapshot -Profile $Profile -Context $Context -ConfigArtifacts @($artifactMetadata)
    if ($AsCollectionResult) { return [pscustomobject]@{ snapshot = $snapshot; configArtifacts = @($configArtifactResults); context = $Context } }
    return $snapshot
}

. (Join-Path $PSScriptRoot 'lib\model.ps1')
. (Join-Path $PSScriptRoot 'lib\process.ps1')
. (Join-Path $PSScriptRoot 'lib\config-artifacts.ps1')
. (Join-Path $PSScriptRoot 'lib\package.ps1')
foreach ($collectorScript in @('git-powershell.ps1', 'editors-agents.ps1', 'runtimes.ps1', 'data-discovery.ps1', 'workstation.ps1', 'wsl-deep.ps1', 'toolchains.ps1', 'platform-tools.ps1')) {
    $collectorPath = Join-Path $PSScriptRoot ('collectors\' + $collectorScript)
    if (Test-Path -LiteralPath $collectorPath -PathType Leaf) { . $collectorPath }
}
