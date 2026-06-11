<#
.SYNOPSIS
    Scripts to build a trimmed-down Windows 11 image.

.DESCRIPTION
    This is a script created to automate the build of a streamlined Windows 11 image, similar to tiny10.
    My main goal is to use only Microsoft utilities like DISM, and no utilities from external sources.
    The only executable included is oscdimg.exe, which is provided in the Windows ADK and it is used to create bootable ISO images.

.PARAMETER ISO
    Drive letter of the mounted Windows 11 ISO (e.g. E), or omit to be prompted for an ISO path or drive letter.

.PARAMETER SCRATCH
    Drive letter of the desired scratch disk (eg: D)
    NOTE: The SCRATCH drive must support file/folder security (i.e., must be, e.g., NTFS filesystem).

.PARAMETER Custom
    Enable interactive selection of which apps to remove. Without this flag, all packages listed in
    removePackage.txt are removed (default behaviour).

.EXAMPLE
    .\tiny11maker.ps1
    .\tiny11maker.ps1 E D
    .\tiny11maker.ps1 -ISO E -SCRATCH D
    .\tiny11maker.ps1 -SCRATCH D -ISO E
    .\tiny11maker.ps1 -ISO E -SCRATCH D -Custom

    *If you use ordinal parameters the first one must be the mounted iso. The second is the scratch drive.
    prefer the use of full named parameter (eg: "-ISO") as you can put in the order you want.

.NOTES
    Auteur: ntdevlabs
    Date: 11-06-26
#>

#---------[ Parameters ]---------#
param (
    [Parameter(Position = 0)]
    [string]$ISO,
    [Parameter(Position = 1)]
    [ValidatePattern('^[c-zC-Z]$')][string]$SCRATCH,
    [switch]$Custom
)

$ErrorActionPreference = 'Stop'
$WarningPreference = 'Continue'
$InformationPreference = 'Continue'

if ($ISO) {
    $ISO = $ISO.Trim().Trim('"').TrimEnd(':')
}
if ($SCRATCH) {
    $SCRATCH = $SCRATCH.Trim().TrimEnd(':')
}

if (-not $SCRATCH) {
    $ScratchDisk = $PSScriptRoot -replace '[\\]+$', ''
} else {
    $ScratchDisk = $SCRATCH + ":"
}

if ($ISO -and $SCRATCH -and ($ISO -match '^[c-zC-Z]$') -and ($ISO.ToUpperInvariant() -eq $SCRATCH.ToUpperInvariant())) {
    throw "ISO source drive and SCRATCH drive must be different."
}

#---------[ Functions ]---------#
$Script:SpecialPackageEntries = @('OneDrive')

function Get-AdkArchitecture {
    param([string]$HostArchitecture)
    switch ($HostArchitecture) {
        'AMD64' { return 'amd64' }
        'ARM64' { return 'arm64' }
        default { return $HostArchitecture.ToLowerInvariant() }
    }
}

function Assert-CommandExitCode {
    param(
        [string]$Label,
        [int[]]$AllowedExitCodes = @(0)
    )
    if ($AllowedExitCodes -notcontains $LASTEXITCODE) {
        throw "$Label failed with exit code $LASTEXITCODE"
    }
}

function Invoke-DismChecked {
    param(
        [string]$Label,
        [Parameter(ValueFromRemainingArguments = $true)]
        [string[]]$DismArgs
    )
    & dism @DismArgs
    Assert-CommandExitCode -Label $Label
}

function Format-ProcessArgument {
    param([string]$Argument)
    if ($Argument -match '\s') {
        return '"' + $Argument.Replace('"', '""') + '"'
    }
    return $Argument
}

function Build-ProcessArgumentString {
    param([string[]]$Arguments)
    return ($Arguments | ForEach-Object { Format-ProcessArgument $_ }) -join ' '
}

$script:LoadedRegHives = [System.Collections.Generic.List[string]]::new()

function Invoke-RegLoad {
    param(
        [string]$HiveName,
        [string]$FilePath
    )
    reg load "HKLM\$HiveName" $FilePath
    Assert-CommandExitCode -Label "reg load HKLM\$HiveName"
    if (-not $script:LoadedRegHives.Contains($HiveName)) {
        $script:LoadedRegHives.Add($HiveName)
    }
}

function Invoke-RegUnload {
    param([string]$HiveName)
    reg unload "HKLM\$HiveName"
    Assert-CommandExitCode -Label "reg unload HKLM\$HiveName"
    if ($script:LoadedRegHives.Contains($HiveName)) {
        $script:LoadedRegHives.Remove($HiveName)
    }
}

function Unload-LoadedRegistries {
    for ($i = $script:LoadedRegHives.Count - 1; $i -ge 0; $i--) {
        $hive = $script:LoadedRegHives[$i]
        reg unload "HKLM\$hive" 2>&1 | Out-Null
        $script:LoadedRegHives.RemoveAt($i)
    }
}

function Invoke-ScriptCleanupOnFailure {
    Unload-LoadedRegistries
    if ($script:MountedByScript -and $script:ImagePath) {
        Dismount-DiskImage -ImagePath $script:ImagePath -ErrorAction SilentlyContinue | Out-Null
        $script:MountedByScript = $false
        $script:ImagePath = $null
    }
    if ($ScratchDisk -and (Test-Path "$ScratchDisk\scratchdir")) {
        try {
            Dismount-WindowsImage -Path "$ScratchDisk\scratchdir" -Discard -ErrorAction Stop
        } catch {
            Write-Warning "Could not dismount scratch image during cleanup."
        }
    }
    if ($ScratchDisk -and (Test-Path "$ScratchDisk\tiny11")) {
        try {
            Remove-Item -Path "$ScratchDisk\tiny11" -Recurse -Force -ErrorAction Stop
        } catch {
            Write-Warning "Could not remove partial tiny11 work folder during cleanup."
        }
    }
}

function Resolve-AutounattendFile {
    param([string]$Architecture)
    if ($Architecture -eq 'arm64') {
        $arm64Path = "$PSScriptRoot\autounattend-arm64.xml"
        if (Test-Path $arm64Path) { return $arm64Path }
        Write-Warning "autounattend-arm64.xml not found; falling back to autounattend.xml (amd64)."
    }
    $defaultPath = "$PSScriptRoot\autounattend.xml"
    if (-not (Test-Path $defaultPath)) {
        throw "autounattend.xml not found in $PSScriptRoot"
    }
    return $defaultPath
}

function Get-BootWimIndex {
    param([string]$BootWimPath)
    $images = @(Get-WindowsImage -ImagePath $BootWimPath)
    foreach ($img in $images) {
        if ($img.ImageName -match 'Windows Setup') {
            return $img.ImageIndex
        }
    }
    if ($images.ImageIndex -contains 2) { return 2 }
    if ($images.Count -gt 0) { return $images[0].ImageIndex }
    throw "No images found in $BootWimPath"
}

