[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$repositoryRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
. (Join-Path $repositoryRoot 'scripts\collect.ps1')
. (Join-Path $repositoryRoot 'scripts\collectors\platform-tools.ps1')

function Assert-PlatformTools {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw ('Platform tools collector test failed: ' + $Message) }
    Write-Output ('PASS: ' + $Message)
}

function New-TestSymbolicLink {
    param([string]$Path, [string]$Target)
    try { [void](New-Item -ItemType SymbolicLink -Path $Path -Target $Target -ErrorAction Stop); return $true }
    catch { return $false }
}

$script:privateReadAttempts = 0
$script:processCalls = @()
$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('mh-platform-' + [guid]::NewGuid().ToString('N'))
[void](New-Item -ItemType Directory -Path $tempRoot)
$originalPath = $env:Path
try {
    $fixtureHome = Join-Path $tempRoot 'home'
    $jetBrains = Join-Path $fixtureHome 'AppData\Roaming\JetBrains\IntelliJIdea2025.1'
    $configDir = Join-Path $jetBrains 'options'
    $pluginDir = Join-Path $jetBrains 'plugins'
    [void](New-Item -ItemType Directory -Path $configDir -Force)
    [void](New-Item -ItemType Directory -Path $pluginDir -Force)
    Set-Content -LiteralPath (Join-Path $configDir 'keymap.xml') -Value '<application />' -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $configDir 'code.style.schemes.xml') -Value '<application />' -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $configDir 'idea.vmoptions') -Value '-Xmx2g' -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $configDir 'settingsSync.xml') -Value '<application />' -Encoding UTF8
    [void](New-Item -ItemType Directory -Path (Join-Path $pluginDir 'org.example.sample') -Force)

    $dockerDir = Join-Path $fixtureHome '.docker'
    $contextMeta = Join-Path $dockerDir 'contexts\meta\context-hash'
    [void](New-Item -ItemType Directory -Path $contextMeta -Force)
    Set-Content -LiteralPath (Join-Path $dockerDir 'config.json') -Value '{"auths":{"registry.example":{"auth":"DOCKER_AUTH_SENTINEL"}},"currentContext":"fixture-context"}' -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $contextMeta 'meta.json') -Value '{"Name":"fixture-context","Endpoints":{"docker":{"Host":"npipe:////./pipe/docker_engine"}}}' -Encoding UTF8
    $dockerDesktop = Join-Path $fixtureHome 'AppData\Roaming\Docker'
    [void](New-Item -ItemType Directory -Path $dockerDesktop -Force)
    Set-Content -LiteralPath (Join-Path $dockerDesktop 'settings-store.json') -Value '{"wslEngineEnabled":true,"integratedWslDistros":["Ubuntu-22.04"],"registryToken":"DOCKER_SETTINGS_SECRET"}' -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $fixtureHome 'compose.yaml') -Value "services:`n  app:`n    image: fixture/app:latest`nvolumes:`n  cache:" -Encoding UTF8

    $sshDir = Join-Path $fixtureHome '.ssh'
    [void](New-Item -ItemType Directory -Path $sshDir -Force)
    Set-Content -LiteralPath (Join-Path $sshDir 'config') -Value "Host work-alias`n  HostName git.example.test`n  Port 2222`n  ProxyCommand echo SSH_CONFIG_SENTINEL`n  PKCS11Provider SECRET_SENTINEL" -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $sshDir 'id_ed25519') -Value 'PRIVATE_KEY_SENTINEL' -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $sshDir 'id_ed25519.pub') -Value 'ssh-ed25519 Zml4dHVyZS1rZXk= public-comment' -Encoding UTF8
    $gpgPrivateDir = Join-Path $fixtureHome '.gnupg\private-keys-v1.d'
    [void](New-Item -ItemType Directory -Path $gpgPrivateDir -Force)
    Set-Content -LiteralPath (Join-Path $gpgPrivateDir 'privatekey-v1-fixture') -Value 'GPG_PRIVATE_KEY_SENTINEL' -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $fixtureHome '.gnupg\gpg.conf') -Value 'default-key 0123456789ABCDEF' -Encoding UTF8

    $externalRoot = Join-Path $tempRoot 'external'
    $externalSsh = Join-Path $externalRoot 'ssh'
    $externalJetBrains = Join-Path $externalRoot 'jetbrains'
    $externalDocker = Join-Path $externalRoot 'docker'
    $externalCompose = Join-Path $externalRoot 'compose'
    $externalGpg = Join-Path $externalRoot 'gpg'
    foreach ($directory in @($externalSsh, (Join-Path $externalJetBrains 'Rider2099.1\plugins'), $externalDocker, $externalCompose, (Join-Path $externalGpg 'private-keys-v1.d'))) { [void](New-Item -ItemType Directory -Path $directory -Force) }
    Set-Content -LiteralPath (Join-Path $externalSsh 'config') -Value 'Host EXTERNAL_SSH_SENTINEL' -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $externalSsh 'id_external.pub') -Value 'ssh-ed25519 Zml4dHVyZS1rZXk= EXTERNAL_PUBLIC_KEY_SENTINEL' -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $externalDocker 'settings-store.json') -Value '{"wslEngineEnabled":true,"integratedWslDistros":["EXTERNAL_DOCKER_SENTINEL"]}' -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $externalJetBrains 'Rider2099.1\plugins\external-plugin.txt') -Value 'EXTERNAL_JETBRAINS_SENTINEL' -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $externalCompose 'compose.yaml') -Value 'services: {}' -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $externalGpg 'private-keys-v1.d\external-key') -Value 'EXTERNAL_GPG_SENTINEL' -Encoding UTF8

    $junctions = @()
    foreach ($fixture in @(
        @{ Path = (Join-Path $tempRoot 'linked-ssh-home\.ssh'); Target = $externalSsh },
        @{ Path = (Join-Path $tempRoot 'linked-jetbrains-root'); Target = $externalJetBrains },
        @{ Path = (Join-Path $tempRoot 'linked-docker-root'); Target = $externalDocker },
        @{ Path = (Join-Path $tempRoot 'linked-compose-root'); Target = $externalCompose },
        @{ Path = (Join-Path $tempRoot 'linked-gpg-root'); Target = $externalGpg }
    )) {
        [void](New-Item -ItemType Directory -Path (Split-Path -Parent $fixture.Path) -Force)
        [void](New-Item -ItemType Junction -Path $fixture.Path -Target $fixture.Target -ErrorAction Stop)
        $junctions += $fixture.Path
    }

    $oversizedHome = Join-Path $tempRoot 'oversized-home'
    $oversizedSsh = Join-Path $oversizedHome '.ssh'
    [void](New-Item -ItemType Directory -Path $oversizedSsh -Force)
    $oversizedConfig = Join-Path $oversizedSsh 'config'
    $oversizedContent = 'Host OVERSIZED_SSH_SENTINEL' + "`n" + ('# fixture padding' + "`n") * 20000
    Set-Content -LiteralPath $oversizedConfig -Value $oversizedContent -Encoding UTF8

    $linkedFileHome = Join-Path $tempRoot 'linked-file-home'
    $linkedFileSsh = Join-Path $linkedFileHome '.ssh'
    [void](New-Item -ItemType Directory -Path $linkedFileSsh -Force)
    $sshConfigSymlink = New-TestSymbolicLink -Path (Join-Path $linkedFileSsh 'config') -Target (Join-Path $externalSsh 'config')
    $sshPublicKeySymlink = New-TestSymbolicLink -Path (Join-Path $linkedFileSsh 'id_external.pub') -Target (Join-Path $externalSsh 'id_external.pub')
    $linkedFileDocker = Join-Path $tempRoot 'linked-file-docker'
    [void](New-Item -ItemType Directory -Path $linkedFileDocker -Force)
    $dockerSettingsSymlink = New-TestSymbolicLink -Path (Join-Path $linkedFileDocker 'settings-store.json') -Target (Join-Path $externalDocker 'settings-store.json')
    $contextLinkDir = Join-Path $dockerDir 'contexts\meta\linked-context'
    [void](New-Item -ItemType Directory -Path $contextLinkDir -Force)
    $externalContext = Join-Path $externalRoot 'context-meta.json'
    Set-Content -LiteralPath $externalContext -Value '{"Name":"EXTERNAL_CONTEXT_SENTINEL"}' -Encoding UTF8
    $dockerContextSymlink = New-TestSymbolicLink -Path (Join-Path $contextLinkDir 'meta.json') -Target $externalContext
    $legacyGpgHome = Join-Path $tempRoot 'linked-file-gpg'
    [void](New-Item -ItemType Directory -Path $legacyGpgHome -Force)
    $gpgLegacySymlink = New-TestSymbolicLink -Path (Join-Path $legacyGpgHome 'secring.gpg') -Target (Join-Path $externalRoot 'private-key.sentinel')
    Set-Content -LiteralPath (Join-Path $externalRoot 'private-key.sentinel') -Value 'EXTERNAL_GPG_LEGACY_SENTINEL' -Encoding UTF8
    $symlinkFixtureCount = @($sshConfigSymlink, $sshPublicKeySymlink, $dockerSettingsSymlink, $dockerContextSymlink, $gpgLegacySymlink | Where-Object { $_ }).Count
    if ($symlinkFixtureCount -gt 0) { Write-Output ('INFO: file symlink fixtures created=' + $symlinkFixtureCount) }
    else { Write-Output 'INFO: file symlinks were unavailable; directory junction fixtures cover reparse ancestors' }

    $fakeBin = Join-Path $tempRoot 'bin'
    [void](New-Item -ItemType Directory -Path $fakeBin)
    foreach ($name in @('docker.exe', 'docker-compose.exe', 'podman.exe', 'ssh-add.exe', 'gpg.exe', 'git.exe')) {
        Set-Content -LiteralPath (Join-Path $fakeBin $name) -Value '' -Encoding ASCII
    }
    $env:Path = $fakeBin + [IO.Path]::PathSeparator + $originalPath
    $script:responses = @{
        'docker.exe|--version' = [pscustomobject]@{ found = $true; exitCode = 0; timedOut = $false; errorCode = $null; stdout = 'Docker version 27.1.0, build fixture' }
        'podman.exe|--version' = [pscustomobject]@{ found = $false; exitCode = $null; timedOut = $false; errorCode = 'NOT_FOUND'; stdout = '' }
        'docker-compose.exe|version --short' = [pscustomobject]@{ found = $true; exitCode = 0; timedOut = $false; errorCode = $null; stdout = 'v2.28.0' }
        'ssh-add.exe|-l' = [pscustomobject]@{ found = $true; exitCode = 0; timedOut = $false; errorCode = $null; stdout = '256 SHA256:fixtureFingerprint comment (ED25519)' }
        'gpg.exe|--version' = [pscustomobject]@{ found = $true; exitCode = 0; timedOut = $false; errorCode = $null; stdout = 'gpg (GnuPG) 2.4.5' }
        'gpg.exe|--batch --with-colons --fingerprint --list-keys' = [pscustomobject]@{ found = $true; exitCode = 0; timedOut = $false; errorCode = $null; stdout = "pub:u:255:22:ABCDEF0123456789:0:0::u:::scESC::::::23::0:`nfpr:::::::::0123456789ABCDEF0123456789ABCDEF01234567:`nuid:::::::::UID_SECRET_SENTINEL:" }
        'git.exe|config --global --get user.signingkey' = [pscustomobject]@{ found = $true; exitCode = 0; timedOut = $false; errorCode = $null; stdout = '0123456789ABCDEF' }
    }
    function Invoke-MHSafeProcess {
        param([string]$Name, [string[]]$Arguments = @(), [int]$TimeoutMilliseconds = 5000, [int]$MaxOutputBytes = 65536, $Context)
        $key = $Name + '|' + ($Arguments -join ' ')
        $script:processCalls += [pscustomobject]@{ Name = $Name; Arguments = @($Arguments); Timeout = $TimeoutMilliseconds; HasContext = ($null -ne $Context) }
        if ($script:responses.ContainsKey($key)) { return $script:responses[$key] }
        return [pscustomobject]@{ found = $false; exitCode = $null; timedOut = $false; errorCode = 'NOT_FOUND'; stdout = '' }
    }
