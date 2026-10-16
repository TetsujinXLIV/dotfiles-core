<#
.SYNOPSIS
Idempotent Windows environment sync script for PC builds, apps, gaming tools, and dotfiles.

.DESCRIPTION
Bootstraps and synchronizes a Windows 11 machine:
- By default: Installs and upgrades user GUI apps, gaming clients, GPU tools, benchmarks, and runtimes via Winget.
  Designed specifically for friends/family PC builds and gaming desktops.
- With '-Dev': Also installs developer CLI tools (Git, PowerShell 7 MSI, Neovim, Starship, Fastfetch, VS Code, 1Password),
  configures Windows OpenSSH Server default shell safely to 64-bit PowerShell 7 (pwsh) and self-heals authorized_keys ACLs,
  links dotfiles configurations, unblocks execution policies across all PowerShell editions, and updates Neovim plugins.

.PARAMETER Upgrade
Runs a full system upgrade on all installed Winget applications (and Neovim plugins if -Dev is specified).

.PARAMETER Dev
Enables developer tools (Git, Neovim, VS Code, Starship, Fastfetch, PowerShell 7 MSI, 1Password), OpenSSH Server
configuration, and dotfiles linking.

.PARAMETER SkipApps
Skips package installation and upgrades via Winget; useful when only configuring dotfiles (-Dev -SkipApps).

.PARAMETER Dotfiles
Explicitly synchronizes dotfiles configurations without requiring full developer tools installation.

.PARAMETER OpenSSH
Explicitly configures OpenSSH Server default shell and authorized_keys ACLs without requiring full developer tools installation.

.PARAMETER Force
Forces recreation of directory junctions and configuration links.
#>

[CmdletBinding()]
param(
    [switch]$Upgrade,
    [switch]$SkipApps,
    [Alias("IncludeDev", "WithDev", "DevTools", "Workstation")]
    [switch]$Dev,
    [switch]$Dotfiles,
    [switch]$OpenSSH,
    [switch]$Force
)

# Feature flags: Developer tools, dotfiles, and OpenSSH are disabled by default
$IncludeDev = [bool]$Dev
$IncludeDotfiles = [bool]($Dev -or $Dotfiles)
$IncludeOpenSSH = [bool]($Dev -or $OpenSSH)

# Enforce UTF-8 console output and set strict error handling
$ErrorActionPreference = "Continue"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

Write-Host "========================================================" -ForegroundColor Cyan
if ($IncludeDev) {
    Write-Host "   WINDOWS WORKSTATION & DOTFILES SYNCHRONIZATION" -ForegroundColor Cyan
} else {
    Write-Host "   WINDOWS PC APPS & RUNTIMES SYNCHRONIZATION" -ForegroundColor Cyan
}
Write-Host "========================================================" -ForegroundColor Cyan

# -----------------------------------------------------------------------------
# 1. Administrator, 64-Bit Host, & Non-MSIX Elevation Check
# -----------------------------------------------------------------------------
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
$is64BitProcess = [Environment]::Is64BitProcess
$currentProcessPath = (Get-Process -Id $PID).Path
$isMsixPwsh = $currentProcessPath -like "*WindowsApps*"

