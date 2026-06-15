function Get-CIPPSamCertificate {
    <#
    .FUNCTIONALITY
        Internal
    .DESCRIPTION
        Loads the CIPP-SAM application certificate (an X509Certificate2 with private key) used to
        authenticate the application with a signed JWT assertion (client_assertion) instead of a
        client secret. This makes CIPP's app-only / client_credentials path phishing-resistant and
        certificate-based.

        Source of the cert (first match wins), stored as a base64-encoded PFX:
          - Production: Key Vault secret 'ApplicationCertificate' (vault = first segment of WEBSITE_DEPLOYMENT_ID)
          - Development: DevSecrets table column 'ApplicationCertificate'
          - Either environment: env var 'ApplicationCertificate' (base64 PFX) as an override
        Optional env var 'ApplicationCertificatePassword' (PFX password).

        SAFETY: this function NEVER throws. If no certificate is configured or anything goes wrong,
        it returns $null and the caller falls back to the existing client-secret auth. That keeps
        the certificate rollout strictly additive — existing deployments are unaffected until a
        certificate is actually provisioned.
    #>
    [CmdletBinding()]
    param()

    try {
        # In-process cache: parse the PFX once per worker.
        if ($script:CIPPSamCertificate -is [System.Security.Cryptography.X509Certificates.X509Certificate2]) {
            return $script:CIPPSamCertificate
        }
        # Negative cache: if we already determined no certificate is configured, don't hit Key Vault
        # again on every token refresh. Get-GraphToken is a hot path.
        if ($script:CIPPSamCertificateChecked -eq $true) {
            return $null
        }
        $script:CIPPSamCertificateChecked = $true

        $Base64Pfx = $env:ApplicationCertificate
        if ([string]::IsNullOrWhiteSpace($Base64Pfx)) {
            if ($env:AzureWebJobsStorage -eq 'UseDevelopmentStorage=true' -or $env:NonLocalHostAzurite -eq 'true') {
                $Table = Get-CIPPTable -tablename 'DevSecrets'
                $Secret = Get-AzDataTableEntity @Table -Filter "PartitionKey eq 'Secret' and RowKey eq 'Secret'" -ErrorAction SilentlyContinue
                if ($Secret -and $Secret.ApplicationCertificate) { $Base64Pfx = $Secret.ApplicationCertificate }
            } elseif ($env:WEBSITE_DEPLOYMENT_ID) {
                $VaultName = ($env:WEBSITE_DEPLOYMENT_ID -split '-')[0]
                $Base64Pfx = Get-CippKeyVaultSecret -VaultName $VaultName -Name 'ApplicationCertificate' -AsPlainText -ErrorAction SilentlyContinue
            }
        }

        if ([string]::IsNullOrWhiteSpace($Base64Pfx)) {
            return $null
        }

        $PfxBytes = [System.Convert]::FromBase64String($Base64Pfx)
        $Password = if ([string]::IsNullOrWhiteSpace($env:ApplicationCertificatePassword)) {
            $null
        } else {
            ConvertTo-SecureString -String $env:ApplicationCertificatePassword -AsPlainText -Force
        }

        # EphemeralKeySet keeps the private key in memory only (no disk persistence on the Function host).
        $Flags = [System.Security.Cryptography.X509Certificates.X509KeyStorageFlags]::EphemeralKeySet
        $Cert = if ($null -eq $Password) {
            [System.Security.Cryptography.X509Certificates.X509Certificate2]::new($PfxBytes, '', $Flags)
        } else {
            [System.Security.Cryptography.X509Certificates.X509Certificate2]::new($PfxBytes, $Password, $Flags)
        }

        if (-not $Cert.HasPrivateKey) {
            Write-Host 'Get-CIPPSamCertificate: configured certificate has no private key; falling back to secret.'
            return $null
        }

        $script:CIPPSamCertificate = $Cert
        return $Cert
    } catch {
        Write-Host "Get-CIPPSamCertificate: could not load SAM certificate, falling back to secret. $($_.Exception.Message)"
        return $null
    }
}
