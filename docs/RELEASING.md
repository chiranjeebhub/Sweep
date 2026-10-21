# Releasing Sweep

Sweep ships outside the Mac App Store, because the App Store requires the app sandbox and a
sandboxed app can't clean caches, logs or other apps' leftovers. Instead it's signed with a
Developer ID, notarized by Apple, packed into a DMG and published on GitHub Releases.

`scripts/release.sh` does all of that in one go:

```sh
scripts/release.sh 0.2.0                       # build, sign, notarize, DMG, then ask before publishing
scripts/release.sh 0.2.0 --notes notes.md      # use your own release notes
scripts/release.sh 0.2.0 --draft               # publish as a draft you review on GitHub first
scripts/release.sh 0.2.0 --no-publish          # stop after the notarized DMG in dist/
scripts/release.sh 0.2.0 --no-notarize         # signing and DMG only, no Apple upload
scripts/release.sh 0.2.0 --no-cask             # publish but leave the Homebrew cask alone
```

What it does:

1. Checks the signing certificate, notarization credentials and `gh` sign-in before the slow steps.
   To publish, the working tree must be clean and `HEAD` must be the pushed `origin/main`.
2. Builds a universal (Apple silicon and Intel) `build/Sweep.app` with `scripts/build-app.sh`,
   and stamps the version you passed and a build number (the commit count) into its Info.plist.
3. Signs the app with your **Developer ID Application** certificate, the hardened runtime, a
   secure timestamp and `Resources/Sweep.entitlements` (Apple Events, for Finder and admin prompts).
4. Notarizes and staples the app, so a copy dragged out of the DMG opens even offline.
5. Builds `dist/Sweep-<version>.dmg` with the app and an Applications shortcut, signs it,
   notarizes and staples it, and checks it with Gatekeeper (`spctl`).
6. Asks, then creates the GitHub release `v<version>` with the DMG and its SHA-256 checksum.
7. Bumps `version` and `sha256` in `Casks/sweep.rb` in
   [chiranjeebhub/homebrew-tap](https://github.com/chiranjeebhub/homebrew-tap) and pushes it, so
   `brew upgrade --cask chiranjeebhub/tap/sweep` picks up the new release. Drafts and `--no-cask` skip this.

Credentials never go in the repo. The script reads them from your keychain or the environment.

## One-time setup

You need a paid Apple Developer Program membership ($99 a year) and Xcode.

### 1. Developer ID Application certificate

1. Open Xcode › Settings › Accounts, select your Apple ID and team, and click **Manage Certificates**.
2. Click **+** and choose **Developer ID Application**. Only the team's Account Holder can create one.
3. Check it's in your keychain:

   ```sh
   security find-identity -v -p codesigning | grep "Developer ID Application"
   ```

The script picks the first Developer ID Application identity it finds. If you have more than one,
set `SWEEP_SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)"`.

### 2. Notarization credentials

Pick one. The keychain profile is the easiest.

**App-specific password, saved as a keychain profile (recommended)**

1. Go to [account.apple.com](https://account.apple.com) › Sign-In and Security › App-Specific
   Passwords, and create one called "Sweep notarization".
2. Find your Team ID at [developer.apple.com/account](https://developer.apple.com/account) under
   Membership details.
3. Save it to the keychain under the profile name the script uses by default:

   ```sh
   xcrun notarytool store-credentials sweep-notary \
       --apple-id "you@example.com" --team-id "TEAMID" --password "abcd-efgh-ijkl-mnop"
   ```

   Use a different name by setting `NOTARY_PROFILE`.

**App Store Connect API key**

Create a key with the Developer role in App Store Connect › Users and Access › Integrations ›
App Store Connect API, download the `.p8` file (you can only download it once) and either save it as
a profile:

```sh
xcrun notarytool store-credentials sweep-notary \
    --key ~/.private/AuthKey_ABC123.p8 --key-id ABC123 --issuer 00000000-0000-0000-0000-000000000000
```

or export `NOTARY_KEY_PATH`, `NOTARY_KEY_ID` and `NOTARY_ISSUER` before running the script.

**Environment variables only**

Export `NOTARY_APPLE_ID`, `NOTARY_TEAM_ID` and `NOTARY_PASSWORD` (the app-specific password).

### 3. GitHub CLI

```sh
brew install gh
gh auth login
```

## Troubleshooting

- **"Apple didn't accept…"**: the script prints Apple's log. The usual causes are a missing hardened
  runtime or an unsigned nested binary, both of which the script handles, or an expired certificate.
- **The app can't empty the Trash after notarizing**: the Apple Events entitlement is missing.
  Check with `codesign -d --entitlements - build/Sweep.app`.
- **"release v… already exists"**: pick a new version, or delete the release and tag on GitHub first.

## Later: automatic updates

Sparkle can be added on top of this: generate an EdDSA key with Sparkle's `generate_keys`, put the
public key in Info.plist (`SUPublicEDKey`) with an `SUFeedURL`, and have the release step run
`sign_update` on the DMG and append it to an appcast published alongside the release.
