param([Parameter(Mandatory = $true)][string]$ConfigBase64)
$ErrorActionPreference = 'Stop'
$mutex = $null
$locked = $false
try {
    $configPath = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($ConfigBase64))
    $config = Get-Content -LiteralPath $configPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $sha = [Security.Cryptography.SHA256]::Create()
    try { $hash = [BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($configPath.ToLowerInvariant()))).Replace('-', '') }
    finally { $sha.Dispose() }
    $mutex = New-Object Threading.Mutex($false, "Local\RunOnLogin_$hash")
    try { $locked = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $locked = $true }
    if (-not $locked) {
        Write-Host 'This workflow is already running. Close this duplicate tab.' -ForegroundColor Yellow
        return
    }
    Set-Location -LiteralPath $config.workingDirectory
    $scriptPath = [IO.Path]::GetFullPath((Join-Path (Split-Path -Parent $configPath) $config.script))
    Write-Host "[$($config.id)] Started at $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -ForegroundColor Cyan
    & $scriptPath
    Write-Host "[$($config.id)] Finished." -ForegroundColor Green
} catch {
    Write-Host "Workflow failed: $_" -ForegroundColor Red
    Write-Host 'The tab stays open so you can inspect the error and retry with run.cmd.'
} finally {
    if ($locked) { $mutex.ReleaseMutex() }
    if ($null -ne $mutex) { $mutex.Dispose() }
}
