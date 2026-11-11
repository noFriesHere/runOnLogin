# Loaded by login.ps1.
function Write-WorkflowJson($Path, $Config) {
    [IO.File]::WriteAllText($Path, (($Config | ConvertTo-Json -Depth 10) + [Environment]::NewLine), (New-Object Text.UTF8Encoding($false)))
}

function Assert-ManagementFields($Config) {
    if ($Config.id -notmatch '^[a-zA-Z0-9][a-zA-Z0-9_-]*$') { throw 'Invalid id. Use letters, digits, underscore or hyphen; start with a letter or digit.' }
    if ([string]::IsNullOrWhiteSpace($Config.title) -or $Config.title -match '[\r\n;"\x00]') { throw 'Invalid title.' }
    if ($Config.tabColor -notmatch '^#[0-9a-fA-F]{6}$') { throw 'tabColor must be #RRGGBB.' }
    if ([string]::IsNullOrWhiteSpace($Config.workingDirectory) -or $Config.workingDirectory -match '[\r\n;"\x00]') { throw 'Invalid working directory.' }
    if ($Config.workingDirectory -notmatch '^([a-zA-Z]:[\\/]|\\\\[^\\/]+[\\/][^\\/]+)') { throw 'Working directory must be an absolute path.' }
}

function Read-ScriptSource {
    if (-not $ScriptFile) { return $null }
    $source = (Resolve-Path -LiteralPath $ScriptFile).ProviderPath
    if ([IO.Path]::GetExtension($source) -ne '.ps1' -or -not (Test-Path -LiteralPath $source -PathType Leaf)) { throw '-ScriptFile must point to a .ps1 file.' }
    $tokens = $null
    $errors = $null
    [void][Management.Automation.Language.Parser]::ParseFile($source, [ref]$tokens, [ref]$errors)
    if ($errors.Count) { throw "Script has syntax errors: $($errors[0].Message)" }
    return $source
}

