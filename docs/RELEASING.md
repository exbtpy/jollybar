# Releasing

Names live in [`macos/identity.env`](../macos/identity.env) and [`AppIdentity.swift`](../macos/Sources/Jollybar/AppIdentity.swift). A unit test fails if they disagree. The disk-image background slot is [`macos/Resources/dmg/background.png`](../macos/Resources/dmg/background.png) (the window is 680×420). Delete that PNG and the image still contains the app plus an Applications symlink.

The tag is the version. `v1.2.3` stamps `CFBundleShortVersionString` `1.2.3`.

## One-time setup

### Apple Developer Program

1. Enroll at [developer.apple.com](https://developer.apple.com/programs/).
2. Create a **Developer ID Application** certificate (not a Mac App Store distribution certificate).
3. Export the certificate and its private key as a `.p12` with a password.
4. Base64 it (the secret is the text, not the file):

   ```sh
   base64 -i Certificates.p12 | pbcopy
   ```

5. Pick one notarization method:
   - Apple ID: the account email, the 10-character Team ID, and an [app-specific password](https://account.apple.com/account/manage) (not the Apple ID password).
   - App Store Connect API key: a key with the Developer role. Save the Key ID, the Issuer ID, and the full `.p8` file contents.

### GitHub Actions secrets

This repository is public, so GitHub Actions minutes are free. Never commit secrets; they belong in GitHub Actions secrets.

Repository → **Settings → Secrets and variables → Actions → New repository secret**.

Signing (both, or neither):

| Secret | Value |
| --- | --- |
| `APPLE_CERTIFICATE_P12` | Base64 of the Developer ID `.p12` |
| `APPLE_CERTIFICATE_PASSWORD` | Password for that `.p12` |

Notarization, either group (or neither):

| Secret | Value |
| --- | --- |
| `APPLE_ID` | Apple ID email |
| `APPLE_TEAM_ID` | 10-character Team ID |
| `APPLE_APP_SPECIFIC_PASSWORD` | App-specific password |

or:

| Secret | Value |
| --- | --- |
| `APP_STORE_CONNECT_API_KEY_ID` | Key ID |
| `APP_STORE_CONNECT_API_ISSUER_ID` | Issuer ID |
| `APP_STORE_CONNECT_API_KEY` | Full `.p8` contents, including the BEGIN/END lines |

Sparkle (leave unset until the key exists):

| Secret | Value |
| --- | --- |
| `SPARKLE_PRIVATE_KEY` | EdDSA private key file from `generate_keys -x` (below) |

Optional Homebrew tap push:

| Secret | Value |
| --- | --- |
| `HOMEBREW_TAP_TOKEN` | Fine-grained PAT on `exbtpy/homebrew-tap` with Contents read and write. Classic `repo` scope also works. |

A partial set (certificate without password, or two of the three Apple ID values) fails the workflow. With no Apple secrets, the workflow still builds an ad-hoc signed universal DMG and zip, and the release notes include the quarantine command. Never commit a `.p12`, `.p8`, or the Sparkle private key.

### Sparkle key

On a Mac, after `make app` has resolved the package (the tool is inside the Sparkle artifact):

```sh
macos/.build/artifacts/sparkle/Sparkle/bin/generate_keys
```

The tool prints `SUPublicEDKey` and stores the private key in your login keychain. Replace the placeholder in [`macos/Resources/Info.plist`](../macos/Resources/Info.plist):

```xml
<key>SUPublicEDKey</key>
<string>the-public-key-from-generate_keys</string>
```

Export the private key and store the file contents in `SPARKLE_PRIVATE_KEY`:

```sh
macos/.build/artifacts/sparkle/Sparkle/bin/generate_keys -x /tmp/sparkle-private-key
```

`-f /tmp/sparkle-private-key` imports that file on another Mac. Delete the file after the secret is saved.

The public key and the private key are a pair. The upstream Claude Usage Bar key is refused. `SUFeedURL` is not in the source plist. The release workflow sets it to:

```text
https://<owner>.github.io/<repo>/appcast.xml
```

For this repository that is `https://exbtpy.github.io/jollybar/appcast.xml`. The workflow builds that URL from the GitHub repository name (`exbtpy/jollybar`). The app checks for updates only when that URL and a real public key are both in the built app. Automatic checks stay off until someone turns them on in Settings.

Optional: secret `SPARKLE_PUBLIC_KEY` overrides the plist value for that build. The plist is the copy that stays in git.

### GitHub Pages

**Settings → Pages → Build and deployment → Source: GitHub Actions.** The release workflow deploys `appcast.xml` there when `SPARKLE_PRIVATE_KEY` is set. The same file is also attached to the GitHub Release. If the deploy job waits on the `github-pages` environment, approve it once.

### Homebrew tap

1. Create a public repository `exbtpy/homebrew-tap`.
2. Copy [`Casks/jollybar.rb`](../Casks/jollybar.rb) to `Casks/jollybar.rb` in that repo and commit it. If the tap already has `Casks/grok-usage-bar.rb`, remove that file in the same commit. `brew install jollybar` is the cask.
3. Add `HOMEBREW_TAP_TOKEN`.

The release workflow then updates `version` and `sha256` on that file. Without the token, or before the repository exists, the step is skipped. To bump by hand:

```sh
shasum -a 256 Jollybar.dmg
```

Put the digest in `sha256` and the tag version (no leading `v`) in `version`. Add `auto_updates true` to the cask after a shipped build contains your `SUPublicEDKey`, so Homebrew leaves updates to Sparkle.

## Cut a release

1. `main` is green.
2. From the commit you want to ship:

   ```sh
   git tag vX.Y.Z
   git push origin vX.Y.Z
   ```

3. The Release workflow, on `macos-26`, builds arm64 + x86_64, writes the DMG and the Sparkle zip, notarizes when the secrets exist, and publishes a GitHub Release with generated notes.
4. When `SPARKLE_PRIVATE_KEY` is set, it signs `appcast.xml` and deploys it to Pages. When the key is absent, that step is skipped and the DMG/zip are still published.
5. When `HOMEBREW_TAP_TOKEN` is set and the tap exists, the cask version and sha256 are pushed.

A dry run uploads the DMG and zip as Actions artifacts and does not publish a Release:

- Tag `vX.Y.Z-dryrun` (or any tag containing `dryrun` or `dry-run`), or
- **Actions → Release → Run workflow**, leave **Publish a GitHub Release** off.

## Rename

1. Edit the values in `macos/identity.env`.
2. Edit the same strings in `AppIdentity.swift`.
3. When the product name changes, rename the SwiftPM target in `macos/Package.swift` and move `macos/Sources/<old>/` and `macos/Tests/<old>Tests/` to match.
4. Replace `macos/Resources/dmg/background.png` when new artwork is ready.
5. Update `Casks/<config-dir>.rb` (token, `app`, `url`, `name`, `zap`) and the copy in the tap.

Do not point `SUFeedURL` or `SUPublicEDKey` at Blimp-Labs/claude-usage-bar.

## Existing installs

Quit the previous app before opening Jollybar so its preferences are flushed. The first launch then copies, once:

- `~/.config/grok-usage-bar` is moved to `~/.config/jollybar` when the new directory is absent. If the new directory is already there, files that exist are left alone and missing files are copied. The old directory is removed only by that move.
- Keys in `~/Library/Preferences/com.exbtpy.GrokUsageBar.plist` are copied when the new bundle id does not already have them.
- Keychain items `management-api-key` and `cursor-api-key` are copied to service `com.exbtpy.Jollybar`. The old items stay. A denied read is tried again on the next launch. macOS may ask for permission to read the old item.

Launch at login is tied to the bundle id. Turn it on again in Settings. Replace `GrokUsageBar.app` in `/Applications` with `Jollybar.app`; they are different bundles, so both can sit side by side until the old one is deleted.
