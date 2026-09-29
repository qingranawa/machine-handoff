[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repositoryRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $repositoryRoot 'scripts\state.ps1')
. (Join-Path $repositoryRoot 'scripts\lib\model.ps1')
. (Join-Path $repositoryRoot 'scripts\lib\config-artifacts.ps1')
. (Join-Path $repositoryRoot 'scripts\lib\package.ps1')

function Assert-PackageSecurity {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw ('Package security check failed: ' + $Message) }
    Write-Output ('PASS: ' + $Message)
}

$tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')
$fixtureRoot = Join-Path $tempRoot ('mh-security-' + [guid]::NewGuid().ToString('N'))
$packagePath = Join-Path $fixtureRoot 'package'
[void](New-Item -ItemType Directory -Path $packagePath -Force)
try {
    $sourcePath = Join-Path $fixtureRoot 'mcp.json'
    $secretValues = @(
        'SYNTHETIC_API_SECRET', 'SYNTHETIC_TOKEN_SECRET', 'SYNTHETIC_OPENAI_VALUE', 'SYNTHETIC_AWS_VALUE',
        'SYNTHETIC_NPM_VALUE', 'SYNTHETIC_BEARER_VALUE', 'SYNTHETIC_URL_PASSWORD', 'SYNTHETIC_PYPI_TOKEN_VALUE',
        'SYNTHETIC_SSH_PRIVATE_SENTINEL', 'SYNTHETIC_GPG_PRIVATE_SENTINEL', 'SYNTHETIC_ENV_SENTINEL', 'SYNTHETIC_JWT_VALUE'
    )
    $secretValues[7] = 'pypi-' + ('A' * 32)
    $sourceText = ConvertTo-Json -InputObject ([pscustomobject]@{
        command = 'server'
        apiKey = $secretValues[0]
        env = [pscustomobject]@{ TOKEN = $secretValues[1]; MODE = 'safe' }
        description = 'OPENAI_API_KEY=' + $secretValues[2] + '; AWS_SECRET_ACCESS_KEY=' + $secretValues[3] + '; npm_auth_token=' + $secretValues[4]
        authorization = 'Bearer ' + $secretValues[5]
        endpoint = 'https://fixture:' + $secretValues[6] + '@example.invalid/path'
        pypi = $secretValues[7]
    }) -Compress
    [IO.File]::WriteAllText($sourcePath, $sourceText, (New-Object System.Text.UTF8Encoding($false)))
    $context = New-MHCollectionContext -Profile Deep
    $artifact = New-MHConfigArtifact -Context $context -Id 'agent:mcp' -Domain 'agents' -SourcePath $sourcePath -TargetPathCandidate '%USERPROFILE%\.agent\mcp.json' -ContentPolicy REDACTED_COPY -Sensitivity PRIVATE -Format JSON -ArtifactPath 'configs/agents/mcp.json' -RestorePolicy REVIEW -ValidationStrategy NORMALIZED_CONFIG
    Assert-PackageSecurity -Condition ($artifact.artifact.captureState -eq 'CAPTURED') -Message 'synthetic MCP config produces a captured sanitized artifact'

    $sshPrivatePath = Join-Path $fixtureRoot 'id_ed25519'
    $gpgPrivatePath = Join-Path $fixtureRoot 'privatekey-v1'
    $envPath = Join-Path $fixtureRoot '.env'
    [IO.File]::WriteAllText($sshPrivatePath, $secretValues[8], (New-Object System.Text.UTF8Encoding($false)))
    [IO.File]::WriteAllText($gpgPrivatePath, $secretValues[9], (New-Object System.Text.UTF8Encoding($false)))
    [IO.File]::WriteAllText($envPath, 'TOKEN=' + $secretValues[10], (New-Object System.Text.UTF8Encoding($false)))
    $neverCollected = @(
        (New-MHConfigArtifact -Context $context -Id 'ssh:private-key' -Domain 'ssh' -SourcePath $sshPrivatePath -TargetPathCandidate $null -ContentPolicy NEVER_COLLECT -Sensitivity SENSITIVE -Format UNKNOWN -ArtifactPath 'configs/ssh/private-key.metadata.json' -RestorePolicy MANUAL_TRANSFER -ValidationStrategy MANUAL),
        (New-MHConfigArtifact -Context $context -Id 'gpg:private-key' -Domain 'gpg' -SourcePath $gpgPrivatePath -TargetPathCandidate $null -ContentPolicy NEVER_COLLECT -Sensitivity SENSITIVE -Format UNKNOWN -ArtifactPath 'configs/gpg/private-key.metadata.json' -RestorePolicy MANUAL_TRANSFER -ValidationStrategy MANUAL),
        (New-MHConfigArtifact -Context $context -Id 'env:file' -Domain 'env' -SourcePath $envPath -TargetPathCandidate $null -ContentPolicy NEVER_COLLECT -Sensitivity SENSITIVE -Format UNKNOWN -ArtifactPath 'configs/env/file.metadata.json' -RestorePolicy MANUAL_TRANSFER -ValidationStrategy MANUAL)
    )
    $jwtPath = Join-Path $fixtureRoot 'jwt.json'
    $jwt = 'eyJ' + ('a' * 20) + '.' + ('b' * 20) + '.' + ('c' * 20)
    $secretValues[11] = $jwt
    [IO.File]::WriteAllText($jwtPath, (ConvertTo-Json -InputObject ([pscustomobject]@{ description = $jwt }) -Compress), (New-Object System.Text.UTF8Encoding($false)))
    $jwtArtifact = New-MHConfigArtifact -Context $context -Id 'agent:jwt-config' -Domain 'agents' -SourcePath $jwtPath -TargetPathCandidate $null -ContentPolicy REDACTED_COPY -Sensitivity SENSITIVE -Format JSON -ArtifactPath 'configs/agents/jwt.json' -RestorePolicy REVIEW -ValidationStrategy MANUAL
    Assert-PackageSecurity -Condition ($jwtArtifact.artifact.captureState -eq 'BLOCKED' -and $null -eq $jwtArtifact.content) -Message 'unredactable JWT metadata is retained without saving its body'

    $snapshot = [pscustomobject]@{ schemaVersion = 2; schemaMarker = 'synthetic-security-test' }
    $files = [ordered]@{ 'manifests/source.snapshot.json' = (ConvertTo-Json $snapshot -Compress) + [Environment]::NewLine }
    $configArtifacts = @($artifact) + @($neverCollected | ForEach-Object { $_.artifact }) + @($jwtArtifact)
    [void](Write-MHPackageTransaction -PackagePath $packagePath -Files $files -ConfigArtifacts $configArtifacts -Context $context)

    $packageText = @()
    foreach ($file in Get-ChildItem -LiteralPath $packagePath -Recurse -File) { $packageText += Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8 }
    $allText = $packageText -join [Environment]::NewLine
    $leakedSecrets = @($secretValues | Where-Object { $allText.Contains($_) })
    Assert-PackageSecurity -Condition ($leakedSecrets.Count -eq 0) -Message 'synthetic API, cloud, bearer, URL, package, SSH, GPG, env, and JWT secrets occur zero times across the generated Package'
    $hasRedactionMarker = $allText.Contains('<REDACTED>')
    $hasCommand = $allText.Contains('"command"')
    $hasMode = $allText.Contains('"MODE"')
    Assert-PackageSecurity -Condition ($hasRedactionMarker -and $hasCommand -and $hasMode) -Message 'Package retains safe MCP structure and redaction markers'
    Assert-MHPackageGeneration -PackagePath $packagePath
} finally {
    Remove-Item -LiteralPath $fixtureRoot -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Output 'Package security suite passed.'
