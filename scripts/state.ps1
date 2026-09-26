Set-StrictMode -Version Latest

function Test-MHSerializedText {
    param([Parameter(Mandatory)][string]$Text)
    $patterns = @(
        '(?i)["'']?(?:api[ _-]?key|access[ _-]?token|refresh[ _-]?token|password|passwd|client_secret|authorization|cookie|private[ _-]?key|bitlocker[ _-]?key)\s*["'']?\s*[:=]\s*["'']?[^"''\s,;\}\]]+',
        '(?i)\bbearer\s+[A-Za-z0-9._~+/-]{12,}',
        '(?i)://[^/\s:@]+:[^/\s@]+@',
        '\b(?:gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|AKIA[0-9A-Z]{16})\b',
        '\beyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\b',
        '-----BEGIN [A-Z ]*PRIVATE KEY-----'
    )
    foreach ($pattern in $patterns) {
        if ($Text -match $pattern) { throw 'REDACTION_BLOCKED' }
    }
}

function Write-MHAtomicText {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Text)
    Test-MHSerializedText -Text $Text
    $fullPath = Assert-MHNoReparseAncestors -Path $Path
    $parent = Split-Path -Parent $fullPath
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) { throw 'OUTPUT_PARENT_MISSING' }
    if (Test-Path -LiteralPath $fullPath) {
        $existing = Get-Item -LiteralPath $fullPath -Force
        if (($existing.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'OUTPUT_REPARSE_BLOCKED' }
    }
    $temp = Join-Path $parent ('.mh-' + [guid]::NewGuid().ToString('N') + '.tmp')
    $backup = Join-Path $parent ('.mh-backup-' + [guid]::NewGuid().ToString('N') + '.tmp')
    try {
        [IO.File]::WriteAllText($temp, $Text, (New-Object System.Text.UTF8Encoding($false)))
        if (Test-Path -LiteralPath $fullPath -PathType Leaf) { [IO.File]::Replace($temp, $fullPath, $backup) }
        else { [IO.File]::Move($temp, $fullPath) }
    } finally {
        if (Test-Path -LiteralPath $temp -PathType Leaf) { Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue }
        if (Test-Path -LiteralPath $backup -PathType Leaf) { Remove-Item -LiteralPath $backup -Force -ErrorAction SilentlyContinue }
    }
}

function Assert-MHNoReparseAncestors {
    param([Parameter(Mandatory)][string]$Path)
    $fullPath = [IO.Path]::GetFullPath($Path)
    $root = [IO.Path]::GetPathRoot($fullPath)
    $current = $root
    $relative = $fullPath.Substring($root.Length)
    foreach ($segment in @($relative -split '[\\/]+' | Where-Object { $_ })) {
        $current = Join-Path $current $segment
        try { $attributes = [IO.File]::GetAttributes($current) }
        catch [System.IO.FileNotFoundException] { break }
        catch [System.IO.DirectoryNotFoundException] { break }
        catch { throw 'PATH_CHECK_FAILED' }
        if (($attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'PATH_REPARSE_BLOCKED' }
    }
    return $fullPath
}

function Write-MHJson {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)]$Value)
    $json = ConvertTo-Json -InputObject $Value -Depth 60
    Write-MHAtomicText -Path $Path -Text ($json + [Environment]::NewLine)
}

function Get-MHField {
    param($Object, [string]$Name, $Default = $null)
    if ($null -eq $Object) { return $Default }
    if ($Object -is [System.Collections.IDictionary] -and $Object.Contains($Name)) { return $Object[$Name] }
    $property = $Object.PSObject.Properties[$Name]
    if ($property) { return $property.Value }
    return $Default
}

function Read-MHJson {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw 'INPUT_FILE_MISSING' }
    [void](Assert-MHNoReparseAncestors -Path $Path)
    $text = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 -ErrorAction Stop
    Test-MHSerializedText -Text $text
    try { return ConvertFrom-Json -InputObject $text -ErrorAction Stop } catch { throw 'INVALID_JSON' }
}

function Test-MHArrayShape {
    param($Value, [string[]]$RequiredProperties = @())
    if ($null -eq $Value) { return $true }
    if ($Value -is [string]) { return ($RequiredProperties.Count -eq 0) }
    if ($Value -is [System.Collections.IDictionary]) {
        foreach ($name in $RequiredProperties) { if (-not $Value.Contains($name)) { return $false } }
        return ($RequiredProperties.Count -gt 0)
    }
    if ($Value -is [System.Collections.IEnumerable]) { return $true }
    foreach ($name in $RequiredProperties) { if ($null -eq $Value.PSObject.Properties[$name]) { return $false } }
    return ($RequiredProperties.Count -gt 0)
}

function Test-MHSnapshot {
    param([Parameter(Mandatory)]$Snapshot)
    if ($Snapshot.schemaVersion -ne 1 -or $Snapshot.platform -ne 'windows') { throw 'UNSUPPORTED_SCHEMA' }
    if ([string]::IsNullOrWhiteSpace([string]$Snapshot.snapshotId) -or [string]::IsNullOrWhiteSpace([string]$Snapshot.sourceId)) { throw 'INVALID_SNAPSHOT' }
    if ($Snapshot.role -notin @('SOURCE', 'DESTINATION')) { throw 'INVALID_SNAPSHOT' }
    foreach ($key in @('collection', 'system', 'env', 'software', 'dev', 'shell', 'editors', 'agents', 'wsl', 'dataLocations', 'unbackedDataCandidates', 'manualItems')) {
        if ($null -eq $Snapshot.PSObject.Properties[$key]) { throw 'INVALID_SNAPSHOT' }
    }
    if ($null -eq $Snapshot.collection -or $null -eq $Snapshot.system -or $null -eq $Snapshot.env -or $null -eq $Snapshot.shell) { throw 'INVALID_SNAPSHOT' }
    $arrayFields = @{
        software = @('id', 'state')
        dev = @('id', 'state')
        editors = @('id', 'state')
        agents = @('id', 'state')
        wsl = @('id', 'state')
        dataLocations = @('id', 'state')
        unbackedDataCandidates = @('path', 'reason', 'status')
        manualItems = @('id')
    }
    foreach ($key in $arrayFields.Keys) {
        $value = Get-MHField -Object $Snapshot -Name $key
        if (-not (Test-MHArrayShape -Value $value -RequiredProperties $arrayFields[$key])) { throw 'INVALID_SNAPSHOT' }
    }
    $collection = Get-MHField -Object $Snapshot -Name 'collection'
    foreach ($key in @('roots', 'excludes')) {
        $value = Get-MHField -Object $collection -Name $key
        if (-not (Test-MHArrayShape -Value $value)) { throw 'INVALID_SNAPSHOT' }
    }
    $domainStatus = Get-MHField -Object $collection -Name 'domainStatus'
    if ($null -eq $domainStatus) { throw 'INVALID_SNAPSHOT' }
    $allowedCollectorStatuses = @('OK', 'PARTIAL', 'UNAVAILABLE', 'ERROR')
    if ($domainStatus -is [System.Collections.IDictionary]) { $collectorEntries = @($domainStatus.Values) }
    else { $collectorEntries = @($domainStatus.PSObject.Properties | ForEach-Object { $_.Value } | Where-Object { $null -ne $_.status }) }
    foreach ($entry in $collectorEntries) { if ($entry.status -notin $allowedCollectorStatuses) { throw 'INVALID_SNAPSHOT' } }
    foreach ($domain in @('software', 'dev', 'editors', 'agents', 'wsl', 'dataLocations')) {
        foreach ($item in @(Get-MHField -Object $Snapshot -Name $domain -Default @())) {
            if ([string]::IsNullOrWhiteSpace([string](Get-MHField -Object $item -Name 'id')) -or (Get-MHField -Object $item -Name 'state') -notin @('PRESENT', 'ABSENT', 'UNKNOWN')) { throw 'INVALID_SNAPSHOT' }
        }
    }
    foreach ($candidate in @(Get-MHField -Object $Snapshot -Name 'unbackedDataCandidates' -Default @())) {
        if ([string]::IsNullOrWhiteSpace([string](Get-MHField -Object $candidate -Name 'path')) -or (Get-MHField -Object $candidate -Name 'status') -notin @('CANDIDATE', 'CONFIRMED')) { throw 'INVALID_SNAPSHOT' }
    }
}

