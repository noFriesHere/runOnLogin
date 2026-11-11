[CmdletBinding()]
param(
    [ValidateSet('help', 'list', 'check', 'run', 'enable', 'disable', 'install', 'uninstall', 'add', 'modify', 'remove')]
    [string]$Command = 'help',
    [string]$Id,
    [switch]$DryRun,
    [string]$ConfigDirectory,
    [string]$Title,
    [string]$TabColor,
    [string]$WorkingDirectory,
    [string]$ScriptFile,
    [ValidateSet('config', 'script', 'both')][string]$Edit,
    [switch]$NoEdit,
    [switch]$Force
)
$ErrorActionPreference = 'Stop'
if (-not $ConfigDirectory) { $ConfigDirectory = Join-Path $PSScriptRoot 'workflows' }

function Read-Workflows {
    param([switch]$ForManagement)
    if (-not (Test-Path -LiteralPath $ConfigDirectory -PathType Container)) { throw "Config directory missing: $ConfigDirectory" }
    $seen = @{}
    foreach ($file in Get-ChildItem -LiteralPath $ConfigDirectory -Filter '*.json' -File | Sort-Object Name) {
        $item = Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($key in @('id', 'enabled', 'title', 'tabColor', 'workingDirectory', 'script')) {
            if ($null -eq $item.PSObject.Properties[$key]) { throw "$($file.Name): missing $key" }
        }
        if ($item.id -notmatch '^[a-zA-Z0-9][a-zA-Z0-9_-]*$') { throw "$($file.Name): invalid id" }
        if ($seen.ContainsKey($item.id)) { throw "Duplicate id: $($item.id)" }
        $seen[$item.id] = $true
        if (-not $ForManagement) {
            if ($item.enabled -isnot [bool]) { throw "$($file.Name): enabled must be boolean" }
            if ([string]::IsNullOrWhiteSpace($item.title) -or $item.title -match '[\r\n;"\x00]') { throw "$($file.Name): invalid title" }
            if ($item.tabColor -notmatch '^#[0-9a-fA-F]{6}$') { throw "$($file.Name): tabColor must be #RRGGBB" }
        }
        $pathsToValidate = if ($ForManagement) { @('script') } else { @('workingDirectory', 'script') }
        foreach ($key in $pathsToValidate) {
            if ([string]::IsNullOrWhiteSpace($item.$key) -or $item.$key -match '[\r\n;"\x00]') { throw "$($file.Name): invalid $key" }
        }
        $scriptPath = [IO.Path]::GetFullPath((Join-Path $file.DirectoryName $item.script))
        if ([IO.Path]::GetExtension($scriptPath) -ne '.ps1') { throw "$($file.Name): script must be a .ps1 file" }
        if (-not $ForManagement -and -not (Test-Path -LiteralPath $scriptPath -PathType Leaf)) { throw "Script missing: $scriptPath" }
        [pscustomobject]@{ Config = $item; File = $file.FullName; Script = $scriptPath }
    }
}

