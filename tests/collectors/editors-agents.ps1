[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repositoryRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
. (Join-Path $repositoryRoot 'scripts\state.ps1')
. (Join-Path $repositoryRoot 'scripts\lib\model.ps1')
. (Join-Path $repositoryRoot 'scripts\lib\process.ps1')
$artifactHelper = Join-Path $repositoryRoot 'scripts\lib\config-artifacts.ps1'
if (-not (Test-Path -LiteralPath $artifactHelper -PathType Leaf)) { throw 'CONFIG_ARTIFACT_HELPER_REQUIRED' }
. $artifactHelper
. (Join-Path $repositoryRoot 'scripts\collectors\editors-agents.ps1')

function Assert-EditorAgent {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw ('Editor/agent collection check failed: ' + $Message) }
    Write-Output ('PASS: ' + $Message)
}

function Write-EditorAgentFixtureFile {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Content)
    $parent = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) { [void](New-Item -ItemType Directory -Path $parent -Force) }
    [IO.File]::WriteAllText($Path, $Content, (New-Object System.Text.UTF8Encoding($false)))
}

function Set-EditorAgentEnvironment {
    param([string]$Name, [AllowNull()][string]$Value)
    if ($null -eq $Value) { Remove-Item -LiteralPath ('Env:' + $Name) -ErrorAction SilentlyContinue }
    else { Set-Item -LiteralPath ('Env:' + $Name) -Value $Value }
}

$fixtureRoot = Join-Path ([IO.Path]::GetTempPath()) ('mh-editors-agents-' + [guid]::NewGuid().ToString('N'))
$oldEnvironment = @{
    USERPROFILE = [Environment]::GetEnvironmentVariable('USERPROFILE')
    APPDATA = [Environment]::GetEnvironmentVariable('APPDATA')
    LOCALAPPDATA = [Environment]::GetEnvironmentVariable('LOCALAPPDATA')
}
$secret = 'synthetic-secret-' + [guid]::NewGuid().ToString('N')

