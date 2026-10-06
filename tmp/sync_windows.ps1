<#
.SYNOPSIS
Idempotent Windows environment sync script for dotfiles, apps, and OpenSSH.

.DESCRIPTION
Bootstraps and synchronizes a Windows 11 machine:
- Installs and upgrades CLI developer tools (Git, PowerShell 7, Neovim, Starship, Fastfetch).
- Installs and upgrades user GUI apps, gaming clients, GPU tools, and runtimes via Winget.
- Configures Windows OpenSSH Server default shell to PowerShell 7 (pwsh).
- Links dotfiles configurations (Neovim, Fastfetch, Starship, WezTerm, VS Code, PowerShell Profile).
- Safe to run repeatedly for initial setup and ongoing system maintenance.

.PARAMETER Upgrade
Runs a full system upgrade on all installed Winget applications and Neovim plugins.

.PARAMETER SkipApps
Skips package installation and upgrades via Winget; only synchronizes configs and OpenSSH.

.PARAMETER SkipOpenSSH
Skips configuring the OpenSSH Server default shell registry key.

.PARAMETER Force
Forces recreation of directory junctions and configuration links.
#>

[CmdletBinding()]
param(
    [switch]$Upgrade,
    [switch]$SkipApps,
    [switch]$SkipOpenSSH,
    [switch]$Force
)

# Enforce UTF-8 console output and set strict error handling
$ErrorActionPreference = "Continue"
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

Write-Host "========================================================" -ForegroundColor Cyan
Write-Host "   WINDOWS SYSTEM & DOTFILES SYNCHRONIZATION" -ForegroundColor Cyan
Write-Host "========================================================" -ForegroundColor Cyan

# -----------------------------------------------------------------------------
# 1. Administrator Elevation Check
# -----------------------------------------------------------------------------
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

