function Invoke-CMLootInventory {
<#

.SYNOPSIS

Perform inventory of files available on SCCM SMB share.

Author: Tomas Rzepka (@1njected) / WithSecure


.EXAMPLE 

Invoke-CMLootInventory -SCCMHost sccm01.domain.local -OutFile sccmfiles.txt

Enumerates files available on SCCM share and saves it to a file.


.EXAMPLE 

Invoke-CMLootInventory -SCCMHost sccm01.domain.local -OutFile sccmfiles.txt -ExcludeExtension "dll,exe"

Enumerates files available on SCCM share and saves it to a file, excludes extensions dll and exe.

#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)] [string]$SCCMHost,
        [Parameter(Mandatory=$true)] [string]$OutFile,
        [Parameter(Mandatory=$false)][string]$ExcludeExtension

    )
    
    # Add .INI to Exclusions
    if ($ExcludeExtension) {
        $ExcludeList = @()
        foreach($item in $ExcludeExtension.Split(",")) {
            $ExcludeList += $item + ".INI"
        }
    }
    
    # Grab all shares on host and fetch all .ini-files SCCMContentLib\DataLib share
    (net view $SCCMHost /all) | % {
        if($_.IndexOf(' Disk ') -gt 0){
            $share = $_.Split('      ')[0]

            if ($share -match 'SCCMContentLib') {

                # Folder fetching
                $folders = Get-ChildItem -Path ('\\' + $SCCMHost + '\' + $share + '\DataLib\') -Directory -ErrorAction SilentlyContinue
                $files = For($i = 0; $i -lt $folders.count; $i++) {
                    # Update progress bar for current folder
                    Write-Progress -Activity "Scanning files." -CurrentOperation ('Collecting INI Files in: '+ $folders[$i].FullName) -PercentComplete (($i+1) / $folders.count * 100) -Status ("Folder {0} of {1}" -f ($i + 1), $folders.count)
                
                    # INI file fetching
                    Get-ChildItem -Path $folders[$i].FullName -File -Recurse -Exclude $ExludeList -Include *.INI |
                        ForEach-Object -Process {
                        if ($_.PSIsContainer) {
                            continue
                        }
                        if ($ExcludeList) {
                            if (($_ -notmatch ($ExcludeList -join '|'))) {
                                $_.FullName.Substring(0, $_.FullName.Length-4) | Add-Content -Path $OutFile
                            }
                        } else {
                            $_.FullName.Substring(0, $_.FullName.Length-4) | Add-Content -Path $OutFile
                        }
                    }
                }
            }
        }
    }
}


function Invoke-CMLootDownload {
<#

.SYNOPSIS

Downloads files from SCCM SMB shares.
File download defaults to CMLootOut in current directory.

Author: Tomas Rzepka (@1njected) / WithSecure


.EXAMPLE 

Invoke-CMLootDownload -OutFolder CMLootOut -InventoryFile .\sccmfiles.txt -GridSelect

Opens previously collected inventory file and opens GridView to select files to download.


.EXAMPLE 

Invoke-CMLootDownload -OutFolder CMLootOut -SingleFile \\sccm\SCCMContentLib$\DataLib\SC100001.1\x86\MigApp.xml

Downloads a single file.


.EXAMPLE 

Invoke-CMLootDownload -OutFolder CMLootOut -InventoryFile .\sccmfiles.txt -Extension ps1

Opens previously collected inventory file and downloads all files with .ps1 extentension.

#>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$false)] [string]$OutFolder = "CMLootOut",
        [Parameter(Mandatory=$false)] [string]$InventoryFile,
        [Parameter(Mandatory=$false)] [string]$SingleFile,
        [Parameter(Mandatory=$false)] [string]$Extension,
        [Parameter(Mandatory=$false)] [switch]$GridSelect
    )
    
    
    # Lookup file location, format FileLib\<first 4 chars of hash\<full file hash>
    function getfilelocation([string] $file) {
        $hash = (Get-Content $file".INI" | Select-String "hash") -split("=")
        $location = $file -split "DataLib"
        return $location[0] + "FileLib\" + $hash[1].Substring(0,4) + "\" + $hash[1]

    }

    
    function downloadfile($File) {
        $FileSource = getfilelocation($File)
        $DestFile = $OutFolder + "\" + $FileSource.Split("\")[$_.Lenght-1] + "_" + $File.Split("\")[$_.Lenght-1]
        Copy-Item $FileSource -Destination $DestFile

    }

    
    # Create output dir
    New-Item $OutFolder -ItemType Directory -ErrorAction Ignore| Out-Null
    
    # Perform action depending on user parameters
    # Single file
    If ($SingleFile) { downloadfile($SingleFile) }

    # GridView
    ElseIf ($GridSelect) {
        $files = Get-Content -Path $InventoryFile | Out-GridView -PassThru
        foreach($item in $files) {
            downloadfile($item)
        }
    } 
    
    # Download all extensions
    ElseIf ($Extension) {
        Get-Content -Path $InventoryFile | Select-String -Pattern $Extension$ | ForEach-Object { $files += @($_.ToString()) }
        foreach ($item in $files) { downloadfile($item) }
    }
}
