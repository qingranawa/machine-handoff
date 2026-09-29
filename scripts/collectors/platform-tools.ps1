Set-StrictMode -Version Latest

function Get-MHPlatformProperty {
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

function Get-MHPlatformCommandPath {
    param([string]$Name)
    $command = Get-Command -Name $Name -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($command) { return [string]$command.Source }
    return $null
}

function Test-MHPlatformReparsePath {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    try { $current = [IO.Path]::GetFullPath($Path) } catch { return $true }
    if ($current.StartsWith('\\', [StringComparison]::Ordinal)) { return $true }
    while (-not [string]::IsNullOrWhiteSpace($current)) {
        if (Test-Path -LiteralPath $current) {
            try {
                $attributes = [IO.File]::GetAttributes($current)
                if (($attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { return $true }
            } catch { return $true }
        }
        $parent = [IO.Path]::GetDirectoryName($current.TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar))
        if ([string]::IsNullOrWhiteSpace($parent) -or $parent -eq $current) { break }
        $current = $parent
    }
    return $false
}

function Read-MHPlatformBoundedText {
    param([string]$Path, [int]$MaxBytes)
    if (Test-MHPlatformReparsePath -Path $Path) { throw 'PATH_REPARSE_BLOCKED' }
    $file = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if (-not $file.PSIsContainer -and ($file.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'PATH_REPARSE_BLOCKED' }
    if ($file.PSIsContainer) { throw 'NOT_A_FILE' }
    if ($file.Length -gt $MaxBytes) { throw 'FILE_SIZE_LIMIT' }
    $stream = New-Object System.IO.FileStream($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    try {
        $buffer = New-Object byte[] ($MaxBytes + 1)
        $readCount = 0
        while ($readCount -lt $buffer.Length) {
            $read = $stream.Read($buffer, $readCount, $buffer.Length - $readCount)
            if ($read -le 0) { break }
            $readCount += $read
        }
        if ($readCount -gt $MaxBytes) { throw 'FILE_SIZE_LIMIT' }
        $encoding = New-Object System.Text.UTF8Encoding($false, $true)
        $text = $encoding.GetString($buffer, 0, $readCount)
        if ($text.Length -gt 0 -and $text[0] -eq [char]0xFEFF) { $text = $text.Substring(1) }
        return $text
    } finally { $stream.Dispose() }
}

function Invoke-MHPlatformCommand {
    param($Context, [string]$Name, [string[]]$Arguments, [int]$TimeoutMilliseconds = 2500)
    $remaining = Get-MHRemainingBudgetMilliseconds -Context $Context
    if ($remaining -le 0) { return [pscustomobject]@{ found = $false; exitCode = $null; timedOut = $false; stdout = ''; errorCode = 'PROCESS_BUDGET_EXHAUSTED' } }
    $timeout = [Math]::Min($TimeoutMilliseconds, $remaining)
    $timeout = [Math]::Min($timeout, [int]$Context.budgets.processTimeoutMs)
    return Invoke-MHSafeProcess -Name $Name -Arguments $Arguments -TimeoutMilliseconds $timeout -MaxOutputBytes ([int]$Context.budgets.maxProcessOutputBytes) -Context $Context
}

function Get-MHPlatformVersionFact {
    param($Context, [string]$Id, [string]$Command, [string[]]$Arguments, [string]$Pattern = '(?i)(?<![\w])v?\d+(?:\.\d+){1,3}(?:[-+][\w.-]+)?')
    $path = Get-MHPlatformCommandPath -Name $Command
    if (-not $path) { return [pscustomobject]@{ id = $Id; state = 'ABSENT'; status = 'NOT_FOUND'; version = $null; path = $null } }
    $result = Invoke-MHPlatformCommand -Context $Context -Name $Command -Arguments $Arguments
    if ($result.timedOut -or $result.errorCode) {
        return [pscustomobject]@{ id = $Id; state = 'UNKNOWN'; status = $(if ($result.timedOut) { 'TIMEOUT' } else { $result.errorCode }); version = $null; path = (ConvertTo-MHSafePath -Path $path) }
    }
    if ($result.exitCode -ne 0) { return [pscustomobject]@{ id = $Id; state = 'UNKNOWN'; status = 'COMMAND_FAILED'; version = $null; path = (ConvertTo-MHSafePath -Path $path) } }
    $version = $null
    if ([string]$result.stdout -match $Pattern) { $version = $Matches[0] }
    return [pscustomobject]@{ id = $Id; state = $(if ($version) { 'PRESENT' } else { 'UNKNOWN' }); status = $(if ($version) { 'OK' } else { 'VERSION_UNAVAILABLE' }); version = $version; path = (ConvertTo-MHSafePath -Path $path) }
}

function Get-MHPlatformPrivateKeyMetadata {
    param([string]$Path)
    if (Test-MHPlatformReparsePath -Path $Path) { throw 'PATH_REPARSE_BLOCKED' }
    $metadata = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if (($metadata.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'PATH_REPARSE_BLOCKED' }
    return [pscustomobject]@{ fileName = $metadata.Name; state = 'PRESENT'; contentRead = $false }
}

function Get-MHPlatformGpgPrivateKeyMetadata {
    param([string]$Directory)
    $gpgRoot = Split-Path -Parent $Directory
    $legacyKeyring = Join-Path $gpgRoot 'secring.gpg'
    if (Test-MHPlatformReparsePath -Path $gpgRoot) { throw 'PATH_REPARSE_BLOCKED' }
    if (Test-Path -LiteralPath $legacyKeyring -PathType Leaf) { if (Test-MHPlatformReparsePath -Path $legacyKeyring) { throw 'PATH_REPARSE_BLOCKED' }; return $true }
    if (Test-MHPlatformReparsePath -Path $Directory) { throw 'PATH_REPARSE_BLOCKED' }
    if (-not (Test-Path -LiteralPath $Directory -PathType Container)) { return $false }
    return @([IO.Directory]::EnumerateFiles($Directory) | Select-Object -First 1).Count -gt 0
}

function New-MHPlatformMetadataArtifact {
    param($Context, [string]$Id, [string]$Name, [string]$Path, [string]$Category)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    if (Test-MHPlatformReparsePath -Path $Path) { throw 'PATH_REPARSE_BLOCKED' }
    $safePath = ConvertTo-MHSafePath -Path $Path
    if (-not $safePath) { return $null }
    $artifactPath = 'configs/PlatformTools/' + $Category + '/' + [IO.Path]::GetFileName($Path)
    $artifactResult = New-MHConfigArtifact -Context $Context -Id $Id -Domain 'platformTools' -SourcePath $safePath -TargetPathCandidate $null -ContentPolicy 'METADATA_ONLY' -Sensitivity 'PRIVATE' -Format 'UNKNOWN' -ArtifactPath $artifactPath -RestorePolicy 'REVIEW' -ValidationStrategy 'Confirm source metadata and review file manually.'
    return $artifactResult.artifact
}

function Get-MHPlatformJetBrains {
    param($Context)
    $profile = [string](Get-MHPlatformProperty -Object $Context -Name 'userProfile' -Default $env:USERPROFILE)
    $explicitRoot = [string](Get-MHPlatformProperty -Object $Context -Name 'jetBrainsRoot')
    $roots = if ($explicitRoot) { @($explicitRoot) } else { @((Join-Path $env:APPDATA 'JetBrains'), (Join-Path $env:LOCALAPPDATA 'JetBrains'), (Join-Path $profile '.config\JetBrains')) }
    $products = @()
    $artifacts = @()
    $partial = $false
    $maxProducts = [Math]::Max(1, [int]$Context.budgets.maxDiscoveredItems)
    foreach ($root in $roots) {
        if ($products.Count -ge $maxProducts) { $partial = $true; break }
        if (Test-MHPlatformReparsePath -Path $root) { $partial = $true; continue }
        if (-not (Test-Path -LiteralPath $root -PathType Container)) { continue }
        try { $directories = @([IO.Directory]::EnumerateDirectories($root) | Select-Object -First $maxProducts) }
        catch { $partial = $true; continue }
        foreach ($directory in $directories) {
            if (Test-MHPlatformReparsePath -Path $directory) { $partial = $true; continue }
            $leaf = [IO.Path]::GetFileName($directory)
            if ($products.Count -ge $maxProducts) { $partial = $true; break }
            if ($leaf -notmatch '^(?<product>IntelliJIdea|IdeaIC|Rider|PyCharm|WebStorm|CLion|DataGrip|GoLand|PhpStorm|RubyMine|RustRover|Fleet)(?<version>\d{4}(?:\.\d{1,2}){0,2})$') { continue }
            $productName = $Matches.product
            $configVersion = $Matches.version
            $options = Join-Path $directory 'options'
            $pluginRoot = Join-Path $directory 'plugins'
            $plugins = @()
            if (Test-Path -LiteralPath $pluginRoot -PathType Container) {
                if (Test-MHPlatformReparsePath -Path $pluginRoot) { $partial = $true; continue }
                try {
                    foreach ($pluginPath in @([IO.Directory]::EnumerateDirectories($pluginRoot) | Select-Object -First ([Math]::Min(500, $maxProducts)))) {
                        $plugin = [IO.Path]::GetFileName($pluginPath)
                        if ($plugin -match '^[A-Za-z0-9_.+-]{1,160}$' -and $plugin -notmatch '(?i)(cache|index|log)') { $plugins += $plugin }
                    }
                } catch { $partial = $true }
            }
            $candidateFiles = @(
                @{ id = 'jetbrains-keymap:' + $leaf; name = 'keymap'; path = (Join-Path $options 'keymap.xml') },
                @{ id = 'jetbrains-code-style:' + $leaf; name = 'code-style'; path = (Join-Path $options 'code.style.schemes.xml') },
                @{ id = 'jetbrains-jvm-options:' + $leaf; name = 'jvm-options'; path = (Join-Path $options 'idea.vmoptions') }
            )
            foreach ($subdirectory in @('keymaps', 'codestyles')) {
                $candidateDirectory = Join-Path $directory $subdirectory
                if (-not (Test-Path -LiteralPath $candidateDirectory -PathType Container)) { continue }
                if (Test-MHPlatformReparsePath -Path $candidateDirectory) { $partial = $true; continue }
                try {
                    foreach ($file in @([IO.Directory]::EnumerateFiles($candidateDirectory, '*.xml') | Select-Object -First 50)) {
                        $kind = if ($subdirectory -eq 'keymaps') { 'keymap' } else { 'code-style' }
                        $candidateFiles += @{ id = 'jetbrains-' + $kind + ':' + $leaf + ':' + [IO.Path]::GetFileName($file); name = $kind; path = $file }
                    }
                } catch { $partial = $true }
            }
            $jvmNames = @('idea64.exe.vmoptions', 'rider64.exe.vmoptions', 'pycharm64.exe.vmoptions', 'webstorm64.exe.vmoptions', 'clion64.exe.vmoptions', 'datagrip64.exe.vmoptions', 'goland64.exe.vmoptions', 'phpstorm64.exe.vmoptions', 'rubymine64.exe.vmoptions')
            foreach ($jvmName in $jvmNames) { $candidateFiles += @{ id = 'jetbrains-jvm-options:' + $leaf + ':' + $jvmName; name = 'jvm-options'; path = (Join-Path $directory $jvmName) } }
            $productArtifacts = @()
            foreach ($candidate in $candidateFiles) {
                if ($artifacts.Count -ge [int]$Context.budgets.maxConfigArtifacts) { $partial = $true; break }
                try {
                    $artifact = New-MHPlatformMetadataArtifact -Context $Context -Id $candidate.id -Name $candidate.name -Path $candidate.path -Category 'JetBrains'
                    if ($artifact) { $productArtifacts += $artifact; $artifacts += $artifact }
                } catch { $partial = $true }
            }
            $jvm = @($productArtifacts | Where-Object id -like 'jetbrains-jvm-options:*' | Select-Object -First 1)
            $syncPath = Join-Path $options 'settingsSync.xml'
            $products += [pscustomobject]@{
                id = 'jetbrains:' + $leaf; state = 'PRESENT'; product = $productName; version = $configVersion; versionSource = 'CONFIG_DIRECTORY'
                configDirectory = ConvertTo-MHSafePath -Path $directory; plugins = @($plugins | Sort-Object -Unique); artifacts = @($productArtifacts)
                jvmOptions = [pscustomobject]@{ state = $(if ($jvm.Count -gt 0) { 'PRESENT' } else { 'UNKNOWN' }); artifactId = $(if ($jvm.Count -gt 0) { $jvm[0].id } else { $null }) }
                syncState = [pscustomobject]@{ state = $(if (Test-Path -LiteralPath $syncPath -PathType Leaf) { 'PRESENT' } else { 'UNKNOWN' }); enabled = 'UNKNOWN' }
                cachesCopied = $false; indexesCopied = $false; authCopied = $false
            }
        }
    }
    $state = if ($products.Count -gt 0) { 'PRESENT' } elseif ($partial) { 'UNKNOWN' } else { 'ABSENT' }
    return [pscustomobject]@{ data = [pscustomobject]@{ id = 'jetbrains'; state = $state; status = $(if ($partial) { 'PARTIAL' } elseif ($products.Count -gt 0) { 'OK' } else { 'NOT_FOUND' }); products = @($products) }; artifacts = @($artifacts); partial = $partial }
}

function Get-MHPlatformWslIntegration {
    param($Context)
    $profile = [string](Get-MHPlatformProperty -Object $Context -Name 'userProfile' -Default $env:USERPROFILE)
    $explicitRoot = [string](Get-MHPlatformProperty -Object $Context -Name 'dockerDesktopRoot')
    $roots = if ($explicitRoot) { @($explicitRoot) } else { @((Join-Path $env:APPDATA 'Docker')) }
    $enabled = $null
    $distros = @()
    $partial = $false
    foreach ($root in $roots) {
        if (Test-MHPlatformReparsePath -Path $root) { $partial = $true; continue }
        if (-not (Test-Path -LiteralPath $root -PathType Container)) { continue }
        foreach ($filename in @('settings-store.json', 'settings.json')) {
            $path = Join-Path $root $filename
            if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { continue }
            try {
                $settingsText = Read-MHPlatformBoundedText -Path $path -MaxBytes 2097152
                $settings = ConvertFrom-Json -InputObject $settingsText -ErrorAction Stop
                $nodes = New-Object System.Collections.Stack
                $nodes.Push($settings)
                $visited = 0
                while ($nodes.Count -gt 0 -and $visited -lt 5000) {
                    $visited++
                    $node = $nodes.Pop()
                    if ($node -is [System.Array]) { foreach ($item in $node) { $nodes.Push($item) }; continue }
                    foreach ($property in $node.PSObject.Properties) {
                        if ($property.Name -match '^(?i:wslEngineEnabled|useWslEngine)$' -and $property.Value -is [bool]) { $enabled = [bool]$property.Value }
                        if ($property.Name -match '^(?i:integratedWslDistros|wslDistros)$' -and $property.Value -is [System.Array]) {
                            foreach ($name in $property.Value) { if ([string]$name -match '^[A-Za-z0-9_.-]{1,80}$') { $distros += [string]$name } }
                        }
                        if ($property.Value -is [System.Management.Automation.PSCustomObject] -or $property.Value -is [System.Array]) { $nodes.Push($property.Value) }
                    }
                }
            } catch { $partial = $true }
        }
    }
    return [pscustomobject]@{ state = $(if ($null -ne $enabled -or $distros.Count -gt 0) { 'PRESENT' } else { 'UNKNOWN' }); status = $(if ($partial) { 'PARTIAL' } else { 'OK' }); enabled = $enabled; integratedDistributions = @($distros | Sort-Object -Unique); source = 'STATIC_SETTINGS'; contentRead = $true }
}

function Get-MHPlatformContainers {
    param($Context)
    $definitions = @(
        @{ id = 'docker'; name = 'docker.exe'; args = @('--version') },
        @{ id = 'podman'; name = 'podman.exe'; args = @('--version') },
        @{ id = 'docker-compose'; name = 'docker-compose.exe'; args = @('version', '--short') }
    )
    $versions = @()
    foreach ($definition in $definitions) { $versions += Get-MHPlatformVersionFact -Context $Context -Id $definition.id -Command $definition.name -Arguments $definition.args }
    $profile = [string](Get-MHPlatformProperty -Object $Context -Name 'userProfile' -Default $env:USERPROFILE)
    $explicitRoot = [string](Get-MHPlatformProperty -Object $Context -Name 'dockerRoot')
    $dockerRoots = if ($explicitRoot) { @($explicitRoot) } else { @((Join-Path $profile '.docker')) }
    $contexts = @()
    $authPresent = $false
    $metadataPartial = $false
    $maxContexts = [Math]::Max(1, [Math]::Min(100, [int]$Context.budgets.maxDiscoveredItems))
    foreach ($root in $dockerRoots) {
        if (Test-MHPlatformReparsePath -Path $root) { $metadataPartial = $true; continue }
        if (-not (Test-Path -LiteralPath $root -PathType Container)) { continue }
        $authPath = Join-Path $root 'config.json'
        if (Test-Path -LiteralPath $authPath -PathType Leaf) {
            if (Test-MHPlatformReparsePath -Path $authPath) { $metadataPartial = $true } else { $authPresent = $true }
        }
        $metadataRoot = Join-Path $root 'contexts\meta'
        if (-not (Test-Path -LiteralPath $metadataRoot -PathType Container)) { continue }
        if (Test-MHPlatformReparsePath -Path $metadataRoot) { $metadataPartial = $true; continue }
        try {
            foreach ($directory in @([IO.Directory]::EnumerateDirectories($metadataRoot) | Select-Object -First $maxContexts)) {
                if (Test-MHPlatformReparsePath -Path $directory) { $metadataPartial = $true; continue }
                $metadataPath = Join-Path $directory 'meta.json'
                if (-not (Test-Path -LiteralPath $metadataPath -PathType Leaf)) { continue }
                try {
                    $metadataText = Read-MHPlatformBoundedText -Path $metadataPath -MaxBytes 65536
                    $metadata = ConvertFrom-Json -InputObject $metadataText -ErrorAction Stop
                    $name = [string](Get-MHPlatformProperty -Object $metadata -Name 'Name')
                    if ($name -match '^[A-Za-z0-9_.-]{1,100}$') { $contexts += [pscustomobject]@{ name = $name; state = 'PRESENT'; source = 'LOCAL_METADATA'; daemonQueried = $false } }
                } catch { $metadataPartial = $true }
            }
        } catch { $metadataPartial = $true }
    }
    $roots = @(Get-MHPlatformProperty -Object $Context -Name 'composeRoots' -Default @($Context.roots))
    $composeFiles = @()
    $composePartial = $false
    $inspectedFiles = 0
    $maxFiles = [Math]::Max(1, [Math]::Min(500, [int]$Context.budgets.maxFilesToInspect))
    $maxDirectories = [Math]::Max(1, [Math]::Min(5000, [int]$Context.budgets.maxDirectories))
    $visited = 0
    foreach ($root in $roots) {
        if (-not $root) { continue }
        if (Test-MHPlatformReparsePath -Path $root) { $composePartial = $true; continue }
        if (-not (Test-Path -LiteralPath $root -PathType Container)) { continue }
        $queue = New-Object System.Collections.Queue
        $queue.Enqueue([pscustomobject]@{ path = $root; depth = 0 })
        while ($queue.Count -gt 0 -and $composeFiles.Count -lt $maxFiles -and $visited -lt $maxDirectories -and -not $composePartial) {
            $current = $queue.Dequeue()
            $visited++
            try {
                foreach ($file in [IO.Directory]::EnumerateFiles($current.path)) {
                    if ($inspectedFiles -ge $maxFiles) { $composePartial = $true; break }
                    $inspectedFiles++
                    if ([IO.Path]::GetFileName($file) -match '^(?:docker-)?compose(?:\.override)?\.(?:ya?ml)$') { $composeFiles += [pscustomobject]@{ path = ConvertTo-MHSafePath -Path $file; project = [IO.Path]::GetFileName($current.path); state = 'PRESENT'; metadata = 'PATH_ONLY'; restorePolicy = 'REVIEW' } }
                    if ($composeFiles.Count -ge $maxFiles) { break }
                }
                if ($current.depth -lt [int]$Context.maxDepth) {
                    foreach ($child in [IO.Directory]::EnumerateDirectories($current.path)) {
                        if ($visited + $queue.Count -ge $maxDirectories) { break }
                        if (Test-MHPlatformReparsePath -Path $child) { $composePartial = $true; continue }
                        if ([IO.Path]::GetFileName($child) -notin @('.git', 'node_modules', 'vendor', 'cache', 'caches', 'images', 'volumes')) { $queue.Enqueue([pscustomobject]@{ path = $child; depth = $current.depth + 1 }) }
                    }
                }
            } catch { $composePartial = $true }
        }
    }
    $wslIntegration = Get-MHPlatformWslIntegration -Context $Context
    $unknownVersion = @($versions | Where-Object state -eq 'UNKNOWN').Count -gt 0
    $present = @($versions | Where-Object state -eq 'PRESENT').Count -gt 0 -or $contexts.Count -gt 0 -or $composeFiles.Count -gt 0
    return [pscustomobject]@{
        id = 'containers'; state = $(if ($present) { 'PRESENT' } elseif ($unknownVersion) { 'UNKNOWN' } else { 'ABSENT' }); status = $(if ($unknownVersion -or $metadataPartial -or $composePartial -or $wslIntegration.status -eq 'PARTIAL') { 'PARTIAL' } else { 'OK' })
        versions = @($versions); contexts = @($contexts | Sort-Object name -Unique); composeFiles = @($composeFiles | Sort-Object path -Unique)
        wslIntegration = $wslIntegration
        images = [pscustomobject]@{ state = 'NOT_TESTED'; count = $null; daemonQueried = $false }
        containers = [pscustomobject]@{ state = 'NOT_TESTED'; count = $null; daemonQueried = $false }
        namedVolumes = [pscustomobject]@{ state = 'NOT_TESTED'; count = $null; daemonQueried = $false }
        localOnlyRisk = [pscustomobject]@{ state = 'UNKNOWN'; reason = 'Daemon inventory is untested; local images, containers, and volumes may not be portable.' }
        authConfig = [pscustomobject]@{ state = $(if ($authPresent) { 'PRESENT_REDACTED' } else { 'ABSENT' }); contentRead = $false }
        daemonQueries = 'NOT_TESTED'; staticMetadataStatus = $(if ($metadataPartial -or $composePartial) { 'PARTIAL' } else { 'OK' })
    }
}

function Get-MHPlatformSsh {
    param($Context)
    $profile = [string](Get-MHPlatformProperty -Object $Context -Name 'userProfile' -Default $env:USERPROFILE)
    $sshRoot = Join-Path $profile '.ssh'
    $hosts = @()
    $activeHosts = @()
    $publicKeys = @()
    $privateKeys = @()
    $partial = $false
    $maxSshFiles = [Math]::Max(1, [int]$Context.budgets.maxFilesToInspect)
    if (Test-MHPlatformReparsePath -Path $sshRoot) {
        return [pscustomobject]@{ id = 'ssh'; state = 'UNKNOWN'; status = 'PARTIAL'; hosts = @(); publicKeys = @(); privateKeys = @(); privateKeyPolicy = 'MANUAL_TRANSFER_REQUIRED'; agent = [pscustomobject]@{ state = 'NOT_TESTED'; keys = @() }; configContentCopied = $false }
    }
    $configPath = Join-Path $sshRoot 'config'
    if (Test-Path -LiteralPath $configPath -PathType Leaf) {
        try {
            $configText = Read-MHPlatformBoundedText -Path $configPath -MaxBytes 262144
            foreach ($line in ($configText -split "`r?`n")) {
                if ($line -match '^\s*Host\s+(?<names>[^#\r\n]+)') {
                    $activeHosts = @()
                    foreach ($name in @($Matches.names.Trim() -split '\s+' | Where-Object { $_ -match '^[A-Za-z0-9_.*@?-]{1,200}$' -and $_ -notmatch '[*?]' })) { $entry = [pscustomobject]@{ name = $name; directives = @() }; $hosts += $entry; $activeHosts += $entry }
                } elseif ($line -match '^\s*(?<key>HostName|Port|ForwardAgent|ServerAliveInterval)\s+(?<value>[^\s#]+)' -and $activeHosts.Count -gt 0) {
                    $key = $Matches.key.ToLowerInvariant()
                    $value = $Matches.value
                    $isSafe = ($key -eq 'hostname' -and $value -match '^[A-Za-z0-9.-]{1,253}$') -or ($key -eq 'port' -and $value -match '^\d{1,5}$' -and [int]$value -le 65535) -or ($key -eq 'forwardagent' -and $value -match '^(?i:yes|no)$') -or ($key -eq 'serveraliveinterval' -and $value -match '^\d{1,5}$' -and [int]$value -le 86400)
                    if ($isSafe) { foreach ($host in $activeHosts) { $host.directives += [pscustomobject]@{ name = $key; value = $value } } }
                }
            }
        } catch { $partial = $true }
    }
    if (Test-Path -LiteralPath $sshRoot -PathType Container) {
        try {
            foreach ($file in @([IO.Directory]::EnumerateFiles($sshRoot) | Select-Object -First $maxSshFiles)) {
                $name = [IO.Path]::GetFileName($file)
                if ($name -match '\.pub$') {
                    try {
                        $publicKeyText = Read-MHPlatformBoundedText -Path $file -MaxBytes 65536
                        $line = @($publicKeyText -split "`r?`n" | Select-Object -First 1)[0]
                        if ($line -match '^(?<algorithm>ssh-(?:ed25519|rsa)|ecdsa-sha2-nistp\d+|sk-ssh-ed25519@openssh\.com)\s+(?<blob>[A-Za-z0-9+/=]{16,})') {
                            $digest = [Security.Cryptography.SHA256]::Create()
                            try { $fingerprint = 'SHA256:' + [Convert]::ToBase64String($digest.ComputeHash([Convert]::FromBase64String($Matches.blob))).TrimEnd('=') } finally { $digest.Dispose() }
                            $publicKeys += [pscustomobject]@{ fileName = $name; algorithm = $Matches.algorithm; fingerprint = $fingerprint; state = 'PRESENT' }
                        }
                    } catch { }
                } elseif ($name -match '^(?:id_[A-Za-z0-9_.-]+|[^.]+\.(?:pem|key))$') {
                    try { $metadata = Get-MHPlatformPrivateKeyMetadata -Path $file; if ($metadata.state -eq 'PRESENT') { $privateKeys += $metadata } } catch { $partial = $true }
                }
            }
        } catch { $partial = $true }
    }
    $agent = [pscustomobject]@{ state = 'UNKNOWN'; keys = @() }
    $sshAdd = Get-MHPlatformCommandPath -Name 'ssh-add.exe'
    if ($sshAdd) {
        $result = Invoke-MHPlatformCommand -Context $Context -Name 'ssh-add.exe' -Arguments @('-l') -TimeoutMilliseconds 1500
        if (-not $result.errorCode -and -not $result.timedOut -and $result.exitCode -eq 0) {
            $keys = @()
            foreach ($line in @(([string]$result.stdout -split "`r?`n") | Where-Object { $_ })) { if ($line -match '^\d+\s+(?<fingerprint>SHA256:[A-Za-z0-9+/]{20,})\s+.*\((?<algorithm>[A-Z0-9-]+)\)$') { $keys += [pscustomobject]@{ fingerprint = $Matches.fingerprint; algorithm = $Matches.algorithm } } }
            $agent = [pscustomobject]@{ state = $(if ($keys.Count -gt 0) { 'PRESENT' } else { 'EMPTY' }); keys = @($keys) }
        } elseif ($result.errorCode -eq 'PROCESS_BUDGET_EXHAUSTED') { $agent = [pscustomobject]@{ state = 'UNKNOWN'; keys = @() } }
        else { $agent = [pscustomobject]@{ state = 'NOT_TESTED'; keys = @() } }
    } else { $agent = [pscustomobject]@{ state = 'NOT_TESTED'; keys = @() } }
    $sshPresent = (Test-Path -LiteralPath $sshRoot -PathType Container) -or $sshAdd
    $sshState = if ($hosts.Count -or $publicKeys.Count -or $privateKeys.Count -or $sshAdd) { 'PRESENT' } elseif ($partial) { 'UNKNOWN' } else { 'ABSENT' }
    return [pscustomobject]@{ id = 'ssh'; state = $sshState; status = $(if ($partial -or ($sshPresent -and $agent.state -in @('UNKNOWN', 'NOT_TESTED'))) { 'PARTIAL' } else { 'OK' }); hosts = @($hosts); publicKeys = @($publicKeys); privateKeys = @($privateKeys); privateKeyPolicy = 'MANUAL_TRANSFER_REQUIRED'; agent = $agent; configContentCopied = $false }
}

function Get-MHPlatformGpg {
    param($Context)
    $program = Get-MHPlatformVersionFact -Context $Context -Id 'gpg' -Command 'gpg.exe' -Arguments @('--version') -Pattern '(?i)\b\d+\.\d+(?:\.\d+)?\b'
    $fingerprints = @()
    $signingMappings = @()
    $partial = $false
    if ($program.state -eq 'PRESENT') {
        $result = Invoke-MHPlatformCommand -Context $Context -Name 'gpg.exe' -Arguments @('--batch', '--with-colons', '--fingerprint', '--list-keys') -TimeoutMilliseconds 3000
        if (-not $result.errorCode -and -not $result.timedOut -and $result.exitCode -eq 0) {
            foreach ($line in @(([string]$result.stdout -split "`r?`n") | Where-Object { $_ -match '^fpr:' })) {
                $fields = $line.Split(':')
                if ($fields.Count -gt 9 -and $fields[9] -match '^[A-Fa-f0-9]{32,64}$') { $fingerprints += [pscustomobject]@{ fingerprint = $fields[9].ToUpperInvariant(); state = 'PRESENT'; usage = 'PUBLIC_KEY' } }
            }
        } elseif ($result.errorCode -or $result.timedOut -or $result.exitCode -ne 0) { $partial = $true }
        if (Get-MHPlatformCommandPath -Name 'git.exe') {
            $mapping = Invoke-MHPlatformCommand -Context $Context -Name 'git.exe' -Arguments @('config', '--global', '--get', 'user.signingkey') -TimeoutMilliseconds 1500
            if (-not $mapping.errorCode -and -not $mapping.timedOut -and $mapping.exitCode -eq 0) {
                $keyId = ([string]$mapping.stdout).Trim()
                if ($keyId -match '^(?:0x)?[A-Fa-f0-9]{8,64}$') { $signingMappings += [pscustomobject]@{ scope = 'GIT_GLOBAL'; keyId = $keyId.ToUpperInvariant(); state = 'CONFIGURED' } }
            } elseif ($mapping.errorCode -or $mapping.timedOut -or $mapping.exitCode -ne 1) { $partial = $true }
        }
    }
    $profile = [string](Get-MHPlatformProperty -Object $Context -Name 'userProfile' -Default $env:USERPROFILE)
    $gpgHome = [string](Get-MHPlatformProperty -Object $Context -Name 'gpgHome' -Default (Join-Path $profile '.gnupg'))
    $privateDir = Join-Path $gpgHome 'private-keys-v1.d'
    $privatePresent = $false
    $privateState = 'UNKNOWN'
    try {
        $privatePresent = Get-MHPlatformGpgPrivateKeyMetadata -Directory $privateDir
        if ($privatePresent) { $privateState = 'PRESENT' }
        elseif ((Test-Path -LiteralPath $privateDir -PathType Container) -and -not (Test-MHPlatformReparsePath -Path $privateDir)) { $privateState = 'ABSENT' }
    } catch { $partial = $true }
    return [pscustomobject]@{ id = 'gpg'; state = $(if ($program.state -eq 'PRESENT' -or $fingerprints.Count -gt 0 -or $privatePresent) { 'PRESENT' } elseif ($program.state -eq 'UNKNOWN') { 'UNKNOWN' } else { 'ABSENT' }); status = $(if ($partial -or $program.state -eq 'UNKNOWN') { 'PARTIAL' } else { 'OK' }); program = $program; publicFingerprints = @($fingerprints | Sort-Object fingerprint -Unique); signingMappings = @($signingMappings); privateKeys = [pscustomobject]@{ state = $privateState; contentRead = $false; transfer = 'MANUAL_TRANSFER_REQUIRED' } }
}

function Get-MHPlatformToolsCollection {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Context)
    $warnings = New-Object 'System.Collections.Generic.List[string]'
    $artifacts = @()
    try { $jetbrainsResult = Get-MHPlatformJetBrains -Context $Context; $jetbrains = $jetbrainsResult.data; $artifacts += $jetbrainsResult.artifacts; if ($jetbrainsResult.partial) { $warnings.Add('JETBRAINS_PARTIAL') } }
    catch { $jetbrains = [pscustomobject]@{ id = 'jetbrains'; state = 'UNKNOWN'; products = @() }; $warnings.Add('JETBRAINS_UNKNOWN') }
    try { $containers = Get-MHPlatformContainers -Context $Context; if ($containers.status -eq 'PARTIAL' -or $containers.staticMetadataStatus -eq 'PARTIAL') { $warnings.Add('CONTAINERS_PARTIAL') } }
    catch { $containers = [pscustomobject]@{ id = 'containers'; state = 'UNKNOWN'; versions = @(); contexts = @(); composeFiles = @(); daemonQueries = 'NOT_TESTED' }; $warnings.Add('CONTAINERS_UNKNOWN') }
    try { $ssh = Get-MHPlatformSsh -Context $Context; if ($ssh.state -eq 'UNKNOWN' -or $ssh.status -eq 'PARTIAL') { $warnings.Add('SSH_PARTIAL') } }
    catch { $ssh = [pscustomobject]@{ id = 'ssh'; state = 'UNKNOWN'; hosts = @(); publicKeys = @(); privateKeys = @(); agent = [pscustomobject]@{ state = 'UNKNOWN'; keys = @() } }; $warnings.Add('SSH_UNKNOWN') }
    try { $gpg = Get-MHPlatformGpg -Context $Context; if ($gpg.state -eq 'UNKNOWN' -or $gpg.status -eq 'PARTIAL') { $warnings.Add('GPG_PARTIAL') } }
    catch { $gpg = [pscustomobject]@{ id = 'gpg'; state = 'UNKNOWN'; publicFingerprints = @(); signingMappings = @(); privateKeys = [pscustomobject]@{ state = 'UNKNOWN'; contentRead = $false; transfer = 'MANUAL_TRANSFER_REQUIRED' } }; $warnings.Add('GPG_UNKNOWN') }
    $manualItems = @()
    foreach ($private in @($ssh.privateKeys | Where-Object state -eq 'PRESENT')) { $manualItems += [pscustomobject]@{ domain = 'ssh'; fileName = $private.fileName; reason = 'MANUAL_TRANSFER_REQUIRED'; safety = 'MANUAL' } }
    if ($gpg.privateKeys.state -eq 'PRESENT') { $manualItems += [pscustomobject]@{ domain = 'gpg'; fileName = 'GnuPG private key material'; reason = 'MANUAL_TRANSFER_REQUIRED'; safety = 'MANUAL' } }
    $payload = [pscustomobject]@{ id = 'platformTools'; jetbrains = $jetbrains; containers = $containers; ssh = $ssh; gpg = $gpg; manualItems = @($manualItems) }
    return New-MHDomainResult -Domain 'platformTools' -Status $(if ($warnings.Count) { 'PARTIAL' } else { 'OK' }) -Items @($payload) -Warnings @($warnings.ToArray() | Sort-Object -Unique) -ConfigArtifacts @($artifacts)
}