function Copy-AutounattendWithIndex {
    param(
        [string]$SourcePath,
        [string]$DestinationPath,
        [int]$ImageIndex = 1
    )
    $xml = Get-Content -Path $SourcePath -Raw
    $xml = $xml -replace '(<Key>/IMAGE/INDEX</Key>\s*<Value>)\d+(</Value>)', "`${1}${ImageIndex}`${2}"
    if ($xml -notmatch "<Key>/IMAGE/INDEX</Key>\s*<Value>$ImageIndex</Value>") {
        throw "Failed to patch /IMAGE/INDEX to $ImageIndex in autounattend source."
    }
    $destDir = Split-Path -Path $DestinationPath -Parent
    if ($destDir -and -not (Test-Path $destDir)) {
        New-Item -ItemType Directory -Force -Path $destDir | Out-Null
    }
    $utf8NoBom = New-Object System.Text.UTF8Encoding $false
    [System.IO.File]::WriteAllText($DestinationPath, $xml, $utf8NoBom)
    if (-not (Test-Path $DestinationPath)) {
        throw "Failed to write autounattend to $DestinationPath"
    }
}

function Assert-WindowsSourceDrive {
    param([string]$DriveRoot)
    if (-not (Test-Path "$DriveRoot\sources\boot.wim")) {
        throw "Drive $DriveRoot does not contain sources\boot.wim. Mount a valid Windows 11 ISO."
    }
    if (-not (Test-Path "$DriveRoot\sources\install.wim") -and -not (Test-Path "$DriveRoot\sources\install.esd")) {
        throw "Drive $DriveRoot does not contain sources\install.wim or install.esd."
    }
}

function Resolve-InstallImageIndex {
    param(
        [string]$ImagePath,
        [Nullable[int]]$PreferredIndex
    )
    $images = @(Get-WindowsImage -ImagePath $ImagePath)
    if ($images.Count -eq 0) {
        throw "No images found in $ImagePath"
    }
    $indexes = @($images | ForEach-Object { $_.ImageIndex })
    if ($null -ne $PreferredIndex -and ($indexes -contains $PreferredIndex)) {
        Write-Output "Using image index $PreferredIndex from earlier selection."
        return $PreferredIndex
    }
    if ($indexes.Count -eq 1) {
        Write-Output "Only one image found; using index $($indexes[0])."
        return $indexes[0]
    }
    $index = $null
    while ($indexes -notcontains $index) {
        Get-WindowsImage -ImagePath $ImagePath
        $rawIndex = Read-Host "Please enter the image index"
        $parsedIndex = 0
        if (-not [int]::TryParse($rawIndex, [ref]$parsedIndex)) {
            Write-Output "Invalid index. Enter one of: $($indexes -join ', ')"
            continue
        }
        if ($indexes -notcontains $parsedIndex) {
            Write-Output "Index $parsedIndex is not available. Enter one of: $($indexes -join ', ')"
            continue
        }
        $index = $parsedIndex
    }
    return $index
}

function Initialize-ScratchWorkspace {
    param([string]$ScratchRoot)
    $scratchDir = Join-Path $ScratchRoot 'scratchdir'
    if (-not (Test-Path $scratchDir)) {
        return
    }
    $mounted = @(Get-WindowsImage -Mounted -ErrorAction SilentlyContinue | Where-Object { $_.Path -eq $scratchDir })
    if ($mounted.Count -gt 0) {
        Write-Output "Dismounting leftover scratch image from a previous run..."
        Dismount-WindowsImage -Path $scratchDir -Discard -ErrorAction Stop
    }
    Remove-Item -Path $scratchDir -Recurse -Force -ErrorAction SilentlyContinue
}

function Assert-IsoBootFiles {
    param([string]$ImageRoot)
    $requiredFiles = @(
        "$ImageRoot\boot\etfsboot.com",
        "$ImageRoot\efi\microsoft\boot\efisys.bin"
    )
    foreach ($file in $requiredFiles) {
        if (-not (Test-Path $file)) {
            throw "Missing boot file required for ISO creation: $file"
        }
    }
}

function Set-RegistryValue {
    param (
        [string]$path,
        [string]$name,
        [string]$type,
        [string]$value
    )
    & 'reg' 'add' $path '/v' $name '/t' $type '/d' $value '/f' | Out-Null
    Assert-CommandExitCode -Label "reg add $path\$name"
    Write-Output "Set registry value: $path\$name"
}

function Remove-RegistryValue {
    param (
        [string]$path
    )
    & 'reg' 'delete' $path '/f' | Out-Null
    if ($LASTEXITCODE -ne 0 -and $LASTEXITCODE -ne 1) {
        throw "reg delete $path failed with exit code $LASTEXITCODE"
    }
    if ($LASTEXITCODE -eq 0) {
        Write-Output "Removed registry value: $path"
    }
}

function Show-PackageSelector {
    param(
        [string[]]$Items
    )

    $selected = @{}
    for ($i = 0; $i -lt $Items.Count; $i++) {
        $selected[$i] = $true
    }

    while ($true) {
        Clear-Host
        Write-Host "Select packages to REMOVE from the image:" -ForegroundColor Cyan
        Write-Host "Toggle items by entering numbers separated by commas. Commands: all, none" -ForegroundColor DarkGray
        Write-Host "Tip: use ranges like 1-5 or combinations like 1,3,7-9" -ForegroundColor DarkGray
        Write-Host "use: q / quit / exit to abort - use: 'done' if the selection is ready to proceed" -ForegroundColor DarkGreen
        Write-Host ""

        for ($i = 0; $i -lt $Items.Count; $i++) {
            $mark = if ($selected[$i]) { '[X]' } else { '[ ]' }
            $num = ($i + 1).ToString().PadLeft(3)
            Write-Host "$num $mark  $($Items[$i])"
        }

        Write-Host ""
        $selectionInput = Read-Host "Enter selection"
        if (-not $selectionInput) { continue }

        $selectionInput = $selectionInput.Trim()
        $lower = $selectionInput.ToLowerInvariant()
        if ($lower -in @('q', 'quit', 'exit')) {
            Write-Host "Exiting selection and keeping current choices." -ForegroundColor Yellow
            break
        }
        if ($lower -eq 'done') { break }
        if ($lower -eq 'all') {
            for ($i = 0; $i -lt $Items.Count; $i++) { $selected[$i] = $true }
            continue
        }
        if ($lower -eq 'none') {
            for ($i = 0; $i -lt $Items.Count; $i++) { $selected[$i] = $false }
            continue
        }

        $tokens = $selectionInput -split '[, ]+' | Where-Object { $_ -ne '' }
        foreach ($t in $tokens) {
            if ($t -match '^\d+$') {
                $idx = [int]$t - 1
                if ($idx -ge 0 -and $idx -lt $Items.Count) {
                    $selected[$idx] = -not $selected[$idx]
                } else {
                    Write-Host "Number out of range: $t" -ForegroundColor DarkYellow
                    Start-Sleep -Seconds 1
                }
            } elseif ($t -match '^(\d+)-(\d+)$') {
                $start = [int]$Matches[1] - 1
                $end = [int]$Matches[2] - 1
                if ($start -lt 0) { $start = 0 }
                if ($end -ge $Items.Count) { $end = $Items.Count - 1 }
                if ($start -le $end) {
                    for ($j = $start; $j -le $end; $j++) {
                        $selected[$j] = -not $selected[$j]
                    }
                } else {
                    Write-Host "Invalid range: $t" -ForegroundColor DarkYellow
                    Start-Sleep -Seconds 1
                }
            } else {
                Write-Host "Ignored token: $t" -ForegroundColor DarkYellow
                Start-Sleep -Seconds 1
            }
        }
    }

    $result = for ($i = 0; $i -lt $Items.Count; $i++) {
        if ($selected[$i]) { $Items[$i] }
    }
    return ,$result
}