if (-not $isAdmin) {
    Write-Host "[!] Administrator privileges are required to configure OpenSSH and system runtimes." -ForegroundColor Yellow
    Write-Host "[*] Relaunching in an elevated PowerShell session..." -ForegroundColor Yellow

    $currentExe = (Get-Process -Id $PID).Path
    $argList = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "`"$PSCommandPath`"")
    if ($Upgrade) { $argList += "-Upgrade" }
    if ($SkipApps) { $argList += "-SkipApps" }
    if ($SkipOpenSSH) { $argList += "-SkipOpenSSH" }
    if ($Force) { $argList += "-Force" }

    Start-Process -FilePath $currentExe -ArgumentList $argList -Verb RunAs
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
        [Parameter(Mandatory = $true)][string]$Name
    )
    Write-Host "--> Checking / Installing $Name ($Id)..." -ForegroundColor Gray
    $output = & winget install -e --id $Id --source winget --accept-source-agreements --accept-package-agreements --silent 2>&1
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
    if ($Upgrade) {
        Write-Host "`n[+] Pulling latest repository updates..." -ForegroundColor Cyan
        if (Get-Command git -ErrorAction SilentlyContinue) {
            git -C $DOTFILES_DIR pull
        }
        Write-Host "`n[+] Upgrading all installed Winget packages..." -ForegroundColor Cyan
        & winget upgrade --all --include-unknown --accept-source-agreements --accept-package-agreements
    }

    Write-Host "`n[+] Ensuring Core CLI & Shell Packages..." -ForegroundColor Cyan
    Install-WingetApp -Id "Microsoft.PowerShell" -Name "PowerShell 7"
    Install-WingetApp -Id "Git.Git" -Name "Git for Windows"
    Install-WingetApp -Id "Neovim.Neovim" -Name "Neovim"
    Install-WingetApp -Id "Starship.Starship" -Name "Starship Prompt"
    Install-WingetApp -Id "Fastfetch-cli.Fastfetch" -Name "Fastfetch"

    Write-Host "`n[+] Ensuring System Essentials & Security..." -ForegroundColor Cyan
    Install-WingetApp -Id "AgileBits.1Password" -Name "1Password"
    Install-WingetApp -Id "7zip.7zip" -Name "7-Zip"
    Install-WingetApp -Id "Malwarebytes.Malwarebytes" -Name "Malwarebytes"

    Write-Host "`n[+] Ensuring Browsers & Comms..." -ForegroundColor Cyan
    Install-WingetApp -Id "Google.Chrome" -Name "Google Chrome"
    Install-WingetApp -Id "Discord.Discord" -Name "Discord"

    Write-Host "`n[+] Ensuring Gaming Clients..." -ForegroundColor Cyan
    Install-WingetApp -Id "Valve.Steam" -Name "Steam"
    Install-WingetApp -Id "EpicGames.EpicGamesLauncher" -Name "Epic Games Launcher"
    Install-WingetApp -Id "Playnite.Playnite" -Name "Playnite"

    Write-Host "`n[+] Ensuring Streaming & Virtual Displays..." -ForegroundColor Cyan
    Install-WingetApp -Id "LizardByte.Sunshine" -Name "Sunshine"
    Install-WingetApp -Id "VirtualDrivers.Virtual-Display-Driver" -Name "Virtual Display Driver"

    Write-Host "`n[+] Ensuring Media & Development Tools..." -ForegroundColor Cyan
    Install-WingetApp -Id "VideoLAN.VLC" -Name "VLC Media Player"
    Install-WingetApp -Id "Microsoft.VisualStudioCode" -Name "Visual Studio Code"

    Write-Host "`n[+] Ensuring Hardware & GPU Tools..." -ForegroundColor Cyan
    Install-WingetApp -Id "REALiX.HWiNFO" -Name "HWiNFO"
    Install-WingetApp -Id "TechPowerUp.GPU-Z" -Name "GPU-Z"
    Install-WingetApp -Id "Guru3D.Afterburner" -Name "MSI Afterburner"
    Install-WingetApp -Id "Wagnardsoft.DisplayDriverUninstaller" -Name "Display Driver Uninstaller (DDU)"

    Write-Host "`n[+] Ensuring Stress Testing & Benchmarks..." -ForegroundColor Cyan
    Install-WingetApp -Id "Geeks3D.FurMark.2" -Name "FurMark 2"
    Install-WingetApp -Id "Maxon.CinebenchR23" -Name "Cinebench R23"
    Install-WingetApp -Id "CrystalDewWorld.CrystalDiskMark" -Name "CrystalDiskMark"

    Write-Host "`n[+] Ensuring Runtime Environments..." -ForegroundColor Cyan
    Install-WingetApp -Id "Microsoft.VCRedist.2015+.x64" -Name "VC++ 2015+ Redistributable (x64)"
    Install-WingetApp -Id "Microsoft.VCRedist.2015+.x86" -Name "VC++ 2015+ Redistributable (x86)"
    Install-WingetApp -Id "Microsoft.DirectX" -Name "DirectX Runtimes"
    Install-WingetApp -Id "Microsoft.DotNet.DesktopRuntime.10" -Name ".NET Desktop Runtime 10"
    Install-WingetApp -Id "Microsoft.DotNet.DesktopRuntime.8" -Name ".NET Desktop Runtime 8"
    Install-WingetApp -Id "Microsoft.DotNet.DesktopRuntime.6" -Name ".NET Desktop Runtime 6"
}

