[CmdletBinding()]
param(
)

$ErrorActionPreference = "Stop"

# This script generates a set of DRM parameters that can be used with the DASH-IF live source simulator, including:
# * The encryption keys and key IDs
# * The DRM system signaling data for DASH manifests
# * License tokens for use with Axinom DRM
# * The MPD signaling to use the license tokens in DASH manifests.

[Reflection.Assembly]::LoadFrom("./Axinom.Toolkit/Axinom.Toolkit.dll") | Out-Null
[Reflection.Assembly]::LoadFrom("./Axinom.Cpix/Axinom.Cpix.dll") | Out-Null

$keyCount = 10
$keyGenerator = [Security.Cryptography.RandomNumberGenerator]::Create()
$keys = @()

# Generate some random keys.
for ($i = 0; $i -lt $keyCount; $i++) {
    $key_id = New-Guid
    $key_value = [Byte[]]::new(16)
    $keyGenerator.GetBytes($key_value)

    # We supply both PlayReady and Widevine initialization data for each.
    # This is just a DRM-specific wrapper for the key ID, nothing more.
    # Encryption algorithm is assumed to be 'cenc' (AES-CTR without pattern)
    $playReadyInitializationDataAsBase64 = [Convert]::ToBase64String(
        [Axinom.Toolkit.NetStandardHelpers]::CreatePsshBox($null,
            [Axinom.Toolkit.PlayReadyConstants]::SystemId,
            [Axinom.Toolkit.NetStandardHelpers]::GenerateRightsManagementHeader($null, $key_id)))
    $widevineInitializationDataAsBase64 = [Convert]::ToBase64String(
        [Axinom.Toolkit.NetStandardHelpers]::CreatePsshBox($null,
            [Axinom.Toolkit.WidevineConstants]::SystemId,
            [Axinom.Toolkit.NetStandardHelpers]::GenerateWidevineCencHeader($null, $key_id)))

    $keys += @{
        key_id = $key_id
        key_id_hex = [Axinom.Toolkit.NetStandardHelpers]::ByteArrayToHexString($null,
            [Axinom.Toolkit.ExtensionsForGuid]::ToBigEndianByteArray($key_id))
        key_value = $key_value
        key_value_base64 = [Convert]::ToBase64String($key_value)
        key_value_hex = [Axinom.Toolkit.NetStandardHelpers]::ByteArrayToHexString($null, $key_value)

        playready_init_data_base64 = $playReadyInitializationDataAsBase64
        widevine_init_data_base64 = $widevineInitializationDataAsBase64
    }

    # The hexadecimal value might be useful for plugging into mp4encrypt.
    Write-Host "Key $($i + 1) has ID $key_id (GUID) or $($keys[$i].key_id_hex) (hex) and key value $($keys[$i].key_value_base64) (base64) or $($keys[$i].key_value_hex) (hex)"

    Write-Verbose ($keys[$i] | ConvertTo-Json)
}

Write-Host "Generated $keyCount keys."

# Anyone can use the Axinom DRM license tokens generated by this script to acquire testing licenses.
# To generate new Axinom DRM license tokens you need a communication key, available to Axinom customers only.
$communicationKeyId = Read-Host "What is your Axinom DRM communication key ID? (Optional, GUID format)"
$communicationKeyAsBase64 = Read-Host "What is your Axinom DRM communication key? (Optional, base64 string)"