try {
    if ($DryRun -and $Command -ne 'run') { throw '-DryRun is only supported with run.' }
    $startup = [Environment]::GetFolderPath('Startup')
    $shortcutPath = Join-Path $startup 'RunOnLogin.lnk'
    if ($Command -eq 'help') {
        Write-Output @'
Usage: .\run.cmd <command> [-Id <id>] [-DryRun]
  list                Show workflows and login startup status
  check               Check scripts, working directories and executables
  run                 Open enabled workflows in Windows Terminal
  run -Id <id>        Open one workflow, including a disabled workflow
  run -DryRun         Preview without opening windows or executing workflows
  enable -Id <id>     Enable a workflow
  disable -Id <id>    Disable a workflow
  add                 Guided creation of a workflow and its script
  add -Id <id>        Create with defaults; opens the new script in Notepad
  modify -Id <id>     Open config and script in Notepad (backs up originals)
  remove -Id <id>     Confirm and archive config and unshared managed script
  install             Enable startup at current user's login
  uninstall           Remove login startup
Options for add/modify:
  -Title <text> -TabColor '#RRGGBB' -WorkingDirectory <path>
  -ScriptFile <file>  Copy a .ps1 file into the workflow
  -Edit config|script|both  Open selected files in Notepad
  -NoEdit            Do not open an editor (add only)
  -Force             Skip remove confirmation; still keeps a backup
Config: workflows\*.json; workflow bodies: scripts\*.ps1
'@
        exit 0
    }
    if ($Command -eq 'uninstall') {
        if (Test-Path -LiteralPath $shortcutPath) { Remove-Item -LiteralPath $shortcutPath }
        Write-Output 'Login startup disabled.'
        exit 0
    }
    if ($Command -eq 'add' -and -not (Test-Path -LiteralPath $ConfigDirectory)) {
        New-Item -ItemType Directory -Path $ConfigDirectory | Out-Null
    }
    $workflows = @(Read-Workflows -ForManagement:($Command -in @('add', 'modify', 'remove')))
    if ($Command -in @('add', 'modify', 'remove')) {
        . (Join-Path $PSScriptRoot 'management.ps1')
        Invoke-WorkflowManagement
        exit 0
    }
    if ($Id) {
        $workflows = @($workflows | Where-Object { $_.Config.id -eq $Id })
        if ($workflows.Count -eq 0) { throw "Unknown workflow: $Id" }
    }
    switch ($Command) {
        'list' {
            $workflows | ForEach-Object {
                [pscustomobject]@{ Id = $_.Config.id; Enabled = $_.Config.enabled; Title = $_.Config.title; TabColor = $_.Config.tabColor }
            } | Format-Table -AutoSize
            Write-Output "Login startup installed: $(Test-Path -LiteralPath $shortcutPath)"
        }
        { $_ -in 'enable', 'disable' } {
            if (-not $Id) { throw '-Id is required.' }
            $entry = $workflows[0]
            $entry.Config.enabled = ($Command -eq 'enable')
            $json = $entry.Config | ConvertTo-Json -Depth 10
            [IO.File]::WriteAllText($entry.File, $json + [Environment]::NewLine, (New-Object Text.UTF8Encoding($false)))
            Write-Output "$Id enabled: $($entry.Config.enabled)"
        }
        'check' {
            $issues = @()
            if (-not (Get-Command wt.exe -ErrorAction SilentlyContinue)) { $issues += 'Windows Terminal (wt.exe) is missing.' }
            foreach ($entry in $workflows) {
                if (-not (Test-Path -LiteralPath $entry.Config.workingDirectory -PathType Container)) {
                    $issues += "$($entry.Config.id): working directory missing: $($entry.Config.workingDirectory)"
                }
                if ($entry.Config.PSObject.Properties['requires']) {
                    foreach ($exe in $entry.Config.requires) {
                        $found = if ($exe -match '[/\\]') {
                            Test-Path -LiteralPath (Join-Path $entry.Config.workingDirectory $exe) -PathType Leaf
                        } else { $null -ne (Get-Command $exe -ErrorAction SilentlyContinue) }
                        if (-not $found) { $issues += "$($entry.Config.id): executable missing: $exe" }
                    }
                }
            }
            if ($issues.Count) { throw ($issues -join [Environment]::NewLine) }
            Write-Output "OK: $($workflows.Count) workflows checked."
        }
        'install' {
            if (-not (Get-Command wt.exe -ErrorAction SilentlyContinue)) { throw 'Windows Terminal (wt.exe) is required.' }
            if (-not (Test-Path -LiteralPath $startup)) { New-Item -ItemType Directory -Path $startup | Out-Null }
            $shell = New-Object -ComObject WScript.Shell
            $shortcut = $shell.CreateShortcut($shortcutPath)
            $shortcut.TargetPath = Join-Path $PSHOME 'powershell.exe'
            $shortcut.Arguments = '-NoLogo -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}" run -ConfigDirectory "{1}"' -f $PSCommandPath, ([IO.Path]::GetFullPath($ConfigDirectory))
            $shortcut.WorkingDirectory = $PSScriptRoot
            $shortcut.WindowStyle = 7
            $shortcut.Description = 'Run enabled workflows at user login'
            $shortcut.Save()
            Write-Output "Login startup installed: $shortcutPath"
        }
        'run' {
            if (-not $Id) { $workflows = @($workflows | Where-Object { $_.Config.enabled }) }
            if (-not $DryRun -and -not (Get-Command wt.exe -ErrorAction SilentlyContinue)) { throw 'Windows Terminal (wt.exe) is required.' }
            foreach ($entry in $workflows) {
                $cfg = $entry.Config
                if ($DryRun) {
                    Write-Output ("{0}: title={1}; color={2}; cwd={3}; script={4}" -f $cfg.id, $cfg.title, $cfg.tabColor, $cfg.workingDirectory, $entry.Script)
                    continue
                }
                # Pass only a base64 payload through wt, avoiding nested Windows argument quoting.
                $payload = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($entry.File))
                $runner = Join-Path $PSScriptRoot 'runner.ps1'
                $launch = "& '" + $runner.Replace("'", "''") + "' -ConfigBase64 '$payload'"
                $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($launch))
                try {
                    & wt.exe -w RunOnLogin new-tab --title $cfg.title --tabColor $cfg.tabColor --suppressApplicationTitle (Join-Path $PSHOME 'powershell.exe') -NoLogo -NoProfile -NoExit -ExecutionPolicy Bypass -EncodedCommand $encoded
                    if ($LASTEXITCODE -ne 0) { throw "wt.exe exit code: $LASTEXITCODE" }
                    Write-Output "Launch requested: $($cfg.id)"
                } catch { Write-Warning "$($cfg.id): $_"; $script:launchFailed = $true }
            }
            if ($script:launchFailed) { exit 1 }
        }
    }
    exit 0
} catch {
    Write-Error $_ -ErrorAction Continue
    exit 1
}
