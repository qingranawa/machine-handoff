Set-StrictMode -Version Latest

function New-MHConfigArtifactRecord {
    param(
        [string]$Id, [string]$Domain, [string]$SourcePath, [string]$TargetPathCandidate,
        [string]$ContentPolicy, [string]$Sensitivity, [string]$CaptureState,
        [string]$RedactionStatus, [string]$ArtifactPath, [string]$ArtifactSha256,
        [string]$RestorePolicy, [string]$ValidationStrategy, [string]$ErrorCode
    )

    return [pscustomobject]@{
        id = $Id
        domain = $Domain
        sourceLocator = $SourcePath
        targetPathCandidate = $TargetPathCandidate
        contentPolicy = $ContentPolicy
        sensitivity = $Sensitivity
        captureState = $CaptureState
        redactionStatus = $RedactionStatus
        artifactPath = $ArtifactPath
        artifactSha256 = $ArtifactSha256
        restorePolicy = $RestorePolicy
        dependsOn = @()
        validationStrategy = $ValidationStrategy
        errorCode = $ErrorCode
    }
}

function New-MHConfigArtifactResult {
    param($Artifact, [AllowNull()]$Content)
    return [pscustomobject]@{ artifact = $Artifact; content = $Content }
}

function ConvertFrom-MHJsonc {
    param([Parameter(Mandatory)][string]$Text)

    $withoutComments = New-Object System.Text.StringBuilder
    $inString = $false
    $escaped = $false
    $lineComment = $false
    $blockComment = $false
    for ($index = 0; $index -lt $Text.Length; $index++) {
        $character = $Text[$index]
        $next = if ($index + 1 -lt $Text.Length) { $Text[$index + 1] } else { [char]0 }
        if ($lineComment) {
            if ($character -eq "`r" -or $character -eq "`n") { $lineComment = $false; [void]$withoutComments.Append($character) }
            continue
        }
        if ($blockComment) {
            if ($character -eq '*' -and $next -eq '/') { $blockComment = $false; $index++ }
            elseif ($character -eq "`r" -or $character -eq "`n") { [void]$withoutComments.Append($character) }
            continue
        }
        if ($inString) {
            [void]$withoutComments.Append($character)
            if ($escaped) { $escaped = $false; continue }
            if ($character -eq '\') { $escaped = $true; continue }
            if ($character -eq '"') { $inString = $false }
            continue
        }
        if ($character -eq '"') { $inString = $true; [void]$withoutComments.Append($character); continue }
        if ($character -eq '/' -and $next -eq '/') { $lineComment = $true; $index++; continue }
        if ($character -eq '/' -and $next -eq '*') { $blockComment = $true; $index++; continue }
        [void]$withoutComments.Append($character)
    }
    if ($blockComment) { throw 'INVALID_CONFIG' }

    $source = $withoutComments.ToString()
    $withoutTrailingCommas = New-Object System.Text.StringBuilder
    $inString = $false
    $escaped = $false
    for ($index = 0; $index -lt $source.Length; $index++) {
        $character = $source[$index]
        if ($inString) {
            [void]$withoutTrailingCommas.Append($character)
            if ($escaped) { $escaped = $false; continue }
            if ($character -eq '\') { $escaped = $true; continue }
            if ($character -eq '"') { $inString = $false }
            continue
        }
        if ($character -eq '"') { $inString = $true; [void]$withoutTrailingCommas.Append($character); continue }
        if ($character -eq ',') {
            $lookahead = $index + 1
            while ($lookahead -lt $source.Length -and [char]::IsWhiteSpace($source[$lookahead])) { $lookahead++ }
            if ($lookahead -lt $source.Length -and ($source[$lookahead] -eq '}' -or $source[$lookahead] -eq ']')) { continue }
        }
        [void]$withoutTrailingCommas.Append($character)
    }
    return $withoutTrailingCommas.ToString()
}

function Test-MHConfigSecretName {
    param([string]$Name)
    $normalized = ($Name -replace '[\s_-]', '').ToLowerInvariant()
    if ($normalized -in @('issecret', 'hassecret', 'secretpresent', 'issecretpresent', 'istoken', 'hastoken', 'tokenpresent', 'privatekeystate', 'privatekeyconfigured', 'keyconfigured', 'credentialhelper', 'credentialhelpertype', 'credentialtype', 'authstate', 'authenticationstate')) { return $false }
    $sensitiveSuffixes = @('apikey', 'apikeyvalue', 'accesstoken', 'refreshtoken', 'token', 'tokenvalue', 'clientsecret', 'secret', 'secretvalue', 'password', 'passwd', 'pwd', 'username', 'userid', 'uid', 'cookie', 'cookies', 'authorizationheader', 'authorization', 'authheader', 'credential', 'credentials', 'privatekey', 'accesskey', 'bitlockerkey')
    foreach ($suffix in $sensitiveSuffixes) { if ($normalized.EndsWith($suffix, [StringComparison]::Ordinal)) { return $true } }
    return $false
}

function ConvertTo-MHRedactedConfigValue {
    param($Value, [ref]$RedactionCount)

    if ($null -eq $Value) { return $Value }
    if ($Value -is [string]) {
        $redactedText = ConvertTo-MHRedactedText -Text $Value
        if ($redactedText -ne $Value) { $RedactionCount.Value++ }
        return $redactedText
    }
    if ($Value.GetType().IsValueType) { return $Value }
    if ($Value -is [System.Collections.IDictionary]) {
        foreach ($key in @($Value.Keys)) {
            if (Test-MHConfigSecretName -Name ([string]$key)) {
                if ($null -ne $Value[$key] -and [string]$Value[$key] -ne '<REDACTED>') { $RedactionCount.Value++ }
                $Value[$key] = '<REDACTED>'
            } else { $Value[$key] = ConvertTo-MHRedactedConfigValue -Value $Value[$key] -RedactionCount $RedactionCount }
        }
        return $Value
    }
    if ($Value -is [System.Collections.IEnumerable]) {
        $items = @()
        foreach ($item in $Value) { $items += ConvertTo-MHRedactedConfigValue -Value $item -RedactionCount $RedactionCount }
        return ,$items
    }
    foreach ($property in @($Value.PSObject.Properties)) {
        if (Test-MHConfigSecretName -Name $property.Name) {
            if ($null -ne $property.Value -and [string]$property.Value -ne '<REDACTED>') { $RedactionCount.Value++ }
            $property.Value = '<REDACTED>'
        } else { $property.Value = ConvertTo-MHRedactedConfigValue -Value $property.Value -RedactionCount $RedactionCount }
    }
    return $Value
}

function ConvertTo-MHRedactedText {
    param([Parameter(Mandatory)][string]$Text)

    if ($Text -match '(?i)-----BEGIN [A-Z ]*PRIVATE KEY-----') { throw 'REDACTION_BLOCKED' }
    $keyPattern = '(?im)(?<prefix>\b(?:[A-Za-z0-9][A-Za-z0-9.-]*[_-])?(?:npm[_-]?auth[_-]?token|_auth[_-]?token|auth[_-]?token|_auth|_password|username|user[ _-]?id|uid|api[_-]?key|access[_-]?token|refresh[_-]?token|client[_-]?secret|secret[_-]?access[_-]?key|access[_-]?key|password|passwd|pwd|token|secret|cookie|authorization|credential|private[_-]?key)\b\s*[:=]\s*)(?:(?<double>"[^"]*")|(?<single>''[^'']*'')|(?<braced>\{[^}]*\})|(?<bare>[^\s,;#]+))'
    $safeText = [regex]::Replace($Text, $keyPattern, {
        param($match)
        $quote = if ($match.Groups['double'].Success) { '"' } elseif ($match.Groups['single'].Success) { "'" } else { '' }
        return $match.Groups['prefix'].Value + $quote + '<REDACTED>' + $quote
    })
    $safeText = [regex]::Replace($safeText, '(?i)\bBearer\s+[A-Za-z0-9._~+/-]{12,}', 'Bearer <REDACTED>')
    $safeText = [regex]::Replace($safeText, '(?i)\bsk-(?:proj-)?[A-Za-z0-9_-]{16,}\b', '<REDACTED>')
    $safeText = [regex]::Replace($safeText, '(?i)\bpypi-[A-Za-z0-9_-]{32,}\b', '<REDACTED>')
    $safeText = [regex]::Replace($safeText, '(?i)(?<scheme>://)[^/\s:@]+:[^/\s@]+@', '${scheme}<REDACTED>@')
    return $safeText
}

function Test-MHConfigSecretText {
    param([AllowNull()][string]$Text, [switch]$Structured)
    if ($null -eq $Text) { return $false }
    $probe = $Text
    $patterns = @()
    if (-not $Structured) {
        $patterns += '(?i)\b(?:[A-Za-z0-9][A-Za-z0-9.-]*[_-])?(?:npm[_-]?auth[_-]?token|_auth[_-]?token|auth[_-]?token|_auth|_password|username|user[ _-]?id|uid|api[_-]?key|access[_-]?token|refresh[_-]?token|client[_-]?secret|secret[_-]?access[_-]?key|access[_-]?key|password|passwd|pwd|authorization|cookie|private[_-]?key|bitlocker[_-]?key)\b["'']?\s*[:=]\s*(?:"(?!(?:<REDACTED>|\\u003cREDACTED\\u003e))[^"]+"|''(?!(?:<REDACTED>|\\u003cREDACTED\\u003e))[^'']+''|\{(?!(?:<REDACTED>|\\u003cREDACTED\\u003e))[^}]+\}|(?:(?!["''<])(?!(?:<REDACTED>|\\u003cREDACTED\\u003e))[^,\s;}\]]+))'
    }
    $patterns += @(
        '(?i)\bbearer\s+[A-Za-z0-9._~+/-]{12,}',
        '(?i)\bsk-(?:proj-)?[A-Za-z0-9_-]{16,}\b',
        '(?i)\bpypi-[A-Za-z0-9_-]{32,}\b',
        '(?i)://[^/\s:@]+:[^/\s@]+@',
        '\b(?:gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|AKIA[0-9A-Z]{16})\b',
        '\beyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\b',
        '-----BEGIN [A-Z ]*PRIVATE KEY-----'
    )
    foreach ($pattern in $patterns) { if ($probe -match $pattern) { return $true } }
    return $false
}

function Get-MHArtifactSha256 {
    param([Parameter(Mandatory)][string]$Text)
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [Text.Encoding]::UTF8.GetBytes($Text)
        return ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-', '').ToLowerInvariant()
    } finally { $sha.Dispose() }
}

function New-MHConfigArtifact {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Context,
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)][string]$Domain,
        [Parameter(Mandatory)][string]$SourcePath,
        [AllowNull()][string]$TargetPathCandidate,
        [Parameter(Mandatory)][ValidateSet('METADATA_ONLY', 'SAFE_COPY', 'REDACTED_COPY', 'MANUAL_TRANSFER', 'NEVER_COLLECT')][string]$ContentPolicy,
        [Parameter(Mandatory)][ValidateSet('PUBLIC', 'PRIVATE', 'SENSITIVE', 'UNKNOWN')][string]$Sensitivity,
        [Parameter(Mandatory)][ValidateSet('JSON', 'JSONC', 'TEXT', 'INI', 'UNKNOWN')][string]$Format,
        [Parameter(Mandatory)][string]$ArtifactPath,
        [Parameter(Mandatory)][ValidateSet('RESTORE', 'REVIEW', 'SKIP', 'MANUAL_TRANSFER')][string]$RestorePolicy,
        [Parameter(Mandatory)][string]$ValidationStrategy
    )

    $normalizedArtifactPath = $ArtifactPath.Replace('\', '/')
    if ($normalizedArtifactPath -notmatch '^configs/[A-Za-z0-9._/-]{1,240}$' -or @($normalizedArtifactPath.Split('/') | Where-Object { $_ -in @('.', '..') }).Count -gt 0) {
        throw 'INVALID_ARTIFACT_PATH'
    }
    $sourceLocator = if ($SourcePath.Length -le 1024 -and -not (Test-MHConfigSecretText -Text $SourcePath)) { $SourcePath.Trim() } else { $null }
    $base = @{ Id = $Id; Domain = $Domain; SourcePath = $sourceLocator; TargetPathCandidate = $TargetPathCandidate; ContentPolicy = $ContentPolicy; Sensitivity = $Sensitivity; RestorePolicy = $RestorePolicy; ValidationStrategy = $ValidationStrategy }

    if ($ContentPolicy -eq 'NEVER_COLLECT') {
        $artifact = New-MHConfigArtifactRecord @base -CaptureState 'NOT_TESTED' -RedactionStatus 'NOT_APPLICABLE' -ArtifactPath $null -ArtifactSha256 $null -ErrorCode 'NEVER_COLLECT'
        return New-MHConfigArtifactResult -Artifact $artifact -Content $null
    }
    if ($ContentPolicy -eq 'MANUAL_TRANSFER') {
        $artifact = New-MHConfigArtifactRecord @base -CaptureState 'REVIEW_REQUIRED' -RedactionStatus 'NOT_APPLICABLE' -ArtifactPath $null -ArtifactSha256 $null -ErrorCode 'MANUAL_TRANSFER_REQUIRED'
        return New-MHConfigArtifactResult -Artifact $artifact -Content $null
    }
    if ($ContentPolicy -eq 'METADATA_ONLY') {
        $exists = Test-Path -LiteralPath $SourcePath -PathType Leaf
        $artifact = New-MHConfigArtifactRecord @base -CaptureState $(if ($exists) { 'METADATA_ONLY' } else { 'NOT_FOUND' }) -RedactionStatus 'NOT_APPLICABLE' -ArtifactPath $null -ArtifactSha256 $null -ErrorCode $null
        return New-MHConfigArtifactResult -Artifact $artifact -Content $null
    }
    if ($Format -eq 'UNKNOWN') {
        $artifact = New-MHConfigArtifactRecord @base -CaptureState 'BLOCKED' -RedactionStatus 'BLOCKED' -ArtifactPath $null -ArtifactSha256 $null -ErrorCode 'UNSUPPORTED_FORMAT'
        return New-MHConfigArtifactResult -Artifact $artifact -Content $null
    }

    try {
        [void](Assert-MHNoReparseAncestors -Path $SourcePath)
        if (-not (Test-Path -LiteralPath $SourcePath -PathType Leaf)) {
            $artifact = New-MHConfigArtifactRecord @base -CaptureState 'NOT_FOUND' -RedactionStatus 'NOT_TESTED' -ArtifactPath $null -ArtifactSha256 $null -ErrorCode 'SOURCE_NOT_FOUND'
            return New-MHConfigArtifactResult -Artifact $artifact -Content $null
        }
        $file = Get-Item -LiteralPath $SourcePath -Force -ErrorAction Stop
        if (($file.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'PATH_REPARSE_BLOCKED' }
        if ($file.Length -gt [long]$Context.budgets.maxConfigBytes) { throw 'CONFIG_SIZE_LIMIT' }
        if ([int]$Context.artifactBudget.capturedCount -ge [int]$Context.budgets.maxConfigArtifacts) { throw 'ARTIFACT_COUNT_LIMIT' }

        $text = Read-MHBoundedUtf8Text -Path $SourcePath -MaxBytes ([long]$Context.budgets.maxConfigBytes)

        $redactionCount = 0
        $content = $text
        if ($Format -eq 'JSON' -or $Format -eq 'JSONC') {
            $jsonText = if ($Format -eq 'JSONC') { ConvertFrom-MHJsonc -Text $text } else { $text }
            try { $parsed = ConvertFrom-Json -InputObject $jsonText -ErrorAction Stop } catch { throw 'INVALID_CONFIG' }
            $protected = ConvertTo-MHRedactedConfigValue -Value $parsed -RedactionCount ([ref]$redactionCount)
            if ($ContentPolicy -eq 'SAFE_COPY' -and $redactionCount -gt 0) { throw 'REDACTION_REQUIRED' }
            if ($ContentPolicy -eq 'REDACTED_COPY') {
                $content = ConvertTo-Json -InputObject $protected -Depth 60
                $content = [regex]::Replace($content, '(?i)\\u003cREDACTED\\u003e', '<REDACTED>') + [Environment]::NewLine
            }
        } elseif ($ContentPolicy -eq 'REDACTED_COPY') {
            $before = $content
            $content = ConvertTo-MHRedactedText -Text $content
            if ($content -ne $before) { $redactionCount = 1 }
        }

        if (Test-MHConfigSecretText -Text $content -Structured:($Format -in @('JSON', 'JSONC'))) { throw 'REDACTION_BLOCKED' }
        $contentBytes = [Text.Encoding]::UTF8.GetByteCount($content)
        if ($contentBytes -gt [long]$Context.budgets.maxConfigBytes) { throw 'CONFIG_SIZE_LIMIT' }
        if (([long]$Context.artifactBudget.capturedBytes + $contentBytes) -gt [long]$Context.budgets.maxArtifactBytes) { throw 'ARTIFACT_SIZE_LIMIT' }

        $hash = Get-MHArtifactSha256 -Text $content
        $redactionStatus = if ($redactionCount -gt 0) { 'REDACTED' } else { 'NOT_REQUIRED' }
        $directory = [IO.Path]::GetDirectoryName($normalizedArtifactPath.Replace('/', '\')).Replace('\', '/')
        $filename = [IO.Path]::GetFileNameWithoutExtension($normalizedArtifactPath)
        $extension = [IO.Path]::GetExtension($normalizedArtifactPath)
        $contentAddressedPath = $directory + '/' + $filename + '.' + $hash.Substring(0, 16) + $extension
        $artifact = New-MHConfigArtifactRecord @base -CaptureState 'CAPTURED' -RedactionStatus $redactionStatus -ArtifactPath $contentAddressedPath -ArtifactSha256 $hash -ErrorCode $null
        $Context.artifactBudget.capturedBytes = [long]$Context.artifactBudget.capturedBytes + $contentBytes
        $Context.artifactBudget.capturedCount = [int]$Context.artifactBudget.capturedCount + 1
        return New-MHConfigArtifactResult -Artifact $artifact -Content $content
    } catch {
        $code = [string]$_.Exception.Message
        if ($code -eq 'JSON_SIZE_LIMIT') { $code = 'CONFIG_SIZE_LIMIT' }
        if ($code -notin @('PATH_REPARSE_BLOCKED', 'CONFIG_SIZE_LIMIT', 'ARTIFACT_COUNT_LIMIT', 'ARTIFACT_SIZE_LIMIT', 'INVALID_CONFIG', 'REDACTION_REQUIRED', 'REDACTION_BLOCKED')) { $code = 'CONFIG_READ_FAILED' }
        $artifact = New-MHConfigArtifactRecord @base -CaptureState 'BLOCKED' -RedactionStatus 'BLOCKED' -ArtifactPath $null -ArtifactSha256 $null -ErrorCode $code
        return New-MHConfigArtifactResult -Artifact $artifact -Content $null
    }
}