function Get-Content {
        param([string]$LiteralPath, [string]$Path, [switch]$Raw, [string]$Encoding, [string]$ErrorAction)
        $candidate = if ($LiteralPath) { $LiteralPath } else { $Path }
        if ($candidate -and [IO.Path]::GetFileName($candidate) -match '^(?:id_|.*private.*|.*secret.*)') { $script:privateReadAttempts++; throw 'PRIVATE_FILE_READ_BLOCKED' }
    Microsoft.PowerShell.Management\Get-Content @PSBoundParameters
}
Assert-PlatformTools (Test-MHPlatformReparsePath -Path '\\server.invalid\share\profile') 'UNC-backed profile roots are rejected before network filesystem checks'

    $context = New-MHCollectionContext -Profile Standard -Roots @($fixtureHome) -MaxDepth 2
    $context | Add-Member -NotePropertyName userProfile -NotePropertyValue $fixtureHome
    $context | Add-Member -NotePropertyName jetBrainsRoot -NotePropertyValue (Join-Path $fixtureHome 'AppData\Roaming\JetBrains')
    $context | Add-Member -NotePropertyName dockerRoot -NotePropertyValue $dockerDir
    $context | Add-Member -NotePropertyName dockerDesktopRoot -NotePropertyValue $dockerDesktop
    $context | Add-Member -NotePropertyName composeRoots -NotePropertyValue @($fixtureHome)
    $context | Add-Member -NotePropertyName gpgHome -NotePropertyValue (Join-Path $fixtureHome '.gnupg')
    $result = Get-MHPlatformToolsCollection -Context $context
    $payload = $result.items[0]
    $serialized = ConvertTo-Json -InputObject $result -Depth 25 -Compress
    $jetbrainsProduct = @($payload.jetbrains.products | Where-Object version -eq '2025.1')[0]
    $collectorPath = Join-Path $repositoryRoot 'scripts\collectors\platform-tools.ps1'
    $tokens = $null
    $parseErrors = $null
    $collectorAst = [Management.Automation.Language.Parser]::ParseFile($collectorPath, [ref]$tokens, [ref]$parseErrors)
    $privateMetadataFunctions = @($collectorAst.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -in @('Get-MHPlatformPrivateKeyMetadata', 'Get-MHPlatformGpgPrivateKeyMetadata') }, $true))
    $privateMetadataSource = @($privateMetadataFunctions | ForEach-Object { $_.Body.Extent.Text }) -join "`n"
    $boundedReaderAst = @($collectorAst.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Read-MHPlatformBoundedText' }, $true))[0]
    $boundedReaderSource = $boundedReaderAst.Body.Extent.Text
    $pathGuardPosition = $boundedReaderSource.IndexOf('Test-MHPlatformReparsePath', [StringComparison]::Ordinal)
    $metadataPosition = $boundedReaderSource.IndexOf('Get-Item', [StringComparison]::Ordinal)
    $sizeGuardPosition = $boundedReaderSource.IndexOf('$file.Length -gt $MaxBytes', [StringComparison]::Ordinal)
    $openPosition = $boundedReaderSource.IndexOf('FileStream', [StringComparison]::Ordinal)
    Assert-PlatformTools ($result.domain -eq 'platformTools' -and $result.status -in @('OK', 'PARTIAL')) 'collector returns the shared domain result contract'
    Assert-PlatformTools (@($payload.jetbrains.products | Where-Object version -eq '2025.1').Count -eq 1) 'JetBrains product/version discovery is retained'
    Assert-PlatformTools (@($jetbrainsProduct.plugins | Where-Object { $_ -eq 'org.example.sample' }).Count -eq 1) 'JetBrains plugin names are inventoried without cache copying'
    Assert-PlatformTools (@($jetbrainsProduct.artifacts | Where-Object { $_.id -like '*keymap*' }).Count -eq 1 -and $jetbrainsProduct.jvmOptions.state -eq 'PRESENT') 'keymap artifact and JVM options metadata are retained'
    Assert-PlatformTools ($jetbrainsProduct.syncState.state -eq 'PRESENT' -and $jetbrainsProduct.syncState.enabled -eq 'UNKNOWN') 'sync configuration presence is distinguished from active sync state'
    Assert-PlatformTools (@($payload.containers.contexts | Where-Object name -eq 'fixture-context').Count -eq 1 -and $payload.containers.composeFiles.Count -eq 1) 'static Docker context and bounded Compose metadata are discovered'
    Assert-PlatformTools ($payload.containers.wslIntegration.enabled -eq $true -and @($payload.containers.wslIntegration.integratedDistributions).Count -eq 1) 'Docker Desktop WSL integration is discovered from static settings'
    Assert-PlatformTools ($payload.containers.images.state -eq 'NOT_TESTED' -and $payload.containers.namedVolumes.state -eq 'NOT_TESTED' -and $payload.containers.localOnlyRisk.state -eq 'UNKNOWN') 'daemon inventory is left untested with a local-only risk marker'
    Assert-PlatformTools (@($payload.ssh.hosts | Where-Object name -eq 'work-alias').Count -eq 1 -and @($payload.ssh.publicKeys | Where-Object algorithm -eq 'ssh-ed25519').Count -eq 1) 'SSH host aliases and public-key metadata are retained'
    Assert-PlatformTools (@($payload.gpg.publicFingerprints | Where-Object fingerprint -eq '0123456789ABCDEF0123456789ABCDEF01234567').Count -eq 1 -and @($payload.gpg.signingMappings | Where-Object keyId -eq '0123456789ABCDEF').Count -eq 1) 'GPG public fingerprints and signing-key mapping are retained'
    Assert-PlatformTools (@($payload.manualItems | Where-Object reason -eq 'MANUAL_TRANSFER_REQUIRED').Count -ge 2) 'SSH and GPG private-key presence requires manual transfer'
    Assert-PlatformTools ($script:privateReadAttempts -eq 0 -and $serialized -notmatch 'PRIVATE_KEY_SENTINEL|GPG_PRIVATE_KEY_SENTINEL') 'private-key fixture files were never opened through content APIs or serialized'
    Assert-PlatformTools ($parseErrors.Count -eq 0 -and $privateMetadataFunctions.Count -eq 2 -and $privateMetadataSource -notmatch '(?i)Get-Content|ReadAll(Text|Bytes|Lines)|ReadLines|OpenRead|StreamReader') 'private-key code paths are structurally limited to filesystem metadata enumeration'
    Assert-PlatformTools ($pathGuardPosition -ge 0 -and $metadataPosition -gt $pathGuardPosition -and $sizeGuardPosition -gt $metadataPosition -and $openPosition -gt $sizeGuardPosition) 'bounded reader checks reparse paths and file size before opening content'
    Assert-PlatformTools ($serialized -notmatch 'DOCKER_AUTH_SENTINEL|DOCKER_SETTINGS_SECRET|SSH_CONFIG_SENTINEL|SECRET_SENTINEL|UID_SECRET_SENTINEL') 'Docker credentials, unsafe SSH directives, and GPG UIDs are absent'
    Assert-PlatformTools (@($script:processCalls | Where-Object { $_.Name -match '^(?:docker|podman)(?:-compose)?\.exe$' -and ($_.Arguments -join ' ') -notin @('--version', 'version --short') }).Count -eq 0) 'container probes never issue daemon operations'
    Assert-PlatformTools (@($script:processCalls | Where-Object { -not $_.HasContext }).Count -eq 0) 'all process probes receive the shared deadline and budget context'

    $linkedHome = Join-Path $tempRoot 'linked-ssh-home'
    $linkedContext = New-MHCollectionContext -Profile Standard -Roots @($fixtureHome) -MaxDepth 2
    $linkedContext | Add-Member -NotePropertyName userProfile -NotePropertyValue $linkedHome
    $linkedContext | Add-Member -NotePropertyName jetBrainsRoot -NotePropertyValue (Join-Path $tempRoot 'linked-jetbrains-root')
    $linkedContext | Add-Member -NotePropertyName dockerRoot -NotePropertyValue (Join-Path $tempRoot 'linked-docker-root')
    $linkedContext | Add-Member -NotePropertyName dockerDesktopRoot -NotePropertyValue (Join-Path $tempRoot 'linked-docker-root')
    $linkedContext | Add-Member -NotePropertyName composeRoots -NotePropertyValue @((Join-Path $tempRoot 'linked-compose-root'))
    $linkedContext | Add-Member -NotePropertyName gpgHome -NotePropertyValue (Join-Path $tempRoot 'linked-gpg-root')
    $linkedResult = Get-MHPlatformToolsCollection -Context $linkedContext
    $linkedPayload = $linkedResult.items[0]
    $linkedText = ConvertTo-Json -InputObject $linkedResult -Depth 25 -Compress
    Assert-PlatformTools (@($linkedPayload.ssh.hosts | Where-Object name -eq 'EXTERNAL_SSH_SENTINEL').Count -eq 0 -and $linkedPayload.ssh.status -eq 'PARTIAL') 'SSH reparse-point ancestor is skipped and reported partial'
    Assert-PlatformTools (@($linkedPayload.jetbrains.products | Where-Object product -eq 'Rider').Count -eq 0 -and $linkedResult.warnings -contains 'JETBRAINS_PARTIAL') 'JetBrains reparse root is skipped and reported partial'
    Assert-PlatformTools (@($linkedPayload.containers.wslIntegration.integratedDistributions | Where-Object { $_ -eq 'EXTERNAL_DOCKER_SENTINEL' }).Count -eq 0 -and $linkedPayload.containers.staticMetadataStatus -eq 'PARTIAL') 'Docker settings reparse root is skipped and reported partial'
    Assert-PlatformTools ($linkedPayload.containers.composeFiles.Count -eq 0 -and $linkedPayload.containers.staticMetadataStatus -eq 'PARTIAL') 'Compose reparse root is skipped and reported partial'
    Assert-PlatformTools (@($linkedPayload.manualItems | Where-Object { $_.domain -eq 'gpg' }).Count -eq 0 -and $linkedText -notmatch 'EXTERNAL_GPG_SENTINEL') 'GPG private-key reparse root is skipped without reading its target'

    if ($sshConfigSymlink -or $sshPublicKeySymlink -or $dockerSettingsSymlink -or $dockerContextSymlink -or $gpgLegacySymlink) {
        $leafContext = New-MHCollectionContext -Profile Standard -Roots @($fixtureHome) -MaxDepth 2
        $leafContext | Add-Member -NotePropertyName userProfile -NotePropertyValue $linkedFileHome
        $leafContext | Add-Member -NotePropertyName jetBrainsRoot -NotePropertyValue (Join-Path $fixtureHome 'AppData\Roaming\JetBrains')
        $leafContext | Add-Member -NotePropertyName dockerRoot -NotePropertyValue $dockerDir
        $leafContext | Add-Member -NotePropertyName dockerDesktopRoot -NotePropertyValue $linkedFileDocker
        $leafContext | Add-Member -NotePropertyName composeRoots -NotePropertyValue @($fixtureHome)
        $leafContext | Add-Member -NotePropertyName gpgHome -NotePropertyValue $legacyGpgHome
        $leafResult = Get-MHPlatformToolsCollection -Context $leafContext
        $leafPayload = $leafResult.items[0]
        $leafText = ConvertTo-Json -InputObject $leafResult -Depth 25 -Compress
        Assert-PlatformTools (@($leafPayload.ssh.hosts | Where-Object name -eq 'EXTERNAL_SSH_SENTINEL').Count -eq 0 -and @($leafPayload.ssh.publicKeys | Where-Object fileName -eq 'id_external.pub').Count -eq 0) 'SSH config and public-key leaf symlinks are skipped'
        Assert-PlatformTools ($leafPayload.containers.wslIntegration.enabled -ne $true -and @($leafPayload.containers.contexts | Where-Object name -eq 'EXTERNAL_CONTEXT_SENTINEL').Count -eq 0) 'Docker settings and context metadata leaf symlinks are skipped'
        Assert-PlatformTools (@($leafPayload.manualItems | Where-Object { $_.domain -eq 'gpg' }).Count -eq 0 -and $leafText -notmatch 'EXTERNAL_GPG_LEGACY_SENTINEL') 'GPG legacy secret-keyring symlink is skipped without opening its target'
    }

    $oversizedContext = New-MHCollectionContext -Profile Standard -Roots @($fixtureHome)
    $oversizedContext | Add-Member -NotePropertyName userProfile -NotePropertyValue $oversizedHome
    $oversizedResult = Get-MHPlatformSsh -Context $oversizedContext
    Assert-PlatformTools ($oversizedResult.status -eq 'PARTIAL' -and @($oversizedResult.hosts | Where-Object name -eq 'OVERSIZED_SSH_SENTINEL').Count -eq 0) 'oversized SSH config is rejected before parsing content'

    $emptyBudget = New-MHCollectionContext -Profile Standard -Roots @($fixtureHome)
    $emptyBudget.budgets.processTimeoutMs = 1
    $emptyBudget.deadline = [DateTimeOffset]::UtcNow.AddMilliseconds(-1)
    $partial = Get-MHPlatformToolsCollection -Context $emptyBudget
    Assert-PlatformTools ($partial.status -in @('PARTIAL', 'UNAVAILABLE')) 'deadline exhaustion produces a domain-local incomplete status'
} finally {
    $env:Path = $originalPath
    if (Test-Path -LiteralPath $tempRoot -PathType Container) { Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue }
}
Write-Output 'Platform tools collector tests passed.'
