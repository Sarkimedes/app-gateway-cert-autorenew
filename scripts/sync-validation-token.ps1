<#
.SYNOPSIS
    Fetches the App Service Certificate domain verification token & Key Vault secret name,
    generates godaddy.html, and uploads it to the static site container for PKI validation.

.DESCRIPTION
    Step 2:
    - Fetches the domain verification token from the Certificate Order.
    - Fetches the Key Vault secret name where Azure saves the certificate.
    - Writes the token into 'godaddy.html'.
    - Uploads 'godaddy.html' to the storage account '$web' container under:
      '/.well-known/pki-validation/godaddy.html'
    - Optionally calls the 'verifyDomainOwnership' REST API to request immediate verification.
    
    This script is designed to run once at deployment time, and also repeatedly at intervals
    as part of a CI/CD pipeline or scheduled task (no blocking polling loops).

.PARAMETER ResourceGroupName
    Target Azure Resource Group. Defaults to 'rg-agwcert'.

.PARAMETER ProjectName
    Optional project name prefix. Defaults to 'agwcert'.

.PARAMETER StorageAccountName
    Optional storage account name. Defaults to 'st' + $ProjectName.

.PARAMETER CertificateOrderName
    Optional certificate order name. Defaults to 'cert' + $ProjectName.

.PARAMETER OutputFile
    Local filename for the token. Defaults to 'godaddy.html'.

.PARAMETER TriggerVerification
    If set, sends a POST request to Azure's verifyDomainOwnership REST API to trigger validation.
    Defaults to $true.

.EXAMPLE
    ./sync-validation-token.ps1 -ResourceGroupName "rg-agwcert"

.EXAMPLE
    ./sync-validation-token.ps1 -ResourceGroupName "rg-agwcert" -ProjectName "agwcert"
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$ResourceGroupName = 'rg-agwcert',

    [Parameter(Mandatory = $false)]
    [string]$ProjectName = 'agwcert',

    [Parameter(Mandatory = $false)]
    [string]$StorageAccountName,

    [Parameter(Mandatory = $false)]
    [string]$CertificateOrderName,

    [Parameter(Mandatory = $false)]
    [string]$OutputFile = 'godaddy.html',

    [Parameter(Mandatory = $false)]
    [switch]$TriggerVerification = $true
)

$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($CertificateOrderName)) {
    $CertificateOrderName = "cert$ProjectName"
}
if ([string]::IsNullOrWhiteSpace($StorageAccountName)) {
    $StorageAccountName = "st$ProjectName"
}

# 1. Fetch domain verification token
$token = az resource show `
    --resource-group $ResourceGroupName `
    --resource-type "Microsoft.CertificateRegistration/certificateOrders" `
    --name $CertificateOrderName `
    --query "properties.domainVerificationToken" `
    --output tsv

if ([string]::IsNullOrWhiteSpace($token)) {
    throw "Unable to retrieve domain verification token for '$CertificateOrderName'."
}

Write-Host "Domain Verification Token : $token" -ForegroundColor Green

# 2. Write token to local file and upload to storage account $web container
Set-Content -Path $OutputFile -Value $token -NoNewline

az storage blob upload `
    --account-name $StorageAccountName `
    --container-name '$web' `
    --name '.well-known/pki-validation/godaddy.html' `
    --file $OutputFile `
    --content-type 'text/html' `
    --overwrite `
    --auth-mode key `
    --output none

Write-Host "Uploaded $OutputFile to storage account '$StorageAccountName' (`$web container)." -ForegroundColor Green

# 3. Request domain verification (non-blocking)
if ($TriggerVerification) {
    $subId = (az account show --query id -o tsv)
    $verifyUri = "/subscriptions/$subId/resourceGroups/$ResourceGroupName/providers/Microsoft.CertificateRegistration/certificateOrders/$CertificateOrderName/verifyDomainOwnership?api-version=2022-09-01"
    az rest --method post --uri $verifyUri 2>$null | Out-Null
    Write-Host "Requested domain ownership re-verification." -ForegroundColor Gray
}

# 4. Snapshot status check
$status = az resource show `
    --resource-group $ResourceGroupName `
    --resource-type "Microsoft.CertificateRegistration/certificateOrders" `
    --name $CertificateOrderName `
    --query "properties.status" `
    --output tsv 2>$null

Write-Host "Current Certificate Status: $status" -ForegroundColor Cyan