function Test-PrefixSelected {
    param(
        [string[]]$SelectedPrefixes,
        [string]$Prefix
    )
    return $SelectedPrefixes -contains $Prefix
}

function Test-Prerequisites {
    Write-Output "Checking prerequisites..."

    if (-not (Get-Command 'dism.exe' -ErrorAction SilentlyContinue)) {
        throw "DISM was not found. Install the Windows Assessment and Deployment Kit (ADK) or run on a Windows edition that includes deployment tools."
    }

    foreach ($cmd in @('Mount-WindowsImage', 'Dismount-WindowsImage', 'Get-WindowsImage', 'Export-WindowsImage')) {
        if (-not (Get-Command $cmd -ErrorAction SilentlyContinue)) {
            throw "Required cmdlet '$cmd' was not found. Install the DISM PowerShell module (usually included with ADK)."
        }
    }

    if (-not (Test-Path "$PSScriptRoot\removePackage.txt")) {
        throw "removePackage.txt was not found in $PSScriptRoot"
    }

    if (-not (Test-Path "$PSScriptRoot\autounattend.xml")) {
        throw "autounattend.xml was not found in $PSScriptRoot"
    }

    Write-Output "Prerequisites OK."
}

function Test-ScratchDiskNtfs {
    param([string]$ScratchPath)
    if (-not (Test-Path $ScratchPath)) {
        Write-Warning "Could not verify NTFS filesystem for $ScratchPath"
        return
    }
    $driveName = (Get-Item $ScratchPath).PSDrive.Name
    $volume = Get-Volume -DriveLetter $driveName -ErrorAction SilentlyContinue
    if (-not $volume) {
        Write-Warning "Could not verify NTFS filesystem for ${driveName}:"
        return
    }
    if ($volume.FileSystem -ne 'NTFS') {
        throw "Scratch drive ${driveName}: must use NTFS (found $($volume.FileSystem)). ACL support is required for image processing."
    }
}

function Test-ScratchDiskSpace {
    param(
        [string]$ScratchPath,
        [uint64]$RequiredBytes = 20GB
    )

    $itemPath = $ScratchPath
    if (-not (Test-Path $itemPath)) {
        $itemPath = Split-Path $ScratchPath -Parent
    }
    if (-not (Test-Path $itemPath)) {
        Write-Warning "Could not verify free disk space for $ScratchPath"
        return
    }

    $driveName = (Get-Item $itemPath).PSDrive.Name
    $freeBytes = (Get-PSDrive -Name $driveName).Free
    $requiredGb = [math]::Round($RequiredBytes / 1GB)
    $freeGb = [math]::Round($freeBytes / 1GB, 1)

    Write-Output "Scratch disk ${driveName}: free space ${freeGb} GB (required: ${requiredGb} GB)"
    if ($freeBytes -lt $RequiredBytes) {
        throw "Insufficient free space on ${driveName}:. Need at least ${requiredGb} GB, but only ${freeGb} GB is available."
    }
}

function Initialize-Oscdimg {
    param([string]$HostArchitecture)

    Write-Output "Checking for prerequisite oscdimg.exe..."
    $adkArch = Get-AdkArchitecture -HostArchitecture $HostArchitecture
    $ADKDepTools = "C:\Program Files (x86)\Windows Kits\10\Assessment and Deployment Kit\Deployment Tools\$adkArch\Oscdimg"
    $localOSCDIMGPath = "$PSScriptRoot\oscdimg.exe"

    $oscdimgPath = $null
    if ([System.IO.Directory]::Exists($ADKDepTools)) {
        Write-Output "Will be using oscdimg.exe from system ADK."
        $oscdimgPath = "$ADKDepTools\oscdimg.exe"
    } else {
        Write-Output "ADK folder not found. Creating/using local copy of oscdimg.exe."
        $url = "https://msdl.microsoft.com/download/symbols/oscdimg.exe/3D44737265000/oscdimg.exe"

        if (-not (Test-Path -Path $localOSCDIMGPath)) {
            Write-Output "Downloading oscdimg.exe..."
            Invoke-WebRequest -Uri $url -OutFile $localOSCDIMGPath

            if (-not (Test-Path $localOSCDIMGPath)) {
                throw "Failed to download oscdimg.exe."
            }
            Write-Output "oscdimg.exe downloaded successfully."
        } else {
            Write-Output "oscdimg.exe already exists locally."
        }

        $oscdimgPath = $localOSCDIMGPath
    }

    if (-not (Test-Path $oscdimgPath)) {
        throw "oscdimg.exe not found at $oscdimgPath"
    }

    return $oscdimgPath
}

function Mount-IsoAndGetDriveLetter {
    param([string]$ImagePath)

    if (-not (Test-Path -LiteralPath $ImagePath -PathType Leaf)) {
        throw "ISO file not found: $ImagePath"
    }

    $imagePath = (Resolve-Path -LiteralPath $ImagePath).Path
    $diskImage = Get-DiskImage -ImagePath $imagePath -ErrorAction SilentlyContinue
    if (-not $diskImage -or -not $diskImage.Attached) {
        Mount-DiskImage -ImagePath $imagePath -Access ReadOnly -PassThru | Out-Null
    } else {
        Write-Output "ISO is already mounted: $imagePath"
    }

    $driveLetter = $null
    for ($i = 0; $i -lt 60; $i++) {
        $vol = Get-DiskImage -ImagePath $imagePath -ErrorAction SilentlyContinue | Get-Volume -ErrorAction SilentlyContinue
        if ($vol) {
            if ($vol -is [System.Array]) {
                $vol = @($vol | Where-Object { $_.DriveLetter } | Select-Object -First 1)
            }
            if ($vol -and $vol.DriveLetter) {
                $driveLetter = [string]$vol.DriveLetter
                break
            }
        }
        Start-Sleep -Milliseconds 500
    }

    if (-not $driveLetter) {
        Dismount-DiskImage -ImagePath $imagePath -ErrorAction SilentlyContinue | Out-Null
        throw "ISO mounted but no drive letter was assigned. Mount the ISO manually in Explorer and pass that drive letter with -ISO."
    }

    $driveRoot = ($driveLetter.TrimEnd(':') + ':')
    if ($driveRoot -notmatch '^[A-Za-z]:$') {
        Dismount-DiskImage -ImagePath $imagePath -ErrorAction SilentlyContinue | Out-Null
        throw "Could not resolve a valid drive letter for mounted ISO (got '$driveLetter')."
    }

    return @{
        ImagePath = $imagePath
        DriveRoot = $driveRoot
    }
}

