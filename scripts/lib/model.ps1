Set-StrictMode -Version Latest

function New-MHCollectionContext {
    [CmdletBinding()]
    param(
        [ValidateSet('Standard', 'Deep')][string]$Profile = 'Standard',
        [string[]]$Roots = @(),
        [string[]]$Excludes = @(),
        [ValidateRange(0, 12)][int]$MaxDepth = 3,
        [switch]$SafeMode,
        [switch]$SkipDefaultRoots
    )

    $limits = if ($Profile -eq 'Deep') {
        [ordered]@{
            globalTimeoutMs = 600000; domainTimeoutMs = 60000; processTimeoutMs = 10000
            maxProcessOutputBytes = 262144; maxDirectories = 10000; maxQueuedDirectories = 10000; maxDepth = 8
            maxRoots = 32; maxFilesToInspect = 20000; maxDiscoveredItems = 2048
            maxConfigBytes = 1048576; maxArtifactBytes = 20971520; maxPackageBytes = 41943040; maxConfigArtifacts = 256
        }
    } else {
        [ordered]@{
            globalTimeoutMs = 120000; domainTimeoutMs = 20000; processTimeoutMs = 5000
            maxProcessOutputBytes = 65536; maxDirectories = 2000; maxQueuedDirectories = 2000; maxDepth = 3
            maxRoots = 16; maxFilesToInspect = 5000; maxDiscoveredItems = 512
            maxConfigBytes = 262144; maxArtifactBytes = 2097152; maxPackageBytes = 10485760; maxConfigArtifacts = 64
        }
    }

    $effectiveDepth = [Math]::Min($MaxDepth, [int]$limits.maxDepth)
    $explicitRoots = @($Roots | Where-Object { $_ })
    $rootsTruncated = $explicitRoots.Count -gt [int]$limits.maxRoots
    if ($rootsTruncated) { $explicitRoots = @($explicitRoots | Select-Object -First ([int]$limits.maxRoots)) }
    return [pscustomobject]@{
        profile = $Profile
        roots = @($explicitRoots)
        rootsTruncated = [bool]$rootsTruncated
        excludes = @($Excludes)
        maxDepth = $effectiveDepth
        safeMode = [bool]$SafeMode
        skipDefaultRoots = [bool]$SkipDefaultRoots
        budgets = [pscustomobject]$limits
        artifactBudget = [pscustomobject]@{ capturedBytes = 0; capturedCount = 0 }
        cancellationSource = New-Object System.Threading.CancellationTokenSource
        startedAt = [DateTimeOffset]::UtcNow
        deadline = [DateTimeOffset]::UtcNow.AddMilliseconds([int]$limits.globalTimeoutMs)
    }
}

function Get-MHRemainingBudgetMilliseconds {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Context)

    if ($Context.cancellationSource -and $Context.cancellationSource.IsCancellationRequested) { return 0 }
    $deadline = if ($Context.PSObject.Properties['domainDeadline']) { [DateTimeOffset]$Context.domainDeadline } else { [DateTimeOffset]$Context.deadline }
    return [Math]::Max(0, [int][Math]::Floor(($deadline - [DateTimeOffset]::UtcNow).TotalMilliseconds))
}

function New-MHDomainContext {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Context)

    $domainDeadline = [DateTimeOffset]::UtcNow.AddMilliseconds([int]$Context.budgets.domainTimeoutMs)
    if ($Context.deadline -lt $domainDeadline) { $domainDeadline = [DateTimeOffset]$Context.deadline }
    $domainContext = [pscustomobject]@{
        profile = $Context.profile
        roots = @($Context.roots)
        rootsTruncated = [bool]$Context.rootsTruncated
        excludes = @($Context.excludes)
        maxDepth = [int]$Context.maxDepth
        safeMode = [bool]$Context.safeMode
        skipDefaultRoots = [bool]$Context.skipDefaultRoots
        budgets = $Context.budgets
        artifactBudget = $Context.artifactBudget
        cancellationSource = $Context.cancellationSource
        startedAt = $Context.startedAt
        deadline = $Context.deadline
        domainDeadline = $domainDeadline
    }
    foreach ($property in @($Context.PSObject.Properties)) {
        if ($null -eq $domainContext.PSObject.Properties[$property.Name]) {
            $domainContext | Add-Member -NotePropertyName $property.Name -NotePropertyValue $property.Value
        }
    }
    return $domainContext
}

function Stop-MHCollection {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Context)
    if ($Context.cancellationSource -and -not $Context.cancellationSource.IsCancellationRequested) { $Context.cancellationSource.Cancel() }
}

function New-MHDomainResult {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Domain,
        [ValidateSet('OK', 'PARTIAL', 'UNAVAILABLE', 'ERROR')][string]$Status = 'OK',
        [object[]]$Items = @(),
        [string[]]$Warnings = @(),
        [string]$ErrorCode,
        [string]$Provenance = 'READ_ONLY_LOCAL_QUERY',
        [object[]]$ConfigArtifacts = @()
    )

    return [pscustomobject]@{
        domain = $Domain
        status = $Status
        items = @($Items)
        warnings = @($Warnings)
        errorCode = $ErrorCode
        provenance = $Provenance
        collectedAt = [DateTimeOffset]::Now.ToString('o')
        configArtifacts = @($ConfigArtifacts)
    }
}

function ConvertTo-MHV2Snapshot {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Snapshot,
        [ValidateSet('Standard', 'Deep')][string]$Profile = 'Standard',
        [object[]]$ConfigArtifacts = @(),
        $Context
    )

    $result = [ordered]@{}
    foreach ($property in $Snapshot.PSObject.Properties) { $result[$property.Name] = $property.Value }
    $result.schemaVersion = 2
    $result.profile = $Profile
    $result.configArtifacts = @($ConfigArtifacts)
    if (-not $result.Contains('git')) { $result.git = @() }

    if (-not $Context) {
        $existingCollection = $Snapshot.collection
        $Context = New-MHCollectionContext -Profile $Profile `
            -Roots @(Get-MHField -Object $existingCollection -Name 'roots' -Default @()) `
            -Excludes @(Get-MHField -Object $existingCollection -Name 'excludes' -Default @()) `
            -MaxDepth ([int](Get-MHField -Object $existingCollection -Name 'maxDepth' -Default 3)) `
            -SafeMode:([bool](Get-MHField -Object $existingCollection -Name 'safeMode' -Default $false))
    }

    $result.collection = [pscustomobject]@{
        roots = @($Context.roots)
        rootsTruncated = [bool]$Context.rootsTruncated
        excludes = @($Context.excludes)
        maxDepth = [int]$Context.maxDepth
        safeMode = [bool]$Context.safeMode
        profile = $Context.profile
        budgets = $Context.budgets
        domainStatus = $Snapshot.collection.domainStatus
    }

    return [pscustomobject]$result
}
