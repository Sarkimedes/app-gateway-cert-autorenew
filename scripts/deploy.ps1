<#
.SYNOPSIS
    Deploys the Application Gateway and Certificate Renewal infrastructure via Bicep.

.DESCRIPTION
    This script handles both deployment phases (Steps 1 & 3):
    - Initial Deploy (Step 1): Run without -SslCertificateSecretName. Deploys base infrastructure,
      Storage Account, Key Vault, Web App, Certificate Order, and Application Gateway with an HTTP
      port 80 listener (and path-based routing for PKI validation).
    - Second Deploy (Step 3): Run with -SslCertificateSecretName <secretName>. Re-runs Bicep passing
      the Key Vault secret name to bind the SSL certificate to Application Gateway and create the
      HTTPS port 443 listener.

.PARAMETER ResourceGroupName
    Target Azure Resource Group. Defaults to 'rg-agwcert'.

.PARAMETER TemplateFile
    Path to Bicep template. Defaults to 'bicep/main.bicep'.

.PARAMETER ParametersFile
    Path to Bicep parameters file. Defaults to 'bicep/main.bicepparam'.

.PARAMETER SslCertificateSecretName
    Name of the Key Vault secret containing the certificate.
    Leave empty for initial deployment (Step 1).
    Provide the secret name for the 2nd deployment (Step 3).

.PARAMETER ProjectName
    Optional override for the projectName parameter.

.PARAMETER CustomDomainName
    Optional override for the customDomainName parameter.

.PARAMETER Location
    Azure region for resources. Defaults to resource group location or current location.

.EXAMPLE
    # Step 1: Initial deployment (without SSL certificate)
    ./deploy.ps1 -ResourceGroupName "rg-agwcert"

.EXAMPLE
    # Step 3: Second deployment (binding issued SSL certificate)
    ./deploy.ps1 -ResourceGroupName "rg-agwcert" -SslCertificateSecretName "certagwcert1b95d780-db76-460f-a90b-845cf261c2fa"
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$ResourceGroupName = 'rg-agwcert2',

    [Parameter(Mandatory = $false)]
    [string]$TemplateFile = 'bicep/main.bicep',

    [Parameter(Mandatory = $false)]
    [string]$ParametersFile = 'bicep/main.bicepparam',

    [Parameter(Mandatory = $false)]
    [string]$SslCertificateSecretName = '',

    [Parameter(Mandatory = $false)]
    [string]$ProjectName,

    [Parameter(Mandatory = $false)]
    [string]$CustomDomainName,

    [Parameter(Mandatory = $false)]
    [string]$Location
)

$ErrorActionPreference = 'Stop'

Write-Host "Verifying Azure CLI login and subscription..." -ForegroundColor Cyan
$subJson = az account show --output json 2>$null
if (-not $subJson) {
    throw "Not logged into Azure CLI. Please run 'az login' first."
}
$sub = ($subJson | Out-String) | ConvertFrom-Json
Write-Host "Active Subscription: $($sub.name) ($($sub.id))" -ForegroundColor Gray

# Ensure target resource group exists
$rgExists = az group exists -n $ResourceGroupName
if ($rgExists -eq 'false') {
    if (-not $Location) {
        throw "Resource group '$ResourceGroupName' does not exist. Please specify the -Location parameter."
    }
    Write-Host "Creating resource group '$ResourceGroupName' in '$Location'..." -ForegroundColor Cyan
    az group create -n $ResourceGroupName -l $Location --output none
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to create resource group '$ResourceGroupName'."
    }
} else {
    if (-not $Location) {
        $Location = az group show -n $ResourceGroupName --query location -o tsv
    }
    Write-Host "Target Resource Group: $ResourceGroupName (Region: $Location)" -ForegroundColor Gray
}

# Construct Bicep deployment arguments
$deploymentName = "agw-deploy-" + (Get-Date -Format "yyyyMMdd-HHmmss")
$deployArgs = @(
    'deployment', 'group', 'create',
    '--name', $deploymentName,
    '--resource-group', $ResourceGroupName,
    '--template-file', $TemplateFile
)

if (Test-Path $ParametersFile) {
    $deployArgs += @('--parameters', $ParametersFile)
}
if ($ProjectName) {
    $deployArgs += @('--parameters', "projectName=$ProjectName")
}
if ($CustomDomainName) {
    $deployArgs += @('--parameters', "customDomainName=$CustomDomainName")
}
if ($Location) {
    $deployArgs += @('--parameters', "location=$Location")
}

# Pass SslCertificateSecretName (either empty string for Step 1, or the secret name for Step 3)
$deployArgs += @('--parameters', "sslCertificateSecretName=$SslCertificateSecretName")

Write-Host "`n==========================================================" -ForegroundColor Cyan
if ([string]::IsNullOrWhiteSpace($SslCertificateSecretName)) {
    Write-Host " Initial Deployment (HTTP Listener & Cert Order)" -ForegroundColor Cyan
    Write-Host "==========================================================" -ForegroundColor Cyan
    Write-Host "Deploying Bicep template without SSL certificate..." -ForegroundColor Yellow
} else {
    Write-Host " Second Deployment (Binding SSL Cert to App Gateway)" -ForegroundColor Cyan
    Write-Host "==========================================================" -ForegroundColor Cyan
    Write-Host "Deploying Bicep template with Key Vault secret '$SslCertificateSecretName'..." -ForegroundColor Yellow
}

$deployResultJson = az @deployArgs --output json
if ($LASTEXITCODE -ne 0) {
    throw "Deployment failed."
}

Write-Host "`nDeployment completed successfully ($deploymentName)." -ForegroundColor Green

# Parse and display outputs
try {
    $deployResult = ($deployResultJson | Out-String) | ConvertFrom-Json
    $outputs = $deployResult.properties.outputs
    if ($outputs) {
        Write-Host "`n--- Deployment Outputs ---" -ForegroundColor Cyan
        if ($outputs.appGatewayName) {
            Write-Host "App Gateway Name          : $($outputs.appGatewayName.value)"
        }
        if ($outputs.storageAccountName) {
            Write-Host "Storage Account Name      : $($outputs.storageAccountName.value)"
        }
        if ($outputs.keyVaultName) {
            Write-Host "Key Vault Name            : $($outputs.keyVaultName.value)"
        }
        if ($outputs.domainVerificationToken -and -not [string]::IsNullOrWhiteSpace($outputs.domainVerificationToken.value)) {
            Write-Host "Domain Verification Token : $($outputs.domainVerificationToken.value)" -ForegroundColor Yellow
        }
        if ($outputs.webAppDefaultHostName) {
            Write-Host "Backend Web App Host      : $($outputs.webAppDefaultHostName.value)"
        }
        if ($outputs.ipAddress) {
            Write-Host "Ip Address                : $($outputs.ipAddress.value)"
        }
        Write-Host "--------------------------" -ForegroundColor Cyan
    }
} catch { }