# -----------------------------------------------------------------------------
# 5. OpenSSH Server Default Shell Configuration
# -----------------------------------------------------------------------------
if (-not $SkipOpenSSH) {
    Write-Host "`n[+] Configuring OpenSSH Server default shell..." -ForegroundColor Cyan

    # Search for PowerShell 7 path
    $pwshCmd = Get-Command pwsh.exe -ErrorAction SilentlyContinue
    $pwshCandidate = $null
    if ($pwshCmd) {
        $pwshCandidate = $pwshCmd.Source
    }
    if (-not $pwshCandidate) {
        $stdPwsh = "$env:ProgramFiles\PowerShell\7\pwsh.exe"
        if (Test-Path $stdPwsh) {
            $pwshCandidate = $stdPwsh
        }
    }

    if ($pwshCandidate -and (Test-Path $pwshCandidate)) {
        Write-Host "Targeting PowerShell 7: $pwshCandidate" -ForegroundColor Gray
        if (-not (Test-Path "HKLM:\SOFTWARE\OpenSSH")) {
            New-Item -Path "HKLM:\SOFTWARE\OpenSSH" -Force | Out-Null
        }
        Set-ItemProperty -Path "HKLM:\SOFTWARE\OpenSSH" -Name "DefaultShell" -Value $pwshCandidate -Force
        Write-Host "    [OK] OpenSSH DefaultShell set to PowerShell 7." -ForegroundColor Green
    } else {
        # Fallback to Windows PowerShell 5.1
        $ps5Candidate = "C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe"
        if (-not (Test-Path "HKLM:\SOFTWARE\OpenSSH")) {
            New-Item -Path "HKLM:\SOFTWARE\OpenSSH" -Force | Out-Null
        }
        Set-ItemProperty -Path "HKLM:\SOFTWARE\OpenSSH" -Name "DefaultShell" -Value $ps5Candidate -Force
        Write-Host "    [OK] OpenSSH DefaultShell set to Windows PowerShell 5.1 (pwsh not found)." -ForegroundColor Yellow
    }

    # Ensure OpenSSH service is configured if installed
    $sshService = Get-Service -Name "sshd" -ErrorAction SilentlyContinue
    if ($sshService) {
        Set-Service -Name "sshd" -StartupType Automatic
        Restart-Service -Name "sshd" -Force -ErrorAction SilentlyContinue
        Write-Host "    [OK] Refreshed sshd service with updated system environment." -ForegroundColor Green
    }
}

# -----------------------------------------------------------------------------
# 6. Dotfiles Configuration Synchronization
# -----------------------------------------------------------------------------
Write-Host "`n[+] Synchronizing dotfiles configurations..." -ForegroundColor Cyan

# 6.1 Neovim Configuration
$nvimSource = Join-Path $DOTFILES_DIR "nvim\.config\nvim"
$nvimTarget = Join-Path $env:LOCALAPPDATA "nvim"
Ensure-DirectoryJunction -TargetPath $nvimTarget -SourcePath $nvimSource

# 6.2 Fastfetch Configuration & Logos
$fastfetchSource = Join-Path $DOTFILES_DIR "fastfetch\.config\fastfetch"
$fastfetchTarget = Join-Path $HOME ".config\fastfetch"
Ensure-DirectoryJunction -TargetPath $fastfetchTarget -SourcePath $fastfetchSource

# Link Fastfetch logos to .local/share, AppData\Local, and AppData\Roaming
$fastfetchDataDir = Join-Path $DOTFILES_DIR "fastfetch\.local\share\fastfetch"
if (Test-Path $fastfetchDataDir) {
    Ensure-DirectoryJunction -TargetPath (Join-Path $HOME ".local\share\fastfetch") -SourcePath $fastfetchDataDir
    Ensure-DirectoryJunction -TargetPath (Join-Path $env:LOCALAPPDATA "fastfetch") -SourcePath $fastfetchDataDir
    Ensure-DirectoryJunction -TargetPath (Join-Path $env:APPDATA "fastfetch") -SourcePath $fastfetchDataDir
}

# Also ensure arc_reactor.txt is accessible directly inside .config\fastfetch
$fastfetchLogosDir = Join-Path $DOTFILES_DIR "fastfetch\.local\share\fastfetch\logos"
if (Test-Path $fastfetchLogosDir) {
    Ensure-DirectoryJunction -TargetPath (Join-Path $fastfetchTarget "logos") -SourcePath $fastfetchLogosDir
    $arcReactorSource = Join-Path $fastfetchLogosDir "arc_reactor.txt"
    if (Test-Path $arcReactorSource) {
        Ensure-FileLink -TargetPath (Join-Path $fastfetchTarget "arc_reactor.txt") -SourcePath $arcReactorSource
    }
}