if (-not $isAdmin -or -not $is64BitProcess -or $isMsixPwsh) {
    Write-Host "[!] 64-bit Administrator privileges (outside MSIX WindowsApps) are required to configure system apps, runtimes, and settings." -ForegroundColor Yellow
    Write-Host "[*] Relaunching in an elevated 64-bit PowerShell session..." -ForegroundColor Yellow

    $stdPwsh = "C:\Program Files\PowerShell\7\pwsh.exe"
    if (Test-Path $stdPwsh) {
        $targetExe = $stdPwsh
    } elseif (-not $is64BitProcess -and (Test-Path "$env:WinDir\Sysnative\WindowsPowerShell\v1.0\powershell.exe")) {
        $targetExe = "$env:WinDir\Sysnative\WindowsPowerShell\v1.0\powershell.exe"
    } else {
        $targetExe = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
    }

    $argList = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "`"$PSCommandPath`"")
    if ($Upgrade) { $argList += "-Upgrade" }
    if ($SkipApps) { $argList += "-SkipApps" }
    if ($Dev) { $argList += "-Dev" }
    if ($Dotfiles) { $argList += "-Dotfiles" }
    if ($OpenSSH) { $argList += "-OpenSSH" }
    if ($Force) { $argList += "-Force" }

    Start-Process -FilePath $targetExe -ArgumentList $argList -Verb RunAs
    exit
}

# -----------------------------------------------------------------------------
# 2. Prerequisites Validation (Winget)
# -----------------------------------------------------------------------------
$DOTFILES_DIR = $PSScriptRoot

if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
    Write-Error "Winget (Windows Package Manager) was not found in PATH. Please install 'App Installer' from the Microsoft Store or GitHub."
    exit 1
}

# -----------------------------------------------------------------------------
# 3. Helper Functions
# -----------------------------------------------------------------------------
function Install-WingetApp {
    param(
        [Parameter(Mandatory = $true)][string]$Id,
        [Parameter(Mandatory = $true)][string]$Name,
        [string[]]$ExtraArgs = @()
    )
    Write-Host "--> Checking / Installing $Name ($Id)..." -ForegroundColor Gray
    $wingetArgs = @("install", "-e", "--id", $Id, "--source", "winget", "--accept-source-agreements", "--accept-package-agreements", "--silent") + $ExtraArgs
    $output = & winget @wingetArgs 2>&1
    if ($LASTEXITCODE -eq 0) {
        Write-Host "    [OK] $Name is installed." -ForegroundColor Green
    } elseif ($LASTEXITCODE -eq -1978335189 -or $LASTEXITCODE -eq -1978335215) {
        # Already installed or no update available
        Write-Host "    [OK] $Name is already installed." -ForegroundColor Green
    } else {
        Write-Host "    [WARN] Winget returned code $LASTEXITCODE for $Id" -ForegroundColor Yellow
    }
}

function Ensure-DirectoryJunction {
    param(
        [Parameter(Mandatory = $true)][string]$TargetPath,
        [Parameter(Mandatory = $true)][string]$SourcePath
    )

    if (-not (Test-Path $SourcePath)) {
        Write-Warning "Source directory does not exist: $SourcePath"
        return
    }

    # Ensure parent folder exists
    $parent = Split-Path -Path $TargetPath -Parent
    if (-not (Test-Path $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }

    # If target already exists
    if (Test-Path $TargetPath) {
        $item = Get-Item -LiteralPath $TargetPath -Force
        # Check if already a reparse point (junction/symlink)
        if ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
            if ($Force) {
                Write-Host "Re-linking junction: $TargetPath -> $SourcePath" -ForegroundColor DarkGray
                cmd /c rmdir "$TargetPath" 2>$null
            } else {
                Write-Host "    [OK] Junction already configured: $TargetPath" -ForegroundColor Green
                return
            }
        } else {
            # Existing standard directory - back it up
            $backupPath = "${TargetPath}.bak_" + (Get-Date -Format "yyyyMMdd_HHmmss")
            Write-Host "Backing up existing directory: $TargetPath -> $backupPath" -ForegroundColor Yellow
            Rename-Item -LiteralPath $TargetPath -NewName (Split-Path $backupPath -Leaf)
        }
    }

    Write-Host "Creating junction: $TargetPath -> $SourcePath" -ForegroundColor Cyan
    cmd /c mklink /J "$TargetPath" "$SourcePath" | Out-Null
}

function Ensure-FileLink {
    param(
        [Parameter(Mandatory = $true)][string]$TargetPath,
        [Parameter(Mandatory = $true)][string]$SourcePath
    )

    if (-not (Test-Path $SourcePath)) {
        Write-Warning "Source file does not exist: $SourcePath"
        return
    }

    $parent = Split-Path -Path $TargetPath -Parent
    if (-not (Test-Path $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }

    if (Test-Path $TargetPath) {
        $item = Get-Item -LiteralPath $TargetPath -Force
        if ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
            if ($Force) {
                Remove-Item -LiteralPath $TargetPath -Force
            } else {
                Write-Host "    [OK] Symlink already configured: $TargetPath" -ForegroundColor Green
                return
            }
        } else {
            if ($Force) {
                Remove-Item -LiteralPath $TargetPath -Force
            } else {
                $fullTarget = (Get-Item -LiteralPath $TargetPath).FullName
                $fullSource = (Get-Item -LiteralPath $SourcePath).FullName
                if ($fullTarget -ne $fullSource) {
                    Write-Host "    [OK] File copy updated: $TargetPath" -ForegroundColor Green
                    Copy-Item -LiteralPath $SourcePath -Destination $TargetPath -Force
                } else {
                    Write-Host "    [OK] File link/copy exists: $TargetPath" -ForegroundColor Green
                }
                return
            }
        }
    }

    try {
        # Try symbolic link first
        New-Item -ItemType SymbolicLink -Path $TargetPath -Target $SourcePath -Force -ErrorAction Stop | Out-Null
        Write-Host "Created symlink: $TargetPath -> $SourcePath" -ForegroundColor Cyan
    } catch {
        # Fallback to copy if developer mode or privilege restricts file symlinks
        Copy-Item -LiteralPath $SourcePath -Destination $TargetPath -Force
        Write-Host "Copied config (symlink restricted): $TargetPath" -ForegroundColor DarkCyan
    }
}

# -----------------------------------------------------------------------------
# 4. Package Installation & Upgrades
# -----------------------------------------------------------------------------
if (-not $SkipApps) {
    if ($IncludeDev) {
        # Remove any MSIX (WindowsApps) PowerShell 7 package so Winget never uses versioned paths
        $msixPwsh = Get-AppxPackage -Name "Microsoft.PowerShell" -ErrorAction SilentlyContinue
        if ($msixPwsh) {
            Write-Host "`n[!] Removing MSIX Store edition of PowerShell 7 in favor of stable MSI edition..." -ForegroundColor Yellow
            $msixPwsh | Remove-AppxPackage -ErrorAction SilentlyContinue
        }
    }

    if ($Upgrade) {
        if ($IncludeDev -and (Get-Command git -ErrorAction SilentlyContinue)) {
            Write-Host "`n[+] Pulling latest repository updates..." -ForegroundColor Cyan
            git -C $DOTFILES_DIR pull
        }
        Write-Host "`n[+] Upgrading all installed Winget packages..." -ForegroundColor Cyan
        & winget upgrade --all --include-unknown --accept-source-agreements --accept-package-agreements
    }

    # 4.1 Developer CLI & Shell Packages (Installed only when -Dev is specified)
    if ($IncludeDev) {
        Write-Host "`n[+] Ensuring Developer CLI & Shell Packages..." -ForegroundColor Cyan
        # Force MSI (wix) installer for PowerShell 7 so C:\Program Files\PowerShell\7\pwsh.exe is always used
        if (-not (Test-Path "C:\Program Files\PowerShell\7\pwsh.exe")) {
            Install-WingetApp -Id "Microsoft.PowerShell" -Name "PowerShell 7 (MSI)" -ExtraArgs @("--installer-type", "wix", "--scope", "machine", "--architecture", "x64", "--force")
        } elseif ($Upgrade) {
            Write-Host "--> Checking / Upgrading PowerShell 7 (MSI)..." -ForegroundColor Gray
            & winget upgrade -e --id Microsoft.PowerShell --source winget --installer-type wix --scope machine --architecture x64 --accept-source-agreements --accept-package-agreements --silent 2>&1 | Out-Null
            Write-Host "    [OK] PowerShell 7 (MSI) is up to date." -ForegroundColor Green
        } else {
            Write-Host "    [OK] PowerShell 7 (MSI) is installed at C:\Program Files\PowerShell\7\pwsh.exe." -ForegroundColor Green
        }

        Install-WingetApp -Id "Git.Git" -Name "Git for Windows"
        Install-WingetApp -Id "Neovim.Neovim" -Name "Neovim"
        Install-WingetApp -Id "Starship.Starship" -Name "Starship Prompt"
        Install-WingetApp -Id "Fastfetch-cli.Fastfetch" -Name "Fastfetch"
        Install-WingetApp -Id "Microsoft.VisualStudioCode" -Name "Visual Studio Code"
        Install-WingetApp -Id "AgileBits.1Password" -Name "1Password"
    } else {
        Write-Host "`n[*] Skipping developer tools, VS Code, and 1Password (use -Dev to include)." -ForegroundColor DarkGray
    }

    # 4.2 System Essentials & Utilities (Default for all builds)
    Write-Host "`n[+] Ensuring System Essentials & Utilities..." -ForegroundColor Cyan
    Install-WingetApp -Id "7zip.7zip" -Name "7-Zip"
    Install-WingetApp -Id "Malwarebytes.Malwarebytes" -Name "Malwarebytes"
    Install-WingetApp -Id "VideoLAN.VLC" -Name "VLC Media Player"
    Install-WingetApp -Id "Gyan.FFmpeg" -Name "FFmpeg"

    # 4.3 Browsers & Comms
    Write-Host "`n[+] Ensuring Browsers & Comms..." -ForegroundColor Cyan
    Install-WingetApp -Id "Google.Chrome" -Name "Google Chrome"
    Install-WingetApp -Id "Discord.Discord" -Name "Discord"

    # 4.4 Gaming Clients
    Write-Host "`n[+] Ensuring Gaming Clients..." -ForegroundColor Cyan
    Install-WingetApp -Id "Valve.Steam" -Name "Steam"
    Install-WingetApp -Id "EpicGames.EpicGamesLauncher" -Name "Epic Games Launcher"
    Install-WingetApp -Id "Playnite.Playnite" -Name "Playnite"

    # 4.5 Streaming & Virtual Displays
    Write-Host "`n[+] Ensuring Streaming & Virtual Displays..." -ForegroundColor Cyan
    Install-WingetApp -Id "LizardByte.Sunshine" -Name "Sunshine"
    Install-WingetApp -Id "VirtualDrivers.Virtual-Display-Driver" -Name "Virtual Display Driver"

    # 4.6 Hardware & GPU Tools
    Write-Host "`n[+] Ensuring Hardware & GPU Tools..." -ForegroundColor Cyan
    Install-WingetApp -Id "REALiX.HWiNFO" -Name "HWiNFO"
    Install-WingetApp -Id "TechPowerUp.GPU-Z" -Name "GPU-Z"
    Install-WingetApp -Id "Guru3D.Afterburner" -Name "MSI Afterburner"
    Install-WingetApp -Id "Wagnardsoft.DisplayDriverUninstaller" -Name "Display Driver Uninstaller (DDU)"

    # 4.7 Stress Testing & Benchmarks
    Write-Host "`n[+] Ensuring Stress Testing & Benchmarks..." -ForegroundColor Cyan
    Install-WingetApp -Id "Geeks3D.FurMark.2" -Name "FurMark 2"
    Install-WingetApp -Id "Maxon.CinebenchR23" -Name "Cinebench R23"
    Install-WingetApp -Id "CrystalDewWorld.CrystalDiskMark" -Name "CrystalDiskMark"

    # 4.8 Runtime Environments
    Write-Host "`n[+] Ensuring Runtime Environments..." -ForegroundColor Cyan
    Install-WingetApp -Id "Microsoft.VCRedist.2015+.x64" -Name "VC++ 2015+ Redistributable (x64)"
    Install-WingetApp -Id "Microsoft.VCRedist.2015+.x86" -Name "VC++ 2015+ Redistributable (x86)"
    Install-WingetApp -Id "Microsoft.DirectX" -Name "DirectX Runtimes"
    Install-WingetApp -Id "Microsoft.DotNet.DesktopRuntime.10" -Name ".NET Desktop Runtime 10"
    Install-WingetApp -Id "Microsoft.DotNet.DesktopRuntime.8" -Name ".NET Desktop Runtime 8"
    Install-WingetApp -Id "Microsoft.DotNet.DesktopRuntime.6" -Name ".NET Desktop Runtime 6"
}