function Resolve-WindowsSource {
    param([string]$IsoParameter)

    $script:ImagePath = $null
    $script:MountedByScript = $false
    $driveLetter = $null

    if ($IsoParameter) {
        if ($IsoParameter -match '^[c-zC-Z]$') {
            $driveLetter = $IsoParameter + ":"
            Assert-WindowsSourceDrive -DriveRoot $driveLetter
            Write-Output "Using mounted drive $driveLetter"
            return $driveLetter
        }
        if ((Test-Path -LiteralPath $IsoParameter -PathType Leaf) -and ($IsoParameter -match '\.iso$')) {
            try {
                $mount = Mount-IsoAndGetDriveLetter -ImagePath $IsoParameter
                $script:ImagePath = $mount.ImagePath
                $driveLetter = $mount.DriveRoot
                Assert-WindowsSourceDrive -DriveRoot $driveLetter
            } catch {
                if ($script:ImagePath) {
                    Dismount-DiskImage -ImagePath $script:ImagePath -ErrorAction SilentlyContinue | Out-Null
                }
                $script:ImagePath = $null
                throw
            }
            $script:MountedByScript = $true
            Write-Output "Mounted $($script:ImagePath) at $driveLetter"
            return $driveLetter
        }
        throw "Invalid -ISO value. Provide a drive letter (e.g. E) or a path to a .iso file."
    }

    do {
        $userInput = Read-Host "Enter Windows 11 ISO path or mounted drive letter"
        $userInput = $userInput.Trim().Trim('"').TrimEnd(':')
        if ($userInput -match '^[c-zC-Z]$') {
            $driveLetter = $userInput + ":"
            try {
                Assert-WindowsSourceDrive -DriveRoot $driveLetter
            } catch {
                Write-Output $_.Exception.Message
                $driveLetter = $null
                continue
            }
            Write-Output "Using mounted drive $driveLetter"
        } elseif ((Test-Path -LiteralPath $userInput -PathType Leaf) -and ($userInput -match '\.iso$')) {
            try {
                $mount = Mount-IsoAndGetDriveLetter -ImagePath $userInput
                $script:ImagePath = $mount.ImagePath
                $driveLetter = $mount.DriveRoot
                Assert-WindowsSourceDrive -DriveRoot $driveLetter
            } catch {
                Write-Output $_.Exception.Message
                if ($script:ImagePath) {
                    Dismount-DiskImage -ImagePath $script:ImagePath -ErrorAction SilentlyContinue | Out-Null
                }
                $script:ImagePath = $null
                $script:MountedByScript = $false
                $driveLetter = $null
                continue
            }
            $script:MountedByScript = $true
            Write-Output "Mounted $($script:ImagePath) at $driveLetter"
        } else {
            Write-Output "Invalid input. Provide a drive letter (e.g. E) or a path to a .iso file."
            $driveLetter = $null
        }
    } while (-not $driveLetter)

    return $driveLetter
}

#---------[ Execution ]---------#
if ((Get-ExecutionPolicy) -eq 'Restricted') {
    Write-Output "Your current PowerShell Execution Policy is set to Restricted, which prevents scripts from running. Do you want to change it to RemoteSigned? (yes/no)"
    $response = Read-Host
    if ($response -eq 'yes') {
        Set-ExecutionPolicy RemoteSigned -Scope CurrentUser -Confirm:$false
    } else {
        Write-Output "The script cannot be run without changing the execution policy. Exiting..."
        exit
    }
}

$adminSID = New-Object System.Security.Principal.SecurityIdentifier("S-1-5-32-544")
$adminGroup = $adminSID.Translate([System.Security.Principal.NTAccount])
$myWindowsID = [System.Security.Principal.WindowsIdentity]::GetCurrent()
$myWindowsPrincipal = new-object System.Security.Principal.WindowsPrincipal($myWindowsID)
$adminRole = [System.Security.Principal.WindowsBuiltInRole]::Administrator
if (! $myWindowsPrincipal.IsInRole($adminRole)) {
    Write-Output "Restarting Tiny11 image creator as admin in a new window, you can close this one."
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-NoExit', '-File', $PSCommandPath)
    if ($ISO) { $argList += @('-ISO', $ISO) }
    if ($SCRATCH) { $argList += @('-SCRATCH', $SCRATCH) }
    if ($Custom) { $argList += '-Custom' }
    $newProcess = new-object System.Diagnostics.ProcessStartInfo "PowerShell"
    $newProcess.Arguments = Build-ProcessArgumentString -Arguments $argList
    $newProcess.Verb = "runas"
    [System.Diagnostics.Process]::Start($newProcess) | Out-Null
    exit
}

Start-Transcript -Path "$PSScriptRoot\tiny11_$(get-date -f yyyyMMdd_HHmms).log"

trap {
    Write-Error "Script failed: $($_.Exception.Message)"
    Invoke-ScriptCleanupOnFailure
    Stop-Transcript -ErrorAction SilentlyContinue
    Read-Host "Press Enter to exit"
    exit 1
}

$Host.UI.RawUI.WindowTitle = "Tiny11 image creator"
Clear-Host
Write-Output "Welcome to the tiny11 image creator! Release: 11-06-26"

$hostArchitecture = $Env:PROCESSOR_ARCHITECTURE
Test-Prerequisites
if ($SCRATCH) {
    Test-ScratchDiskNtfs -ScratchPath $ScratchDisk
}
Test-ScratchDiskSpace -ScratchPath $ScratchDisk
$OSCDIMG = Initialize-Oscdimg -HostArchitecture $hostArchitecture
Initialize-ScratchWorkspace -ScratchRoot $ScratchDisk

New-Item -ItemType Directory -Force -Path "$ScratchDisk\tiny11\sources" | Out-Null
$DriveLetter = Resolve-WindowsSource -IsoParameter $ISO
$selectedImageIndex = $null

Write-Output "Copying Windows image..."
Copy-Item -Path "$DriveLetter\*" -Destination "$ScratchDisk\tiny11" -Recurse -Force | Out-Null
if (-not (Test-Path "$ScratchDisk\tiny11\sources\boot.wim")) {
    throw "boot.wim is missing from the copied source. The ISO may be incomplete."
}