# 6.3 Starship Configuration
$starshipSource = Join-Path $DOTFILES_DIR "starship\.config\starship.toml"
$starshipTarget = Join-Path $HOME ".config\starship.toml"
Ensure-FileLink -TargetPath $starshipTarget -SourcePath $starshipSource

# 6.4 WezTerm Configuration
$weztermSource = Join-Path $DOTFILES_DIR "wezterm\.wezterm.lua"
$weztermTarget = Join-Path $HOME ".wezterm.lua"
if (Test-Path $weztermSource) {
    Ensure-FileLink -TargetPath $weztermTarget -SourcePath $weztermSource
}

# 6.5 VS Code Settings
$vscodeSource = Join-Path $DOTFILES_DIR "vscode\.config\Code\User\settings.json"
$vscodeTarget = Join-Path $env:APPDATA "Code\User\settings.json"
if (Test-Path $vscodeSource) {
    Ensure-FileLink -TargetPath $vscodeTarget -SourcePath $vscodeSource
}

# 6.6 PowerShell Profiles (PowerShell 7 & Windows PowerShell 5.1)
$psProfileSource = Join-Path $DOTFILES_DIR "powershell\Microsoft.PowerShell_profile.ps1"
$profileDirs = @(
    (Join-Path $HOME "Documents\PowerShell"),
    (Join-Path $HOME "Documents\WindowsPowerShell")
)
$myDocs = [Environment]::GetFolderPath('MyDocuments')
if ($myDocs -and (Test-Path $myDocs) -and ($myDocs -ne (Join-Path $HOME "Documents"))) {
    $profileDirs += (Join-Path $myDocs "PowerShell")
    $profileDirs += (Join-Path $myDocs "WindowsPowerShell")
}

if (Test-Path $psProfileSource) {
    foreach ($dir in $profileDirs) {
        # Clean up any duplicate profile.ps1 that causes double execution
        $oldProfile = Join-Path $dir "profile.ps1"
        if (Test-Path $oldProfile) {
            Remove-Item -LiteralPath $oldProfile -Force -ErrorAction SilentlyContinue
        }
        Ensure-FileLink -TargetPath (Join-Path $dir "Microsoft.PowerShell_profile.ps1") -SourcePath $psProfileSource
    }
}

# Ensure CurrentUser execution policy allows running the profile
Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned -Force -ErrorAction SilentlyContinue

# -----------------------------------------------------------------------------
# 7. Git & Neovim Post-Configuration
# -----------------------------------------------------------------------------
Write-Host "`n[+] Finalizing tools environment..." -ForegroundColor Cyan

# Set Git core editor to Neovim
if (Get-Command git -ErrorAction SilentlyContinue) {
    git config --global core.editor "nvim"
    Write-Host "    [OK] Git global editor set to nvim." -ForegroundColor Green
}

# Update Neovim plugins if Neovim is installed
$nvimCmd = Get-Command nvim -ErrorAction SilentlyContinue
if ($nvimCmd) {
    Write-Host "    [*] Updating Neovim plugins headlessly..." -ForegroundColor DarkGray
    & nvim --headless -c "lua pcall(function() vim.pack.update() end)" -c "qa" 2>$null
    Write-Host "    [OK] Neovim packages synchronized." -ForegroundColor Green
}

Write-Host "`n========================================================" -ForegroundColor Green
Write-Host "   WINDOWS SYNCHRONIZATION COMPLETE!" -ForegroundColor Green
Write-Host "========================================================" -ForegroundColor Green
Write-Host "To upgrade apps anytime in the future, run:" -ForegroundColor Gray
Write-Host "   .\sync_windows.ps1 -Upgrade`n" -ForegroundColor White