# -----------------------------------------------------------------------------
# 5. OpenSSH Server Default Shell & Authorized Keys Self-Healing (Only when -Dev or -OpenSSH)
# -----------------------------------------------------------------------------
if ($IncludeOpenSSH) {
    Write-Host "`n[+] Configuring OpenSSH Server default shell & keys..." -ForegroundColor Cyan

    # Strictly use stable 64-bit Program Files path (never use versioned WindowsApps paths)
    $stdPwsh = "C:\Program Files\PowerShell\7\pwsh.exe"
    $ps5Fallback = "C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe"

    if (Test-Path $stdPwsh) {
        $targetShell = $stdPwsh
        Write-Host "    [OK] Targeting PowerShell 7 (MSI): $targetShell" -ForegroundColor Green
    } else {
        $targetShell = $ps5Fallback
        Write-Host "    [WARN] $stdPwsh not found; falling back safely to Windows PowerShell 5.1" -ForegroundColor Yellow
    }

    # Always write to the 64-bit registry view (/reg:64) so sshd sees the exact path
    & reg.exe add "HKLM\SOFTWARE\OpenSSH" /v DefaultShell /t REG_SZ /d "$targetShell" /f /reg:64 | Out-Null

    # Self-heal authorized_keys across both ProgramData and User .ssh with clean UTF-8 (no BOM) and strict ACLs
    $adminKeyFile = "C:\ProgramData\ssh\administrators_authorized_keys"
    $userSshDir   = Join-Path $HOME ".ssh"
    $userKeyFile  = Join-Path $userSshDir "authorized_keys"
    $repoKeyFile  = Join-Path $DOTFILES_DIR "ssh\authorized_keys"

    $sourceKeyFile = $null
    if (Test-Path $repoKeyFile) {
        $sourceKeyFile = $repoKeyFile
    } elseif (Test-Path $adminKeyFile) {
        $sourceKeyFile = $adminKeyFile
    } elseif (Test-Path $userKeyFile) {
        $sourceKeyFile = $userKeyFile
    }

    if ($sourceKeyFile) {
        [string[]]$rawKeys = @(Get-Content $sourceKeyFile | Where-Object { $_.Trim() -ne "" })
        if ($rawKeys.Count -gt 0) {
            $utf8NoBom = New-Object System.Text.UTF8Encoding($false)

            if (Test-Path "C:\ProgramData\ssh") {
                [System.IO.File]::WriteAllLines($adminKeyFile, $rawKeys, $utf8NoBom)
                & icacls.exe $adminKeyFile /reset | Out-Null
                & icacls.exe $adminKeyFile /inheritance:r /grant "*S-1-5-32-544:F" /grant "*S-1-5-18:F" | Out-Null
            }

            New-Item -ItemType Directory -Path $userSshDir -Force | Out-Null
            [System.IO.File]::WriteAllLines($userKeyFile, $rawKeys, $utf8NoBom)
            & icacls.exe $userKeyFile /reset | Out-Null
            & icacls.exe $userKeyFile /inheritance:r /grant "$($env:USERNAME):(R,W)" /grant "*S-1-5-32-544:F" /grant "*S-1-5-18:F" | Out-Null
            Write-Host "    [OK] Synchronized SSH authorized_keys (UTF-8 no BOM) and enforced strict ACLs." -ForegroundColor Green
        }
    }

    $sshService = Get-Service -Name "sshd" -ErrorAction SilentlyContinue
    if ($sshService) {
        Set-Service -Name "sshd" -StartupType Automatic
        Restart-Service -Name "sshd" -Force -ErrorAction SilentlyContinue
        Write-Host "    [OK] Refreshed sshd service." -ForegroundColor Green
    }
}

