# Install Joyfiles

Joyfiles is a file manager that you control with a game controller.
This page tells you how to download Joyfiles and how to add it to Steam as a non-Steam game.
After you add it, you start Joyfiles from Game Mode and you do not need a mouse.

## Download

Open the [Releases page](https://github.com/BlueBeret/joyfiles/releases) of the Joyfiles repository on GitHub.
Download one file from the newest release.

| Your device | File to download |
| --- | --- |
| Steam Deck or other SteamOS device | `joyfiles-VERSION-x86_64.AppImage` |
| Other Linux computer | `joyfiles-VERSION-x86_64.AppImage` |
| Windows computer or Windows handheld | `joyfiles-VERSION-windows-x86_64.zip` |

VERSION is the version number of the release.
The release also has a file named `SHA256SUMS`.
You can use this file to check your download.

## Check the download (optional)

On Linux, open a terminal in the folder of the downloaded files.
Run this command:

```
sha256sum --check --ignore-missing SHA256SUMS
```

The output must show OK for your file.

On Windows, open PowerShell in the folder of the downloaded files.
Run this command:

```
Get-FileHash .\joyfiles-VERSION-windows-x86_64.zip
```

Compare the hash with the line for your file in `SHA256SUMS`.

## Install on SteamOS

You use Desktop Mode one time.
After that, you use Game Mode only.

### Step 1: Prepare the file in Desktop Mode

1. Press the Steam button.
2. Select Power, then select Switch to Desktop.
3. Open the web browser and download the AppImage file from the Releases page.
4. Open the Dolphin file manager.
5. Make a folder named `Applications` in your home folder.
6. Move the AppImage file into the `Applications` folder.
7. Rename the file to `joyfiles.AppImage`.
8. Right click the file and select Properties.
9. Open the Permissions tab and select Is executable.
10. Select OK.

Steam stores the path of the file.
When the file has a fixed name, the Steam shortcut still works after an update.

### Step 2: Add Joyfiles to Steam in Desktop Mode

1. Open Steam.
2. Select Add a Game at the bottom left, then select Add a Non-Steam Game.
3. Select Browse.
4. Set the file type filter to All Files.
5. Select `joyfiles.AppImage` in the `Applications` folder, then select Open.
6. Select Add Selected Programs.

### Step 3: Choose the controller template in Game Mode

1. Select Return to Gaming Mode on the desktop.
2. Press the Steam button and select Library.
3. Open the Non-Steam tab and select Joyfiles.
4. Select the Controller icon.
5. Select Current Layout and open the Templates list.
6. Select the template named Gamepad.
7. Select Apply Layout.
8. Select Play.

Joyfiles reads gamepad buttons.
The Gamepad template sends these buttons to Joyfiles.
Do not select a template that has Keyboard or Mouse in its name.

## Install on Windows

1. Download the ZIP file from the Releases page.
2. Right click the ZIP file and select Extract All.
3. Select a permanent folder, for example `C:\Games\Joyfiles`.
4. Keep `joyfiles.exe` and `joyfiles_core.dll` in the same folder.
5. Open Steam.
6. Select the Games menu, then select Add a Non-Steam Game to My Library.
7. Select Browse and select `joyfiles.exe`.
8. Select Add Selected Programs.
9. Right click Joyfiles in your Library and select Properties.
10. Open the Controller tab.
11. Set the override for Joyfiles to Enable Steam Input.
12. Open the controller layout of Joyfiles.
13. Select Browse Configs and open the Templates list.
14. Select the template named Gamepad.
15. Select Apply Configuration.
16. Select Play.

You can also start Joyfiles without Steam.
Double click `joyfiles.exe` to do this.
Windows can show a SmartScreen warning because the app has no signature.
Select More info, then select Run anyway.

## Update Joyfiles

On SteamOS, download the new AppImage file.
Rename it to `joyfiles.AppImage`.
Replace the old file in the `Applications` folder.
Set the file to Is executable again.

On Windows, extract the new ZIP file into the same folder.
Replace the old files.

You do not add Joyfiles to Steam again.

## Fix a problem

Joyfiles does not start on SteamOS:

1. Right click Joyfiles in the Steam Library and select Properties.
2. Find the Launch Options field.
3. Enter `APPIMAGE_EXTRACT_AND_RUN=1 %command%`.

The controls do not work in Game Mode:

1. Open the controller layout of Joyfiles in Steam.
2. Make sure that the template is Gamepad.