function Get-MHCollectorStatus {
    param($Snapshot, [string]$Domain)
    $collection = Get-MHField -Object $Snapshot -Name 'collection'
    $statuses = Get-MHField -Object $collection -Name 'domainStatus'
    $entry = Get-MHField -Object $statuses -Name $Domain
    $status = Get-MHField -Object $entry -Name 'status' -Default 'UNKNOWN'
    $metadata = Get-MHField -Object $entry -Name 'metadata'
    if ($Domain -eq 'data' -and ((Get-MHField -Object $metadata -Name 'scanTruncated') -or (Get-MHField -Object $metadata -Name 'skippedRootCount' -Default 0) -gt 0)) { return 'PARTIAL' }
    if ($Domain -eq 'wsl') {
        $probe = Get-MHField -Object $metadata -Name 'status'
        if ($probe -eq 'PARTIAL' -or $probe -eq 'NOT_TESTED') { return 'PARTIAL' }
        if ($probe -eq 'LIST_UNAVAILABLE') { return 'UNKNOWN' }
    }
    if ($Domain -eq 'software') {
        $wingetStatus = Get-MHField -Object $metadata -Name 'wingetStatus'
        if ($wingetStatus -in @('NOT_TESTED', 'EXPORT_UNAVAILABLE')) { return 'PARTIAL' }
    }
    return [string]$status
}

function New-MHDefaultDecisions {
    return [pscustomobject]@{ schemaVersion = 1; pathMappings = @(); exclusions = @(); policyOverrides = @(); approvals = @() }
}

function Test-MHDecisions {
    param([Parameter(Mandatory)]$Decisions)
    if ((Get-MHField -Object $Decisions -Name 'schemaVersion') -ne 1) { throw 'INVALID_DECISIONS' }
    foreach ($field in @('pathMappings', 'exclusions', 'policyOverrides', 'approvals')) {
        $property = $Decisions.PSObject.Properties[$field]
        if ($null -eq $property) { throw 'INVALID_DECISIONS' }
        $value = $property.Value
        if ($value -is [string] -or $value -is [System.Collections.IDictionary]) { throw 'INVALID_DECISIONS' }
    }
    foreach ($override in @(Get-MHField -Object $Decisions -Name 'policyOverrides' -Default @())) {
        if ([string]::IsNullOrWhiteSpace([string](Get-MHField -Object $override -Name 'component')) -or (Get-MHField -Object $override -Name 'restorePolicy') -notin @('RESTORE', 'REVIEW', 'SKIP')) { throw 'INVALID_DECISIONS' }
    }
}

function Get-MHEffectiveRestorePolicy {
    param([Parameter(Mandatory)][string]$Component, $Entry, $Decisions)
    $policy = Get-MHField -Object $Entry -Name 'restorePolicy' -Default 'REVIEW'
    if ($policy -notin @('RESTORE', 'REVIEW', 'SKIP')) { $policy = 'REVIEW' }
    $overrides = @(Get-MHField -Object $Decisions -Name 'policyOverrides' -Default @())
    foreach ($override in $overrides) {
        if ((Get-MHField -Object $override -Name 'component') -eq $Component) { $policy = [string](Get-MHField -Object $override -Name 'restorePolicy') }
    }
    $exclusions = @(Get-MHField -Object $Decisions -Name 'exclusions' -Default @())
    if ($exclusions -contains $Component) { $policy = 'SKIP' }
    return $policy
}

function ConvertTo-MHComparableItems {
    param([Parameter(Mandatory)]$Snapshot)
    $items = @()
    foreach ($item in @(Get-MHField -Object $Snapshot -Name 'software' -Default @())) { $items += [pscustomobject]@{ domain = 'software'; id = [string]$item.id; value = $item } }
    foreach ($item in @(Get-MHField -Object $Snapshot -Name 'dev' -Default @())) { $items += [pscustomobject]@{ domain = 'dev'; id = [string]$item.id; value = $item } }
    foreach ($item in @(Get-MHField -Object $Snapshot -Name 'editors' -Default @())) { $items += [pscustomobject]@{ domain = 'editors'; id = [string]$item.id; value = $item } }
    foreach ($item in @(Get-MHField -Object $Snapshot -Name 'agents' -Default @())) { $items += [pscustomobject]@{ domain = 'agents'; id = [string]$item.id; value = $item } }
    foreach ($item in @(Get-MHField -Object $Snapshot -Name 'wsl' -Default @())) { $items += [pscustomobject]@{ domain = 'wsl'; id = [string]$item.id; value = $item } }
    foreach ($item in @(Get-MHField -Object $Snapshot -Name 'dataLocations' -Default @())) { $items += [pscustomobject]@{ domain = 'data'; id = [string]$item.id; value = $item } }
    return @($items | Where-Object { $_.id })
}

