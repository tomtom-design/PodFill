# PodFill: notes for Claude

## Releases are Claude's job

The maintainer never tags or releases by hand. When asked to "release vX.Y.Z", run the whole procedure below. That
request is the go-ahead. Never release unprompted: the Releases page is public.

1. **Preflight:** be on `main` with a clean tracked tree. Run `git fetch` and check that HEAD equals `origin/main`. Check
   that CI is green for that commit (`gh run list --workflow ci.yml --commit <sha>`).
2. **Version:** use a patch bump for fixes and a minor bump for features. Ask if it's unclear.
3. **Tag and push:** run `git tag -a vX.Y.Z -m "PodFill vX.Y.Z"`, then `git push origin vX.Y.Z` as its own command,
   never piped. The push triggers `release.yml`, which builds `PodFill-Windows.zip` on windows-latest and creates the
   release.
4. **Mac:** run `./release-mac.sh vX.Y.Z` (in the background; notarization takes a few minutes). It needs HEAD at the tag
   and a clean tree. It builds the universal app, signs it with the keychain's Developer ID Application identity,
   notarizes it through the `PodFill` notarytool keychain profile, staples the ticket and uploads `PodFill-macOS.zip`.
5. **Watch CI:** `gh run watch` the release.yml run until it succeeds.
6. **Verify from the public release, not from local files:**
   - Download both assets with curl into a scratch directory.
   - **Mac:** extract with `ditto -x -k`, then set the quarantine attribute a browser would set
     (`xattr -w com.apple.quarantine "0081;<hex time>;Safari;"`). `spctl -a -vvv -t exec` must report
     `source=Notarized Developer ID`. Also check `xcrun stapler validate`, `lipo -archs` (x86_64 arm64) and
     `CFBundleShortVersionString`.
   - **Windows:** `unzip -l`, and `file PodFill.exe` must report PE32+ GUI x86-64.
7. **Report:** give the release link and what was verified.

**If something fails:**
- **Notarization:** the script prints the `notarytool log`. Fix, re-tag only if the code changed, and re-run.
- **Expired certificate:** the Developer ID certificate expires in December 2027. After that a new one is needed, and
  `release-mac.sh` stops with a clear message until it exists.

## Repo rules

- **Public repo:** never commit personal paths, usernames, emails or credentials. Use `/Users/you` or `C:\Users\you`
  in tests and fixtures.
- **Matching uv pins:** the uv version and checksums are pinned in both `Sources/PodFillCore/UvRelease.swift` and
  `windows/src/PodFill.Core/UvRelease.cs`. The self-check fails if they differ, so bump both together.
- **Screenshots:** only `screencapture -l <windowID>` of PodFill's own window, never full-screen or region captures.
  The maintainer's screen shows private calls and clipboard history.
- **Checks before pushing:** `swift run -c release PodFillSelfCheck`, `./build.sh`, `dotnet test` in `windows/`,
  `actionlint` and `shellcheck build.sh release-mac.sh windows/build.sh`.