function Backup-Workflow($Entry, [string]$Reason) {
    $backupRoot = Join-Path $ConfigDirectory '.backups'
    $backup = Join-Path $backupRoot ((Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + $Entry.Config.id + '-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Path $backup -Force | Out-Null
    Copy-Item -LiteralPath $Entry.File -Destination (Join-Path $backup 'config.json')
    if (Test-Path -LiteralPath $Entry.Script -PathType Leaf) {
        Copy-Item -LiteralPath $Entry.Script -Destination (Join-Path $backup 'script.ps1')
    }
    Write-WorkflowJson (Join-Path $backup 'manifest.json') ([pscustomobject]@{
        reason = $Reason; configPath = $Entry.File; scriptPath = $Entry.Script
    })
    Write-Host "Backup: $backup"
    return $backup
}

function Open-WorkflowEditor($Entry, [string]$Selection) {
    $paths = @()
    if ($Selection -in @('config', 'both')) { $paths += $Entry.File }
    if ($Selection -in @('script', 'both')) { $paths += $Entry.Script }
    foreach ($path in $paths) {
        # A separate launch per file also works with the classic Windows Notepad.
        Start-Process -FilePath 'notepad.exe' -ArgumentList ('"' + $path + '"') | Out-Null
    }
    Write-Output 'After saving, use run.cmd check or run.cmd run -DryRun to validate.'
}

function Read-Default([string]$Label, [string]$Default) {
    $answer = Read-Host "$Label [$Default]"
    if ([string]::IsNullOrWhiteSpace($answer)) { return $Default }
    return $answer
}

function Invoke-WorkflowManagement {
    if ($NoEdit -and $Command -ne 'add') { throw '-NoEdit is only supported with add.' }
    if ($NoEdit -and $Edit) { throw '-NoEdit and -Edit cannot be combined.' }
    if ($Force -and $Command -ne 'remove') { throw '-Force is only supported with remove.' }
    $scriptsRoot = [IO.Path]::GetFullPath((Join-Path ([IO.Path]::GetFullPath($ConfigDirectory)) '../scripts'))
    if ($Command -eq 'add') {
        if (-not $Id) {
            $script:Id = Read-Host 'Workflow id (letters, digits, underscore, hyphen)'
            if (-not $Title) { $script:Title = Read-Default 'Tab title' $Id }
            if (-not $WorkingDirectory) { $script:WorkingDirectory = Read-Default 'Working directory' (Get-Location).Path }
            if (-not $TabColor) { $script:TabColor = Read-Default 'Tab color' '#800000' }
            if (-not $ScriptFile) { $script:ScriptFile = Read-Host 'Existing .ps1 file to copy (Enter for a new template)' }
        }
        $config = [pscustomobject]@{
            id = $Id; enabled = $false
            title = $(if ($Title) { $Title } else { $Id })
            tabColor = $(if ($TabColor) { $TabColor } else { '#800000' })
            workingDirectory = $(if ($WorkingDirectory) { $WorkingDirectory } else { (Get-Location).Path })
            script = "../scripts/$Id.ps1"
            requires = @()
        }
        Assert-ManagementFields $config
        if (@($workflows | Where-Object { $_.Config.id -eq $Id }).Count) { throw "Workflow already exists: $Id" }
        $configPath = Join-Path $ConfigDirectory "$Id.json"
        $scriptPath = Join-Path $scriptsRoot "$Id.ps1"
        if ((Test-Path -LiteralPath $configPath) -or (Test-Path -LiteralPath $scriptPath)) { throw 'Target config or script file already exists.' }
        $source = Read-ScriptSource
        New-Item -ItemType Directory -Path $scriptsRoot -Force | Out-Null
        if ($source) { Copy-Item -LiteralPath $source -Destination $scriptPath }
        else {
            $template = @'
$ErrorActionPreference = 'Stop'
# Add your commands here. External programs need an explicit exit-code check:
# & your-program.exe
# if ($LASTEXITCODE -ne 0) { throw "Program failed: $LASTEXITCODE" }
Write-Host 'Edit this script to define your workflow.'
'@
            [IO.File]::WriteAllText($scriptPath, $template + [Environment]::NewLine, (New-Object Text.UTF8Encoding($true)))
        }
        try { Write-WorkflowJson $configPath $config }
        catch { Remove-Item -LiteralPath $scriptPath; throw }
        $entry = [pscustomobject]@{ Config = $config; File = $configPath; Script = $scriptPath }
        Write-Output "Added (disabled): $Id"
        Write-Output "Config: $configPath"
        Write-Output "Script: $scriptPath"
        Write-Output "Enable when ready: run.cmd enable -Id $Id"
        if (-not $NoEdit) { Open-WorkflowEditor $entry $(if ($Edit) { $Edit } else { 'script' }) }
        return
    }

    if (-not $Id) {
        $workflows | ForEach-Object { Write-Host ("{0}: {1}" -f $_.Config.id, $_.Config.title) }
        $script:Id = Read-Host "Workflow id to $Command"
    }
    $matches = @($workflows | Where-Object { $_.Config.id -eq $Id })
    if ($matches.Count -ne 1) { throw "Unknown workflow: $Id" }
    $entry = $matches[0]
    if ($Command -eq 'modify') {
        $hasChanges = $false
        foreach ($field in @('Title', 'TabColor', 'WorkingDirectory')) {
            if ($script:PSBoundParameters.ContainsKey($field)) {
                $entry.Config.$field = Get-Variable -Name $field -ValueOnly
                $hasChanges = $true
            }
        }
        if ($hasChanges) { Assert-ManagementFields $entry.Config }
        $source = Read-ScriptSource
        if (@($workflows | Where-Object { $_.File -ne $entry.File -and $_.Script -eq $entry.Script }).Count -gt 0 -and ($source -or $Edit -in @('script', 'both') -or (-not $hasChanges -and -not $Edit))) {
            Write-Warning 'This script is shared with other workflows; script edits affect all of them.'
        }
        $backup = Backup-Workflow $entry 'modify'
        try {
            if ($source -and $source -ne $entry.Script) { Copy-Item -LiteralPath $source -Destination $entry.Script -Force }
            if ($hasChanges) { Write-WorkflowJson $entry.File $entry.Config }
        } catch {
            Copy-Item -LiteralPath (Join-Path $backup 'config.json') -Destination $entry.File -Force
            if (Test-Path -LiteralPath (Join-Path $backup 'script.ps1')) {
                Copy-Item -LiteralPath (Join-Path $backup 'script.ps1') -Destination $entry.Script -Force
            }
            throw
        }
        if ($hasChanges -or $source) { Write-Output "Updated: $Id" }
        if ($Edit -or (-not $hasChanges -and -not $source)) { Open-WorkflowEditor $entry $(if ($Edit) { $Edit } else { 'both' }) }
        return
    }

    if ($Title -or $TabColor -or $WorkingDirectory -or $ScriptFile -or $Edit) { throw 'remove does not accept edit options.' }
    $shared = @($workflows | Where-Object { $_.File -ne $entry.File -and $_.Script -eq $entry.Script }).Count -gt 0
    $owned = $entry.Script.StartsWith($scriptsRoot.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)
    Write-Output "Remove config: $($entry.File)"
    $removeScript = $owned -and -not $shared
    if ($removeScript) { Write-Output "Remove script: $($entry.Script)" }
    else { Write-Output "Keep shared or external script: $($entry.Script)" }
    if (-not $Force -and (Read-Host 'Remove this workflow? [y/N]') -notmatch '^(y|yes)$') {
        Write-Output 'Cancelled.'
        return
    }
    $backup = Backup-Workflow $entry 'remove'
    try {
        if ($removeScript -and (Test-Path -LiteralPath $entry.Script)) { Remove-Item -LiteralPath $entry.Script }
        Remove-Item -LiteralPath $entry.File
    } catch {
        Copy-Item -LiteralPath (Join-Path $backup 'config.json') -Destination $entry.File -Force
        if ($removeScript -and (Test-Path -LiteralPath (Join-Path $backup 'script.ps1'))) {
            Copy-Item -LiteralPath (Join-Path $backup 'script.ps1') -Destination $entry.Script -Force
        }
        throw
    }
    Write-Output "Removed: $Id"
}
