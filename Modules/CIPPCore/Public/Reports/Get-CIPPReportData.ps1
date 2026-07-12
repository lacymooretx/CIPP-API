function Get-CIPPReportData {
    <#
    .SYNOPSIS
        Dispatch to the correct report-data builder for a report type.
    .DESCRIPTION
        Central registry/dispatcher for the Aspendora / CIPP report suite. Maps a
        ReportType key to its Get-CIPP<Type>ReportData builder and returns the report
        model consumed by Write-CippReportHtml. Every report type therefore shares the
        same on-demand endpoint, scheduler command, renderer and branding.
    .FUNCTIONALITY
        Internal
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$TenantFilter,
        [Parameter(Mandatory = $true)]
        [string]$ReportType
    )

    switch ($ReportType) {
        'Security' { return Get-CIPPSecurityReportData -TenantFilter $TenantFilter }
        'Forwarding' { return Get-CIPPForwardingReportData -TenantFilter $TenantFilter }
        'Applications' { return Get-CIPPApplicationReportData -TenantFilter $TenantFilter }
        'IntuneCompliance' { return Get-CIPPIntuneComplianceReportData -TenantFilter $TenantFilter }
        'Licenses' { return Get-CIPPLicenseReportData -TenantFilter $TenantFilter }
        'AdminTracker' { return Get-CIPPAdminReportData -TenantFilter $TenantFilter }
        'DomainInfo' { return Get-CIPPDomainReportData -TenantFilter $TenantFilter }
        'AccessTracker' { return Get-CIPPAccessReportData -TenantFilter $TenantFilter }
        'Accounts' { return Get-CIPPAccountsReportData -TenantFilter $TenantFilter }
        'LoginTracker' { return Get-CIPPLoginReportData -TenantFilter $TenantFilter }
        'MailboxSize' { return Get-CIPPMailboxSizeReportData -TenantFilter $TenantFilter }
        'MailboxFolderPermissions' { return Get-CIPPMailboxFolderPermReportData -TenantFilter $TenantFilter }
        'SharePointUsage' { return Get-CIPPSharePointUsageReportData -TenantFilter $TenantFilter }
        'SharingTracker' { return Get-CIPPSharingReportData -TenantFilter $TenantFilter }
        'SitePermissions' { return Get-CIPPSitePermissionsReportData -TenantFilter $TenantFilter }
        'Copilot' { return Get-CIPPCopilotReportData -TenantFilter $TenantFilter }
        default { throw "Unknown report type '$ReportType'." }
    }
}
