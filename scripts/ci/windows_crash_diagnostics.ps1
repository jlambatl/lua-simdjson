[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('Setup', 'Analyze', 'Cleanup')][string]$Mode,
    [Parameter(Mandatory)][string]$OutputDir,
    [string]$ModuleDir = $PWD.Path,
    [string]$LuaExe,
    [switch]$SelfTest
)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$OutputDir = [IO.Path]::GetFullPath($OutputDir)
New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null
$statePath = Join-Path $OutputDir 'wer-state.json'
$backup = Join-Path $OutputDir 'wer-backup.reg'
$dumpDir = Join-Path $OutputDir 'dumps'

function Invoke-CheckedProcess([string]$File, [string[]]$Arguments, [string]$Log, [int]$Timeout = 120000) {
    $p = Start-Process -FilePath $File -ArgumentList $Arguments -PassThru -NoNewWindow `
        -RedirectStandardOutput $Log -RedirectStandardError ($Log + '.stderr')
    if (-not $p.WaitForExit($Timeout)) {
        $p.Kill()
        throw "Timed out: $File"
    }
    $p.WaitForExit()
    if ($p.ExitCode -notin @(0, 3010)) { throw "$File exited $($p.ExitCode); see $Log" }
}

try {
    $admin = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    if (-not $admin.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'WER diagnostics require administrator access on this ephemeral runner.'
    }
    if ($Mode -eq 'Cleanup') {
        if (-not (Test-Path $statePath)) { Write-Host 'No WER state to restore'; exit 0 }
        $state = Get-Content -Raw $statePath | ConvertFrom-Json
        if (Test-Path $state.key) { Remove-Item -Recurse -Force $state.key }
        if ($state.existed) {
            & reg.exe import $backup
            if ($LASTEXITCODE -ne 0) { throw 'Failed to restore original WER registry values' }
        }
        Write-Host 'WER registry restored'
        exit 0
    }
    if ($Mode -eq 'Setup') {
        if (-not (Test-Path $LuaExe)) { throw "Missing interpreter: $LuaExe" }
        $name = [IO.Path]::GetFileName($LuaExe)
        $key = "HKLM:\SOFTWARE\Microsoft\Windows\Windows Error Reporting\LocalDumps\$name"
        $nativeKey = "HKLM\SOFTWARE\Microsoft\Windows\Windows Error Reporting\LocalDumps\$name"
        $existed = Test-Path $key
        if ($existed) {
            & reg.exe export $nativeKey $backup /y
            if ($LASTEXITCODE -ne 0) { throw 'Failed to back up WER application key' }
        }
        $state = @{ key = $key; existed = $existed; name = $name; debugger = '' }
        $state | ConvertTo-Json | Set-Content $statePath
        $cdb = Join-Path ${env:ProgramFiles(x86)} 'Windows Kits\10\Debuggers\x64\cdb.exe'
        if (-not (Test-Path $cdb)) {
            $installer = Join-Path $OutputDir 'tmp_rovo_winsdksetup.exe'
            Invoke-WebRequest 'https://go.microsoft.com/fwlink/?linkid=2196241' -OutFile $installer
            Invoke-CheckedProcess $installer @('/quiet', '/norestart', '/features', 'OptionId.WindowsDesktopDebuggers') `
                (Join-Path $OutputDir 'debugger-install.log') 600000
        }
        if (-not (Test-Path $cdb)) { throw 'Native debugger is unavailable after SDK setup' }
        $state.debugger = $cdb
        $state | ConvertTo-Json | Set-Content $statePath
        New-Item -ItemType Directory -Force -Path $dumpDir | Out-Null
        New-Item -Force -Path $key | Out-Null
        New-ItemProperty $key -Name DumpFolder -Value $dumpDir -PropertyType ExpandString -Force | Out-Null
        New-ItemProperty $key -Name DumpType -Value 2 -PropertyType DWord -Force | Out-Null
        New-ItemProperty $key -Name DumpCount -Value 3 -PropertyType DWord -Force | Out-Null
        if ($SelfTest) {
            # Infrastructure-only native failure, NOT an issue117 reproduction.
            $selfDir = Join-Path $OutputDir 'selftest'
            New-Item -ItemType Directory -Force -Path $selfDir | Out-Null
            $source = Join-Path $selfDir 'tmp_rovo_failfast.cs'
            @'
using System;
using System.Runtime.InteropServices;
class CrashInfrastructure {
    [DllImport("kernel32.dll")]
    static extern void RaiseFailFastException(IntPtr record, IntPtr context, uint flags);
    static void Main() { RaiseFailFastException(IntPtr.Zero, IntPtr.Zero, 0); }
}
'@ | Set-Content $source
            $exe = Join-Path $selfDir $name
            $csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
            & $csc /nologo /target:exe "/out:$exe" $source
            if ($LASTEXITCODE -ne 0) { throw 'Synthetic crash child compilation failed' }
            $child = Start-Process $exe -PassThru -NoNewWindow
            if (-not $child.WaitForExit(30000)) { $child.Kill(); throw 'Synthetic crash child hung' }
            $deadline = (Get-Date).AddSeconds(60)
            do {
                $dumps = @(Get-ChildItem $dumpDir -Filter '*.dmp')
                if ($dumps.Count -gt 0) { break }
                Start-Sleep 1
            } while ((Get-Date) -lt $deadline)
            if ($dumps.Count -eq 0) { throw 'Synthetic native failure did not produce a WER dump' }
            $dumps | Move-Item -Destination $selfDir
            Write-Host 'SYNTHETIC infrastructure dump captured; not issue117 evidence'
        }
    } else {
        if (-not (Test-Path $statePath)) { throw 'Missing dump setup state' }
        $state = Get-Content -Raw $statePath | ConvertFrom-Json
        $real = @(Get-ChildItem $dumpDir -Filter '*.dmp')
        if ($real.Count -eq 0) {
            'No real native crash dump was produced.' | Set-Content (Join-Path $OutputDir 'no-native-crash.txt')
        }
        $all = @($real) + @(Get-ChildItem (Join-Path $OutputDir 'selftest') -Filter '*.dmp' -ErrorAction SilentlyContinue)
        foreach ($dump in $all) {
            $kind = if ($dump.Directory.Name -eq 'selftest') { 'synthetic' } else { 'native' }
            $commands = Join-Path $OutputDir 'tmp_rovo_cdb.txt'
            @('.symfix', ".sympath+ `"$ModuleDir`"", '.reload', '!analyze -v', '.ecxr', 'kv', 'lm', 'q') |
                Set-Content $commands
            Invoke-CheckedProcess $state.debugger @('-z', "`"$($dump.FullName)`"", '-cf', "`"$commands`"") `
                (Join-Path $OutputDir "$kind-$($dump.BaseName).txt")
        }
    }
    exit 0
} catch {
    Write-Error $_
    exit 1
}