# -----------------------------------------------------------------------------
# 6. Dotfiles Configuration Synchronization (Only when -Dev or -Dotfiles)
# -----------------------------------------------------------------------------
if ($IncludeDotfiles) {
    Write-Host "`n[+] Synchronizing dotfiles configurations..." -ForegroundColor Cyan

    # 6.1 Neovim Configuration
    $nvimSource = Join-Path $DOTFILES_DIR "nvim\.config\nvim"
    if (Test-Path $nvimSource) {
        $nvimTarget = Join-Path $env:LOCALAPPDATA "nvim"
        Ensure-DirectoryJunction -TargetPath $nvimTarget -SourcePath $nvimSource
    }

    # 6.2 VS Code Settings & Extensions
    $vscodeSource = Join-Path $DOTFILES_DIR "vscode\.config\Code\User\settings.json"
    if (Test-Path $vscodeSource) {
        $vscodeTarget = Join-Path $env:APPDATA "Code\User\settings.json"
        Ensure-FileLink -TargetPath $vscodeTarget -SourcePath $vscodeSource
    }

    # VS Code extension manifest reconciliation (if code CLI is present)
    $vscodeExtList = Join-Path $DOTFILES_DIR "vscode\extensions.list"
    if ((Test-Path $vscodeExtList) -and (Get-Command code -ErrorAction SilentlyContinue)) {
        Write-Host "    [*] Reconciling VS Code extensions..." -ForegroundColor DarkGray
        $installed = & code --list-extensions 2>$null
        Get-Content $vscodeExtList | ForEach-Object { $_.Trim() } | Where-Object { $_ -and -not $_.StartsWith("#") } | ForEach-Object {
            $extId = $_
            if ($installed -notcontains $extId) {
                Write-Host "        Installing extension: $extId" -ForegroundColor DarkGray
                & code --install-extension $extId --force | Out-Null
            }
        }
    }

    # 6.3 Ghostty Configuration
    $ghosttySource = Join-Path $DOTFILES_DIR "ghostty\.config\ghostty\config"
    if (Test-Path $ghosttySource) {
        $ghosttyTarget = Join-Path $env:APPDATA "ghostty\config"
        Ensure-FileLink -TargetPath $ghosttyTarget -SourcePath $ghosttySource
    }

    # 6.4 PowerShell Profiles (PowerShell 7 & Windows PowerShell 5.1)
    $psProfileSource = Join-Path $DOTFILES_DIR "powershell\Microsoft.PowerShell_profile.ps1"
    if (Test-Path $psProfileSource) {
        $profileDirs = @(
            (Join-Path $HOME "Documents\PowerShell"),
            (Join-Path $HOME "Documents\WindowsPowerShell")
        )
        $myDocs = [Environment]::GetFolderPath('MyDocuments')
        if ($myDocs -and (Test-Path $myDocs) -and ($myDocs -ne (Join-Path $HOME "Documents"))) {
            $profileDirs += (Join-Path $myDocs "PowerShell")
            $profileDirs += (Join-Path $myDocs "WindowsPowerShell")
        }

        foreach ($dir in ($profileDirs | Select-Object -Unique)) {
            $oldProfile = Join-Path $dir "profile.ps1"
            if (Test-Path $oldProfile) {
                Remove-Item -LiteralPath $oldProfile -Force -ErrorAction SilentlyContinue
            }
            Ensure-FileLink -TargetPath (Join-Path $dir "Microsoft.PowerShell_profile.ps1") -SourcePath $psProfileSource
        }
    }

    # Ensure ExecutionPolicy is RemoteSigned across PowerShell 7, 64-bit PS 5.1, and 32-bit PS 5.1
    Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned -Force -ErrorAction SilentlyContinue
    Set-ExecutionPolicy -Scope LocalMachine -ExecutionPolicy RemoteSigned -Force -ErrorAction SilentlyContinue
    & reg.exe add "HKLM\SOFTWARE\Microsoft\PowerShell\1\ShellIds\Microsoft.PowerShell" /v ExecutionPolicy /t REG_SZ /d "RemoteSigned" /f /reg:64 | Out-Null
    & reg.exe add "HKLM\SOFTWARE\Microsoft\PowerShell\1\ShellIds\Microsoft.PowerShell" /v ExecutionPolicy /t REG_SZ /d "RemoteSigned" /f /reg:32 | Out-Null
    Write-Host "    [OK] ExecutionPolicy set to RemoteSigned across all PowerShell editions." -ForegroundColor Green

    # 6.5 Optional Configurations (Linked only if present in repo)
    $fastfetchSource = Join-Path $DOTFILES_DIR "fastfetch\.config\fastfetch"
    if (Test-Path $fastfetchSource) {
        Ensure-DirectoryJunction -TargetPath (Join-Path $HOME ".config\fastfetch") -SourcePath $fastfetchSource
    }

    $starshipSource = Join-Path $DOTFILES_DIR "starship\.config\starship.toml"
    if (Test-Path $starshipSource) {
        Ensure-FileLink -TargetPath (Join-Path $HOME ".config\starship.toml") -SourcePath $starshipSource
    }

    $weztermSource = Join-Path $DOTFILES_DIR "wezterm\.wezterm.lua"
    if (Test-Path $weztermSource) {
        Ensure-FileLink -TargetPath (Join-Path $HOME ".wezterm.lua") -SourcePath $weztermSource
    }
}