if (-not (Test-Path "$ScratchDisk\tiny11\sources\install.wim")) {
    if (Test-Path "$ScratchDisk\tiny11\sources\install.esd") {
        Write-Output "Found install.esd, converting to install.wim..."
        $esdIndex = Resolve-InstallImageIndex -ImagePath "$ScratchDisk\tiny11\sources\install.esd" -PreferredIndex $null
        Write-Output ' '
        Write-Output 'Converting install.esd to install.wim. This may take a while...'
        Export-WindowsImage -SourceImagePath "$ScratchDisk\tiny11\sources\install.esd" -SourceIndex $esdIndex -DestinationImagePath "$ScratchDisk\tiny11\sources\install.wim" -CompressionType Maximum -CheckIntegrity
        $selectedImageIndex = 1
    } else {
        throw "Can't find install.wim or install.esd in the copied source. Provide a valid Windows 11 ISO or mounted drive."
    }
}
if (-not (Test-Path "$ScratchDisk\tiny11\sources\install.wim")) {
    throw "install.wim is missing after copy/conversion. The source may be incomplete."
}
if ($script:MountedByScript -and $script:ImagePath) {
    Dismount-DiskImage -ImagePath $script:ImagePath -ErrorAction SilentlyContinue | Out-Null
    $script:MountedByScript = $false
    $script:ImagePath = $null
    Write-Output "Source ISO unmounted after copy."
}
Set-ItemProperty -Path "$ScratchDisk\tiny11\sources\install.esd" -Name IsReadOnly -Value $false -ErrorAction 'Continue' | Out-Null
Remove-Item "$ScratchDisk\tiny11\sources\install.esd" -ErrorAction 'Continue' | Out-Null
Write-Output "Copy complete!"
Start-Sleep -Seconds 2
Clear-Host
Write-Output "Getting image information:"
$index = Resolve-InstallImageIndex -ImagePath $ScratchDisk\tiny11\sources\install.wim -PreferredIndex $selectedImageIndex
Write-Output "Mounting Windows image. This may take a while."
$wimFilePath = "$ScratchDisk\tiny11\sources\install.wim"
& takeown "/F" $wimFilePath
& icacls $wimFilePath "/grant" "$($adminGroup.Value):(F)"
Set-ItemProperty -Path $wimFilePath -Name IsReadOnly -Value $false -ErrorAction Stop
New-Item -ItemType Directory -Force -Path "$ScratchDisk\scratchdir" | Out-Null
Mount-WindowsImage -ImagePath $ScratchDisk\tiny11\sources\install.wim -Index $index -Path $ScratchDisk\scratchdir

$imageIntl = & dism /English /Get-Intl "/Image:$($ScratchDisk)\scratchdir"
$languageLine = $imageIntl -split '\n' | Where-Object { $_ -match 'Default system UI language : ([a-zA-Z]{2}-[a-zA-Z]{2})' }

if ($languageLine) {
    $languageCode = $Matches[1]
    Write-Output "Default system UI language code: $languageCode"
} else {
    Write-Output "Default system UI language code not found."
}

$imageInfo = & 'dism' '/English' '/Get-WimInfo' "/wimFile:$($ScratchDisk)\tiny11\sources\install.wim" "/index:$index"
$lines = $imageInfo -split '\r?\n'
$architecture = $null

foreach ($line in $lines) {
    if ($line -like '*Architecture : *') {
        $architecture = $line -replace 'Architecture : ',''
        if ($architecture -eq 'x64') {
            $architecture = 'amd64'
        }
        Write-Output "Architecture: $architecture"
        break
    }
}

if (-not $architecture) {
    throw "Could not detect image architecture. Cannot apply arch-specific changes or select autounattend."
}

Write-Output "Mounting complete! Performing removal of applications..."

$packages = & 'dism' '/English' "/image:$($ScratchDisk)\scratchdir" '/Get-ProvisionedAppxPackages' |
    ForEach-Object {
        if ($_ -match 'PackageName : (.*)') {
            $matches[1]
        }
    }

$packagePrefixes = Get-Content -Path "$PSScriptRoot\removePackage.txt" |
    Where-Object { $_.Trim() -ne '' -and -not $_.Trim().StartsWith('#') } |
    ForEach-Object { $_.Trim() }

if ($Custom) {
    try {
        $selectedPrefixes = @(Show-PackageSelector -Items $packagePrefixes)
    } catch {
        Write-Warning "Interactive selector failed or was interrupted. Defaulting to all prefixes."
        $selectedPrefixes = @($packagePrefixes)
    }
} else {
    $selectedPrefixes = @($packagePrefixes)
}

if (-not $selectedPrefixes -or @($selectedPrefixes).Count -eq 0) {
    Write-Output "No package prefixes selected for removal. Skipping Appx package removal step."
    $packagesToRemove = @()
} else {
    Write-Output "Selected package prefixes to remove:"
    $selectedPrefixes | ForEach-Object { Write-Output " - $_" }

    $appxPrefixes = $selectedPrefixes | Where-Object { $_ -notin $Script:SpecialPackageEntries }
    $packagesToRemove = $packages | Where-Object {
        $pkg = $_
        $match = $false
        foreach ($pref in $appxPrefixes) {
            if ($pkg -like "*$pref*") { $match = $true; break }
        }
        $match
    }
}

foreach ($package in $packagesToRemove) {
    Write-Output "Removing provisioned package: $package"
    & 'dism' '/English' "/image:$($ScratchDisk)\scratchdir" '/Remove-ProvisionedAppxPackage' "/PackageName:$package"
    if ($LASTEXITCODE -ne 0) {
        Write-Warning "Failed to remove package $package (dism exit code $LASTEXITCODE)"
    }
}

$removeEdge = (-not $Custom) -or (Test-PrefixSelected $selectedPrefixes 'Microsoft.MicrosoftEdge.Stable_8wekyb3d8bbwe!App')
if ($removeEdge) {
    Write-Output "Removing Edge:"
    Remove-Item -Path "$ScratchDisk\scratchdir\Program Files (x86)\Microsoft\Edge" -Recurse -Force -ErrorAction SilentlyContinue | Out-Null
    Remove-Item -Path "$ScratchDisk\scratchdir\Program Files (x86)\Microsoft\EdgeUpdate" -Recurse -Force -ErrorAction SilentlyContinue | Out-Null
    Remove-Item -Path "$ScratchDisk\scratchdir\Program Files (x86)\Microsoft\EdgeCore" -Recurse -Force -ErrorAction SilentlyContinue | Out-Null
    if ($architecture -eq 'amd64') {
        $edgeWinSxS = Get-ChildItem -Path "$ScratchDisk\scratchdir\Windows\WinSxS" -Filter "amd64_microsoft-edge-webview_31bf3856ad364e35*" -Directory -ErrorAction SilentlyContinue | Select-Object -ExpandProperty FullName
    } elseif ($architecture -eq 'arm64') {
        $edgeWinSxS = Get-ChildItem -Path "$ScratchDisk\scratchdir\Windows\WinSxS" -Filter "arm64_microsoft-edge-webview_31bf3856ad364e35*" -Directory -ErrorAction SilentlyContinue | Select-Object -ExpandProperty FullName
    }
    if ($edgeWinSxS) {
        & 'takeown' '/f' $edgeWinSxS '/r' | Out-Null
        & 'icacls' $edgeWinSxS '/grant' "$($adminGroup.Value):(F)" '/T' '/C' | Out-Null
        Remove-Item -Path $edgeWinSxS -Recurse -Force -ErrorAction SilentlyContinue | Out-Null
    }
    & 'takeown' '/f' "$ScratchDisk\scratchdir\Windows\System32\Microsoft-Edge-Webview" '/r' | Out-Null
    & 'icacls' "$ScratchDisk\scratchdir\Windows\System32\Microsoft-Edge-Webview" '/grant' "$($adminGroup.Value):(F)" '/T' '/C' | Out-Null
    Remove-Item -Path "$ScratchDisk\scratchdir\Windows\System32\Microsoft-Edge-Webview" -Recurse -Force -ErrorAction SilentlyContinue | Out-Null
}

