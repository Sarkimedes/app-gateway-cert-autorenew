# TODO

- [x] Create new subdomain cert-test.peterwynroberts.com
- [x] Provision an app gateway
- [x] Set up app service cert
- [x] Set up web app (have it return a simple hello world)
- [ ] Attach our cert to the gateway
- [x] Have a static site which returns a HTML page

- [x] Add  	f3c21649-0979-4721-ac85-b0216b2cf413 service principal (well-known) as Key Vault Secrets Officer for site

- [x] Set up a managed identity with Key Vault Secrets User rights
- [x] Assign it to the gateway
- [x] Set up HTML web page validation as below:

# HTML web page domain validation:


IMPORTANT UPDATE: Starting 11/30/2021, your new/renewed/rekeyed certificate will NOT be issued with the additional 'www' domain when using App Service verification. However, if you validate your certificate with DNS manual verification (refer to Manual verification), your certificate will still be issued with the extra 'www' domain. Learn More

NOTE: If you have any SSL binding in your web apps for 'www' domains using App Service Certificates, your SSL bindings will not be able to use the renewed App Service Certificate and will continue to use the old certificate, which may cause downtime to your web app when the old certificate expires. Due to this change, we recommend to follow the steps for the DNS manual verification from Manual verification to avoid any issues.

    Create an HTML file named : godaddy.html.

    Content of this file should be just the value of Domain Verification Token : f29pje21sk9kqh7o2ah6svqil3

    Make the html file available to the public internet from your site under the url : http://cert-test.peterwynroberts.com/.well-known/pki-validation/godaddy.html

    Validate the file is accessible by browsing to: http://cert-test.peterwynroberts.com/.well-known/pki-validation/godaddy.html. The response should be a text file containing the your domain verification f29pje21sk9kqh7o2ah6svqil3

    Click on Refresh button to check the Certificate status. Certificate verification can take a few minutes to complete.

    This domain should be a static site listening at this address - provision a static site with that address on it

    certorders can come from Bicep: 

    https://github.com/brwilkinson/AzureDeploymentFramework/blob/main/ADF/bicep/AppServiceCert-Request.bicep
    https://github.com/brwilkinson/AzureDeploymentFramework/blob/main/ADF/bicep/AppServiceCert.bicep


Taken from: 
  https://github.com/Azure/bicep/discussions/6005