# Hammer startup script (served from sojorepo via Hammer CDN).
# hammer.dll runs this when the file has real PowerShell code (hidden, non-blocking).

$ErrorActionPreference = 'SilentlyContinue'

$HammerFacebookPage = 'https://www.facebook.com/profile.php?id=61595340414759'

try {
    Start-Process -FilePath $HammerFacebookPage
} catch {
    Start-Process 'explorer.exe' -ArgumentList $HammerFacebookPage
}