$removeOneDrive = (-not $Custom) -or (Test-PrefixSelected $selectedPrefixes 'OneDrive')
if ($removeOneDrive) {
    Write-Output "Removing OneDrive:"
    if (Test-Path "$ScratchDisk\scratchdir\Windows\System32\OneDriveSetup.exe") {
        & 'takeown' '/f' "$ScratchDisk\scratchdir\Windows\System32\OneDriveSetup.exe" | Out-Null
        & 'icacls' "$ScratchDisk\scratchdir\Windows\System32\OneDriveSetup.exe" '/grant' "$($adminGroup.Value):(F)" '/T' '/C' | Out-Null
        Remove-Item -Path "$ScratchDisk\scratchdir\Windows\System32\OneDriveSetup.exe" -Force -ErrorAction SilentlyContinue | Out-Null
    } else {
        Write-Output "OneDriveSetup.exe not present, skipping."
    }
}
Write-Output "Removal complete!"
Start-Sleep -Seconds 2
Clear-Host
Write-Output "Loading registry..."
Invoke-RegLoad -HiveName 'zCOMPONENTS' -FilePath "$ScratchDisk\scratchdir\Windows\System32\config\COMPONENTS"
Invoke-RegLoad -HiveName 'zDEFAULT' -FilePath "$ScratchDisk\scratchdir\Windows\System32\config\default"
Invoke-RegLoad -HiveName 'zNTUSER' -FilePath "$ScratchDisk\scratchdir\Users\Default\ntuser.dat"
Invoke-RegLoad -HiveName 'zSOFTWARE' -FilePath "$ScratchDisk\scratchdir\Windows\System32\config\SOFTWARE"
Invoke-RegLoad -HiveName 'zSYSTEM' -FilePath "$ScratchDisk\scratchdir\Windows\System32\config\SYSTEM"
Write-Output "Bypassing system requirements(on the system image):"
Set-RegistryValue 'HKLM\zDEFAULT\Control Panel\UnsupportedHardwareNotificationCache' 'SV1' 'REG_DWORD' '0'
Set-RegistryValue 'HKLM\zDEFAULT\Control Panel\UnsupportedHardwareNotificationCache' 'SV2' 'REG_DWORD' '0'
Set-RegistryValue 'HKLM\zNTUSER\Control Panel\UnsupportedHardwareNotificationCache' 'SV1' 'REG_DWORD' '0'
Set-RegistryValue 'HKLM\zNTUSER\Control Panel\UnsupportedHardwareNotificationCache' 'SV2' 'REG_DWORD' '0'
Set-RegistryValue 'HKLM\zSYSTEM\Setup\LabConfig' 'BypassCPUCheck' 'REG_DWORD' '1'
Set-RegistryValue 'HKLM\zSYSTEM\Setup\LabConfig' 'BypassRAMCheck' 'REG_DWORD' '1'
Set-RegistryValue 'HKLM\zSYSTEM\Setup\LabConfig' 'BypassSecureBootCheck' 'REG_DWORD' '1'
Set-RegistryValue 'HKLM\zSYSTEM\Setup\LabConfig' 'BypassStorageCheck' 'REG_DWORD' '1'
Set-RegistryValue 'HKLM\zSYSTEM\Setup\LabConfig' 'BypassTPMCheck' 'REG_DWORD' '1'
Set-RegistryValue 'HKLM\zSYSTEM\Setup\MoSetup' 'AllowUpgradesWithUnsupportedTPMOrCPU' 'REG_DWORD' '1'
Write-Output "Disabling Sponsored Apps:"
Set-RegistryValue 'HKLM\zNTUSER\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'OemPreInstalledAppsEnabled' 'REG_DWORD' '0'
Set-RegistryValue 'HKLM\zNTUSER\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'PreInstalledAppsEnabled' 'REG_DWORD' '0'
Set-RegistryValue 'HKLM\zNTUSER\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'SilentInstalledAppsEnabled' 'REG_DWORD' '0'
Set-RegistryValue 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\CloudContent' 'DisableWindowsConsumerFeatures' 'REG_DWORD' '1'
Set-RegistryValue 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'ContentDeliveryAllowed' 'REG_DWORD' '0'
Set-RegistryValue 'HKLM\zSOFTWARE\Microsoft\PolicyManager\current\device\Start' 'ConfigureStartPins' 'REG_SZ' '{"pinnedList": [{}]}'
Set-RegistryValue 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'FeatureManagementEnabled' 'REG_DWORD' '0'
Set-RegistryValue 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'PreInstalledAppsEverEnabled' 'REG_DWORD' '0'
Set-RegistryValue 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'SoftLandingEnabled' 'REG_DWORD' '0'
Set-RegistryValue 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'SubscribedContentEnabled' 'REG_DWORD' '0'
Set-RegistryValue 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'SubscribedContent-310093Enabled' 'REG_DWORD' '0'
Set-RegistryValue 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'SubscribedContent-338388Enabled' 'REG_DWORD' '0'
Set-RegistryValue 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'SubscribedContent-338389Enabled' 'REG_DWORD' '0'
Set-RegistryValue 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'SubscribedContent-338393Enabled' 'REG_DWORD' '0'
Set-RegistryValue 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'SubscribedContent-353694Enabled' 'REG_DWORD' '0'
Set-RegistryValue 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'SubscribedContent-353696Enabled' 'REG_DWORD' '0'
Set-RegistryValue 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'SystemPaneSuggestionsEnabled' 'REG_DWORD' '0'
Set-RegistryValue 'HKLM\zSOFTWARE\Policies\Microsoft\PushToInstall' 'DisablePushToInstall' 'REG_DWORD' '1'
Set-RegistryValue 'HKLM\zSOFTWARE\Policies\Microsoft\MRT' 'DontOfferThroughWUAU' 'REG_DWORD' '1'
Remove-RegistryValue 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager\Subscriptions'
Remove-RegistryValue 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager\SuggestedApps'
Set-RegistryValue 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\CloudContent' 'DisableConsumerAccountStateContent' 'REG_DWORD' '1'
Set-RegistryValue 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\CloudContent' 'DisableCloudOptimizedContent' 'REG_DWORD' '1'
Write-Output "Enabling Local Accounts on OOBE:"
Set-RegistryValue 'HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\OOBE' 'BypassNRO' 'REG_DWORD' '1'
$autounattendSource = Resolve-AutounattendFile -Architecture $architecture
Copy-AutounattendWithIndex -SourcePath $autounattendSource -DestinationPath "$ScratchDisk\scratchdir\Windows\System32\Sysprep\autounattend.xml" -ImageIndex 1

Write-Output "Disabling Reserved Storage:"
Set-RegistryValue 'HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\ReserveManager' 'ShippedWithReserves' 'REG_DWORD' '0'
Write-Output "Disabling BitLocker Device Encryption"
Set-RegistryValue 'HKLM\zSYSTEM\ControlSet001\Control\BitLocker' 'PreventDeviceEncryption' 'REG_DWORD' '1'
Write-Output "Disabling Chat icon:"
Set-RegistryValue 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\Windows Chat' 'ChatIcon' 'REG_DWORD' '3'
Set-RegistryValue 'HKLM\zNTUSER\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'TaskbarMn' 'REG_DWORD' '0'

if ($removeEdge) {
    Write-Output "Removing Edge related registries"
    Remove-RegistryValue "HKEY_LOCAL_MACHINE\zSOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\Microsoft Edge"
    Remove-RegistryValue "HKEY_LOCAL_MACHINE\zSOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\Microsoft Edge Update"
}

