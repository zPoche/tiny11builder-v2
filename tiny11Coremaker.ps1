$ErrorActionPreference = 'Stop'

function Assert-CommandExitCode {
    param(
        [string]$Label,
        [int[]]$AllowedExitCodes = @(0)
    )
    if ($AllowedExitCodes -notcontains $LASTEXITCODE) {
        throw "$Label failed with exit code $LASTEXITCODE"
    }
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

function Test-CoremakerPrerequisites {
    Write-Host "Checking prerequisites..."
    if (-not (Get-Command 'dism.exe' -ErrorAction SilentlyContinue)) {
        throw "DISM was not found. Install the Windows ADK or run on a Windows edition with deployment tools."
    }
    foreach ($cmd in @('Mount-WindowsImage', 'Dismount-WindowsImage', 'Get-WindowsImage')) {
        if (-not (Get-Command $cmd -ErrorAction SilentlyContinue)) {
            throw "Required cmdlet '$cmd' was not found."
        }
    }
    Write-Host "Prerequisites OK."
}

function Test-ScratchDiskSpace {
    param(
        [string]$ScratchPath,
        [uint64]$RequiredBytes = 20GB
    )
    $driveName = (Get-Item $ScratchPath).PSDrive.Name
    $freeBytes = (Get-PSDrive -Name $driveName).Free
    $requiredGb = [math]::Round($RequiredBytes / 1GB)
    $freeGb = [math]::Round($freeBytes / 1GB, 1)
    Write-Host "Scratch disk ${driveName}: free space ${freeGb} GB (required: ${requiredGb} GB)"
    if ($freeBytes -lt $RequiredBytes) {
        throw "Insufficient free space on ${driveName}:. Need at least ${requiredGb} GB, but only ${freeGb} GB is available."
    }
}

function Invoke-RegLoad {
    param(
        [string]$HiveName,
        [string]$FilePath
    )
    reg load "HKLM\$HiveName" $FilePath
    Assert-CommandExitCode -Label "reg load HKLM\$HiveName"
}

function Invoke-RegUnload {
    param([string]$HiveName)
    reg unload "HKLM\$HiveName"
    Assert-CommandExitCode -Label "reg unload HKLM\$HiveName"
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
}

function Remove-RegistryValue {
    param ([string]$path)
    & 'reg' 'delete' $path '/f' | Out-Null
    if ($LASTEXITCODE -ne 0 -and $LASTEXITCODE -ne 1) {
        throw "reg delete $path failed with exit code $LASTEXITCODE"
    }
}

function Initialize-Oscdimg {
    param([string]$HostArchitecture)
    $adkArch = switch ($HostArchitecture) { 'AMD64' { 'amd64' } 'ARM64' { 'arm64' } default { $HostArchitecture.ToLowerInvariant() } }
    $ADKDepTools = "C:\Program Files (x86)\Windows Kits\10\Assessment and Deployment Kit\Deployment Tools\$adkArch\Oscdimg"
    $localOSCDIMGPath = "$PSScriptRoot\oscdimg.exe"
    if ([System.IO.Directory]::Exists($ADKDepTools)) {
        Write-Host "Will be using oscdimg.exe from system ADK."
        return "$ADKDepTools\oscdimg.exe"
    }
    if (-not (Test-Path -Path $localOSCDIMGPath)) {
        Write-Host "Downloading oscdimg.exe..."
        $url = "https://msdl.microsoft.com/download/symbols/oscdimg.exe/3D44737265000/oscdimg.exe"
        Invoke-WebRequest -Uri $url -OutFile $localOSCDIMGPath
        if (-not (Test-Path $localOSCDIMGPath)) {
            throw "Failed to download oscdimg.exe."
        }
    }
    return $localOSCDIMGPath
}

if ((Get-ExecutionPolicy) -eq 'Restricted') {
    Write-Host "Your current PowerShell Execution Policy is set to Restricted, which prevents scripts from running. Do you want to change it to RemoteSigned? (yes/no)"
    $response = Read-Host
    if ($response -eq 'yes') {
        Set-ExecutionPolicy RemoteSigned -Scope CurrentUser -Confirm:$false
    } else {
        Write-Host "The script cannot be run without changing the execution policy. Exiting..."
        exit
    }
}

# Check and run the script as admin if required
$adminSID = New-Object System.Security.Principal.SecurityIdentifier("S-1-5-32-544")
$adminGroup = $adminSID.Translate([System.Security.Principal.NTAccount])
$myWindowsID=[System.Security.Principal.WindowsIdentity]::GetCurrent()
$myWindowsPrincipal=new-object System.Security.Principal.WindowsPrincipal($myWindowsID)
$adminRole=[System.Security.Principal.WindowsBuiltInRole]::Administrator
if (! $myWindowsPrincipal.IsInRole($adminRole))
{
    Write-Host "Restarting Tiny11 image creator as admin in a new window, you can close this one."
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-NoExit', '-File', $PSCommandPath)
    $newProcess = new-object System.Diagnostics.ProcessStartInfo "PowerShell"
    $newProcess.Arguments = Build-ProcessArgumentString -Arguments $argList
    $newProcess.Verb = "runas"
    [System.Diagnostics.Process]::Start($newProcess) | Out-Null
    exit
}
Start-Transcript -Path "$PSScriptRoot\tiny11.log"

trap {
    Write-Error "Script failed: $($_.Exception.Message)"
    Stop-Transcript -ErrorAction SilentlyContinue
    Read-Host "Press Enter to exit"
    exit 1
}

Write-Host "Welcome to tiny11 core builder! BETA 09-05-25"
Write-Host "This script generates a significantly reduced Windows 11 image. However, it's not suitable for regular use due to its lack of serviceability - you can't add languages, updates, or features post-creation. tiny11 Core is not a full Windows 11 substitute but a rapid testing or development tool, potentially useful for VM environments."
Write-Host "Do you want to continue? (y/n)"
$continueChoice = Read-Host

if ($continueChoice -eq 'y') {
    Write-Host "Off we go..."
Start-Sleep -Seconds 3
Clear-Host

$mainOSDrive = $env:SystemDrive
$hostArchitecture = $Env:PROCESSOR_ARCHITECTURE
Test-CoremakerPrerequisites
Test-ScratchDiskSpace -ScratchPath $mainOSDrive
$OSCDIMG = Initialize-Oscdimg -HostArchitecture $hostArchitecture
New-Item -ItemType Directory -Force -Path "$mainOSDrive\tiny11\sources" | Out-Null
do {
    $driveInput = (Read-Host "Please enter the drive letter for the Windows 11 image").Trim() -replace ':$', ''
    if ($driveInput -match '^[c-zC-Z]$') {
        $DriveLetter = $driveInput + ":"
    } else {
        Write-Host "Invalid drive letter. Enter a single letter (e.g. E)."
        $DriveLetter = $null
    }
} while (-not $DriveLetter)

if ((Test-Path "$DriveLetter\sources\boot.wim") -eq $false -or (Test-Path "$DriveLetter\sources\install.wim") -eq $false) {
    if ((Test-Path "$DriveLetter\sources\install.esd") -eq $true) {
        Write-Host "Found install.esd, converting to install.wim..."
        &  'dism' '/English' "/Get-WimInfo" "/wimfile:$DriveLetter\sources\install.esd"
        $index = Read-Host "Please enter the image index"
        Write-Host ' '
        Write-Host 'Converting install.esd to install.wim. This may take a while...'
        & 'DISM' /Export-Image /SourceImageFile:"$DriveLetter\sources\install.esd" /SourceIndex:$index /DestinationImageFile:"$mainOSDrive\tiny11\sources\install.wim" /Compress:max /CheckIntegrity
    } else {
        Write-Host "Can't find Windows OS Installation files in the specified Drive Letter.."
        Write-Host "Please enter the correct DVD Drive Letter.."
        exit
    }
}

Write-Host "Copying Windows image..."
Copy-Item -Path "$DriveLetter\*" -Destination "$mainOSDrive\tiny11" -Recurse -Force | Out-Null
Set-ItemProperty -Path "$mainOSDrive\tiny11\sources\install.esd" -Name IsReadOnly -Value $false -ErrorAction 'Continue' | Out-Null
Remove-Item "$mainOSDrive\tiny11\sources\install.esd" -ErrorAction 'Continue' | Out-Null
Write-Host "Copy complete!"
Start-Sleep -Seconds 2
Clear-Host
Write-Host "Getting image information:"
$index = $null
$ImagesIndex = (Get-WindowsImage -ImagePath $mainOSDrive\tiny11\sources\install.wim).ImageIndex
while ($ImagesIndex -notcontains $index) {
    Get-WindowsImage -ImagePath $mainOSDrive\tiny11\sources\install.wim
    $index = [int](Read-Host "Please enter the image index")
}
Write-Host "Mounting Windows image. This may take a while."
$wimFilePath = "$($env:SystemDrive)\tiny11\sources\install.wim" 
& takeown "/F" $wimFilePath 
& icacls $wimFilePath "/grant" "$($adminGroup.Value):(F)"
try {
    Set-ItemProperty -Path $wimFilePath -Name IsReadOnly -Value $false -ErrorAction Stop
} catch {
    # This block will catch the error and suppress it.
}
New-Item -ItemType Directory -Force -Path "$mainOSDrive\scratchdir" | Out-Null
& dism /English "/mount-image" "/imagefile:$($env:SystemDrive)\tiny11\sources\install.wim" "/index:$index" "/mountdir:$($env:SystemDrive)\scratchdir"

$imageIntl = & dism /English /Get-Intl "/Image:$($env:SystemDrive)\scratchdir"
$languageLine = $imageIntl -split '\n' | Where-Object { $_ -match 'Default system UI language : ([a-zA-Z]{2}-[a-zA-Z]{2})' }

if ($languageLine) {
    $languageCode = $Matches[1]
    Write-Host "Default system UI language code: $languageCode"
} else {
    $languageCode = 'en-US'
    Write-Host "Default system UI language code not found. Falling back to $languageCode for language package removal."
}

$imageInfo = & 'dism' '/English' '/Get-WimInfo' "/wimFile:$($env:SystemDrive)\tiny11\sources\install.wim" "/index:$index"
$lines = $imageInfo -split '\r?\n'

foreach ($line in $lines) {
    if ($line -like '*Architecture : *') {
        $architecture = $line -replace 'Architecture : ',''
        # If the architecture is x64, replace it with amd64
        if ($architecture -eq 'x64') {
            $architecture = 'amd64'
        }
        Write-Host "Architecture: $architecture"
        break
    }
}

if (-not $architecture) {
    Write-Host "Architecture information not found."
}

Write-Host "Mounting complete! Performing removal of applications..."

$packages = & 'dism' '/English' "/image:$($env:SystemDrive)\scratchdir" '/Get-ProvisionedAppxPackages' |
    ForEach-Object {
        if ($_ -match 'PackageName : (.*)') {
            $matches[1]
        }
    }
$packagePrefixes = 'Clipchamp.Clipchamp_', 'Microsoft.BingNews_', 'Microsoft.BingWeather_', 'Microsoft.GamingApp_', 'Microsoft.GetHelp_', 'Microsoft.Getstarted_', 'Microsoft.MicrosoftOfficeHub_', 'Microsoft.MicrosoftSolitaireCollection_', 'Microsoft.People_', 'Microsoft.PowerAutomateDesktop_', 'Microsoft.Todos_', 'Microsoft.WindowsAlarms_', 'microsoft.windowscommunicationsapps_', 'Microsoft.WindowsFeedbackHub_', 'Microsoft.WindowsMaps_', 'Microsoft.WindowsSoundRecorder_', 'Microsoft.Xbox.TCUI_', 'Microsoft.XboxGamingOverlay_', 'Microsoft.XboxGameOverlay_', 'Microsoft.XboxSpeechToTextOverlay_', 'Microsoft.YourPhone_', 'Microsoft.ZuneMusic_', 'Microsoft.ZuneVideo_', 'MicrosoftCorporationII.MicrosoftFamily_', 'MicrosoftCorporationII.QuickAssist_', 'MicrosoftTeams_', 'Microsoft.549981C3F5F10_', 'Microsoft.Windows.Copilot', 'MSTeams_', 'Microsoft.OutlookForWindows_', 'Microsoft.Windows.Teams_', 'Microsoft.Copilot_'

$packagesToRemove = $packages | Where-Object {
    $packageName = $_
    $packagePrefixes -contains ($packagePrefixes | Where-Object { $packageName -like "$_*" })
}
foreach ($package in $packagesToRemove) {
    write-host "Removing $package :"
    & 'dism' '/English' "/image:$($env:SystemDrive)\scratchdir" '/Remove-ProvisionedAppxPackage' "/PackageName:$package"
}

Write-Host "Removing of system apps complete! Now proceeding to removal of system packages..."
Start-Sleep -Seconds 1
Clear-Host

$scratchDir = "$($env:SystemDrive)\scratchdir"
$packagePatterns = @(
    "Microsoft-Windows-InternetExplorer-Optional-Package~31bf3856ad364e35",
    "Microsoft-Windows-Kernel-LA57-FoD-Package~31bf3856ad364e35~amd64",
    "Microsoft-Windows-LanguageFeatures-Handwriting-$languageCode-Package~31bf3856ad364e35",
    "Microsoft-Windows-LanguageFeatures-OCR-$languageCode-Package~31bf3856ad364e35",
    "Microsoft-Windows-LanguageFeatures-Speech-$languageCode-Package~31bf3856ad364e35",
    "Microsoft-Windows-LanguageFeatures-TextToSpeech-$languageCode-Package~31bf3856ad364e35",
    "Microsoft-Windows-MediaPlayer-Package~31bf3856ad364e35",
    "Microsoft-Windows-Wallpaper-Content-Extended-FoD-Package~31bf3856ad364e35",
    "Windows-Defender-Client-Package~31bf3856ad364e35~",
    "Microsoft-Windows-WordPad-FoD-Package~",
    "Microsoft-Windows-TabletPCMath-Package~",
    "Microsoft-Windows-StepsRecorder-Package~"

)

# Get all packages
$allPackages = & dism /image:$scratchDir /Get-Packages /Format:Table
$allPackages = $allPackages -split "`n" | Select-Object -Skip 1

foreach ($packagePattern in $packagePatterns) {
    # Filter the packages to remove
    $packagesToRemove = $allPackages | Where-Object { $_ -like "$packagePattern*" }

    foreach ($package in $packagesToRemove) {
        # Extract the package identity
        $packageIdentity = ($package -split "\s+")[0]

        Write-Host "Removing $packageIdentity..."
        & dism /image:$scratchDir /Remove-Package /PackageName:$packageIdentity 
    }
}

Write-Host "Do you want to enable .NET 3.5? This cannot be done after the image has been created! (y/n)"
$dotnetChoice = Read-Host

if ($dotnetChoice -eq 'y') {
    Write-Host "Enabling .NET 3.5..."
    & 'dism'  "/image:$scratchDir" '/enable-feature' '/featurename:NetFX3' '/All' "/source:$($env:SystemDrive)\tiny11\sources\sxs" 
    Write-Host ".NET 3.5 has been enabled."
}
elseif ($dotnetChoice -eq 'n') {
    Write-Host "You chose not to enable .NET 3.5. Continuing..."
}
else {
    Write-Host "Invalid input. Please enter 'y' to enable .NET 3.5 or 'n' to continue without installing .net 3.5."
}
Write-Host "Removing Edge:"
Remove-Item -Path "$mainOSDrive\scratchdir\Program Files (x86)\Microsoft\Edge" -Recurse -Force | Out-Null
Remove-Item -Path "$mainOSDrive\scratchdir\Program Files (x86)\Microsoft\EdgeUpdate" -Recurse -Force | Out-Null
Remove-Item -Path "$mainOSDrive\scratchdir\Program Files (x86)\Microsoft\EdgeCore" -Recurse -Force | Out-Null
if ($architecture -eq 'amd64') {
    $folderPath = Get-ChildItem -Path "$mainOSDrive\scratchdir\Windows\WinSxS" -Filter "amd64_microsoft-edge-webview_31bf3856ad364e35*" -Directory | Select-Object -ExpandProperty FullName

    if ($folderPath) {
        & 'takeown' '/f' $folderPath '/r' | Out-Null
        & icacls $folderPath  "/grant" "$($adminGroup.Value):(F)" '/T' '/C' | Out-Null
        Remove-Item -Path $folderPath -Recurse -Force | Out-Null
    } else {
        Write-Host "Folder not found."
    }
} elseif ($architecture -eq 'arm64') {
    $folderPath = Get-ChildItem -Path "$mainOSDrive\scratchdir\Windows\WinSxS" -Filter "arm64_microsoft-edge-webview_31bf3856ad364e35*" -Directory | Select-Object -ExpandProperty FullName

    if ($folderPath) {
        & 'takeown' '/f' $folderPath '/r'| Out-Null
        & icacls $folderPath  "/grant" "$($adminGroup.Value):(F)" '/T' '/C' | Out-Null
        Remove-Item -Path $folderPath -Recurse -Force | Out-Null
    } else {
        Write-Host "Folder not found."
    }
} else {
    Write-Host "Unknown architecture: $architecture"
}
& 'takeown' '/f' "$mainOSDrive\scratchdir\Windows\System32\Microsoft-Edge-Webview" '/r' | Out-Null
& 'icacls' "$mainOSDrive\scratchdir\Windows\System32\Microsoft-Edge-Webview" '/grant' "$($adminGroup.Value):(F)" '/T' '/C' | Out-Null
Remove-Item -Path "$mainOSDrive\scratchdir\Windows\System32\Microsoft-Edge-Webview" -Recurse -Force -ErrorAction SilentlyContinue | Out-Null
Write-Host "Removing WinRE"
& 'takeown' '/f' "$mainOSDrive\scratchdir\Windows\System32\Recovery" '/r'
& 'icacls' "$mainOSDrive\scratchdir\Windows\System32\Recovery" '/grant' 'Administrators:F' '/T' '/C'
Remove-Item -Path "$mainOSDrive\scratchdir\Windows\System32\Recovery\winre.wim" -Recurse -Force
New-Item -Path "$mainOSDrive\scratchdir\Windows\System32\Recovery\winre.wim" -ItemType File -Force
Write-Host "Removing OneDrive:"
if (Test-Path "$mainOSDrive\scratchdir\Windows\System32\OneDriveSetup.exe") {
    & 'takeown' '/f' "$mainOSDrive\scratchdir\Windows\System32\OneDriveSetup.exe" | Out-Null
    & 'icacls' "$mainOSDrive\scratchdir\Windows\System32\OneDriveSetup.exe" '/grant' "$($adminGroup.Value):(F)" '/T' '/C' | Out-Null
    Remove-Item -Path "$mainOSDrive\scratchdir\Windows\System32\OneDriveSetup.exe" -Force -ErrorAction SilentlyContinue | Out-Null
} else {
    Write-Host "OneDriveSetup.exe not present, skipping."
}
Write-Host "Removal complete!"
Start-Sleep -Seconds 2
Clear-Host
Write-Host "Taking ownership of the WinSxS folder. This might take a while..."
& 'takeown' '/f' "$mainOSDrive\scratchdir\Windows\WinSxS" '/r'
& 'icacls' "$mainOSDrive\scratchdir\Windows\WinSxS" '/grant' "$($adminGroup.Value):(F)" '/T' '/C'
Write-host "Complete!"
Start-Sleep -Seconds 2
Clear-Host
Write-Host "Preparing..."
$folderPath = Join-Path -Path $mainOSDrive -ChildPath "\scratchdir\Windows\WinSxS_edit"
$sourceDirectory = "$mainOSDrive\scratchdir\Windows\WinSxS"
$destinationDirectory = "$mainOSDrive\scratchdir\Windows\WinSxS_edit"
New-Item -Path $folderPath -ItemType Directory
if ($architecture -eq "amd64") {
   $dirsToCopy = @(
        "x86_microsoft.windows.common-controls_6595b64144ccf1df_*",
        "x86_microsoft.windows.gdiplus_6595b64144ccf1df_*",    
        "x86_microsoft.windows.i..utomation.proxystub_6595b64144ccf1df_*",
        "x86_microsoft.windows.isolationautomation_6595b64144ccf1df_*",
        "x86_microsoft-windows-s..ngstack-onecorebase_31bf3856ad364e35_*",
        "x86_microsoft-windows-s..stack-termsrv-extra_31bf3856ad364e35_*",
        "x86_microsoft-windows-servicingstack_31bf3856ad364e35_*",
        "x86_microsoft-windows-servicingstack-inetsrv_*",
        "x86_microsoft-windows-servicingstack-onecore_*",
        "amd64_microsoft.vc80.crt_1fc8b3b9a1e18e3b_*",
        "amd64_microsoft.vc90.crt_1fc8b3b9a1e18e3b_*",
        "amd64_microsoft.windows.c..-controls.resources_6595b64144ccf1df_*",
        "amd64_microsoft.windows.common-controls_6595b64144ccf1df_*",
        "amd64_microsoft.windows.gdiplus_6595b64144ccf1df_*",
        "amd64_microsoft.windows.i..utomation.proxystub_6595b64144ccf1df_*",
        "amd64_microsoft.windows.isolationautomation_6595b64144ccf1df_*",
        "amd64_microsoft-windows-s..stack-inetsrv-extra_31bf3856ad364e35_*",
        "amd64_microsoft-windows-s..stack-msg.resources_31bf3856ad364e35_*",
        "amd64_microsoft-windows-s..stack-termsrv-extra_31bf3856ad364e35_*",
        "amd64_microsoft-windows-servicingstack_31bf3856ad364e35_*",
        "amd64_microsoft-windows-servicingstack-inetsrv_31bf3856ad364e35_*",
        "amd64_microsoft-windows-servicingstack-msg_31bf3856ad364e35_*",
        "amd64_microsoft-windows-servicingstack-onecore_31bf3856ad364e35_*",
        "Catalogs",
        "FileMaps",
        "Fusion",
        "InstallTemp",
        "Manifests",
        "x86_microsoft.vc80.crt_1fc8b3b9a1e18e3b_*",
        "x86_microsoft.vc90.crt_1fc8b3b9a1e18e3b_*",
        "x86_microsoft.windows.c..-controls.resources_6595b64144ccf1df_*"
    )
}
elseif ($architecture -eq "arm64") {
    # Specify the list of files to copy
     $dirsToCopy = @(
        "arm64_microsoft-windows-servicingstack-onecore_31bf3856ad364e35_*",
        "Catalogs",
        "FileMaps",
        "Fusion",
        "InstallTemp",
        "Manifests",
        "SettingsManifests",
        "Temp",
        "x86_microsoft.vc80.crt_1fc8b3b9a1e18e3b_*",
        "x86_microsoft.vc90.crt_1fc8b3b9a1e18e3b_*",
        "x86_microsoft.windows.c..-controls.resources_6595b64144ccf1df_*",
        "x86_microsoft.windows.common-controls_6595b64144ccf1df_*",
        "x86_microsoft.windows.gdiplus_6595b64144ccf1df_*",
        "x86_microsoft.windows.i..utomation.proxystub_6595b64144ccf1df_*",
        "x86_microsoft.windows.isolationautomation_6595b64144ccf1df_*",
        "arm_microsoft.windows.c..-controls.resources_6595b64144ccf1df_*",
        "arm_microsoft.windows.common-controls_6595b64144ccf1df_*",
        "arm_microsoft.windows.gdiplus_6595b64144ccf1df_*",
        "arm_microsoft.windows.i..utomation.proxystub_6595b64144ccf1df_*",
        "arm_microsoft.windows.isolationautomation_6595b64144ccf1df_*",
        "arm64_microsoft.vc80.crt_1fc8b3b9a1e18e3b_*",
        "arm64_microsoft.vc90.crt_1fc8b3b9a1e18e3b_*",
        "arm64_microsoft.windows.c..-controls.resources_6595b64144ccf1df_*",
        "arm64_microsoft.windows.common-controls_6595b64144ccf1df_*",
        "arm64_microsoft.windows.gdiplus_6595b64144ccf1df_*",
        "arm64_microsoft.windows.i..utomation.proxystub_6595b64144ccf1df_*",
        "arm64_microsoft.windows.isolationautomation_6595b64144ccf1df_*",
        "arm64_microsoft-windows-servicing-adm_31bf3856ad364e35_*",
        "arm64_microsoft-windows-servicingcommon_31bf3856ad364e35_*",
        "arm64_microsoft-windows-servicing-onecore-uapi_31bf3856ad364e35_*",
        "arm64_microsoft-windows-servicingstack_31bf3856ad364e35_*",
        "arm64_microsoft-windows-servicingstack-inetsrv_31bf3856ad364e35_*",
        "arm64_microsoft-windows-servicingstack-msg_31bf3856ad364e35_*"
    )
} else {
    throw "Unsupported architecture for WinSxS trimming: $architecture"
}

foreach ($dir in $dirsToCopy) {
    $sourceDirs = Get-ChildItem -Path $sourceDirectory -Filter $dir -Directory
    foreach ($sourceDir in $sourceDirs) {
        $destDir = Join-Path -Path $destinationDirectory -ChildPath $sourceDir.Name
        Write-Host "Copying $sourceDir.FullName to $destDir"
        Copy-Item -Path $sourceDir.FullName -Destination $destDir -Recurse -Force
    }
}

Write-Host "Deleting WinSxS. This may take a while..."
        Remove-Item -Path $mainOSDrive\scratchdir\Windows\WinSxS -Recurse -Force

Rename-Item -Path "$mainOSDrive\scratchdir\Windows\WinSxS_edit" -NewName "WinSxS"
Write-Host "Complete!"

Write-Host "Loading registry..."
Invoke-RegLoad -HiveName 'zCOMPONENTS' -FilePath "$mainOSDrive\scratchdir\Windows\System32\config\COMPONENTS"
Invoke-RegLoad -HiveName 'zDEFAULT' -FilePath "$mainOSDrive\scratchdir\Windows\System32\config\default"
Invoke-RegLoad -HiveName 'zNTUSER' -FilePath "$mainOSDrive\scratchdir\Users\Default\ntuser.dat"
Invoke-RegLoad -HiveName 'zSOFTWARE' -FilePath "$mainOSDrive\scratchdir\Windows\System32\config\SOFTWARE"
Invoke-RegLoad -HiveName 'zSYSTEM' -FilePath "$mainOSDrive\scratchdir\Windows\System32\config\SYSTEM"
Write-Host "Bypassing system requirements(on the system image):"
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
Write-Host "Disabling Sponsored Apps:"
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
Write-Host "Enabling Local Accounts on OOBE:"
Set-RegistryValue 'HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\OOBE' 'BypassNRO' 'REG_DWORD' '1'
Copy-Item -Path "$PSScriptRoot\autounattend.xml" -Destination "$mainOSDrive\scratchdir\Windows\System32\Sysprep\autounattend.xml" -Force | Out-Null
Write-Host "Disabling Reserved Storage:"
Set-RegistryValue 'HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\ReserveManager' 'ShippedWithReserves' 'REG_DWORD' '0'
Write-Host "Disabling BitLocker Device Encryption"
Set-RegistryValue 'HKLM\zSYSTEM\ControlSet001\Control\BitLocker' 'PreventDeviceEncryption' 'REG_DWORD' '1'
Write-Host "Disabling Chat icon:"
Set-RegistryValue 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\Windows Chat' 'ChatIcon' 'REG_DWORD' '3'
Set-RegistryValue 'HKLM\zNTUSER\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'TaskbarMn' 'REG_DWORD' '0'
Write-Host "Removing Edge related registries"
Remove-RegistryValue "HKEY_LOCAL_MACHINE\zSOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\Microsoft Edge"
Remove-RegistryValue "HKEY_LOCAL_MACHINE\zSOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\Microsoft Edge Update"
Write-Host "Disabling OneDrive folder backup"
Set-RegistryValue "HKLM\zSOFTWARE\Policies\Microsoft\Windows\OneDrive" "DisableFileSyncNGSC" "REG_DWORD" "1"
Write-Output "Disabling Search Highlights:"
Set-RegistryValue "HKLM\zSoftware\Microsoft\Windows\CurrentVersion\SearchSettings" "IsDynamicSearchBoxEnabled" "REG_DWORD" "0"
Write-Host "Disabling Telemetry:"
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
Write-Host "Prevents installation or DevHome and Outlook:"
Set-RegistryValue 'HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Orchestrator\UScheduler\OutlookUpdate' 'workCompleted' 'REG_DWORD' '1'
Set-RegistryValue 'HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Orchestrator\UScheduler\DevHomeUpdate' 'workCompleted' 'REG_DWORD' '1'
Remove-RegistryValue 'HKLM\zSOFTWARE\Microsoft\WindowsUpdate\Orchestrator\UScheduler_Oobe\OutlookUpdate'
Remove-RegistryValue 'HKLM\zSOFTWARE\Microsoft\WindowsUpdate\Orchestrator\UScheduler_Oobe\DevHomeUpdate'
Write-Host "Disabling Copilot"
Set-RegistryValue 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\WindowsCopilot' 'TurnOffWindowsCopilot' 'REG_DWORD' '1'
Set-RegistryValue 'HKLM\zSOFTWARE\Policies\Microsoft\Edge' 'HubsSidebarEnabled' 'REG_DWORD' '0'
Set-RegistryValue 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\Explorer' 'DisableSearchBoxSuggestions' 'REG_DWORD' '1'
Write-Host "Prevents installation of Teams:"
Set-RegistryValue 'HKLM\zSOFTWARE\Policies\Microsoft\Teams' 'DisableInstallation' 'REG_DWORD' '1'
Write-Host "Prevent installation of New Outlook":
Set-RegistryValue 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\Windows Mail' 'PreventRun' 'REG_DWORD' '1'
$tasksPath = "$mainOSDrive\scratchdir\Windows\System32\Tasks"

Write-Host "Deleting scheduled task definition files..."

# Application Compatibility Appraiser
Remove-Item -Path "$tasksPath\Microsoft\Windows\Application Experience\Microsoft Compatibility Appraiser" -Force -ErrorAction SilentlyContinue

# Customer Experience Improvement Program (removes the entire folder and all tasks within it)
Remove-Item -Path "$tasksPath\Microsoft\Windows\Customer Experience Improvement Program" -Recurse -Force -ErrorAction SilentlyContinue

# Program Data Updater
Remove-Item -Path "$tasksPath\Microsoft\Windows\Application Experience\ProgramDataUpdater" -Force -ErrorAction SilentlyContinue

# Chkdsk Proxy
Remove-Item -Path "$tasksPath\Microsoft\Windows\Chkdsk\Proxy" -Force -ErrorAction SilentlyContinue

# Windows Error Reporting (QueueReporting)
Remove-Item -Path "$tasksPath\Microsoft\Windows\Windows Error Reporting\QueueReporting" -Force -ErrorAction SilentlyContinue

Write-Host "Task files have been deleted."
Write-Host "Disabling Windows Update..."
Set-RegistryValue "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce" 'StopWUPostOOBE1' 'REG_SZ' 'net stop wuauserv'
Set-RegistryValue "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce" 'StopWUPostOOBE2' 'REG_SZ' 'sc stop wuauserv'
Set-RegistryValue "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce" 'StopWUPostOOBE3' 'REG_SZ' 'sc config wuauserv start= disabled'
Set-RegistryValue "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce" 'DisbaleWUPostOOBE1' 'REG_SZ' 'reg add HKLM\SYSTEM\CurrentControlSet\Services\wuauserv /v Start /t REG_DWORD /d 4 /f'
Set-RegistryValue "HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce" 'DisbaleWUPostOOBE2' 'REG_SZ' 'reg add HKLM\SYSTEM\ControlSet001\Services\wuauserv /v Start /t REG_DWORD /d 4 /f'
Set-RegistryValue 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\WindowsUpdate' 'DoNotConnectToWindowsUpdateInternetLocations' 'REG_DWORD' '1'
Set-RegistryValue 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\WindowsUpdate' 'DisableWindowsUpdateAccess' 'REG_DWORD' '1'
Set-RegistryValue 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\WindowsUpdate' 'WUServer' 'REG_SZ' 'localhost'
Set-RegistryValue 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\WindowsUpdate' 'WUStatusServer' 'REG_SZ' 'localhost'
Set-RegistryValue 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\WindowsUpdate' 'UpdateServiceUrlAlternate' 'REG_SZ' 'localhost'
Set-RegistryValue 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU' 'UseWUServer' 'REG_DWORD' '1'
Set-RegistryValue 'HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\OOBE' 'DisableOnline' 'REG_DWORD' '1'
Set-RegistryValue 'HKLM\zSYSTEM\ControlSet001\Services\wuauserv' 'Start' 'REG_DWORD' '4'
Remove-RegistryValue 'HKLM\zSYSTEM\ControlSet001\Services\WaaSMedicSVC'
Remove-RegistryValue 'HKLM\zSYSTEM\ControlSet001\Services\UsoSvc'
Set-RegistryValue 'HKEY_LOCAL_MACHINE\zSOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU' 'NoAutoUpdate' 'REG_DWORD' '1'
Write-Host "Disabling Windows Defender"
# Set registry values for Windows Defender services
$servicePaths = @(
    "WinDefend",
    "WdNisSvc",
    "WdNisDrv",
    "WdFilter",
    "Sense"
)

foreach ($path in $servicePaths) {
    Set-ItemProperty -Path "HKLM:\zSYSTEM\ControlSet001\Services\$path" -Name "Start" -Value 4
}
Set-RegistryValue 'HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer' 'SettingsPageVisibility' 'REG_SZ' 'hide:virus;windowsupdate'
Write-Host "Tweaking complete!"
Write-Host "Unmounting Registry..."
Invoke-RegUnload -HiveName 'zCOMPONENTS'
Invoke-RegUnload -HiveName 'zDEFAULT'
Invoke-RegUnload -HiveName 'zNTUSER'
Invoke-RegUnload -HiveName 'zSOFTWARE'
Invoke-RegUnload -HiveName 'zSYSTEM'
Write-Host "Cleaning up image..."
& 'dism' '/English' "/image:$mainOSDrive\scratchdir" '/Cleanup-Image' '/StartComponentCleanup' '/ResetBase' | Out-Null
Write-Host "Cleanup complete."
Write-Host ' '
Write-Host "Unmounting image..."
& 'dism' '/English' '/unmount-image' "/mountdir:$mainOSDrive\scratchdir" '/commit'
Write-Host "Exporting image..."
& 'dism' '/English' '/Export-Image' "/SourceImageFile:$mainOSDrive\tiny11\sources\install.wim" "/SourceIndex:$index" "/DestinationImageFile:$mainOSDrive\tiny11\sources\install2.wim" '/compress:max'
Remove-Item -Path "$mainOSDrive\tiny11\sources\install.wim" -Force | Out-Null
Rename-Item -Path "$mainOSDrive\tiny11\sources\install2.wim" -NewName "install.wim" | Out-Null
Write-Host "Windows image completed. Continuing with boot.wim."
Start-Sleep -Seconds 2
Clear-Host
Write-Host "Mounting boot image:"
$wimFilePath = "$($env:SystemDrive)\tiny11\sources\boot.wim" 
& takeown "/F" $wimFilePath | Out-Null
& icacls $wimFilePath "/grant" "$($adminGroup.Value):(F)"
Set-ItemProperty -Path $wimFilePath -Name IsReadOnly -Value $false
& 'dism' '/English' '/mount-image' "/imagefile:$mainOSDrive\tiny11\sources\boot.wim" '/index:2' "/mountdir:$mainOSDrive\scratchdir"
Write-Host "Loading registry..."
Invoke-RegLoad -HiveName 'zCOMPONENTS' -FilePath "$mainOSDrive\scratchdir\Windows\System32\config\COMPONENTS"
Invoke-RegLoad -HiveName 'zDEFAULT' -FilePath "$mainOSDrive\scratchdir\Windows\System32\config\default"
Invoke-RegLoad -HiveName 'zNTUSER' -FilePath "$mainOSDrive\scratchdir\Users\Default\ntuser.dat"
Invoke-RegLoad -HiveName 'zSOFTWARE' -FilePath "$mainOSDrive\scratchdir\Windows\System32\config\SOFTWARE"
Invoke-RegLoad -HiveName 'zSYSTEM' -FilePath "$mainOSDrive\scratchdir\Windows\System32\config\SYSTEM"
Write-Host "Bypassing system requirements(on the setup image):"
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
Set-RegistryValue 'HKEY_LOCAL_MACHINE\zSYSTEM\Setup' 'CmdLine' 'REG_SZ' 'X:\sources\setup.exe'
Write-Host "Tweaking complete!"
Write-Host "Unmounting Registry..."
Invoke-RegUnload -HiveName 'zCOMPONENTS'
Invoke-RegUnload -HiveName 'zDEFAULT'
Invoke-RegUnload -HiveName 'zNTUSER'
Invoke-RegUnload -HiveName 'zSOFTWARE'
Invoke-RegUnload -HiveName 'zSYSTEM'
Write-Host "Unmounting image..."
& 'dism' '/English' '/unmount-image' "/mountdir:$mainOSDrive\scratchdir" '/commit'
Clear-Host
Write-Host "Exporting ESD. This may take a while..."
& dism /Export-Image /SourceImageFile:"$mainOSDrive\tiny11\sources\install.wim" /SourceIndex:1 /DestinationImageFile:"$mainOSDrive\tiny11\sources\install.esd" /Compress:recovery
Remove-Item "$mainOSDrive\tiny11\sources\install.wim" -ErrorAction SilentlyContinue | Out-Null
Write-Host "The tiny11 image is now completed. Proceeding with the making of the ISO..."
Write-Host "Creating ISO image..."
& "$OSCDIMG" '-m' '-o' '-u2' '-udfver102' "-bootdata:2#p0,e,b$mainOSDrive\tiny11\boot\etfsboot.com#pEF,e,b$mainOSDrive\tiny11\efi\microsoft\boot\efisys.bin" "$mainOSDrive\tiny11" "$PSScriptRoot\tiny11.iso"
Assert-CommandExitCode -Label 'oscdimg ISO creation'

# Finishing up
Write-Host "Creation completed! Press any key to exit the script..."
Read-Host "Press Enter to continue"
Write-Host "Performing Cleanup..."
Remove-Item -Path "$mainOSDrive\tiny11" -Recurse -Force | Out-Null
Remove-Item -Path "$mainOSDrive\scratchdir" -Recurse -Force | Out-Null

# Stop the transcript
Stop-Transcript

exit
}
elseif ($continueChoice -eq 'n') {
    Write-Host "You chose not to continue. The script will now exit."
    exit
}
else {
    Write-Host "Invalid input. Please enter 'y' to continue or 'n' to exit."
}