function Get-MHRestoreSuggestion {
    param([string]$Domain, $Source, $Destination, [ValidateSet('RESTORE', 'REVIEW', 'SKIP')][string]$RestorePolicy = 'REVIEW')
    $sourceState = Get-MHField -Object $Source -Name 'state'
    $destinationState = Get-MHField -Object $Destination -Name 'state'
    if ($RestorePolicy -eq 'SKIP') { return @{ action = 'SKIP'; safety = 'AUTO'; risk = 'LOW'; reason = 'Excluded or marked SKIP in decisions.json; no restore action is planned.' } }
    if ($RestorePolicy -eq 'REVIEW') { return @{ action = 'REVIEW'; safety = 'MANUAL'; risk = 'MEDIUM'; reason = 'Restore policy is REVIEW; select RESTORE or SKIP in decisions.json after reviewing this component.' } }
    if ($Domain -eq 'agents' -and $Source -and $sourceState -eq 'PRESENT') { return @{ action = 'REAUTHENTICATE'; safety = 'MANUAL'; risk = 'MEDIUM'; reason = 'Recreate settings as needed, then sign in and verify MCP connections manually.' } }
    if ($Source -and $sourceState -eq 'ABSENT' -and $Destination -and $destinationState -eq 'PRESENT') { return @{ action = 'SKIP'; safety = 'AUTO'; risk = 'LOW'; reason = 'Not selected on source; destination already has it.' } }
    if ($Source -and $sourceState -eq 'PRESENT' -and (-not $Destination -or $destinationState -eq 'ABSENT')) {
        if ($Domain -in @('software', 'dev')) { return @{ action = 'INSTALL'; safety = 'CONFIRM'; risk = 'MEDIUM'; reason = 'Present on source and absent on destination; review package and version.' } }
        if ($Domain -eq 'data') { return @{ action = 'COPY'; safety = 'MANUAL'; risk = 'HIGH'; reason = 'Source path has no mapped destination; review backup and target first.' } }
        if ($Domain -eq 'agents') { return @{ action = 'REAUTHENTICATE'; safety = 'MANUAL'; risk = 'MEDIUM'; reason = 'Agent state is absent; recreate settings and sign in manually.' } }
        return @{ action = 'RECREATE'; safety = 'CONFIRM'; risk = 'MEDIUM'; reason = 'Present on source and absent on destination; review exact target.' }
    }
    return @{ action = 'REVIEW'; safety = 'MANUAL'; risk = 'MEDIUM'; reason = 'States differ or cannot be matched safely.' }
}

function Get-MHFingerprint {
    param([string]$Domain, $Value)
    switch ($Domain) {
        'software' { return [pscustomobject]@{ id = (Get-MHField $Value 'id'); state = (Get-MHField $Value 'state'); version = (Get-MHField $Value 'version'); packageId = (Get-MHField $Value 'packageId'); restorePolicy = (Get-MHField $Value 'restorePolicy') } }
        'dev' { return [pscustomobject]@{ id = (Get-MHField $Value 'id'); state = (Get-MHField $Value 'state'); version = (Get-MHField $Value 'version') } }
        'editors' { return [pscustomobject]@{ id = (Get-MHField $Value 'id'); state = (Get-MHField $Value 'state'); extensions = @(Get-MHField $Value 'extensions' -Default @()) } }
        'agents' {
            $files = @(Get-MHField -Object $Value -Name 'configFiles' -Default @() | ForEach-Object { [pscustomobject]@{ name = (Get-MHField -Object $_ -Name 'name'); state = (Get-MHField -Object $_ -Name 'state'); enablement = (Get-MHField -Object $_ -Name 'enablement' -Default 'UNKNOWN') } })
            return [pscustomobject]@{ id = (Get-MHField $Value 'id'); state = (Get-MHField $Value 'state'); auth = (Get-MHField $Value 'auth'); terminalIntegration = (Get-MHField -Object $Value -Name 'terminalIntegration' -Default 'UNKNOWN'); configFiles = @($files) }
        }
        'wsl' { return [pscustomobject]@{ id = (Get-MHField $Value 'id'); state = (Get-MHField $Value 'state'); version = (Get-MHField $Value 'version'); configState = (Get-MHField $Value 'configState'); safeSettings = @(Get-MHField $Value 'safeSettings' -Default @()) } }
        'data' {
            $git = Get-MHField -Object $Value -Name 'git'
            return [pscustomobject]@{ state = (Get-MHField $Value 'state'); type = (Get-MHField $Value 'type'); readability = (Get-MHField $Value 'readability'); git = $(if ($git) { [pscustomobject]@{ branch = (Get-MHField $git 'branch'); dirtyCount = (Get-MHField $git 'dirtyCount'); untrackedCount = (Get-MHField $git 'untrackedCount'); ahead = (Get-MHField $git 'ahead'); behind = (Get-MHField $git 'behind') } } else { $null }) }
        }
    }
    return $Value
}

