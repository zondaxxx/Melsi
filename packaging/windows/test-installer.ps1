# Run on a disposable Windows runner after compiling the real Inno installer.
# The two named fixtures only sleep; this test never starts a VPN or the app.
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Installer
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if ($env:OS -ne 'Windows_NT') {
    throw 'The installer smoke test requires Windows.'
}
$Installer = (Resolve-Path -LiteralPath $Installer).Path
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = [Security.Principal.WindowsPrincipal]::new($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Run this test elevated on a disposable Windows runner.'
}
if (@(Get-CimInstance Win32_Process -Filter "Name = 'melsi.exe' OR Name = 'melsi-core.exe'").Count -ne 0) {
    throw 'A Melsi process already exists; refusing to interfere with it.'
}
$uninstallKey = 'Software\Microsoft\Windows\CurrentVersion\Uninstall\{94F602EF-2E3A-4BD1-BA94-D5CCC2E37FD0}_is1'
foreach ($registryPath in @("HKLM:\$uninstallKey", "HKCU:\$uninstallKey", "HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\{94F602EF-2E3A-4BD1-BA94-D5CCC2E37FD0}_is1")) {
    if (Test-Path -LiteralPath $registryPath) {
        throw 'Melsi is already installed; use a disposable Windows runner.'
    }
}

$workspace = Join-Path ([IO.Path]::GetTempPath()) ('Melsi installer smoke ' + [Guid]::NewGuid().ToString('N'))
$installDirectory = Join-Path $workspace 'Installed Melsi'
$installedApp = Join-Path $installDirectory 'melsi.exe'
$uninstaller = Join-Path $installDirectory 'unins000.exe'
$ownedProcesses = [Collections.Generic.List[Diagnostics.Process]]::new()
$completed = $false
New-Item -ItemType Directory -Path $workspace | Out-Null

function Stop-OwnedProcess([Diagnostics.Process]$Process) {
    $Process.Refresh()
    if (-not $Process.HasExited) {
        # Target only the process this test launched, never a global image name.
        & "$env:WINDIR\System32\taskkill.exe" /PID $Process.Id /T /F 2>&1 | Out-Null
        if (-not $Process.WaitForExit(5000)) {
            throw "Test process $($Process.Id) could not be stopped."
        }
    }
}

function Invoke-InstallerProcess([string]$Executable, [string[]]$Arguments, [int]$TimeoutSeconds = 45) {
    $process = Start-Process -FilePath $Executable -ArgumentList $Arguments -PassThru
    $ownedProcesses.Add($process)
    # Keep the native handle open so ExitCode remains available even for fast refusals.
    $null = $process.Handle
    if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
        Stop-OwnedProcess $process
        throw "Installer operation exceeded ${TimeoutSeconds}s: $Executable"
    }
    # Refresh the process after the wait so ExitCode is available to PowerShell.
    $process.Refresh()
    if ($null -eq $process.ExitCode) { throw "No exit code was returned by $Executable." }
    return $process.ExitCode
}

function Start-Fixture([string]$Name) {
    $process = Start-Process -FilePath (Join-Path $workspace $Name) -PassThru
    $ownedProcesses.Add($process)
    $deadline = [DateTime]::UtcNow.AddSeconds(5)
    do {
        $process.Refresh()
        if ($process.HasExited) { throw "Fixture $Name exited unexpectedly." }
        if ($null -ne (Get-CimInstance Win32_Process -Filter "ProcessId = $($process.Id)")) {
            return $process
        }
        Start-Sleep -Milliseconds 100
    } while ([DateTime]::UtcNow -lt $deadline)
    throw "Fixture $Name was not visible to WMI."
}

function Assert-Blocked([int]$ExitCode, [Diagnostics.Process]$Fixture, [string]$LogFile) {
    if ($ExitCode -eq 0) { throw 'Operation succeeded despite a running Melsi fixture.' }
    $Fixture.Refresh()
    if ($Fixture.HasExited) { throw 'The installer terminated a running Melsi fixture.' }
    if (-not (Select-String -LiteralPath $LogFile -SimpleMatch 'Disconnect the VPN in Melsi' -Quiet)) {
        throw "Operation failed without reporting the running-process guard: $LogFile"
    }
}

