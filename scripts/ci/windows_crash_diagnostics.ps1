[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('Setup', 'Capture', 'Analyze', 'Cleanup')][string]$Mode,
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
            # Hosted runners did not emit WER dumps for fail-fast. Launch under
            # Microsoft's ProcDump debugger instead; prove capture with this child.
            $zip = Join-Path $OutputDir 'tmp_rovo_procdump.zip'
            Invoke-WebRequest 'https://download.sysinternals.com/files/Procdump.zip' -OutFile $zip
            $tools = Join-Path $OutputDir 'procdump'
            Expand-Archive -Path $zip -DestinationPath $tools -Force
            $pd = Join-Path $tools 'procdump64.exe'
            if ((Get-AuthenticodeSignature $pd).Status -ne 'Valid') { throw 'ProcDump signature invalid' }
            $state.procdump = $pd
            $state | ConvertTo-Json | Set-Content $statePath
            $pdArgs = @('-accepteula', '-ma', '-e', '-x', "`"$selfDir`"", "`"$exe`"")
            $child = Start-Process $pd -ArgumentList $pdArgs -PassThru -NoNewWindow `
                -RedirectStandardOutput (Join-Path $selfDir 'capture.log') `
                -RedirectStandardError (Join-Path $selfDir 'capture.stderr')
            if (-not $child.WaitForExit(90000)) { $child.Kill(); throw 'Synthetic debugger child hung' }
            $dumps = @(Get-ChildItem $selfDir -Filter '*.dmp')
            if ($dumps.Count -eq 0) { throw 'ProcDump synthetic self-test produced no dump' }
            Write-Host 'SYNTHETIC debugger dump captured; not issue117 evidence'
        }
    } elseif ($Mode -eq 'Capture') {
        $state = Get-Content -Raw $statePath | ConvertFrom-Json
        if (-not $state.procdump) { throw 'ProcDump capture is not configured' }
        $probe = Join-Path $ModuleDir 'scripts/ci/encode_probe.lua'
        $args = @('-accepteula', '-ma', '-e', '-n', '1', '-x', "`"$dumpDir`"", "`"$LuaExe`"", "`"$probe`"", 'nan', "`"$ModuleDir`"")
        $p = Start-Process $state.procdump -ArgumentList $args -PassThru -NoNewWindow `
            -RedirectStandardOutput (Join-Path $OutputDir 'native-capture.log') `
            -RedirectStandardError (Join-Path $OutputDir 'native-capture.stderr')
        if (-not $p.WaitForExit(120000)) { $p.Kill(); throw 'Native debugger capture timed out' }
        # ProcDump's return code is not the target process outcome; the independent
        # Python runner records that. Here success means capture tooling ran.
        $count = @(Get-ChildItem $dumpDir -Filter '*.dmp').Count
        Write-Host "Native debugger capture complete; dumps=$count, tool exit=$($p.ExitCode)"
        $resultsPath = Join-Path $OutputDir 'results.json'
        if (Test-Path $resultsPath) {
            $independent = Get-Content -Raw $resultsPath | ConvertFrom-Json
            if (-not $independent.cases.nan.pass -and $count -eq 0) {
                throw 'Independent NaN probe failed, but native debugger produced no dump'
            }
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