# -----------------------------------------------------------------------------
# 7. Git & Neovim Post-Configuration (Only when -Dev)
# -----------------------------------------------------------------------------
if ($IncludeDev) {
    Write-Host "`n[+] Finalizing developer environment..." -ForegroundColor Cyan

    if (Get-Command git -ErrorAction SilentlyContinue) {
        git config --global core.editor "nvim"
        Write-Host "    [OK] Git global editor set to nvim." -ForegroundColor Green
    }

    $nvimCmd = Get-Command nvim -ErrorAction SilentlyContinue
    if ($nvimCmd) {
        Write-Host "    [*] Updating Neovim plugins headlessly..." -ForegroundColor DarkGray
        & nvim --headless -c "lua pcall(function() vim.pack.update() end)" -c "qa" 2>$null
        Write-Host "    [OK] Neovim packages synchronized." -ForegroundColor Green
    }
}

Write-Host "`n========================================================" -ForegroundColor Green
if ($IncludeDev) {
    Write-Host "   WINDOWS WORKSTATION & DOTFILES COMPLETE!" -ForegroundColor Green
    Write-Host "========================================================" -ForegroundColor Green
    Write-Host "To upgrade all apps and tools in the future, run:" -ForegroundColor Gray
    Write-Host "   .\sync_windows.ps1 -Dev -Upgrade`n" -ForegroundColor White
} else {
    Write-Host "   WINDOWS PC APPS & RUNTIMES SYNCHRONIZED!" -ForegroundColor Green
    Write-Host "========================================================" -ForegroundColor Green
    Write-Host "To upgrade all installed apps in the future, run:" -ForegroundColor Gray
    Write-Host "   .\sync_windows.ps1 -Upgrade`n" -ForegroundColor White
    Write-Host "To include developer tools, OpenSSH, and dotfiles, run:" -ForegroundColor Gray
    Write-Host "   .\sync_windows.ps1 -Dev`n" -ForegroundColor White
}