try {
    $compiler = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
    if (-not (Test-Path -LiteralPath $compiler)) {
        $compiler = Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\csc.exe'
    }
    $source = Join-Path $workspace 'Fixture.cs'
    'internal static class Program { private static void Main() { System.Threading.Thread.Sleep(System.Threading.Timeout.Infinite); } }' |
        Set-Content -LiteralPath $source -Encoding ascii
    foreach ($name in @('melsi-core.exe', 'melsi.exe')) {
        & $compiler /nologo /target:exe "/out:$(Join-Path $workspace $name)" $source
        if ($LASTEXITCODE -ne 0) { throw "Failed to compile fixture $name." }
    }

    $installArguments = @('/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', '/SP-', '/LANG=english', '/NOICONS', '/TASKS=""', "/DIR=`"$installDirectory`"")
    foreach ($name in @('melsi-core.exe', 'melsi.exe')) {
        $fixture = Start-Fixture $name
        try {
            $logFile = Join-Path $workspace "install-blocked-$name.log"
            $code = Invoke-InstallerProcess $Installer ($installArguments + "/LOG=`"$logFile`"")
            Assert-Blocked $code $fixture $logFile
            if ($code -ne 7) { throw "Expected PrepareToInstall exit code 7, got $code." }
            if (Test-Path -LiteralPath $installedApp) { throw 'Blocked installation wrote the app executable.' }
            Write-Host "PASS: installation preserves and rejects running $name"
        } finally {
            Stop-OwnedProcess $fixture
        }
    }

    $logFile = Join-Path $workspace 'install-clean.log'
    $code = Invoke-InstallerProcess $Installer ($installArguments + "/LOG=`"$logFile`"") 60
    if ($code -ne 0) { throw "Clean installation failed with exit code $code." }
    if (-not (Test-Path -LiteralPath $installedApp) -or -not (Test-Path -LiteralPath $uninstaller)) {
        throw 'Clean installation did not create the app and uninstaller.'
    }
    if (@(Get-CimInstance Win32_Process -Filter "Name = 'melsi.exe' OR Name = 'melsi-core.exe'").Count -ne 0) {
        throw 'Silent installation unexpectedly launched Melsi.'
    }
    Write-Host 'PASS: clean silent installation does not launch Melsi'

    $uninstallArguments = @('/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART')
    foreach ($name in @('melsi-core.exe', 'melsi.exe')) {
        $fixture = Start-Fixture $name
        try {
            $logFile = Join-Path $workspace "uninstall-blocked-$name.log"
            $code = Invoke-InstallerProcess $uninstaller ($uninstallArguments + "/LOG=`"$logFile`"")
            Assert-Blocked $code $fixture $logFile
            if (-not (Test-Path -LiteralPath $installedApp) -or -not (Test-Path -LiteralPath $uninstaller)) {
                throw 'Blocked uninstallation removed installed files.'
            }
            Write-Host "PASS: uninstallation preserves and rejects running $name"
        } finally {
            Stop-OwnedProcess $fixture
        }
    }

    $logFile = Join-Path $workspace 'uninstall-clean.log'
    $code = Invoke-InstallerProcess $uninstaller ($uninstallArguments + "/LOG=`"$logFile`"")
    if ($code -ne 0) { throw "Clean uninstallation failed with exit code $code." }
    if (Test-Path -LiteralPath $installedApp) { throw 'Clean uninstallation left the app executable.' }
    Write-Host 'PASS: clean silent uninstallation removes Melsi'
    $completed = $true
} finally {
    foreach ($process in $ownedProcesses) {
        try { Stop-OwnedProcess $process } catch { Write-Warning $_ }
    }
    if (-not $completed) {
        Get-ChildItem -LiteralPath $workspace -Filter '*.log' | ForEach-Object {
            Write-Host "--- $($_.Name) ---"
            Get-Content -LiteralPath $_.FullName -Tail 60
        }
        if (Test-Path -LiteralPath $uninstaller) {
            try {
                $cleanupLog = Join-Path $workspace 'uninstall-cleanup.log'
                $code = Invoke-InstallerProcess $uninstaller @('/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', "/LOG=`"$cleanupLog`"")
                if ($code -ne 0) { Write-Warning "Cleanup uninstallation returned $code." }
            } catch { Write-Warning $_ }
        }
    }
    # Inno's temporary uninstaller can finish self-deletion just after its parent exits.
    for ($attempt = 0; $attempt -lt 10; $attempt++) {
        try {
            Remove-Item -LiteralPath $workspace -Recurse -Force
            break
        } catch {
            if ($attempt -eq 9) { Write-Warning "Could not remove smoke-test files at $workspace`: $_" }
            else { Start-Sleep -Milliseconds 200 }
        }
    }
}
