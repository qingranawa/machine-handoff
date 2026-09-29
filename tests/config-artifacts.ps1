[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repositoryRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $repositoryRoot 'scripts\state.ps1')
. (Join-Path $repositoryRoot 'scripts\lib\model.ps1')
. (Join-Path $repositoryRoot 'scripts\lib\config-artifacts.ps1')

function Assert-ConfigArtifact {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw ('Config artifact check failed: ' + $Message) }
    Write-Output ('PASS: ' + $Message)
}

$root = Join-Path ([IO.Path]::GetTempPath()) ('mh-config-' + [guid]::NewGuid().ToString('N'))
[void](New-Item -ItemType Directory -Path $root)
try {
    $context = New-MHCollectionContext -Profile Deep
    $jsonPath = Join-Path $root 'mcp.json'
    $jsonText = '{"command":"server","args":["--stdio"],"apiKey":"SYNTHETIC_SECRET_1","env":{"TOKEN":"SYNTHETIC_SECRET_2","MODE":"safe"}}'
    [IO.File]::WriteAllText($jsonPath, $jsonText, (New-Object System.Text.UTF8Encoding($false)))
    $artifact = New-MHConfigArtifact -Context $context -Id 'agents:mcp' -Domain 'agents' -SourcePath $jsonPath -TargetPathCandidate '%USERPROFILE%\.config\agent\mcp.json' -ContentPolicy REDACTED_COPY -Sensitivity PRIVATE -Format JSON -ArtifactPath 'configs/agents/mcp.json' -RestorePolicy REVIEW -ValidationStrategy NORMALIZED_CONFIG
    Assert-ConfigArtifact -Condition ($artifact.artifact.captureState -eq 'CAPTURED' -and $artifact.artifact.redactionStatus -eq 'REDACTED') -Message 'nested JSON secrets are redacted and captured'
    Assert-ConfigArtifact -Condition ($artifact.content.Contains('"command"') -and $artifact.content.Contains('--stdio') -and $artifact.content.Contains('"MODE"') -and $artifact.content.Contains('"safe"')) -Message 'nonsecret MCP fields are preserved'
    Assert-ConfigArtifact -Condition (-not $artifact.content.Contains('SYNTHETIC_SECRET_1') -and -not $artifact.content.Contains('SYNTHETIC_SECRET_2')) -Message 'synthetic secret values are absent from the artifact'
    Assert-ConfigArtifact -Condition ($artifact.artifact.artifactSha256 -match '^[A-Fa-f0-9]{64}$') -Message 'artifact hash covers the sanitized content'
    Test-MHSerializedText -Text $artifact.content
    Assert-ConfigArtifact -Condition $true -Message 'final package scanner accepts a sanitized config with redaction markers'

    $boundedSourcePath = Join-Path $root 'bounded-reader.json'
    [IO.File]::WriteAllText($boundedSourcePath, '{}', (New-Object System.Text.UTF8Encoding($false)))
    $originalBoundedReader = (Get-Item Function:Read-MHBoundedUtf8Text).ScriptBlock
    $script:boundedReaderCalled = $false
    $script:boundedReaderLimit = 0L
    $script:boundedReaderPath = $boundedSourcePath
    $script:originalBoundedReader = $originalBoundedReader
    try {
        Set-Item Function:Read-MHBoundedUtf8Text -Value {
            param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][long]$MaxBytes)
            $script:boundedReaderCalled = $true
            $script:boundedReaderLimit = $MaxBytes
            if ($Path -ne $script:boundedReaderPath) { throw 'UNEXPECTED_CONFIG_PATH' }
            return & $script:originalBoundedReader -Path $Path -MaxBytes $MaxBytes
        }
        $boundedContext = New-MHCollectionContext -Profile Deep
        $boundedContext.budgets.maxConfigBytes = 64
        $boundedArtifact = New-MHConfigArtifact -Context $boundedContext -Id 'test:bounded-reader' -Domain 'test' -SourcePath $boundedSourcePath -TargetPathCandidate '%TEMP%\bounded-reader.json' -ContentPolicy SAFE_COPY -Sensitivity PRIVATE -Format JSON -ArtifactPath 'configs/test/bounded-reader.json' -RestorePolicy REVIEW -ValidationStrategy HASH
    } finally {
        $boundedReaderUsed = [bool]$script:boundedReaderCalled
        $observedReaderLimit = [long]$script:boundedReaderLimit
        Set-Item Function:Read-MHBoundedUtf8Text -Value $originalBoundedReader
        Remove-Variable boundedReaderCalled, boundedReaderLimit, boundedReaderPath, originalBoundedReader -Scope Script -ErrorAction SilentlyContinue
    }
    Assert-ConfigArtifact -Condition ($boundedReaderUsed -and $observedReaderLimit -eq 64 -and $boundedArtifact.artifact.captureState -eq 'CAPTURED') -Message 'config artifact reads go through the shared byte-bounded UTF-8 reader'

    Test-MHSerializedText -Text '{"credentialHelper":"manager-core","privateKeyState":"NOT_COLLECTED","apiKeyConfigured":true}'
    Assert-ConfigArtifact -Condition $true -Message 'secret scanning permits safe credential and private-key metadata'
    $serializedRedactionMarker = ConvertTo-Json -InputObject ([pscustomobject]@{ apiKey = '<REDACTED>' }) -Compress
    Assert-ConfigArtifact -Condition (-not (Test-MHConfigSecretText -Text $serializedRedactionMarker)) -Message 'PowerShell JSON escaping of redaction markers is accepted by the raw scanner'

    $embeddedSecretPath = Join-Path $root 'embedded-secret.json'
    $embeddedSecretValue = 'description contains OPENAI_API_KEY=SYNTHETIC_JSON_STRING_KEY'
    $embeddedSecretJson = ConvertTo-Json -InputObject ([pscustomobject]@{ description = $embeddedSecretValue }) -Compress
    [IO.File]::WriteAllText($embeddedSecretPath, $embeddedSecretJson, (New-Object System.Text.UTF8Encoding($false)))
    $embeddedSecretArtifact = New-MHConfigArtifact -Context (New-MHCollectionContext -Profile Deep) -Id 'test:embedded-secret' -Domain 'test' -SourcePath $embeddedSecretPath -TargetPathCandidate '%TEMP%\embedded-secret.json' -ContentPolicy REDACTED_COPY -Sensitivity PRIVATE -Format JSON -ArtifactPath 'configs/test/embedded-secret.json' -RestorePolicy REVIEW -ValidationStrategy NORMALIZED_CONFIG
    Assert-ConfigArtifact -Condition ($embeddedSecretArtifact.artifact.captureState -eq 'CAPTURED' -and $embeddedSecretArtifact.artifact.redactionStatus -eq 'REDACTED' -and $embeddedSecretArtifact.content.Contains('<REDACTED>') -and -not $embeddedSecretArtifact.content.Contains('SYNTHETIC_JSON_STRING_KEY')) -Message 'embedded secret assignments in JSON string values are redacted'
    $safeCopyArtifact = New-MHConfigArtifact -Context (New-MHCollectionContext -Profile Deep) -Id 'test:safe-copy-secret' -Domain 'test' -SourcePath $embeddedSecretPath -TargetPathCandidate '%TEMP%\embedded-secret.json' -ContentPolicy SAFE_COPY -Sensitivity PRIVATE -Format JSON -ArtifactPath 'configs/test/embedded-secret-safe.json' -RestorePolicy REVIEW -ValidationStrategy NORMALIZED_CONFIG
    Assert-ConfigArtifact -Condition ($safeCopyArtifact.artifact.captureState -eq 'BLOCKED' -and $safeCopyArtifact.artifact.errorCode -eq 'REDACTION_REQUIRED' -and $null -eq $safeCopyArtifact.content) -Message 'SAFE_COPY refuses JSON containing embedded secret assignments'

    $jsoncPath = Join-Path $root 'settings.json'
    $jsoncText = "{`n  // user comment`n  `"url`": `"https://example.invalid/a//b`",`n  `"items`": [1, 2,],`n}`n"
    [IO.File]::WriteAllText($jsoncPath, $jsoncText, (New-Object System.Text.UTF8Encoding($false)))
    $jsonc = New-MHConfigArtifact -Context $context -Id 'vscode:settings' -Domain 'editors' -SourcePath $jsoncPath -TargetPathCandidate '%APPDATA%\Code\User\settings.json' -ContentPolicy REDACTED_COPY -Sensitivity PRIVATE -Format JSONC -ArtifactPath 'configs/vscode/settings.json' -RestorePolicy REVIEW -ValidationStrategy NORMALIZED_CONFIG
    Assert-ConfigArtifact -Condition ($jsonc.artifact.captureState -eq 'CAPTURED' -and $jsonc.content.Contains('https://example.invalid/a//b')) -Message 'JSONC comments and trailing commas are handled without corrupting strings'

    $npmrcPath = Join-Path $root '.npmrc'
    $npmrcText = "registry=https://registry.npmjs.org/`n//registry.npmjs.org/:_authToken=SYNTHETIC_NPM_TOKEN`nalways-auth=true`n"
    [IO.File]::WriteAllText($npmrcPath, $npmrcText, (New-Object System.Text.UTF8Encoding($false)))
    $npmrc = New-MHConfigArtifact -Context $context -Id 'node:npmrc' -Domain 'node' -SourcePath $npmrcPath -TargetPathCandidate '%USERPROFILE%\.npmrc' -ContentPolicy REDACTED_COPY -Sensitivity PRIVATE -Format INI -ArtifactPath 'configs/node/npmrc' -RestorePolicy REVIEW -ValidationStrategy NORMALIZED_CONFIG
    Assert-ConfigArtifact -Condition ($npmrc.artifact.captureState -eq 'CAPTURED' -and -not $npmrc.content.Contains('SYNTHETIC_NPM_TOKEN')) -Message 'npm auth token is removed while registry configuration remains migratable'

    $connectionStringPath = Join-Path $root 'database.ini'
    [IO.File]::WriteAllText($connectionStringPath, 'Server=db.example;Database=app;User ID=service-user;Pwd={SYNTHETIC_CONNECTION_PASSWORD;TAIL_SECRET};Encrypt=true;', (New-Object System.Text.UTF8Encoding($false)))
    $connectionStringArtifact = New-MHConfigArtifact -Context $context -Id 'test:connection-string' -Domain 'test' -SourcePath $connectionStringPath -TargetPathCandidate '%APPDATA%\Test\database.ini' -ContentPolicy REDACTED_COPY -Sensitivity SENSITIVE -Format INI -ArtifactPath 'configs/test/database.ini' -RestorePolicy REVIEW -ValidationStrategy NORMALIZED_CONFIG
    Assert-ConfigArtifact -Condition ($connectionStringArtifact.artifact.captureState -eq 'CAPTURED' -and $connectionStringArtifact.content.Contains('Pwd=<REDACTED>') -and -not $connectionStringArtifact.content.Contains('SYNTHETIC_CONNECTION_PASSWORD') -and -not $connectionStringArtifact.content.Contains('TAIL_SECRET') -and -not $connectionStringArtifact.content.Contains('service-user')) -Message 'connection string User ID and braced Pwd values are redacted completely'
    $unsafeConnectionStringArtifact = New-MHConfigArtifact -Context $context -Id 'test:safe-copy-connection-string' -Domain 'test' -SourcePath $connectionStringPath -TargetPathCandidate '%APPDATA%\Test\database.ini' -ContentPolicy SAFE_COPY -Sensitivity SENSITIVE -Format INI -ArtifactPath 'configs/test/database-safe.ini' -RestorePolicy REVIEW -ValidationStrategy NORMALIZED_CONFIG
    Assert-ConfigArtifact -Condition ($unsafeConnectionStringArtifact.artifact.captureState -eq 'BLOCKED' -and $unsafeConnectionStringArtifact.artifact.errorCode -in @('REDACTION_REQUIRED', 'REDACTION_BLOCKED') -and $null -eq $unsafeConnectionStringArtifact.content) -Message 'SAFE_COPY blocks connection strings containing credential fields'

    $textSecretPath = Join-Path $root 'profile.txt'
    $textSecret = '$env:OPENAI_API_KEY = "SYNTHETIC_OPENAI_ENV_KEY_VALUE"' + [Environment]::NewLine + '$client = "sk-proj-SYNTHETIC_OPENAI_TOKEN_VALUE12345"'
    [IO.File]::WriteAllText($textSecretPath, $textSecret, (New-Object System.Text.UTF8Encoding($false)))
    $textArtifact = New-MHConfigArtifact -Context $context -Id 'shell:profile' -Domain 'shell' -SourcePath $textSecretPath -TargetPathCandidate '%USERPROFILE%\Documents\PowerShell\profile.ps1' -ContentPolicy REDACTED_COPY -Sensitivity SENSITIVE -Format TEXT -ArtifactPath 'configs/shell/profile.txt' -RestorePolicy REVIEW -ValidationStrategy MANUAL_REVIEW
    Assert-ConfigArtifact -Condition ($textArtifact.artifact.captureState -eq 'CAPTURED' -and $textArtifact.artifact.redactionStatus -eq 'REDACTED' -and -not $textArtifact.content.Contains('SYNTHETIC_OPENAI_ENV_KEY_VALUE') -and -not $textArtifact.content.Contains('SYNTHETIC_OPENAI_TOKEN_VALUE12345')) -Message 'prefixed OpenAI assignments and sk-proj token values are redacted from text artifacts'
    Test-MHSerializedText -Text $textArtifact.content
    Assert-ConfigArtifact -Condition $true -Message 'redacted prefixed text artifact passes the final serialized-output scanner'

    $unsupportedPath = Join-Path $root 'settings.bin'
    [IO.File]::WriteAllBytes($unsupportedPath, [byte[]]@(0, 255, 0, 255))
    $unsupported = New-MHConfigArtifact -Context $context -Id 'unknown:binary' -Domain 'unknown' -SourcePath $unsupportedPath -TargetPathCandidate $null -ContentPolicy REDACTED_COPY -Sensitivity UNKNOWN -Format UNKNOWN -ArtifactPath 'configs/unknown/data.bin' -RestorePolicy REVIEW -ValidationStrategy MANUAL
    Assert-ConfigArtifact -Condition ($unsupported.artifact.captureState -eq 'BLOCKED' -and $null -eq $unsupported.content) -Message 'unsupported formats fail closed without storing content'
}
finally {
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Output 'Config artifact suite passed.'
