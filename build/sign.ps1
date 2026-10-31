#Requires -Version 7.0
<#
  Signs one file in place with Authenticode. Called by build.ps1 -SignScript for puddock.exe,
  the installer and the uninstaller. Fails closed until it is wired to a signing service.

  TODO(release): pick one (see docs/PUBLISHING.md, section 5) and replace the throw below:
    - Azure Trusted Signing: Invoke-TrustedSigning / signtool with the Azure.CodeSigning dlib
    - SignPath (free for OSS): submit through their GitHub action instead of this script
    - A local certificate:   signtool sign /fd sha256 /tr <timestamp url> /td sha256 /sha1 <thumb> $Path
#>
param([Parameter(Mandatory)] [string] $Path)
$ErrorActionPreference = 'Stop'
throw "build/sign.ps1 is not configured yet - refusing to produce an unsigned 'signed' build ($Path)"