if ($removeOneDrive) {
    Write-Output "Disabling OneDrive folder backup"
    Set-RegistryValue "HKLM\zSOFTWARE\Policies\Microsoft\Windows\OneDrive" "DisableFileSyncNGSC" "REG_DWORD" "1"
}
Write-Output "Disabling Search Highlights:"
Set-RegistryValue 'HKLM\zSoftware\Microsoft\Windows\CurrentVersion\SearchSettings' 'IsDynamicSearchBoxEnabled' 'REG_DWORD' '0'
Write-Output "Disabling Telemetry:"
Set-RegistryValue 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo' 'Enabled' 'REG_DWORD' '0'
Set-RegistryValue 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\Privacy' 'TailoredExperiencesWithDiagnosticDataEnabled' 'REG_DWORD' '0'
Set-RegistryValue 'HKLM\zNTUSER\Software\Microsoft\Speech_OneCore\Settings\OnlineSpeechPrivacy' 'HasAccepted' 'REG_DWORD' '0'
Set-RegistryValue 'HKLM\zNTUSER\Software\Microsoft\Input\TIPC' 'Enabled' 'REG_DWORD' '0'
Set-RegistryValue 'HKLM\zNTUSER\Software\Microsoft\InputPersonalization' 'RestrictImplicitInkCollection' 'REG_DWORD' '1'
Set-RegistryValue 'HKLM\zNTUSER\Software\Microsoft\InputPersonalization' 'RestrictImplicitTextCollection' 'REG_DWORD' '1'
Set-RegistryValue 'HKLM\zNTUSER\Software\Microsoft\InputPersonalization\TrainedDataStore' 'HarvestContacts' 'REG_DWORD' '0'
Set-RegistryValue 'HKLM\zNTUSER\Software\Microsoft\Personalization\Settings' 'AcceptedPrivacyPolicy' 'REG_DWORD' '0'
Set-RegistryValue 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\DataCollection' 'AllowTelemetry' 'REG_DWORD' '0'
Set-RegistryValue 'HKLM\zSYSTEM\ControlSet001\Services\dmwappushservice' 'Start' 'REG_DWORD' '4'
Set-RegistryValue 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'RotatingLockScreenEnabled' 'REG_DWORD' '0'
Set-RegistryValue 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'RotatingLockScreenOverlayEnabled' 'REG_DWORD' '0'
Set-RegistryValue 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' 'SubscribedContent-338387Enabled' 'REG_DWORD' '0'

$response = Read-Host "Prevent Windows from automatically installing device drivers? (Y/n)"
if ($response -eq '' -or $response.ToLower() -eq 'y') {
    Set-RegistryValue 'HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\DriverSearching' 'SearchOrderConfig' 'REG_DWORD' '0'
}

$removeDevHome = (-not $Custom) -or (Test-PrefixSelected $selectedPrefixes 'Microsoft.Windows.DevHome')
$removeOutlook = (-not $Custom) -or (Test-PrefixSelected $selectedPrefixes 'Microsoft.OutlookForWindows')
$removeCopilot = (-not $Custom) -or (Test-PrefixSelected $selectedPrefixes 'Microsoft.Windows.Copilot') -or (Test-PrefixSelected $selectedPrefixes 'Microsoft.Copilot')
$removeTeams = (-not $Custom) -or (Test-PrefixSelected $selectedPrefixes 'Microsoft.Windows.Teams') -or (Test-PrefixSelected $selectedPrefixes 'MicrosoftTeams') -or (Test-PrefixSelected $selectedPrefixes 'MSTeams')

if ($removeOutlook) {
    Write-Output "Prevent installation of Outlook:"
    Set-RegistryValue 'HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Orchestrator\UScheduler_Oobe\OutlookUpdate' 'workCompleted' 'REG_DWORD' '1'
    Set-RegistryValue 'HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Orchestrator\UScheduler\OutlookUpdate' 'workCompleted' 'REG_DWORD' '1'
    Remove-RegistryValue 'HKLM\zSOFTWARE\Microsoft\WindowsUpdate\Orchestrator\UScheduler_Oobe\OutlookUpdate'
    Set-RegistryValue 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\Windows Mail' 'PreventRun' 'REG_DWORD' '1'
}
if ($removeDevHome) {
    Write-Output "Prevent installation of DevHome:"
    Set-RegistryValue 'HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Orchestrator\UScheduler\DevHomeUpdate' 'workCompleted' 'REG_DWORD' '1'
    Remove-RegistryValue 'HKLM\zSOFTWARE\Microsoft\WindowsUpdate\Orchestrator\UScheduler_Oobe\DevHomeUpdate'
}
if ($removeCopilot) {
    Write-Output "Disabling Copilot"
    Set-RegistryValue 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\WindowsCopilot' 'TurnOffWindowsCopilot' 'REG_DWORD' '1'
    Set-RegistryValue 'HKLM\zSOFTWARE\Policies\Microsoft\Edge' 'HubsSidebarEnabled' 'REG_DWORD' '0'
    Set-RegistryValue 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\Explorer' 'DisableSearchBoxSuggestions' 'REG_DWORD' '1'
}
if ($removeTeams) {
    Write-Output "Prevents installation of Teams:"
    Set-RegistryValue 'HKLM\zSOFTWARE\Policies\Microsoft\Teams' 'DisableInstallation' 'REG_DWORD' '1'
}

Write-Host "Deleting scheduled task definition files..."
$tasksPath = "$ScratchDisk\scratchdir\Windows\System32\Tasks"