function New-MHDiff {
    param([Parameter(Mandatory)]$Source, [Parameter(Mandatory)]$Destination, $Decisions)
    Test-MHSnapshot -Snapshot $Source
    Test-MHSnapshot -Snapshot $Destination
    $sourceItems = @(ConvertTo-MHComparableItems -Snapshot $Source | Where-Object { (Get-MHField -Object $_.value -Name 'state') -ne 'ABSENT' })
    $destinationItems = @(ConvertTo-MHComparableItems -Snapshot $Destination | Where-Object { (Get-MHField -Object $_.value -Name 'state') -ne 'ABSENT' })
    $destByKey = @{}
    foreach ($entry in $destinationItems) { $destByKey[($entry.domain + '|' + $entry.id)] = $entry.value }
    $sourceKeys = @{}
    $matchedDestinationKeys = @{}
    $diff = @()
    foreach ($entry in $sourceItems) {
        $key = $entry.domain + '|' + $entry.id
        $sourceKeys[$key] = $true
        $restorePolicy = Get-MHEffectiveRestorePolicy -Component $key -Entry $entry.value -Decisions $Decisions
        $destinationValue = $destByKey[$key]
        if ($entry.domain -eq 'data' -and $Decisions) {
            $mapping = @($Decisions.pathMappings | Where-Object { $_.sourceId -eq $entry.id -or $_.sourcePath -eq $entry.value.sourcePath } | Select-Object -First 1)
            if ($mapping.Count -gt 0) {
                $destinationValue = @($destinationItems | Where-Object { $_.value.sourcePath -eq $mapping[0].destinationPath } | Select-Object -First 1 | ForEach-Object { $_.value })
                if ($destinationValue.Count -gt 0) { $destinationValue = $destinationValue[0] } else { $destinationValue = $null }
            }
        }
        if ($destinationValue) { $matchedDestinationKeys[$entry.domain + '|' + $destinationValue.id] = $true }
        $sourceJson = ConvertTo-Json -InputObject (Get-MHFingerprint -Domain $entry.domain -Value $entry.value) -Depth 40 -Compress
        $destinationJson = if ($destinationValue) { ConvertTo-Json -InputObject (Get-MHFingerprint -Domain $entry.domain -Value $destinationValue) -Depth 40 -Compress } else { $null }
        if ($destinationValue -and $sourceJson -eq $destinationJson -and $entry.domain -ne 'agents') { continue }
        $suggestion = Get-MHRestoreSuggestion -Domain $entry.domain -Source $entry.value -Destination $destinationValue -RestorePolicy $restorePolicy
        $sourceCollectorStatus = Get-MHCollectorStatus -Snapshot $Source -Domain $entry.domain
        $destinationCollectorStatus = Get-MHCollectorStatus -Snapshot $Destination -Domain $entry.domain
        if ($restorePolicy -eq 'RESTORE' -and ($sourceCollectorStatus -ne 'OK' -or $destinationCollectorStatus -ne 'OK') -and $suggestion.action -ne 'SKIP') {
            $suggestion = @{ action = 'REVIEW'; safety = 'MANUAL'; risk = 'MEDIUM'; reason = ('Collector coverage is incomplete (source=' + $sourceCollectorStatus + ', destination=' + $destinationCollectorStatus + '); absence cannot be confirmed.') }
        }
        $status = if ($restorePolicy -eq 'SKIP') { 'SKIPPED' } elseif ($restorePolicy -eq 'REVIEW' -or $suggestion.action -eq 'REVIEW') { 'REVIEW' } else { 'PLANNED' }
        $diff += [pscustomobject]@{ component = $key; sourceState = $entry.value; destinationState = $destinationValue; desiredState = $entry.value; restorePolicy = $restorePolicy; action = $suggestion.action; risk = $suggestion.risk; safety = $suggestion.safety; reason = $suggestion.reason; preconditions = @('Review destination and target mapping'); verification = @('Re-collect destination and compare state'); status = $status }
    }
    foreach ($entry in $destinationItems) {
        $key = $entry.domain + '|' + $entry.id
        if ($sourceKeys.ContainsKey($key) -or $matchedDestinationKeys.ContainsKey($key)) { continue }
        $restorePolicy = Get-MHEffectiveRestorePolicy -Component $key -Entry $null -Decisions $Decisions
        $suggestion = Get-MHRestoreSuggestion -Domain $entry.domain -Source $null -Destination $entry.value -RestorePolicy $restorePolicy
        $reason = if ($restorePolicy -eq 'SKIP') { $suggestion.reason + ' Existing destination data is retained.' } else { 'Destination-only item; keep unless the user explicitly asks to remove it.' }
        $diff += [pscustomobject]@{ component = $key; sourceState = $null; destinationState = $entry.value; desiredState = $null; restorePolicy = $restorePolicy; action = $(if ($restorePolicy -eq 'SKIP') { 'SKIP' } else { 'REVIEW' }); risk = $suggestion.risk; safety = 'MANUAL'; reason = $reason; preconditions = @(); verification = @('No removal is performed'); status = $(if ($restorePolicy -eq 'SKIP') { 'SKIPPED' } else { 'REVIEW' }) }
    }
    return [pscustomobject]@{ schemaVersion = 1; sourceSnapshotId = $Source.snapshotId; destinationSnapshotId = $Destination.snapshotId; createdAt = [DateTimeOffset]::Now.ToString('o'); items = @($diff) }
}

