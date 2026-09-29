[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repositoryRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
. (Join-Path $repositoryRoot 'scripts\state.ps1')
. (Join-Path $repositoryRoot 'scripts\lib\model.ps1')
. (Join-Path $repositoryRoot 'scripts\lib\process.ps1')
. (Join-Path $repositoryRoot 'scripts\lib\config-artifacts.ps1')

function Assert-GitPowerShell {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw ('Git/PowerShell collector check failed: ' + $Message) }
    Write-Output ('PASS: ' + $Message)
}

# Keep process coverage deterministic and entirely in memory.  The production
# collector still receives the shared Context parameter and uses the shared
# safe-process API; this fixture prevents the test from touching host commands.
function Invoke-MHSafeProcess {
    param(
        [Parameter(Mandatory)][string]$Name,
        [string[]]$Arguments = @(),
        [int]$TimeoutMilliseconds = 5000,
        [int]$MaxOutputBytes = 65536,
        $Context
    )

    if ($Name -in @('git.exe', 'git')) {
        $argumentList = @($Arguments)
        if ($argumentList.Count -gt 0 -and $argumentList[0] -eq 'config' -and $argumentList -contains '--system') {
            if ($argumentList -contains '--list') {
                $tokens = @(
                    'file:C:\ProgramData\Git\config', 'core.autocrlf',
                    'file:C:\ProgramData\Git\config', 'user.email',
                    'file:C:\ProgramData\Git\config', 'credential.helper',
                    'file:C:\ProgramData\Git\config', 'alias.co',
                    'file:C:\ProgramData\Git\config', 'alias.run',
                    'file:C:\ProgramData\Git\config', 'include.path',
                    'file:C:\ProgramData\Git\config', 'gpg.format'
                )
                return [pscustomobject]@{ found = $true; started = $true; exitCode = 0; timedOut = $false; stdout = [string]::Join([string][char]0, $tokens) + [char]0; stderr = ''; errorCode = $null }
            }
            if ($argumentList -contains '--get-all') {
                $key = [string]$argumentList[$argumentList.Count - 1]
                $value = switch -CaseSensitive ($key) {
                    'core.autocrlf' { 'false' }
                    'user.email' { 'system@example.test' }
                    'credential.helper' { 'manager-core --timeout=900' }
                    'alias.co' { 'status --short' }
                    'alias.run' { '!powershell -NoProfile -Command Write-Output fixture' }
                    'include.path' { 'C:\ProgramData\Git\system-includes.gitconfig' }
                    'gpg.format' { 'ssh' }
                    default { $null }
                }
                if ($null -eq $value) { return [pscustomobject]@{ found = $true; started = $true; exitCode = 1; timedOut = $false; stdout = ''; stderr = ''; errorCode = $null } }
                $tokens = @('file:C:\ProgramData\Git\config', $value)
                return [pscustomobject]@{ found = $true; started = $true; exitCode = 0; timedOut = $false; stdout = [string]::Join([string][char]0, $tokens) + [char]0; stderr = ''; errorCode = $null }
            }
        }
        return [pscustomobject]@{ found = $true; started = $true; exitCode = 0; timedOut = $false; stdout = 'git version 99.1.2.windows.1'; stderr = ''; errorCode = $null }
    }
    if ($Name -in @('pwsh', 'powershell.exe')) {
        return [pscustomobject]@{ found = $true; started = $true; exitCode = 0; timedOut = $false; stdout = '7.99.1'; stderr = ''; errorCode = $null }
    }
    return [pscustomobject]@{ found = $false; started = $false; exitCode = $null; timedOut = $false; stdout = ''; stderr = ''; errorCode = 'NOT_FOUND' }
}

. (Join-Path $repositoryRoot 'scripts\collectors\git-powershell.ps1')

$fixtureRoot = Join-Path ([IO.Path]::GetTempPath()) ('mh-git-powershell-' + [guid]::NewGuid().ToString('N'))
$fixtureHome = Join-Path $fixtureRoot 'home'
$fixtureConfig = Join-Path $fixtureHome '.gitconfig'
$fixtureIgnore = Join-Path $fixtureHome '.config\git\ignore'
$fixtureProfile = Join-Path $fixtureHome 'Documents\PowerShell\Microsoft.PowerShell_profile.ps1'
$fixtureProfileCurrent = Join-Path $fixtureHome 'Documents\PowerShell\CurrentUserCurrentHost.ps1'
$fixtureProfileJwt = Join-Path $fixtureHome 'Documents\PowerShell\JwtProfile.ps1'
$fixtureProfileBinary = Join-Path $fixtureHome 'Documents\PowerShell\BinaryProfile.ps1'
$remoteSecret = 'remote-' + [guid]::NewGuid().ToString('N')
$profileSecret = 'profile-' + [guid]::NewGuid().ToString('N')
$profileUrlSecret = 'url-' + [guid]::NewGuid().ToString('N')
$ignoreSecret = 'ignore-' + [guid]::NewGuid().ToString('N')
$jwtValue = 'eyJ' + ('a' * 20) + '.' + ('b' * 20) + '.' + ('c' * 20)

