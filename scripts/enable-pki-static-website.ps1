param (
    [string] $ResourceGroupName,
    [string] $StorageAccountName,
    [string] $VerificationToken
)

$ErrorActionPreference = 'Stop'

# Create storage context using connected account (RBAC)
$ctx = New-AzStorageContext -StorageAccountName $StorageAccountName -UseConnectedAccount

# Enable static website hosting
Enable-AzStorageStaticWebsite `
    -Context $ctx `
    -IndexDocument 'index.html' `
    -ErrorDocument404Path 'index.html'

# Create and upload godaddy.html containing the verification token
$tempFile = [System.IO.Path]::GetTempFileName()
try {
    Set-Content -Path $tempFile -Value $VerificationToken -NoNewline

    Set-AzStorageBlobContent `
        -File $tempFile `
        -Container '$web' `
        -Blob '.well-known/pki-validation/godaddy.html' `
        -Context $ctx `
        -Properties @{ ContentType = 'text/html' } `
        -Force
}
finally {
    if (Test-Path $tempFile) {
        Remove-Item -Path $tempFile -Force
    }
}