function New-MHValidation {
    param([Parameter(Mandatory)]$Diff, $Source, $Destination, $Decisions)
    $checks = @()
    foreach ($item in @($Diff.items)) {
        $status = 'UNKNOWN'
        $evidence = 'No current verification evidence.'
        $sourceConfigState = Get-MHField -Object $item.sourceState -Name 'configState'
        $destinationConfigState = Get-MHField -Object $item.destinationState -Name 'configState'
        $sourceItemState = Get-MHField -Object $item.sourceState -Name 'state'
        $domain = [string]$item.component.Split('|')[0]
        $restorePolicy = Get-MHEffectiveRestorePolicy -Component ([string]$item.component) -Entry $item.sourceState -Decisions $Decisions
        $collectorFailed = (Get-MHCollectorStatus -Snapshot $Source -Domain $domain) -in @('ERROR', 'UNAVAILABLE', 'UNKNOWN') -or (Get-MHCollectorStatus -Snapshot $Destination -Domain $domain) -in @('ERROR', 'UNAVAILABLE', 'UNKNOWN')
        $collectorPartial = (Get-MHCollectorStatus -Snapshot $Source -Domain $domain) -eq 'PARTIAL' -or (Get-MHCollectorStatus -Snapshot $Destination -Domain $domain) -eq 'PARTIAL'
        if ($collectorFailed) { $status = 'UNKNOWN'; $evidence = 'A required collector did not produce a complete current result.' }
        elseif ($collectorPartial) { $status = 'WARN'; $evidence = 'A bounded collector reached a limit; review coverage.' }
        elseif ($restorePolicy -eq 'SKIP' -or $item.action -eq 'SKIP') { $status = 'WARN'; $evidence = 'Skipped by source/destination policy.' }
        elseif ($restorePolicy -eq 'REVIEW') { $status = 'WARN'; $evidence = 'Restore policy is REVIEW; this component is not selected for restoration.' }
        elseif ($item.action -eq 'REAUTHENTICATE') { $status = 'UNKNOWN'; $evidence = 'Sign-in and MCP connectivity require a separate live check.' }
        elseif ($item.action -eq 'COPY' -and -not $item.destinationState) { $status = 'UNKNOWN'; $evidence = 'No confirmed target path or copy operation.' }
        elseif ($item.component -like 'wsl|*' -and ($sourceConfigState -eq 'UNKNOWN' -or $destinationConfigState -eq 'UNKNOWN')) { $status = 'UNKNOWN'; $evidence = 'Linux /etc/wsl.conf was not inspected without starting a distribution.' }
        elseif ($item.destinationState -and $item.sourceState -and $item.action -eq 'REVIEW') { $status = 'WARN'; $evidence = 'Destination item exists but differs; review required.' }
        elseif ($item.sourceState -and $sourceItemState -eq 'PRESENT' -and -not $item.destinationState -and $restorePolicy -eq 'RESTORE') { $status = 'FAIL'; $evidence = 'Selected source item is absent from destination snapshot.' }
        elseif ($item.destinationState -and -not $item.sourceState) { $status = 'WARN'; $evidence = 'Destination-only item; no source requirement.' }
        $checks += [pscustomobject]@{ component = $item.component; status = $status; checkedAt = [DateTimeOffset]::Now.ToString('o'); evidence = $evidence; nextStep = $item.reason }
    }
    if ($Source -and $Destination) {
        $sourceEnv = Get-MHField -Object $Source -Name 'env'
        $destinationEnv = Get-MHField -Object $Destination -Name 'env'
        $envCollectorsReady = (Get-MHCollectorStatus -Snapshot $Source -Domain 'env') -eq 'OK' -and (Get-MHCollectorStatus -Snapshot $Destination -Domain 'env') -eq 'OK'
        $sourcePathScopes = Get-MHField -Object $sourceEnv -Name 'path' -Default ([ordered]@{})
        $destinationPathScopes = Get-MHField -Object $destinationEnv -Name 'path' -Default ([ordered]@{})
        foreach ($scope in @('USER', 'MACHINE')) {
            $sourcePath = @(Get-MHField -Object $sourcePathScopes -Name $scope -Default @())
            $destinationPath = @(Get-MHField -Object $destinationPathScopes -Name $scope -Default @())
            $status = if (-not $envCollectorsReady) { 'UNKNOWN' } elseif ((ConvertTo-Json $sourcePath -Compress) -eq (ConvertTo-Json $destinationPath -Compress)) { 'PASS' } else { 'WARN' }
            $checks += [pscustomobject]@{ component = 'env:path:' + $scope.ToLowerInvariant(); status = $status; checkedAt = [DateTimeOffset]::Now.ToString('o'); evidence = 'User/Machine PATH entries compared without changing them.'; nextStep = $(if ($status -eq 'WARN') { 'Review destination PATH entries; do not copy the source PATH wholesale.' } else { 'No PATH action required.' }) }
        }
        $sourceVariables = @(Get-MHField -Object $sourceEnv -Name 'variables' -Default @())
        $destinationVariables = @(Get-MHField -Object $destinationEnv -Name 'variables' -Default @())
        $destinationNames = @($destinationVariables | ForEach-Object { $_.scope + '|' + $_.name })
        $missingNames = @($sourceVariables | Where-Object { $destinationNames -notcontains ($_.scope + '|' + $_.name) })
        $destinationByName = @{}
        foreach ($variable in $destinationVariables) { $destinationByName[([string]$variable.scope + '|' + [string]$variable.name)] = $variable }
        $differentSafeValues = @($sourceVariables | Where-Object {
            $key = [string]$_.scope + '|' + [string]$_.name
            $null -ne $_.value -and $destinationByName.ContainsKey($key) -and [string]$destinationByName[$key].value -ine [string]$_.value
        })
        $secretNames = @($sourceVariables | Where-Object isSecret)
        $checks += [pscustomobject]@{ component = 'env:variables'; status = $(if (-not $envCollectorsReady) { 'UNKNOWN' } elseif ($missingNames.Count -eq 0 -and $differentSafeValues.Count -eq 0) { 'PASS' } else { 'WARN' }); checkedAt = [DateTimeOffset]::Now.ToString('o'); evidence = ('Missing names=' + $missingNames.Count + '; differing allowlisted safe values=' + $differentSafeValues.Count); nextStep = 'Review missing names and differing allowlisted values; recreate only reviewed nonsecret variables.' }
        if ($secretNames.Count -gt 0) { $checks += [pscustomobject]@{ component = 'env:secrets'; status = 'UNKNOWN'; checkedAt = [DateTimeOffset]::Now.ToString('o'); evidence = ('Secret names present on source: ' + $secretNames.Count + '; values were not collected.'); nextStep = 'Set or reauthenticate each required secret manually.' } }
        foreach ($domain in @('system', 'software', 'dev', 'shell', 'editors', 'agents', 'wsl', 'data')) {
            $sourceStatus = Get-MHCollectorStatus -Snapshot $Source -Domain $domain
            $destinationStatus = Get-MHCollectorStatus -Snapshot $Destination -Domain $domain
            if ($sourceStatus -notin @('OK', 'PARTIAL') -or $destinationStatus -notin @('OK', 'PARTIAL')) {
                $checks += [pscustomobject]@{ component = 'collector:' + $domain; status = 'UNKNOWN'; checkedAt = [DateTimeOffset]::Now.ToString('o'); evidence = ('Source=' + $sourceStatus + '; destination=' + $destinationStatus); nextStep = 'Rerun this collector or review its unavailable status before claiming completion.' }
            } elseif ($sourceStatus -eq 'PARTIAL' -or $destinationStatus -eq 'PARTIAL') {
                $checks += [pscustomobject]@{ component = 'collector:' + $domain; status = 'WARN'; checkedAt = [DateTimeOffset]::Now.ToString('o'); evidence = ('Source=' + $sourceStatus + '; destination=' + $destinationStatus); nextStep = 'Review bounded-collection warnings.' }
            }
        }
        foreach ($snapshot in @($Source, $Destination)) {
            $snapshotCollection = Get-MHField -Object $snapshot -Name 'collection'
            $snapshotDomainStatus = Get-MHField -Object $snapshotCollection -Name 'domainStatus'
            $snapshotSoftwareStatus = Get-MHField -Object $snapshotDomainStatus -Name 'software'
            $snapshotSoftwareMetadata = Get-MHField -Object $snapshotSoftwareStatus -Name 'metadata'
            $winget = Get-MHField -Object $snapshotSoftwareMetadata -Name 'wingetStatus' -Default 'UNKNOWN'
            if ($winget -ne 'OK') { $checks += [pscustomobject]@{ component = 'software:winget:' + $snapshot.role.ToLowerInvariant(); status = 'UNKNOWN'; checkedAt = [DateTimeOffset]::Now.ToString('o'); evidence = 'winget inventory status: ' + $winget; nextStep = 'Review package-manager inventory before declaring the software list complete.' } }
            $wslStatus = Get-MHField -Object (Get-MHField -Object $snapshotDomainStatus -Name 'wsl') -Name 'metadata'
            $wslProbe = Get-MHField -Object $wslStatus -Name 'status' -Default 'UNKNOWN'
            if ($wslProbe -ne 'OK') { $checks += [pscustomobject]@{ component = 'wsl:inventory:' + $snapshot.role.ToLowerInvariant(); status = $(if ($wslProbe -eq 'NOT_FOUND') { 'WARN' } else { 'UNKNOWN' }); checkedAt = [DateTimeOffset]::Now.ToString('o'); evidence = 'WSL inventory status: ' + $wslProbe; nextStep = 'If WSL is required, run a normal read-only collection or review its unavailable status.' } }
        }
        $alreadyChecked = @{}
        foreach ($check in $checks) { $alreadyChecked[[string]$check.component] = $true }
        $destinationItems = @(ConvertTo-MHComparableItems -Snapshot $Destination | Where-Object { (Get-MHField -Object $_.value -Name 'state') -eq 'PRESENT' })
        foreach ($entry in @(ConvertTo-MHComparableItems -Snapshot $Source | Where-Object { (Get-MHField -Object $_.value -Name 'state') -eq 'PRESENT' })) {
            $component = $entry.domain + '|' + $entry.id
            if ((Get-MHEffectiveRestorePolicy -Component $component -Entry $entry.value -Decisions $Decisions) -ne 'RESTORE') { continue }
            if ($alreadyChecked.ContainsKey($component)) { continue }
            if ((Get-MHCollectorStatus -Snapshot $Source -Domain $entry.domain) -ne 'OK' -or (Get-MHCollectorStatus -Snapshot $Destination -Domain $entry.domain) -ne 'OK') { continue }
            $match = @($destinationItems | Where-Object { $_.domain -eq $entry.domain -and $_.id -eq $entry.id } | Select-Object -First 1)
            if ($entry.domain -eq 'data' -and $Decisions) {
                $mapping = @($Decisions.pathMappings | Where-Object { $_.sourceId -eq $entry.id -or $_.sourcePath -eq $entry.value.sourcePath } | Select-Object -First 1)
                if ($mapping.Count -gt 0) { $match = @($destinationItems | Where-Object { $_.domain -eq 'data' -and $_.value.sourcePath -eq $mapping[0].destinationPath } | Select-Object -First 1) }
            }
            if ($match.Count -eq 0) { continue }
            $sourceFingerprint = ConvertTo-Json -InputObject (Get-MHFingerprint -Domain $entry.domain -Value $entry.value) -Depth 40 -Compress
            $destinationFingerprint = ConvertTo-Json -InputObject (Get-MHFingerprint -Domain $entry.domain -Value $match[0].value) -Depth 40 -Compress
            if ($entry.domain -eq 'data' -and ((Get-MHField -Object $entry.value -Name 'readability') -eq 'FAIL' -or (Get-MHField -Object $match[0].value -Name 'readability') -eq 'FAIL')) {
                $checks += [pscustomobject]@{ component = $component; status = 'FAIL'; checkedAt = [DateTimeOffset]::Now.ToString('o'); evidence = 'The selected directory could not be enumerated.'; nextStep = 'Check destination permissions and retry.' }
            } elseif ($entry.domain -eq 'data' -and ((Get-MHField -Object $entry.value -Name 'readability') -eq 'UNKNOWN' -or (Get-MHField -Object $match[0].value -Name 'readability') -eq 'UNKNOWN')) {
                $checks += [pscustomobject]@{ component = $component; status = 'UNKNOWN'; checkedAt = [DateTimeOffset]::Now.ToString('o'); evidence = 'The data path was recorded but not traversed.'; nextStep = 'Verify the mapped path manually.' }
            } elseif ($entry.domain -eq 'wsl' -and ((Get-MHField -Object $entry.value -Name 'configState') -ne 'PRESENT' -or (Get-MHField -Object $match[0].value -Name 'configState') -ne 'PRESENT')) {
                $checks += [pscustomobject]@{ component = $component; status = 'UNKNOWN'; checkedAt = [DateTimeOffset]::Now.ToString('o'); evidence = 'The distribution was matched, but /etc/wsl.conf was not read on both sides.'; nextStep = 'Run an approved read-only check when both selected distributions are already running.' }
            } elseif ($sourceFingerprint -eq $destinationFingerprint -and $entry.domain -ne 'agents') {
                $checks += [pscustomobject]@{ component = $component; status = 'PASS'; checkedAt = [DateTimeOffset]::Now.ToString('o'); evidence = 'Current destination collector matched the selected source state.'; nextStep = 'No action required.' }
            }
        }
        $sourceAgents = @(Get-MHField -Object $Source -Name 'agents' -Default @() | Where-Object state -eq 'PRESENT')
        foreach ($agent in $sourceAgents) {
            $component = 'agents|' + $agent.id
            if ((Get-MHEffectiveRestorePolicy -Component $component -Entry $agent -Decisions $Decisions) -ne 'RESTORE') { continue }
            if (@($checks | Where-Object component -eq $component).Count -eq 0) { $checks += [pscustomobject]@{ component = $component; status = 'UNKNOWN'; checkedAt = [DateTimeOffset]::Now.ToString('o'); evidence = 'Authentication and live MCP state were not collected.'; nextStep = 'Sign in and verify requested integrations.' } }
        }
        $sourceEditors = @(Get-MHField -Object $Source -Name 'editors' -Default @() | Where-Object state -eq 'PRESENT')
        foreach ($editor in $sourceEditors) {
            $component = 'editors|' + $editor.id
            if ((Get-MHEffectiveRestorePolicy -Component $component -Entry $editor -Decisions $Decisions) -ne 'RESTORE') { continue }
            $checks += [pscustomobject]@{ component = 'editor-launch:' + $editor.id; status = 'UNKNOWN'; checkedAt = [DateTimeOffset]::Now.ToString('o'); evidence = 'The editor GUI was not launched during read-only validation.'; nextStep = 'Launch the editor and verify the selected profile/extensions.' }
        }
        $sourceCandidates = @(Get-MHField -Object $Source -Name 'unbackedDataCandidates' -Default @())
        foreach ($candidate in $sourceCandidates) {
            $checks += [pscustomobject]@{ component = 'backup:' + $candidate.path; status = 'UNKNOWN'; checkedAt = [DateTimeOffset]::Now.ToString('o'); evidence = 'Backup destination/parity not proven by local metadata.'; nextStep = 'Verify an external copy or record user confirmation.' }
        }
        $sourceWsl = @(Get-MHField -Object $Source -Name 'wsl' -Default @() | Where-Object { $_.id -ne 'wsl:global-config' -and $_.state -eq 'PRESENT' })
        foreach ($distro in $sourceWsl) {
            $component = 'wsl|' + $distro.id
            if ((Get-MHEffectiveRestorePolicy -Component $component -Entry $distro -Decisions $Decisions) -ne 'RESTORE') { continue }
            $destinationDistro = @((Get-MHField -Object $Destination -Name 'wsl' -Default @()) | Where-Object { $_.id -eq $distro.id } | Select-Object -First 1)
            $status = 'UNKNOWN'
            $evidence = 'Distribution configuration was not inspected safely.'
            $nextStep = 'Verify /etc/wsl.conf and project paths during an approved manual check.'
            $sourceWslStatus = Get-MHCollectorStatus -Snapshot $Source -Domain 'wsl'
            $destinationWslStatus = Get-MHCollectorStatus -Snapshot $Destination -Domain 'wsl'
            if ($sourceWslStatus -ne 'OK' -or $destinationWslStatus -ne 'OK') { $status = 'WARN'; $evidence = ('WSL inventory coverage is incomplete (source=' + $sourceWslStatus + ', destination=' + $destinationWslStatus + ').'); $nextStep = 'Rerun a complete read-only WSL inventory before treating the distro as absent or matched.' }
            elseif ($destinationDistro.Count -eq 0) { $status = 'FAIL'; $evidence = 'Selected WSL distribution is absent from the destination.'; $nextStep = 'Review and approve a separate import plan.' }
            elseif ($distro.configState -eq 'PRESENT' -and $destinationDistro[0].configState -eq 'PRESENT') {
                if ((ConvertTo-Json $distro.safeSettings -Compress) -eq (ConvertTo-Json $destinationDistro[0].safeSettings -Compress)) { $status = 'PASS'; $evidence = 'Allowlisted /etc/wsl.conf settings matched.'; $nextStep = 'No configuration action required.' }
                else { $status = 'WARN'; $evidence = 'Allowlisted /etc/wsl.conf settings differ.'; $nextStep = 'Review the target settings before changing them.' }
            }
            $checks += [pscustomobject]@{ component = 'wsl-config:' + $distro.id; status = $status; checkedAt = [DateTimeOffset]::Now.ToString('o'); evidence = $evidence; nextStep = $nextStep }
        }
    }
    if ($checks.Count -eq 0) { $checks += [pscustomobject]@{ component = 'snapshot'; status = 'UNKNOWN'; checkedAt = [DateTimeOffset]::Now.ToString('o'); evidence = 'No complete current checks were produced.'; nextStep = 'Run validation with selected components and current destination evidence.' } }
    return [pscustomobject]@{ schemaVersion = 1; createdAt = [DateTimeOffset]::Now.ToString('o'); checks = @($checks); counts = [pscustomobject]@{ pass = @($checks | Where-Object status -eq 'PASS').Count; warn = @($checks | Where-Object status -eq 'WARN').Count; fail = @($checks | Where-Object status -eq 'FAIL').Count; unknown = @($checks | Where-Object status -eq 'UNKNOWN').Count } }
}