if ($communicationKeyId -or $communicationKeyAsBase64) {
    if ($null -eq (Get-Command New-LicenseToken -ErrorAction Ignore)) {
        Write-Error "You must install the Axinom.Drm PowerShell module to generate license tokens. To install, execute 'Install-Module Axinom.Drm'"
    }

    $permissivePolicy = @{
        name = "Permissive"

        playready = @{
            # Here is an example for how to make the PlayReady DRM configuration maximally permissive.
            # This lets you play content on virtual machines and pre-production devices, for easy testing.
            min_device_security_level = 150
            play_enablers = @(
                "786627D8-C2A6-44BE-8F88-08AE255B01A7"
            )
        }
    }

    foreach ($key in $keys) {
        # We generate a unique license token for each key. This is not strictly required (we could generate
        # one for the entire set of keys) but is likely the more useful option for testing client behavior.
        $token = New-LicenseToken

        $token.content_key_usage_policies = @(
            $permissivePolicy
        )

        $token = $token | Add-ContentKey -KeyId $key.key_id -KeyAsBase64 $key.key_value_base64 -CommunicationKeyAsBase64 $communicationKeyAsBase64 -KeyUsagePolicyName $permissivePolicy.name

        # A token must be exported to structure it for use by DASH clients.
        $key.license_token = $token | Export-LicenseToken -CommunicationKeyId $communicationKeyId -CommunicationKeyAsBase64 $communicationKeyAsBase64

        Write-Verbose "License token for $($key.key_id) is $($key.license_token)"

        Set-Content -Path "$($key.key_id).token.txt" -Value $key.license_token
    }

    Write-Host "Generated license tokens for each key and exported each as <keyid>.token.txt."
} else {
    Write-Warning "Without a communication key, the license tokens cannot be generated. Without license tokens, clients will not be able to obtain licenses from the Axinom DRM license server. You may still be able to use the keys with a different license server."
}

$dashifNamespace = "https://dashif.org/"

# We export the data set as a CPIX document.
# Here, we also generate all the MPD XML to be added.
$cpix = New-Object Axinom.Cpix.CpixDocument

foreach ($key in $keys) {
    $cpixKey = New-Object Axinom.Cpix.ContentKey
    $cpixKey.Id = $key.key_id
    $cpixKey.Value = $key.key_value

    $cpix.ContentKeys.Add($cpixKey)

    $playReadySignaling = New-Object Axinom.Cpix.DrmSystem
    $playReadySignaling.SystemId = [Axinom.Toolkit.PlayReadyConstants]::SystemId
    $playReadySignaling.KeyId = $key.key_id
    $playReadySignaling.ContentProtectionData = @"
<pssh xmlns="urn:mpeg:cenc:2013">$($key.playready_init_data_base64)</pssh>
<laurl xmlns="$dashifNamespace">https://axinom-drm-bearer-token-proxy.azurewebsites.net/PlayReady/AcquireLicense</laurl>
<authzurl xmlns="$dashifNamespace">https://dashif-test-vectors-authz.azurewebsites.net/Authorize/ByPredefinedTokenId/$($key.key_id)</authzurl>
"@
    $cpix.DrmSystems.Add($playReadySignaling)

    $widevineSignaling = New-Object Axinom.Cpix.DrmSystem
    $widevineSignaling.SystemId = [Axinom.Toolkit.WidevineConstants]::SystemId
    $widevineSignaling.KeyId = $key.key_id
    $widevineSignaling.ContentProtectionData = @"
<pssh xmlns="urn:mpeg:cenc:2013">$($key.widevine_init_data_base64)</pssh>
<laurl xmlns="$dashifNamespace">https://axinom-drm-bearer-token-proxy.azurewebsites.net/Widevine/AcquireLicense</laurl>
<authzurl xmlns="$dashifNamespace">https://dashif-test-vectors-authz.azurewebsites.net/Authorize/ByPredefinedTokenId/$($key.key_id)</authzurl>
"@
    $cpix.DrmSystems.Add($widevineSignaling)

    Write-Verbose "DASH manifest PlayReady signaling for $($key.key_id) is $($playReadySignaling.ContentProtectionData)"
    Write-Verbose "DASH manifest Widevine signaling for $($key.key_id) is $($widevineSignaling.ContentProtectionData)"
}

$cpix.Save("DrmData.xml")

Write-Host "Exported generated data as CPIX to DrmData.xml"