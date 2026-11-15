targetScope = 'resourceGroup'

// ============================================================================
// Parameters
// ============================================================================

@description('Project name used as a prefix/suffix for all deployed resources.')
@minLength(3)
@maxLength(22)
param projectName string = 'agwcert'

@description('Location for all regional resources.')
param location string = resourceGroup().location

@description('Name of the storage account used for static website hosting (must be globally unique, 3-24 lowercase alphanumeric).')
@minLength(3)
@maxLength(24)
param storageAccountName string = 'st${projectName}'

@description('Custom domain name for the certificate order and validation.')
param customDomainName string = 'cert-test.peterwynroberts.com'

@description('Object ID of the Microsoft.Azure.WebSites App Service Certificate SPN (appId f3c21649-0979-4721-ac85-b0216b2cf413) in your tenant.')
param certManagementSpnObjectId string = 'ea9f3de1-5e71-48f6-8f96-f3312841e295'

@description('Name of the certificate secret in Key Vault to bind to the HTTPS listener on Application Gateway. Leave empty initially if the certificate has not yet been issued.')
param sslCertificateSecretName string = ''

@description('Optional explicit FQDN for the static website. Defaults to the storage account web endpoint pattern.')
param staticSiteFqdn string = ''

// ============================================================================
// Variables
// ============================================================================

var resolvedStaticSiteFqdn = !empty(staticSiteFqdn) ? staticSiteFqdn : '${storageAccountName}.z33.web.${environment().suffixes.storage}'
var keyVaultSecretsOfficerRoleId = roleDefinitions('Key Vault Secrets Officer').id
var keyVaultSecretsUserRoleId = roleDefinitions('Key Vault Secrets User').id
var certificateOrderName = 'cert${projectName}'
var hasSslCert = !empty(sslCertificateSecretName)

// ============================================================================
// Resources
// ============================================================================

// Virtual Network: Subnet for Application Gateway
resource virtualNetwork 'Microsoft.Network/virtualNetworks@2024-05-01' = {
  name: 'vnet-${projectName}'
  location: location
  properties: {
    addressSpace: {
      addressPrefixes: [
        '10.0.0.0/16'
      ]
    }
  }
}

resource agwSubnet 'Microsoft.Network/virtualNetworks/subnets@2024-05-01' = {
  parent: virtualNetwork
  name: 'agw-internal'
  properties: {
    addressPrefix: '10.0.0.0/24'
  }
}

// Website (Backend Web App)
resource appServicePlan 'Microsoft.Web/serverfarms@2024-04-01' = {
  name: 'asp-${projectName}'
  location: location
  sku: {
    name: 'F1'
  }
  kind: 'linux'
  properties: {
    reserved: true
  }
}

module site 'br/public:avm/res/web/site:0.24.0' = {
  name: 'siteDeployment'
  params: {
    kind: 'app,linux,container'
    name: 'app-${projectName}'
    serverFarmResourceId: appServicePlan.id
    siteConfig: {
      appSettings: [
        {
          name: 'WEBSITES_ENABLE_APP_SERVICE_STORAGE'
          value: 'false'
        }
      ]
      ftpsState: 'FtpsOnly'
      linuxFxVersion: 'DOCKER|mcr.microsoft.com/appsvc/staticsite:latest'
      minTlsVersion: '1.2'
    }
  }
}

// Key Vault
resource keyVault 'Microsoft.KeyVault/vaults@2023-07-01' = {
  name: 'kv-${projectName}'
  location: location
  properties: {
    sku: {
      family: 'A'
      name: 'standard'
    }
    tenantId: subscription().tenantId
    enableRbacAuthorization: true
  }
}

// Allow cert registration permission to use Key Vault
resource certRegistrationRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(resourceGroup().id, certManagementSpnObjectId, keyVaultSecretsOfficerRoleId)
  properties: {
    principalId: certManagementSpnObjectId
    roleDefinitionId: keyVaultSecretsOfficerRoleId
    principalType: 'ServicePrincipal'
  }
  scope: keyVault
}

// User-Assigned Managed Identity for Application Gateway
resource managedIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: 'id-${projectName}'
  location: location
}