function ConvertTo-MHCell {
    param([AllowNull()]$Value)
    if ($null -eq $Value) { return '' }
    $text = [string]$Value
    return (($text -replace '[\r\n]+', ' ') -replace '\|', '\|')
}

function Write-MHTable {
    param([string[]]$Headers, $Rows)
    $lines = @()
    $lines += '| ' + ($Headers -join ' | ') + ' |'
    $lines += '| ' + (@($Headers | ForEach-Object { '---' }) -join ' | ') + ' |'
    foreach ($row in $Rows) {
        $cells = @()
        foreach ($cell in $row) { $cells += ConvertTo-MHCell -Value $cell }
        $lines += '| ' + ($cells -join ' | ') + ' |'
    }
    return $lines -join [Environment]::NewLine
}

function New-MHRows {
    param([object[]]$Items, [scriptblock]$Selector)
    $rows = New-Object System.Collections.ArrayList
    foreach ($item in $Items) { [void]$rows.Add([object[]]@(& $Selector $item)) }
    return ,$rows
}

function Get-MHReportText {
    param([Parameter(Mandatory)]$Snapshot, [Parameter(Mandatory)][string]$Name, $Diff, $Validation)
    $software = @(Get-MHField -Object $Snapshot -Name 'software' -Default @())
    $dev = @(Get-MHField -Object $Snapshot -Name 'dev' -Default @())
    $editors = @(Get-MHField -Object $Snapshot -Name 'editors' -Default @())
    $agents = @(Get-MHField -Object $Snapshot -Name 'agents' -Default @())
    $data = @(Get-MHField -Object $Snapshot -Name 'dataLocations' -Default @())
    $candidates = @(Get-MHField -Object $Snapshot -Name 'unbackedDataCandidates' -Default @())
    $system = Get-MHField -Object $Snapshot -Name 'system'
    $environment = Get-MHField -Object $Snapshot -Name 'env'
    $collection = Get-MHField -Object $Snapshot -Name 'collection'
    $domainStatus = Get-MHField -Object $collection -Name 'domainStatus'
    $softwareStatus = Get-MHField -Object $domainStatus -Name 'software'
    $softwareMetadata = Get-MHField -Object $softwareStatus -Name 'metadata'
    $wingetStatus = Get-MHField -Object $softwareMetadata -Name 'wingetStatus' -Default 'UNKNOWN'
    $diffItems = @(Get-MHField -Object $Diff -Name 'items' -Default @())
    $validationChecks = @(Get-MHField -Object $Validation -Name 'checks' -Default @())
    $wslItems = @(Get-MHField -Object $Snapshot -Name 'wsl' -Default @())
    $collectionRoots = @(Get-MHField -Object $collection -Name 'roots' -Default @())
    $collectedAt = Get-MHField -Object $Snapshot -Name 'collectedAt' -Default 'UNKNOWN'
    $hostLabel = Get-MHField -Object $system -Name 'computerLabel' -Default 'UNKNOWN'
    switch ($Name) {
        'HANDOFF.md' {
            $templatePath = Join-Path $PSScriptRoot '..\assets\HANDOFF.template.md'
            $content = Get-Content -LiteralPath $templatePath -Raw -Encoding UTF8
            $toolSummary = (@($dev | Where-Object state -eq 'PRESENT' | ForEach-Object { $_.id + ' ' + $_.version }) -join ', ')
            $agentSummary = (@($agents | Where-Object state -eq 'PRESENT' | ForEach-Object { $_.id }) -join ', ')
            $wslSummary = (@($wslItems | ForEach-Object { $_.name + ' (WSL ' + $_.version + ')' }) -join ', ')
            $pathSummary = (@($data | ForEach-Object { $_.type + ': ' + $_.sourcePath }) -join '; ')
            $candidateSummary = (@($candidates | ForEach-Object { $_.path + ' — ' + $_.reason }) -join '; ')
            $windows = if ($system) { $system.windows.productName + ' build ' + $system.windows.build } else { 'UNKNOWN' }
            $map = @{
                '{{HOST_LABEL}}' = [string]$hostLabel
                '{{COLLECTED_AT}}' = [string]$collectedAt
                '{{WINDOWS_SUMMARY}}' = $windows
                '{{WORK_ROOTS}}' = ($collectionRoots -join ', ')
                '{{TOOL_SUMMARY}}' = $toolSummary
                '{{AGENT_SUMMARY}}' = $agentSummary
                '{{WSL_SUMMARY}}' = $wslSummary
                '{{DATA_SUMMARY}}' = $pathSummary
                '{{UNBACKED_SUMMARY}}' = $candidateSummary
                '{{RESTORE_ORDER}}' = '确认目标路径 → 安装已选软件和工具链 → 恢复经审阅配置与项目 → 按单独计划处理 WSL → 重新登录并验证。'
                '{{BLOCKERS}}' = '未采集项见 evidence/collection-status.json；未验证的备份保持候选。'
            }
            foreach ($key in $map.Keys) { $content = $content.Replace($key, [string]$map[$key]) }
            return $content
        }
        'SYSTEM.md' {
            $systemJson = ConvertTo-Json -InputObject $system -Depth 20
            $envVariables = @(Get-MHField -Object $environment -Name 'variables' -Default @())
            $envPath = Get-MHField -Object $environment -Name 'path' -Default ([ordered]@{})
            $envRows = New-MHRows -Items $envVariables -Selector { param($item) @($item.scope, $item.name, $item.present, $(if ($item.isSecret) { 'REDACTED' } elseif ($item.value) { $item.value } else { '' })) }
            return "# 系统与环境`n`n~~~json`n$systemJson`n~~~ `n`n## 环境变量与 PATH`n`n$(Write-MHTable -Headers @('范围', '名称', '存在', '安全值') -Rows $envRows)`n`n### PATH`n`n~~~json`n$(ConvertTo-Json -InputObject $envPath -Depth 10)`n~~~"
        }
        'SOFTWARE.md' {
            $rows = New-MHRows -Items $software -Selector { param($item) @($item.name, $item.version, $item.source, $item.category, $item.restorePolicy, $item.id) }
            return "# 软件清单`n`nwinget 状态：$wingetStatus`n`n软件策略默认为 REVIEW，由 Agent 与用户确认是否保留。`n`n$(Write-MHTable -Headers @('软件', '版本', '来源', '分类', '策略', '标识') -Rows $rows)"
        }
        'DEVELOPMENT.md' {
            $toolRows = New-MHRows -Items $dev -Selector { param($item) @($item.id, $item.state, $item.version, $item.path, $item.status) }
            $editorRows = New-MHRows -Items $editors -Selector { param($item) @($item.id, $item.state, $item.path, (@(Get-MHField -Object $item -Name 'extensions' -Default @()) -join ', '), (@((Get-MHField -Object $item -Name 'profiles' -Default @()) | ForEach-Object { $_.name }) -join ', '), (@((Get-MHField -Object $item -Name 'configFiles' -Default @()) | ForEach-Object { $_.name }) -join ', '), (Get-MHField -Object $item -Name 'launchStatus') ) }
            $wslRows = New-MHRows -Items $wslItems -Selector { param($item) @($item.name, $item.version, $item.running, $item.configState, $item.restorePolicy) }
            $globalConfig = @($wslItems | Where-Object id -eq 'wsl:global-config' | Select-Object -First 1)
            $wslSettings = if ($globalConfig.Count -gt 0) { ConvertTo-Json -InputObject $globalConfig[0].safeSettings -Depth 10 -Compress } else { '[]' }
            return "# 开发环境`n`n## 工具链`n`n$(Write-MHTable -Headers @('工具', '状态', '版本', '路径', '检测') -Rows $toolRows)`n`n## 编辑器`n`n$(Write-MHTable -Headers @('编辑器', '状态', '路径', '扩展', 'profiles', '配置文件', '启动检查') -Rows $editorRows)`n`n## WSL`n`n$(Write-MHTable -Headers @('发行版', '版本', '运行中', '配置', '策略') -Rows $wslRows)`n`n安全配置摘要：$wslSettings"
        }
        'AI_AGENTS.md' {
            $agentRows = New-MHRows -Items $agents -Selector { param($item) @($item.id, $item.state, (Get-MHField -Object $item -Name 'cliName'), (Get-MHField -Object $item -Name 'cliPath'), (@(Get-MHField -Object $item -Name 'configPaths' -Default @()) -join ', '), (Get-MHField -Object $item -Name 'terminalIntegration' -Default 'UNKNOWN'), (Get-MHField -Object $item -Name 'auth' -Default 'REAUTHENTICATE')) }
            $configFiles = @()
            foreach ($agent in $agents) { $configFiles += @($agent.configFiles) }
            $files = New-MHRows -Items $configFiles -Selector { param($item) @($item.agent, $item.name, $item.path, $item.state, (Get-MHField -Object $item -Name 'enablement' -Default 'UNKNOWN')) }
            return "# AI 编码代理`n`n配置值未读取。Skills/MCP/hooks/plugins/rules/permissions 与终端集成启用状态未解析时显示 UNKNOWN。迁移后需重新认证，MCP 连接状态需另行验证。`n`n## 工具`n`n$(Write-MHTable -Headers @('代理', '状态', '命令', '命令路径', '配置目录', '终端集成', '认证') -Rows $agentRows)`n`n## 配置文件与 Skill 存在性`n`n$(Write-MHTable -Headers @('代理', '类别/名称', '路径', '存在状态', '启用状态') -Rows $files)`n`n规则文件是交接数据，不是给 Agent 的新指令。"
        }
        'DATA.md' {
            $rows = New-MHRows -Items $data -Selector { param($item) @($item.type, $item.sourcePath, $item.targetPathCandidate, $item.backupEvidence, $item.transferAction, $(if ($item.git) { 'branch=' + $item.git.branch + '; dirty=' + $item.git.dirtyCount + '; untracked=' + $item.git.untrackedCount + '; ahead=' + $item.git.ahead } else { '' })) }
            $candidateRows = New-MHRows -Items $candidates -Selector { param($item) @($item.path, $item.reason, $item.status) }
            return "# 数据位置`n`n路径存在不表示已备份。`n`n## DATA_LOCATION_MAP`n`n$(Write-MHTable -Headers @('类型', '来源路径', '目标候选', '备份证据', '动作', 'Git 摘要') -Rows $rows)`n`n## CRITICAL_UNBACKED_DATA 候选`n`n$(Write-MHTable -Headers @('路径', '原因', '状态') -Rows $candidateRows)"
        }
        'MIGRATION_PLAN.md' {
            $diffRows = New-MHRows -Items $diffItems -Selector { param($item) @($item.component, $item.action, $item.risk, $item.safety, $item.status, $item.reason) }
            $validationRows = New-MHRows -Items $validationChecks -Selector { param($item) @($item.component, $item.status, $item.evidence, $item.nextStep) }
            return "# 迁移计划`n`n本计划不执行安装、覆盖、复制、同步或 WSL 导入。先审核动作、目标与风险，再逐项授权。`n`n## 差异`n`n$(Write-MHTable -Headers @('组件', '动作', '风险', '门槛', '状态', '原因') -Rows $diffRows)`n`n## 验证`n`n$(Write-MHTable -Headers @('组件', '状态', '证据', '下一步') -Rows $validationRows)"
        }
    }
    throw 'UNKNOWN_REPORT'
}

