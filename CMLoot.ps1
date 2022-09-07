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
    
    # Print help if no commands
    if($PSBoundParameters.Count -eq 0) {
        Get-Help $MyInvocation.MyCommand -Detailed
        return
    }

    # Add .INI to Exclusions
    if ($ExcludeExtension) {
        $ExcludeList = @()
        foreach($item in $ExcludeExtension.Split(",")) {
            $ExcludeList += $item + ".INI"
        }
    }
    
    $OutfileNoAccess = $OutFile.Split(".")[0] + "_noaccess." + $OutFile.Split(".")[1]

    # Check if OutFile exists.
    if (Test-Path -Path $OutFile -PathType Leaf) {
        Write-Output "[*] OutFile exists."
        Remove-Item -Path $OutFile -Confirm
    }

    if (Test-Path -Path $OutfileNoAccess -PathType Leaf) {
        Write-Output "[*] OutFile exists."
        Remove-Item -Path $OutfileNoAccess -Confirm
    }

    # Grab all shares on host and fetch all .ini-files SCCMContentLib\DataLib share
    (net view $SCCMHost /all) | % {
        if($_.IndexOf(' Disk ') -gt 0){
            $share = $_.Split('      ')[0]

            if ($share -match 'SCCMContentLib') {

                # Folder fetching
                $folders = Get-ChildItem -Path ('\\' + $SCCMHost + '\' + $share + '\DataLib\') -Directory -ErrorAction SilentlyContinue
                For($i = 0; $i -lt $folders.count; $i++) {
                    
                    # Update progress bar for current folder
                    Write-Progress -Activity "Scanning files." -CurrentOperation ('Collecting INI Files in: '+ $folders[$i].FullName) -PercentComplete (($i+1) / $folders.count * 100) -Status ("Folder {0} of {1}" -f ($i + 1), $folders.count)
                
                    # INI file fetching
                    Get-ChildItem -Path $folders[$i].FullName -File -Recurse -Exclude $ExludeList -Include *.INI -ErrorAction SilentlyContinue -ErrorVariable +fileErr |
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

            # Check errors if access is denied = interesting file
            foreach($ex in $fileErr)
                {
                    if ($ex.Exception -is [System.UnauthorizedAccessException]) 
                        {
                            Write-Output ("[*] Access to {0} is denied, adding to {1}" -f $ex.TargetObject, $OutfileNoAccess) ""
                            $ex.TargetObject.Split("\")[-1] | Add-Content -Path $OutfileNoAccess
                            
                        }
                }
            # Write help text
            if (Test-Path -Path $OutFile -PathType Leaf)
                {
                    Write-Output ("[*] Inventory created. Use Invoke-CMLootDownload -InventoryFile {0} to download files. See Get-Help Invoke-CMLootDownload for options." -f $Outfile) "" 
                }
            if (Test-Path -Path $OutfileNoAccess -PathType Leaf)
                {
                    Write-Output ("[*] Inaccessible DataLib content detected. Use Invoke-CMLootHunt -SCCMHost {0} -NoAccessFile {1} to search for correlating files." -f $SCCMHost, $OutfileNoAccess) ""
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
WARNING: Opening large inventory file might exhaust RAM.


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
    
    # Print help if no commands
    if($PSBoundParameters.Count -eq 0) {
        Get-Help $MyInvocation.MyCommand -Detailed
        return
    }
    
    # Lookup file location, format FileLib\<first 4 chars of hash\<full file hash>
    function getfilelocation([string] $file) {
        $hash = (Get-Content $file".INI" | Select-String "hash") -split("=")
        $location = $file -split "DataLib"
        return $location[0] + "FileLib\" + $hash[1].Substring(0,4) + "\" + $hash[1]

    }

    function downloadfile($File) {
        # Output stucture <folder: ext>\<first 4 chars of hash>_<original filename>
        $subfolder = $OutFolder + "\" + $File.Split(".")[-1]
        
        if (-not (Test-Path -Path $subfolder -PathType Container))
            {
                New-Item $subfolder -ItemType Directory -ErrorAction Ignore| Out-Null
            }

        $FileSource = getfilelocation($File)
        $DestFile = $subfolder + "\" + $FileSource.Split("\")[-1].Substring(0,4) + "_" + $File.Split("\")[-1]
        
        if (-not (Test-Path -Path $DestFile -PathType Leaf))
            {
                Write-Output ("Downloading {0}" -f $File)
                Copy-Item $FileSource -Destination $DestFile
            } else {
                Write-Output ("Already downloaded, skipping {0}" -f $File)
            }
    }

    # Create output base dir
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


function Invoke-CMLootHunt {
    <#
    
    .SYNOPSIS
    
    Locate the actual files for which the DataLib content is denied.
    
    Author: Tomas Rzepka (@1njected) / WithSecure
    
    
    .EXAMPLE 
    
    Invoke-CMLootHunt -SCCMHost sccm01.domain.local -NoAccessFile sccmfiles.txt.noaccess
    
    Try to match ACL denies from inventory and try to locate the actual file.
    
    #>
        [CmdletBinding()]
        param(
            [Parameter(Mandatory=$true)] [string]$SCCMHost,
            [Parameter(Mandatory=$true)] [string]$NoAccessFile,
            [Parameter(Mandatory=$false)] [string]$OutFolder = "CMLootOut"
        )
        
    # Print help if no commands
    if($PSBoundParameters.Count -eq 0) {
        Get-Help $MyInvocation.MyCommand -Detailed
        return
    }

    # Create output base dir
    New-Item $OutFolder -ItemType Directory -ErrorAction Ignore| Out-Null
    
    # Build array of lines in file
    foreach($line in Get-Content $NoAccessFile) { $ACLSearch += $line }

    # Find SCCMContentLib share on SCCM host, check all .INI files in FileLib and match content.
    (net view $SCCMHost /all) | % {
        if($_.IndexOf(' Disk ') -gt 0){
            $share = $_.Split('      ')[0]

            if ($share -match 'SCCMContentLib') {

                # Folder fetching
                $folders = Get-ChildItem -Path ('\\' + $SCCMHost + '\' + $share + '\FileLib\') -Directory -ErrorAction SilentlyContinue
                For($i = 0; $i -lt $folders.count; $i++) {
                    
                    # Update progress bar for current folder
                    Write-Progress -Activity "Scanning files." -CurrentOperation ('Collecting INI Files in: '+ $folders[$i].FullName) -PercentComplete (($i+1) / $folders.count * 100) -Status ("Folder {0} of {1}" -f ($i + 1), $folders.count)
                
                    # INI file fetching
                    Get-ChildItem -Path $folders[$i].FullName -File -Recurse -Exclude $ExludeList -Include *.INI -ErrorAction SilentlyContinue -ErrorVariable +fileErr |
                        ForEach-Object -Process {
                            if ($_.PSIsContainer) {
                                    continue
                                }
                            # Extract reference to DataLib
                            $content = (Get-Content -Path $_.FullName | Select -Skip 1) -split "="

                            # Match NoAccess against content
                            if ($ACLSearch.contains($content[0])) 
                                {
                                    $sourcefile =  $_.DirectoryName + "\" + $_.FullName.Split("\")[-1].Split(".")[0]

                                    Write-Output ("[*] File {0} match {1}. Copying to outfolder." -f $sourcefile, $content[0]) ""
                                    Copy-Item $sourcefile -Destination $OutFolder
                                }
                        }
                }
            }
        }
    }
}

function Invoke-CMLootExtract {
    <#
    
    .SYNOPSIS
    
    Extract file(s). For now, just .MSI files.
    
    Author: Tomas Rzepka (@1njected) / WithSecure
    
    
    .EXAMPLE 
    
    Invoke-CMLootExtract -Path C:\Temp\CMLootOut\msi
    
    Extract MSI files, create a folder in same directory where the extracted files are located.
    
    #>
        [CmdletBinding()]
        param(
            [Parameter(Mandatory=$true)] [string]$Path
        )
        
    # Print help if no commands
    if($PSBoundParameters.Count -eq 0) {
        Get-Help $MyInvocation.MyCommand -Detailed
        return
    }

    # Look for files without extension (files with hash as filename) and try to extract
    Get-ChildItem -Path $Path -File -Filter "*." |
        ForEach-Object -Process {
            Write-Output ("Processing {0}..." -f $_.FullName)
            $targetdir = $_.DirectoryName + "\_" + $_.BaseName
            Start-Process "msiexec" -ArgumentList "/a $($_.FullName) /qb TARGETDIR=$targetdir" -Wait
        }
    
    # Look for .msi extension and try to extract
    Get-ChildItem -Path $Path -File -Filter "*.msi" |
        ForEach-Object -Process {
            Write-Output ("Processing {0}..." -f $_.FullName)
            $targetdir = $_.DirectoryName + "\_" + $_.BaseName
            Start-Process "msiexec" -ArgumentList "/a $($_.FullName) /qb TARGETDIR=$targetdir" -Wait
    }
}