// Grant the Managed Identity permissions to read secrets from Key Vault
resource agwManagedIdentityRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(resourceGroup().id, managedIdentity.id, keyVaultSecretsUserRoleId)
  properties: {
    principalId: managedIdentity.properties.principalId
    roleDefinitionId: keyVaultSecretsUserRoleId
    principalType: 'ServicePrincipal'
  }
  scope: keyVault
}

// Public IP for Application Gateway
resource publicIP 'Microsoft.Network/publicIPAddresses@2024-05-01' = {
  name: 'pip-agw-${projectName}'
  location: location
  zones: [
    '1'
    '2'
    '3'
  ]
  sku: {
    name: 'Standard'
  }
  properties: {
    publicIPAllocationMethod: 'Static'
  }
}

// App Service Certificate Order & Key Vault Binding
resource certificateOrder 'Microsoft.CertificateRegistration/certificateOrders@2022-09-01' = {
  name: certificateOrderName
  location: 'global'
  properties: {
    distinguishedName: 'CN=${customDomainName}'
    autoRenew: true
    productType: 'StandardDomainValidatedSsl'
    validityInYears: 1
    keySize: 2048
  }
  dependsOn: [
    certRegistrationRoleAssignment
  ]
}

resource certificateOrderCert 'Microsoft.CertificateRegistration/certificateOrders/certificates@2022-09-01' = {
  parent: certificateOrder
  name: certificateOrderName
  location: 'global'
  properties: {
    keyVaultId: keyVault.id
    keyVaultSecretName: certificateOrderName
  }
  dependsOn: [
    certRegistrationRoleAssignment
  ]
}

// PKI Static Site Storage Account
module storageSite 'modules/pki-static-site.bicep' = {
  name: 'storageSiteDeployment'
  params: {
    location: location
    accountName: storageAccountName
    skuName: 'Standard_LRS'
    verificationToken: certificateOrder.properties.domainVerificationToken
  }
}