function New-MHReportTexts {
    param([Parameter(Mandatory)]$Snapshot, $Diff, $Validation)
    $reports = [ordered]@{}
    foreach ($name in @('HANDOFF.md', 'SYSTEM.md', 'SOFTWARE.md', 'DEVELOPMENT.md', 'AI_AGENTS.md', 'DATA.md', 'MIGRATION_PLAN.md')) {
        $text = Get-MHReportText -Snapshot $Snapshot -Name $name -Diff $Diff -Validation $Validation
        Test-MHSerializedText -Text $text
        $reports[$name] = $text
    }
    return $reports
}

function Write-MHReports {
    param([Parameter(Mandatory)][string]$PackagePath, [Parameter(Mandatory)]$Snapshot, $Diff, $Validation, $ReportTexts)
    if ($null -eq $ReportTexts) { $ReportTexts = New-MHReportTexts -Snapshot $Snapshot -Diff $Diff -Validation $Validation }
    foreach ($name in @('HANDOFF.md', 'SYSTEM.md', 'SOFTWARE.md', 'DEVELOPMENT.md', 'AI_AGENTS.md', 'DATA.md', 'MIGRATION_PLAN.md')) {
        Write-MHAtomicText -Path (Join-Path $PackagePath $name) -Text $ReportTexts[$name]
    }
}