Remove-Item -Path "$tasksPath\Microsoft\Windows\Application Experience\Microsoft Compatibility Appraiser" -Force -ErrorAction SilentlyContinue
Remove-Item -Path "$tasksPath\Microsoft\Windows\Customer Experience Improvement Program" -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item -Path "$tasksPath\Microsoft\Windows\Application Experience\ProgramDataUpdater" -Force -ErrorAction SilentlyContinue
Remove-Item -Path "$tasksPath\Microsoft\Windows\Chkdsk\Proxy" -Force -ErrorAction SilentlyContinue
Remove-Item -Path "$tasksPath\Microsoft\Windows\Windows Error Reporting\QueueReporting" -Force -ErrorAction SilentlyContinue
Write-Host "Task files have been deleted."
Write-Host "Unmounting Registry..."
Invoke-RegUnload -HiveName 'zCOMPONENTS'
Invoke-RegUnload -HiveName 'zDEFAULT'
Invoke-RegUnload -HiveName 'zNTUSER'
Invoke-RegUnload -HiveName 'zSOFTWARE'
Invoke-RegUnload -HiveName 'zSYSTEM'
Write-Output "Cleaning up image..."
Invoke-DismChecked -Label 'DISM cleanup' /Image:$ScratchDisk\scratchdir /Cleanup-Image /StartComponentCleanup /ResetBase
Write-Output "Cleanup complete."
Write-Output ' '
Write-Output "Unmounting image..."
Dismount-WindowsImage -Path $ScratchDisk\scratchdir -Save
Write-Host "Exporting image..."
Invoke-DismChecked -Label 'DISM export install.wim' /Export-Image /SourceImageFile:"$ScratchDisk\tiny11\sources\install.wim" /SourceIndex:$index /DestinationImageFile:"$ScratchDisk\tiny11\sources\install2.wim" /Compress:recovery
if (-not (Test-Path "$ScratchDisk\tiny11\sources\install2.wim")) {
    throw "DISM export failed: install2.wim was not created."
}
Remove-Item -Path "$ScratchDisk\tiny11\sources\install.wim" -Force | Out-Null
Rename-Item -Path "$ScratchDisk\tiny11\sources\install2.wim" -NewName "install.wim" | Out-Null
if (-not (Test-Path "$ScratchDisk\tiny11\sources\install.wim")) {
    throw "Failed to replace install.wim after export."
}
$index = 1
Write-Output "Windows image completed. Continuing with boot.wim."
Initialize-ScratchWorkspace -ScratchRoot $ScratchDisk
Start-Sleep -Seconds 2
Clear-Host
Write-Output "Mounting boot image:"
$wimFilePath = "$ScratchDisk\tiny11\sources\boot.wim"
& takeown "/F" $wimFilePath | Out-Null
& icacls $wimFilePath "/grant" "$($adminGroup.Value):(F)"
Set-ItemProperty -Path $wimFilePath -Name IsReadOnly -Value $false -ErrorAction Stop
$bootWimIndex = Get-BootWimIndex -BootWimPath "$ScratchDisk\tiny11\sources\boot.wim"
Write-Output "Using boot.wim index $bootWimIndex"
Mount-WindowsImage -ImagePath $ScratchDisk\tiny11\sources\boot.wim -Index $bootWimIndex -Path $ScratchDisk\scratchdir
Write-Output "Loading registry..."
Invoke-RegLoad -HiveName 'zCOMPONENTS' -FilePath "$ScratchDisk\scratchdir\Windows\System32\config\COMPONENTS"
Invoke-RegLoad -HiveName 'zDEFAULT' -FilePath "$ScratchDisk\scratchdir\Windows\System32\config\default"
Invoke-RegLoad -HiveName 'zNTUSER' -FilePath "$ScratchDisk\scratchdir\Users\Default\ntuser.dat"
Invoke-RegLoad -HiveName 'zSOFTWARE' -FilePath "$ScratchDisk\scratchdir\Windows\System32\config\SOFTWARE"
Invoke-RegLoad -HiveName 'zSYSTEM' -FilePath "$ScratchDisk\scratchdir\Windows\System32\config\SYSTEM"

Write-Output "Bypassing system requirements(on the setup image):"
Set-RegistryValue 'HKLM\zDEFAULT\Control Panel\UnsupportedHardwareNotificationCache' 'SV1' 'REG_DWORD' '0'
Set-RegistryValue 'HKLM\zDEFAULT\Control Panel\UnsupportedHardwareNotificationCache' 'SV2' 'REG_DWORD' '0'
Set-RegistryValue 'HKLM\zNTUSER\Control Panel\UnsupportedHardwareNotificationCache' 'SV1' 'REG_DWORD' '0'
Set-RegistryValue 'HKLM\zNTUSER\Control Panel\UnsupportedHardwareNotificationCache' 'SV2' 'REG_DWORD' '0'
Set-RegistryValue 'HKLM\zSYSTEM\Setup\LabConfig' 'BypassCPUCheck' 'REG_DWORD' '1'
Set-RegistryValue 'HKLM\zSYSTEM\Setup\LabConfig' 'BypassRAMCheck' 'REG_DWORD' '1'
Set-RegistryValue 'HKLM\zSYSTEM\Setup\LabConfig' 'BypassSecureBootCheck' 'REG_DWORD' '1'
Set-RegistryValue 'HKLM\zSYSTEM\Setup\LabConfig' 'BypassStorageCheck' 'REG_DWORD' '1'
Set-RegistryValue 'HKLM\zSYSTEM\Setup\LabConfig' 'BypassTPMCheck' 'REG_DWORD' '1'
Set-RegistryValue 'HKLM\zSYSTEM\Setup\MoSetup' 'AllowUpgradesWithUnsupportedTPMOrCPU' 'REG_DWORD' '1'
Write-Output "Tweaking complete!"

Write-Output "Unmounting Registry..."
Invoke-RegUnload -HiveName 'zCOMPONENTS'
Invoke-RegUnload -HiveName 'zDEFAULT'
Invoke-RegUnload -HiveName 'zNTUSER'
Invoke-RegUnload -HiveName 'zSOFTWARE'
Invoke-RegUnload -HiveName 'zSYSTEM'

Write-Output "Unmounting image..."
Dismount-WindowsImage -Path $ScratchDisk\scratchdir -Save
Clear-Host
Write-Output "The tiny11 image is now completed. Proceeding with the making of the ISO..."
Write-Output "Copying unattended file for bypassing MS account on OOBE..."
Copy-AutounattendWithIndex -SourcePath $autounattendSource -DestinationPath "$ScratchDisk\tiny11\autounattend.xml" -ImageIndex 1
Assert-IsoBootFiles -ImageRoot "$ScratchDisk\tiny11"
Write-Output "Creating ISO image..."

& "$OSCDIMG" '-m' '-o' '-u2' '-udfver102' "-bootdata:2#p0,e,b$ScratchDisk\tiny11\boot\etfsboot.com#pEF,e,b$ScratchDisk\tiny11\efi\microsoft\boot\efisys.bin" "$ScratchDisk\tiny11" "$PSScriptRoot\tiny11.iso"
Assert-CommandExitCode -Label 'oscdimg ISO creation'
if (-not (Test-Path "$PSScriptRoot\tiny11.iso")) {
    throw "ISO creation failed: tiny11.iso was not created."
}

Write-Output "Creation completed! Press any key to exit the script..."
Read-Host "Press Enter to continue"
Write-Output "Performing Cleanup..."
Remove-Item -Path "$ScratchDisk\tiny11" -Recurse -Force | Out-Null
Remove-Item -Path "$ScratchDisk\scratchdir" -Recurse -Force | Out-Null

Write-Output "Cleanup check :"
if (Test-Path -Path "$ScratchDisk\tiny11") {
    Write-Output "tiny11 folder still exists. Attempting to remove it again..."
    Remove-Item -Path "$ScratchDisk\tiny11" -Recurse -Force -ErrorAction SilentlyContinue
    if (Test-Path -Path "$ScratchDisk\tiny11") {
        Write-Output "Failed to remove tiny11 folder."
    } else {
        Write-Output "tiny11 folder removed successfully."
    }
} else {
    Write-Output "tiny11 folder does not exist. No action needed."
}
if (Test-Path -Path "$ScratchDisk\scratchdir") {
    Write-Output "scratchdir folder still exists. Attempting to remove it again..."
    Remove-Item -Path "$ScratchDisk\scratchdir" -Recurse -Force -ErrorAction SilentlyContinue
    if (Test-Path -Path "$ScratchDisk\scratchdir") {
        Write-Output "Failed to remove scratchdir folder."
    } else {
        Write-Output "scratchdir folder removed successfully."
    }
} else {
    Write-Output "scratchdir folder does not exist. No action needed."
}
Stop-Transcript

exit