// Application Gateway
resource appGateway 'Microsoft.Network/applicationGateways@2024-05-01' = {
  name: 'agw-${projectName}'
  location: location
  zones: [
    '1'
    '2'
    '3'
  ]
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${managedIdentity.id}': {}
    }
  }
  properties: {
    sku: {
      name: 'Basic'
      tier: 'Basic'
      capacity: 2
    }
    enableHttp2: true
    gatewayIPConfigurations: [
      {
        name: 'appGatewayIpConfig'
        properties: {
          subnet: {
            id: agwSubnet.id
          }
        }
      }
    ]
    frontendIPConfigurations: [
      {
        name: 'appGwPublicFrontendIpIPv4'
        properties: {
          publicIPAddress: {
            id: publicIP.id
          }
        }
      }
    ]
    frontendPorts: concat([
      {
        name: 'port_80'
        properties: {
          port: 80
        }
      }
    ], hasSslCert ? [
      {
        name: 'port_443'
        properties: {
          port: 443
        }
      }
    ] : [])
    sslCertificates: hasSslCert ? [
      {
        name: 'app-service-cert'
        properties: {
          keyVaultSecretId: '${keyVault.properties.vaultUri}secrets/${sslCertificateSecretName}'
        }
      }
    ] : []
    probes: [
      {
        name: 'cert-probe'
        properties: {
          protocol: 'Https'
          path: '/.well-known/pki-validation/godaddy.html'
          interval: 30
          timeout: 30
          unhealthyThreshold: 3
          pickHostNameFromBackendHttpSettings: true
          match: {
            statusCodes: [
              '200-399'
            ]
          }
        }
      }
    ]
    backendAddressPools: [
      {
        name: 'static-site'
        properties: {
          backendAddresses: [
            {
              fqdn: resolvedStaticSiteFqdn
            }
          ]
        }
      }
      {
        name: 'web-app'
        properties: {
          backendAddresses: [
            {
              fqdn: site.outputs.defaultHostname
            }
          ]
        }
      }
    ]
    backendHttpSettingsCollection: [
      {
        name: 'web-app-settings'
        properties: {
          port: 443
          protocol: 'Https'
          cookieBasedAffinity: 'Disabled'
          pickHostNameFromBackendAddress: true
          requestTimeout: 20
        }
      }
      {
        name: 'cert-check-settings'
        properties: {
          port: 443
          protocol: 'Https'
          cookieBasedAffinity: 'Disabled'
          pickHostNameFromBackendAddress: true
          requestTimeout: 20
          probe: {
            id: resourceId('Microsoft.Network/applicationGateways/probes', 'agw-${projectName}', 'cert-probe')
          }
        }
      }
    ]
    httpListeners: concat([
      {
        name: 'http-basic'
        properties: {
          frontendIPConfiguration: {
            id: resourceId('Microsoft.Network/applicationGateways/frontendIPConfigurations', 'agw-${projectName}', 'appGwPublicFrontendIpIPv4')
          }
          frontendPort: {
            id: resourceId('Microsoft.Network/applicationGateways/frontendPorts', 'agw-${projectName}', 'port_80')
          }
          protocol: 'Http'
          requireServerNameIndication: false
        }
      }
    ], hasSslCert ? [
      {
        name: 'https-basic'
        properties: {
          frontendIPConfiguration: {
            id: resourceId('Microsoft.Network/applicationGateways/frontendIPConfigurations', 'agw-${projectName}', 'appGwPublicFrontendIpIPv4')
          }
          frontendPort: {
            id: resourceId('Microsoft.Network/applicationGateways/frontendPorts', 'agw-${projectName}', 'port_443')
          }
          protocol: 'Https'
          requireServerNameIndication: false
          sslCertificate: {
            id: resourceId('Microsoft.Network/applicationGateways/sslCertificates', 'agw-${projectName}', 'app-service-cert')
          }
        }
      }
    ] : [])
    urlPathMaps: [
      {
        name: 'http-default'
        properties: {
          defaultBackendAddressPool: {
            id: resourceId('Microsoft.Network/applicationGateways/backendAddressPools', 'agw-${projectName}', 'web-app')
          }
          defaultBackendHttpSettings: {
            id: resourceId('Microsoft.Network/applicationGateways/backendHttpSettingsCollection', 'agw-${projectName}', 'web-app-settings')
          }
          pathRules: [
            {
              name: 'pki-check'
              properties: {
                paths: [
                  '/.well-known/pki-validation/godaddy.html'
                ]
                backendAddressPool: {
                  id: resourceId('Microsoft.Network/applicationGateways/backendAddressPools', 'agw-${projectName}', 'static-site')
                }
                backendHttpSettings: {
                  id: resourceId('Microsoft.Network/applicationGateways/backendHttpSettingsCollection', 'agw-${projectName}', 'cert-check-settings')
                }
              }
            }
          ]
        }
      }
    ]
    requestRoutingRules: concat([
      {
        name: 'http-default'
        properties: {
          ruleType: 'PathBasedRouting'
          priority: 100
          httpListener: {
            id: resourceId('Microsoft.Network/applicationGateways/httpListeners', 'agw-${projectName}', 'http-basic')
          }
          urlPathMap: {
            id: resourceId('Microsoft.Network/applicationGateways/urlPathMaps', 'agw-${projectName}', 'http-default')
          }
        }
      }
    ], hasSslCert ? [
      {
        name: 'https-default'
        properties: {
          ruleType: 'Basic'
          priority: 101
          httpListener: {
            id: resourceId('Microsoft.Network/applicationGateways/httpListeners', 'agw-${projectName}', 'https-basic')
          }
          backendAddressPool: {
            id: resourceId('Microsoft.Network/applicationGateways/backendAddressPools', 'agw-${projectName}', 'web-app')
          }
          backendHttpSettings: {
            id: resourceId('Microsoft.Network/applicationGateways/backendHttpSettingsCollection', 'agw-${projectName}', 'web-app-settings')
          }
        }
      }
    ] : [])
  }
  dependsOn: [
    agwManagedIdentityRoleAssignment
    storageSite
  ]
}

// ============================================================================
// Outputs
// ============================================================================

output appGatewayName string = appGateway.name
output webAppDefaultHostName string = site.outputs.defaultHostname
output storageAccountName string = storageSite.outputs.storageAccountName
output keyVaultName string = keyVault.name
output managedIdentityPrincipalId string = managedIdentity.properties.principalId
output domainVerificationToken string = certificateOrder.properties.domainVerificationToken
output keyVaultSecretName string = certificateOrderName
output ipAddress string = publicIP.properties.ipAddress
