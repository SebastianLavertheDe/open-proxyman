# Sparkle optional update framework

ProxyMirror's optional automatic updater uses [Sparkle 2.10.1](https://github.com/sparkle-project/Sparkle/releases/tag/2.10.1), pinned to an exact version. The [upstream package manifest](https://github.com/sparkle-project/Sparkle/blob/2.10.1/Package.swift) declares Swift tools 5.5 and macOS 12; ProxyMirror requires Swift tools 5.10 or newer and targets macOS 13. The current locked ASN.1, Atomics, Certificates, Collections, Crypto, NIO, NIO HTTP/2 and NIO SSL packages all require tools 5.10; the locked System package requires 5.9. The standalone ProxyMirrorBridgeKit package retains its independent tools 5.9 minimum. The binary distribution contains an Objective-C framework. macOS compilation and update installation still need validation on the supported Macs.

The official SwiftPM binary archive is approximately 10.2 MB, with SHA-256 `4c2e48a3e50ebcc2c88a58a4c7264a1a99c3c31857ce754357afb9cdb323022a`. SwiftPM verifies this checksum. No binary archive is vendored in this repository. The original [license and bundled external notices](./Sparkle-LICENSE) must ship with builds that embed Sparkle.

The source compiles without Sparkle using `#if canImport(Sparkle)`. Such builds provide an explicitly manual link to the [project Releases page](https://github.com/SebastianLavertheDe/open-proxyman/releases). That page does not currently contain a published release; the application does not claim that an update is available or create a release.

## Build integration

`PM_ENABLE_SPARKLE=1` enables the optional SwiftPM dependency and its `Sparkle` product on the core target. Leave it unset for ordinary development builds. The package dependency is:

```swift
.package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.1")
```

The core target dependency is:

```swift
.product(name: "Sparkle", package: "Sparkle", condition: .when(platforms: [.macOS]))
```

For a build that supports automatic updates, also supply `PM_DEVELOPER_ID`, `PM_APPCAST_URL` and `PM_UPDATE_PUBLIC_KEY`. The feed URL must use HTTPS. The public key must decode to 32 bytes; it is public configuration and the private signing key must stay in the publisher's Keychain. `Scripts/configure_updates.py <staged.app>` checks these two variables together and writes the corresponding Info.plist values before signing.

After building, locate the resolved framework under `.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework` (the artifact directory's case can vary by SwiftPM version). Invoke `Scripts/embed_sparkle.sh <staged.app> <framework> <signing-identity>` before the final app signature. It preserves symlinks, signs the framework's nested helpers, embeds the license, and adds `@executable_path/../Frameworks` to the host executable's runpath. The parent app must use the same signing identity. Ad-hoc hardened-runtime signing is intentionally rejected for this optional configuration because of library validation; regular ad-hoc builds keep the manual updater.

The host app calls `AppUpdateController.shared.startIfConfigured()` after application launch, inserts `AppUpdateMenuItems()` after app information, and presents `UpdateSettingsView()` for update preferences. The updater observes Sparkle's KVO values and keeps the automatic-check preference in Sparkle's existing defaults. It does not override that choice at each launch. Automatic checking defaults to off. The packager also disables automatic installation, so a periodic check only notifies the user.

## Publisher setup and verification

Use Sparkle's official `generate_keys` once to create the private Ed25519 signing identity and copy only the public key to `PM_UPDATE_PUBLIC_KEY`. Create a notarized, Developer ID signed app archive with an increasing `CFBundleVersion`. Use the matching Sparkle `generate_appcast` tool to sign both the archive and the feed/release notes, and serve the resulting files over HTTPS. ProxyMirror's configuration enables `SURequireSignedFeed` and `SUVerifyUpdateBeforeExtraction`. This setup does not enable the `SURequireFeedBundleIdentifier` option, which belongs to Sparkle 2.11 and is unavailable in the pinned version.

This repository does not publish an appcast, release archive, or release automatically. Before distribution, test a signed older version against a private signed feed, verify that tampered feeds and archives are rejected, verify a valid update and relaunch, and verify that disabling automatic checks survives relaunch. Linux source checks cannot establish these macOS installation behaviors.

Sources: [official setup](https://sparkle-project.org/documentation/), [programmatic setup and SwiftUI](https://sparkle-project.org/documentation/programmatic-setup/), [configuration](https://sparkle-project.org/documentation/customization/), [publishing updates](https://sparkle-project.org/documentation/publishing/).
