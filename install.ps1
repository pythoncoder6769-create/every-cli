# every-cli installer for Windows 11 (Git Bash + Scoop)
# Run in PowerShell as Administrator

Write-Host "every-cli installer for Windows 11" -ForegroundColor Cyan

# 1. Install Scoop if missing
if (-not (Get-Command scoop -ErrorAction SilentlyContinue)) {
  Write-Host "Installing Scoop..."
  Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser -Force
  Invoke-RestMethod -Uri https://get.scoop.sh | Invoke-Expression
}

# 2. Required packages
Write-Host "Installing dependencies via Scoop..."
scoop bucket add extras
scoop install git fzf mpv yt-dlp ffmpeg

# 3. Copy every-cli to Git Bash bin
$GitBin = "$env:USERPROFILE\scoop\apps\git\current\usr\bin"
if (-not (Test-Path $GitBin)) {
  $GitBin = "C:\Program Files\Git\usr\bin"
}
Copy-Item "every-cli" "$GitBin\every-cli" -Force

# Copy lib dir
$LibDest = "$env:USERPROFILE\.every-cli\lib"
New-Item -ItemType Directory -Force -Path "$LibDest\scrapers" | Out-Null
New-Item -ItemType Directory -Force -Path "$LibDest\providers" | Out-Null
Copy-Item "lib\core.sh" "$LibDest\" -Force
Copy-Item "lib\scrapers\*" "$LibDest\scrapers\" -Force
Copy-Item "lib\providers\*" "$LibDest\providers\" -Force

Write-Host "Done! Open Git Bash in Windows Terminal and run: every-cli" -ForegroundColor Green
Write-Host "Tip: set Git Bash as default profile in Windows Terminal for best experience."