try {
    $appData = Join-Path $fixtureRoot 'AppData\Roaming'
    $localAppData = Join-Path $fixtureRoot 'AppData\Local'
    Set-EditorAgentEnvironment -Name 'USERPROFILE' -Value $fixtureRoot
    Set-EditorAgentEnvironment -Name 'APPDATA' -Value $appData
    Set-EditorAgentEnvironment -Name 'LOCALAPPDATA' -Value $localAppData

    Write-EditorAgentFixtureFile -Path (Join-Path $fixtureRoot '.vscode\extensions\ms-python.python-1.2.3\package.json') -Content '{"publisher":"ms-python","name":"python","version":"1.2.3","contributes":{"commands":["python.run"]}}'
    Write-EditorAgentFixtureFile -Path (Join-Path $fixtureRoot '.vscode\extensions\Cache\package.json') -Content ('{"token":"' + $secret + '"}')
    Write-EditorAgentFixtureFile -Path (Join-Path $appData 'Code\User\settings.json') -Content ('{"editor.fontSize":14,"apiKey":"' + $secret + '"}')
    Write-EditorAgentFixtureFile -Path (Join-Path $appData 'Code\User\keybindings.json') -Content '[{"key":"ctrl+alt+p","command":"workbench.action.files.openFileFolder"}]'
    Write-EditorAgentFixtureFile -Path (Join-Path $appData 'Code\User\snippets\powershell.json') -Content '{"log":{"prefix":"log","body":["Write-Output $1"]}}'
    Write-EditorAgentFixtureFile -Path (Join-Path $appData 'Code\User\snippets\typescript.json') -Content '{"type":{"prefix":"type","body":["type $1 = $2"]}}'
    Write-EditorAgentFixtureFile -Path (Join-Path $appData 'Code\User\profiles\fixture-profile\settings.json') -Content '{"editor.wordWrap":"on"}'
    Write-EditorAgentFixtureFile -Path (Join-Path $appData 'Code\User\profiles\fixture-profile\snippets\bash.json') -Content '{"echo":{"prefix":"echo","body":["echo $1"]}}'
    Write-EditorAgentFixtureFile -Path (Join-Path $appData 'Code\User\profiles\fixture-profile\snippets\zsh.json') -Content '{"print":{"prefix":"print","body":["print $1"]}}'

    Write-EditorAgentFixtureFile -Path (Join-Path $fixtureRoot '.cursor\extensions\acme.assistant-0.9.1\package.json') -Content '{"publisher":"acme","name":"assistant","version":"0.9.1"}'
    Write-EditorAgentFixtureFile -Path (Join-Path $appData 'Cursor\User\settings.json') -Content '{"editor.tabSize":2}'

    Write-EditorAgentFixtureFile -Path (Join-Path $fixtureRoot '.codex\settings.json') -Content ('{"model":"safe","apiKey":"' + $secret + '"}')
    Write-EditorAgentFixtureFile -Path (Join-Path $fixtureRoot '.codex\mcp.json') -Content '{"servers":{"local":{"command":"server","args":["--stdio"],"env":{"MODE":"safe"}}}}'
    Write-EditorAgentFixtureFile -Path (Join-Path $fixtureRoot '.codex\mcp.yaml') -Content 'servers:`n  local:`n    command: server'
    Write-EditorAgentFixtureFile -Path (Join-Path $fixtureRoot '.codex\mcp.toml') -Content ('x=' + ('a' * 300000))
    Write-EditorAgentFixtureFile -Path (Join-Path $fixtureRoot '.codex\hooks.json') -Content ('{"hooks":[{"command":"run","token":"' + $secret + '"}]}')
    Write-EditorAgentFixtureFile -Path (Join-Path $fixtureRoot '.codex\cache\secret.json') -Content ('{"apiKey":"' + $secret + '"}')
    Write-EditorAgentFixtureFile -Path (Join-Path $fixtureRoot '.codex\skills\fixture-skill\SKILL.md') -Content '# Fixture skill`nThis file is collected as data and requires review.'
    Write-EditorAgentFixtureFile -Path (Join-Path $fixtureRoot '.codex\plugins\fixture-plugin\plugin.json') -Content '{"name":"fixture-plugin","version":"1.0.0"}'
    Write-EditorAgentFixtureFile -Path (Join-Path $fixtureRoot '.claude\CLAUDE.md') -Content '# Fixture rules`nReview before restore.'
    Write-EditorAgentFixtureFile -Path (Join-Path $fixtureRoot '.gemini\settings.json') -Content ('{"apiKey":"' + $secret + '",')

    $context = New-MHCollectionContext -Profile Standard -Roots @($fixtureRoot) -SkipDefaultRoots
    $context | Add-Member -NotePropertyName skipProcessProbes -NotePropertyValue $true -Force
    $result = Get-MHEditorAgentCollection -Context $context
    $json = ConvertTo-Json -InputObject $result -Depth 40 -Compress
    $editors = @($result.items | Where-Object { $_.domain -eq 'editors' })
    $agents = @($result.items | Where-Object { $_.domain -eq 'agents' })
    $vscode = @($editors | Where-Object { $_.id -eq 'editor:vscode' })[0]
    $cursor = @($editors | Where-Object { $_.id -eq 'editor:cursor' })[0]
    $codex = @($agents | Where-Object { $_.id -eq 'agent:codex' })[0]
    $claude = @($agents | Where-Object { $_.id -eq 'agent:claude-code' })[0]
    $extension = @($vscode.extensions | Where-Object { $_.id -eq 'ms-python.python' })[0]
    $hook = @($codex.configFiles | Where-Object { $_.category -eq 'EXECUTABLE_RULES' })[0]
    $cacheMention = @($result.configArtifacts | Where-Object {
        $locator = if ($_.artifact.PSObject.Properties['sourceLocator']) { [string]$_.artifact.sourceLocator } elseif ($_.artifact.PSObject.Properties['sourcePath']) { [string]$_.artifact.sourcePath } else { '' }
        $locator -match '(?i)cache|secret'
    })
    $blocked = @($result.configArtifacts | Where-Object { $_.artifact.captureState -eq 'BLOCKED' })
    $unsupported = @($result.configArtifacts | Where-Object { $_.artifact.id -match ':mcp\.yaml$' -and $_.artifact.captureState -eq 'BLOCKED' })
    $oversized = @($result.configArtifacts | Where-Object { $_.artifact.id -match ':mcp\.toml$' -and $_.artifact.captureState -eq 'BLOCKED' })
    $skillManifest = @($codex.configFiles | Where-Object { $_.category -eq 'SKILLS' -and $_.kind -eq 'config' })[0]
    $snippetConfigs = @($vscode.configFiles | Where-Object { $_.category -match 'SNIPPETS' })
    $uniqueSnippetIds = @($snippetConfigs | Select-Object -ExpandProperty id -Unique)

    Assert-EditorAgent -Condition ($result.domain -eq 'editors-agents') -Message 'collector returns the shared domain result contract'
    Assert-EditorAgent -Condition ($editors.Count -eq 2 -and $agents.Count -eq 5) -Message 'known editor and agent identities are reported without account discovery'
    Assert-EditorAgent -Condition ($vscode.status -in @('FOUND', 'CONFIG_ONLY', 'NOT_TESTED') -and $cursor.status -in @('FOUND', 'CONFIG_ONLY', 'NOT_TESTED')) -Message 'editor presence is inferred from fixture configuration roots'
    Assert-EditorAgent -Condition ($extension.version -eq '1.2.3') -Message 'extension package metadata captures ID and version only'
    Assert-EditorAgent -Condition ($vscode.configFiles.Count -ge 4) -Message 'settings, keybindings, snippets, and profile settings are bounded candidates'
    Assert-EditorAgent -Condition ($snippetConfigs.Count -eq 4 -and $uniqueSnippetIds.Count -eq 4) -Message 'each user and profile snippet file receives a unique component ID'
    Assert-EditorAgent -Condition ($codex.status -in @('FOUND', 'CONFIG_ONLY', 'NOT_TESTED') -and $claude.status -in @('FOUND', 'CONFIG_ONLY', 'NOT_TESTED')) -Message 'agent roots are inventoried without launching an agent'
    Assert-EditorAgent -Condition ($hook.captureState -eq 'METADATA_ONLY' -and $hook.restorePolicy -eq 'REVIEW') -Message 'hook content is never copied and remains manual review'
    Assert-EditorAgent -Condition ($skillManifest.restorePolicy -eq 'REVIEW') -Message 'skill manifest is treated as data requiring review'
    Assert-EditorAgent -Condition ($blocked.Count -gt 0) -Message 'malformed or redaction-blocked configuration is represented as blocked metadata'
    Assert-EditorAgent -Condition ($unsupported.Count -eq 1 -and $oversized.Count -eq 1) -Message 'unsupported and oversized structured candidates fail closed'
    Assert-EditorAgent -Condition ($cacheMention.Count -eq 0) -Message 'cache and secret-bearing paths are excluded before artifact capture'
    Assert-EditorAgent -Condition (-not $json.Contains($secret)) -Message 'secret values are absent from items, artifacts, and result serialization'
    Assert-EditorAgent -Condition ($result.status -in @('OK', 'PARTIAL')) -Message 'bounded collection returns a valid status'
}
finally {
    foreach ($name in $oldEnvironment.Keys) { Set-EditorAgentEnvironment -Name $name -Value $oldEnvironment[$name] }
    if (Test-Path -LiteralPath $fixtureRoot) { Remove-Item -LiteralPath $fixtureRoot -Recurse -Force -ErrorAction SilentlyContinue }
}

Write-Output 'Editor/agent collector suite passed.'