try {
    New-Item -ItemType Directory -Path (Split-Path -Parent $fixtureIgnore) -Force | Out-Null
    New-Item -ItemType Directory -Path (Split-Path -Parent $fixtureProfile) -Force | Out-Null
    @'
[user]
    name = Fixture User
    email = fixture@example.test
    signingkey = C:\Users\Fixture\.ssh\id_ed25519
[credential]
    helper = manager-core --timeout=900
[credential "https://fixture:PLACEHOLDER@example.test"]
    helper = !fixture-helper
[remote "origin"]
    url = https://fixture:PLACEHOLDER@example.test/org/repo.git
[include]
    path = ../included.gitconfig
[includeIf "gitdir:C:/fixture/"]
    path = ../conditional.gitconfig
[core]
    excludesFile = ~/.config/git/ignore
    autocrlf = false
    filemode = true
[commit]
    gpgsign = true
[gpg]
    format = ssh
'@.Replace('PLACEHOLDER', $remoteSecret) | Set-Content -LiteralPath $fixtureConfig -Encoding UTF8
    @'
*.fixture-secret
KEEP_IGNORE_PATTERN
npm_auth_token = PLACEHOLDER_IGNORE
'@.Replace('PLACEHOLDER_IGNORE', $ignoreSecret) | Set-Content -LiteralPath $fixtureIgnore -Encoding UTF8
    ('$safeSetting = "PROFILE_SAFE_KEEP"' + [Environment]::NewLine + '$token = "' + $profileSecret + '"' + [Environment]::NewLine + '$endpoint = "https://fixture:' + $profileUrlSecret + '@example.test/path"' + [Environment]::NewLine + 'function Prompt { ''fixture'' }') | Set-Content -LiteralPath $fixtureProfile -Encoding UTF8
    'function Prompt { ''current'' }' | Set-Content -LiteralPath $fixtureProfileCurrent -Encoding UTF8
    ('$safeSetting = "JWT_PROFILE_SAFE"' + [Environment]::NewLine + '$jwt = "' + $jwtValue + '"' + [Environment]::NewLine + 'function Prompt { ''jwt'' }') | Set-Content -LiteralPath $fixtureProfileJwt -Encoding UTF8
    [IO.File]::WriteAllBytes($fixtureProfileBinary, [byte[]](0xFF, 0xFE, 0x00, 0x01))

    $context = New-MHCollectionContext -Profile Standard -SkipDefaultRoots
    $context | Add-Member -NotePropertyName userHome -NotePropertyValue $fixtureHome
    $context | Add-Member -NotePropertyName gitConfigPaths -NotePropertyValue @($fixtureConfig)
    $context | Add-Member -NotePropertyName profilePaths -NotePropertyValue @(
        [pscustomobject]@{ name = 'CurrentUserAllHosts'; path = $fixtureProfile },
        [pscustomobject]@{ name = 'CurrentUserCurrentHost'; path = $fixtureProfileCurrent },
        [pscustomobject]@{ name = 'JwtProfile'; path = $fixtureProfileJwt },
        [pscustomobject]@{ name = 'BinaryProfile'; path = $fixtureProfileBinary }
    )

    $result = Get-MHGitPowerShellCollection -Context $context
    $git = @($result.items | Where-Object id -eq 'git:global')[0]
    $shell = @($result.items | Where-Object id -eq 'shell:powershell')[0]
    $serialized = ConvertTo-Json -InputObject $result -Depth 30 -Compress

    Assert-GitPowerShell -Condition ($result.domain -eq 'git-powershell') -Message 'collector returns the shared domain result shape'
    Assert-GitPowerShell -Condition ($null -ne $git -and $null -ne $shell) -Message 'collector emits stable Git and PowerShell item IDs'
    Assert-GitPowerShell -Condition ($git.configState -eq 'PRESENT' -and $git.scope -eq 'global') -Message 'synthetic global Git config is detected with global scope'
    $systemAutocrlf = @($git.systemSettings | Where-Object key -eq 'core.autocrlf')[0]
    $systemAlias = @($git.aliases | Where-Object { $_.scope -eq 'system' -and $_.name -eq 'co' })[0]
    $systemShellAlias = @($git.aliases | Where-Object { $_.scope -eq 'system' -and $_.name -eq 'run' })[0]
    Assert-GitPowerShell -Condition ($git.systemConfigState -eq 'OK' -and @($git.systemConfigFiles | Where-Object { $_.path -eq 'C:\ProgramData\Git\config' -and $_.scope -eq 'system' }).Count -eq 1) -Message 'system Git config files and scope are recorded independently'
    Assert-GitPowerShell -Condition ($null -ne $systemAutocrlf -and $systemAutocrlf.value -eq 'false' -and $systemAutocrlf.origin -eq 'C:\ProgramData\Git\config' -and @($git.settings | Where-Object { $_.key -eq 'core.autocrlf' -and $_.scope -eq 'system' }).Count -eq 1) -Message 'system allowlisted settings retain their config origin and scope'
    Assert-GitPowerShell -Condition (@($git.systemCredentialHelpers | Where-Object { $_.type -eq 'manager-core' -and $_.origin -eq 'C:\ProgramData\Git\config' }).Count -eq 1 -and @($git.systemCredentialHelpers | Where-Object { $_.type -match 'timeout|900' }).Count -eq 0) -Message 'system credential helper records type and origin without arguments'
    Assert-GitPowerShell -Condition ($null -ne $systemAlias -and $systemAlias.value -eq 'status --short' -and $null -ne $systemShellAlias -and $null -eq $systemShellAlias.value -and $systemShellAlias.execution -eq 'NEVER_RUN') -Message 'system Git aliases are scoped while shell alias commands are never copied or run'
    Assert-GitPowerShell -Condition (@($git.includeRules | Where-Object { $_.PSObject.Properties['scope'] -and $_.scope -eq 'system' -and $_.sourcePath -eq 'C:\ProgramData\Git\config' -and -not $_.followed }).Count -eq 1) -Message 'system include paths retain origin without following included files'
    Assert-GitPowerShell -Condition (@($git.includeRules).Count -eq 3 -and (@($git.includeRules | Where-Object { -not $_.followed }).Count -eq 3)) -Message 'global and system include paths are recorded without following files'
    Assert-GitPowerShell -Condition (@($git.credentialHelpers | Where-Object { $_.scope -eq 'global' -and $_.type -eq 'manager-core' }).Count -eq 1 -and @($git.credentialHelpers | Where-Object { $_.scope -eq 'global' -and $_.type -eq 'custom' }).Count -eq 1) -Message 'global credential helpers preserve type only'
    $remoteSetting = @($git.settings | Where-Object key -like 'remote.*.url')[0]
    Assert-GitPowerShell -Condition ($null -ne $remoteSetting -and [string]$remoteSetting.value -match '<redacted>') -Message 'remote URL credentials are redacted before persistence'
    Assert-GitPowerShell -Condition ($git.signing.keyConfigured -and $git.signing.privateKeyState -eq 'NOT_COLLECTED' -and $git.signing.restorePolicy -eq 'REVIEW') -Message 'signing metadata never captures private key material'
    $artifactRows = @($result.configArtifacts | ForEach-Object { if ($_.PSObject.Properties['artifact']) { $_.artifact } else { $_ } })
    $artifactResults = @($result.configArtifacts)
    $globalIgnoreResult = @($artifactResults | Where-Object { $_.artifact.id -eq 'git:global-ignore' })[0]
    $safeProfileResult = @($artifactResults | Where-Object { $_.artifact.id -eq 'shell:powershell-profile:CurrentUserAllHosts' })[0]
    $jwtProfileResult = @($artifactResults | Where-Object { $_.artifact.id -eq 'shell:powershell-profile:JwtProfile' })[0]
    $binaryProfileResult = @($artifactResults | Where-Object { $_.artifact.id -eq 'shell:powershell-profile:BinaryProfile' })[0]
    $jwtProfile = @($shell.profiles | Where-Object id -eq 'shell:powershell-profile:JwtProfile')[0]
    $binaryProfile = @($shell.profiles | Where-Object id -eq 'shell:powershell-profile:BinaryProfile')[0]
    Assert-GitPowerShell -Condition ($git.globalIgnore.state -eq 'PRESENT' -and $git.globalIgnore.contentPolicy -eq 'REDACTED_COPY' -and $git.globalIgnore.captureState -eq 'CAPTURED' -and $git.globalIgnore.restorePolicy -eq 'REVIEW') -Message 'global ignore is captured as a review-gated redacted copy'
    Assert-GitPowerShell -Condition (@($shell.profiles | Where-Object { $_.state -eq 'PRESENT' -and $_.executable -and $_.contentPolicy -eq 'REDACTED_COPY' -and $_.execution -eq 'NEVER_RUN' -and $_.restorePolicy -eq 'REVIEW' }).Count -eq 4) -Message 'PowerShell profiles are executable redacted-copy review metadata'
    Assert-GitPowerShell -Condition (@($result.configArtifacts).Count -ge 6) -Message 'Git config, ignore, and PowerShell profile artifacts are exposed'
    Assert-GitPowerShell -Condition (@($artifactRows | Where-Object { $_.id -like 'git:global-config:*' -and $_.sourceLocator -eq 'C:\ProgramData\Git\config' }).Count -eq 0 -and @($artifactRows | Where-Object { $_.id -like 'git:system-config:*' -and $_.sourceLocator -eq 'C:\ProgramData\Git\config' }).Count -eq 1) -Message 'system config metadata uses the system artifact classification'
    Assert-GitPowerShell -Condition (@($artifactRows | Where-Object { $_.domain -eq 'git' -and $_.id -ne 'git:global-ignore' -and ($_.contentPolicy -ne 'METADATA_ONLY' -or $_.restorePolicy -ne 'REVIEW') }).Count -eq 0) -Message 'complete Git config remains metadata-only and review-gated'
    Assert-GitPowerShell -Condition ($null -ne $globalIgnoreResult -and $globalIgnoreResult.artifact.captureState -eq 'CAPTURED' -and $globalIgnoreResult.artifact.redactionStatus -eq 'REDACTED' -and [string]$globalIgnoreResult.content -like '*KEEP_IGNORE_PATTERN*' -and [string]$globalIgnoreResult.content -like '*<REDACTED>*') -Message 'global ignore keeps safe patterns and redacts auth-like values'
    Assert-GitPowerShell -Condition ($null -ne $safeProfileResult -and $safeProfileResult.artifact.captureState -eq 'CAPTURED' -and $safeProfileResult.artifact.redactionStatus -eq 'REDACTED' -and [string]$safeProfileResult.content -like '*PROFILE_SAFE_KEEP*' -and [string]$safeProfileResult.content -like '*<REDACTED>*' -and [string]$safeProfileResult.content -notlike ('*' + $profileSecret + '*') -and [string]$safeProfileResult.content -notlike ('*' + $profileUrlSecret + '*')) -Message 'profile text keeps safe fields while redacting token and URL credentials'
    Assert-GitPowerShell -Condition ($null -ne $jwtProfileResult -and $jwtProfileResult.artifact.captureState -eq 'BLOCKED' -and $null -eq $jwtProfileResult.content -and $jwtProfileResult.artifact.restorePolicy -eq 'REVIEW') -Message 'JWT-bearing profile fails closed to blocked manual migration metadata'
    Assert-GitPowerShell -Condition ($null -ne $jwtProfile -and $jwtProfile.captureState -eq 'BLOCKED' -and $jwtProfile.migrationAction -eq 'MANUAL_TRANSFER' -and $jwtProfile.execution -eq 'NEVER_RUN') -Message 'blocked profile item exposes manual migration metadata without execution'
    Assert-GitPowerShell -Condition ($null -ne $binaryProfileResult -and $binaryProfileResult.artifact.captureState -eq 'BLOCKED' -and $null -eq $binaryProfileResult.content -and $null -ne $binaryProfile -and $binaryProfile.migrationAction -eq 'MANUAL_TRANSFER') -Message 'invalid UTF-8 profile fails closed without reading binary content'
    Assert-GitPowerShell -Condition ($serialized -notlike ('*' + $remoteSecret + '*') -and $serialized -notlike ('*' + $profileSecret + '*') -and $serialized -notlike ('*' + $profileUrlSecret + '*') -and $serialized -notlike ('*' + $ignoreSecret + '*') -and $serialized -notlike ('*' + $jwtValue + '*')) -Message 'synthetic credential, token, URL, ignore, and JWT values never enter serialization'
    Test-MHSerializedText -Text $serialized
    Assert-GitPowerShell -Condition (-not (Test-MHConfigSecretText -Text $serialized)) -Message 'serialized collector result passes the shared and raw secret-pattern guards'
} finally {
    if (Test-Path -LiteralPath $fixtureRoot -PathType Container) {
        Remove-Item -LiteralPath $fixtureRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Write-Output 'Git/PowerShell collector suite passed.'
