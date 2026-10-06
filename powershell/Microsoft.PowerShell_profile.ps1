# Microsoft.PowerShell_profile.ps1
# Global profile for PowerShell 7 and Windows PowerShell 5.1

# Prevent duplicate initialization if multiple profiles are invoked
if ($global:__DOTFILES_PROFILE_INITIALIZED) { return }
$global:__DOTFILES_PROFILE_INITIALIZED = $true

# 1. Enforce UTF-8 Encoding
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

# 2. Starship Prompt Initialization
if (Get-Command starship -ErrorAction SilentlyContinue) {
    Invoke-Expression (&starship init powershell)
}

# 3. Fastfetch Greeting
if (Get-Command fastfetch -ErrorAction SilentlyContinue) {
    fastfetch
}

# 4. Quality of Life Aliases & Functions (Linux parity)
Set-Alias -Name v -Value nvim -Option AllScope -ErrorAction SilentlyContinue
Set-Alias -Name vim -Value nvim -Option AllScope -ErrorAction SilentlyContinue
Set-Alias -Name g -Value git -Option AllScope -ErrorAction SilentlyContinue
Set-Alias -Name ff -Value fastfetch -Option AllScope -ErrorAction SilentlyContinue

function ll {
    Get-ChildItem -Path $(if ($args) { $args } else { "." })
}

function la {
    Get-ChildItem -Force -Path $(if ($args) { $args } else { "." })
}

# Quick reload of profile
function reload-profile {
    $global:__DOTFILES_PROFILE_INITIALIZED = $false
    & $PROFILE
    Write-Host "PowerShell profile reloaded." -ForegroundColor Green
}
