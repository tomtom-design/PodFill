PodFill for Windows
===================

PodFill turns Spotify playlist, album and track links into tagged MP3 files
(title, artist, album, cover art) for an iPod. It uses the free spotDL tool:
spotDL reads the song list from Spotify, downloads the matching audio from
YouTube Music and saves it as MP3.

Needs Windows 10 or 11 (64-bit) and an internet connection.


1. FIRST START
--------------
1. Right-click PodFill-Windows.zip and choose "Extract All...". Put PodFill.exe
   wherever you like (Desktop, Documents...). There is nothing to install.

2. Double-click PodFill.exe.

   Windows may say "Windows protected your PC". That is because PodFill is not
   signed by a publisher, not because something was found in it. Click
   "More info", then "Run anyway". Windows asks only once.
   To avoid the message: copy PodFill.exe over with a USB stick, or before
   extracting, right-click the zip > Properties > tick "Unblock" > OK.

3. Click "Set up" (one time only). PodFill downloads its engine: spotDL,
   Python, ffmpeg and Deno. That's about 450 MB on disk and takes a few
   minutes. Everything goes in its own folder (see "Uninstall" below).
   If setup stops halfway (no internet...), click "Set up" again: it continues
   where it stopped.


2. DOWNLOAD MUSIC
-----------------
1. In Spotify: Share > Copy link (of a playlist, an album or a song).
2. Paste the links into PodFill, one per line.
3. "Save to" is Music\iPod in your user folder. Click "Choose..." to change it.
   PodFill remembers your choice.
4. Click "Download". Each song shows its progress; "3 of 12" shows the total.
   - Albums and playlists get their own folder; single songs go in "Singles".
   - Files are named "Artist - Title.mp3".
   - Downloading the same playlist again only fetches the new songs
     ("Already had it" for the others).
   - "Cancel" stops everything and deletes the half-finished files.
5. When it's done, "Show in Explorer" opens the folder.

"Log" shows spotDL's own messages, which helps when something goes wrong.


3. PUT THE MUSIC ON THE iPOD
----------------------------
Apple says iPod classic, iPod nano and iPod shuffle can only get music by
syncing from a computer. On Windows there are two ways. Use ONE of them.

Way A: iTunes (simplest for an iPod classic, nano or shuffle)
   Apple: "To sync content from your computer to iPod classic, iPod nano, or
   iPod shuffle, use iTunes on Windows 10 or later."
   1. Install iTunes from the Microsoft Store.
   2. In iTunes: File > Add Folder to Library, and choose the Music\iPod folder.
   3. Connect the iPod with its USB cable. Click the iPod button near the top
      left of the iTunes window.
   4. Click "Music" in the sidebar, tick "Sync Music", choose what to sync,
      then click "Apply".
   Note: if the Apple Music app is installed, iTunes no longer handles music.
   Apple: "When you install the Apple Music or Apple TV app, you can only use
   those apps for your music, TV shows, and movies". In that case use Way B.

Way B: the Apple Music app + the Apple Devices app (both in the Microsoft Store)
   1. In Apple Music: click the "..." button (Sidebar Actions) at the top of the
      sidebar > Library > Add Folder to Library, and choose Music\iPod.
   2. Connect the iPod. Open Apple Devices and select the iPod in the sidebar.
   3. Click "Music", turn on "Sync Music onto [your iPod]", then click "Apply".

Both apps play the MP3s from where PodFill saved them. Don't move or delete
the Music\iPod folder after adding it (or add it again if you do).
To add new songs later: download them with PodFill, add the folder again
(the app skips songs it already has), then sync.

Sources (Apple Support, checked November 2026):
  - iTunes, syncing iPod classic/nano/shuffle:
    https://support.apple.com/guide/itunes/sync-itunes-content-with-your-devices-itns5ecc4d98/windows
    https://support.apple.com/guide/itunes/intro-to-syncing-itnsa874d59/windows
  - How iTunes is changing on PC (Apple Music app takes over music):
    https://support.apple.com/guide/itunes/itns5ecc4f3c/windows
  - Add a folder in iTunes:
    https://support.apple.com/guide/itunes/import-items-already-on-your-computer-itns3081/windows
  - Add a folder in Apple Music for Windows:
    https://support.apple.com/guide/music-windows/import-items-already-on-your-computer-mus3081/windows
  - Apple Devices syncing (includes iPod classic, nano, shuffle):
    https://support.apple.com/guide/devices-windows/mchl923c1147/windows
  - Download iTunes, Apple Music and Apple Devices for Windows:
    https://support.apple.com/en-us/118290


4. WHEN DOWNLOADS STOP WORKING
-----------------------------
YouTube changes things every few months and the downloader then fails
("Failed" for every song, or "nothing found"). Click "Update downloader": it
fetches the latest spotDL and yt-dlp. Then try again.

- "Spotify is rate-limiting...": spotDL shares one Spotify key with all its
  users, and Spotify sometimes says "too many requests". Wait an hour and try
  again. For a permanent fix, create your own free app at
  developer.spotify.com and put its Client ID and Client Secret in
  "client_id" and "client_secret" in this file (open it with Notepad):
      %LOCALAPPDATA%\PodFill\home\.spotdl\config.json
- A message says to click "Set up": click it. It repairs only what is missing.


5. UNINSTALL
------------
1. Delete PodFill.exe.
2. Paste %LOCALAPPDATA%\PodFill into the address bar of File Explorer, press
   Enter, go up one level and delete the "PodFill" folder.
Your music in Music\iPod stays.


Good to know
------------
- The MP3s keep YouTube's quality (about 128-160 kbps); converting them higher
  would only make bigger files.
- PodFill is built for regular (x64) Windows PCs. On Windows on ARM, setup
  stops at the ffmpeg step: spotDL has no ffmpeg download for that platform.
