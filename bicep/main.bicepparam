using 'main.bicep'

param projectName = 'agwcert2'
param customDomainName = 'cert-test2.peterwynroberts.com'
param certManagementSpnObjectId = 'ea9f3de1-5e71-48f6-8f96-f3312841e295'

// Leave empty on initial deployment before the certificate is validated and issued.
// Once issued, set to the secret name created in Key Vault (e.g., 'certagwcert<guid>').
param sslCertificateSecretName = ''
