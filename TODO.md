# TODO

Distributing Flick to other people. These need the Apple Developer ID certificate, so do them on a Mac that has it in its keychain.

- [ ] Sign release builds with the Developer ID and notarize them: a release mode in `build.sh` that signs with the Developer ID Application identity and the hardened runtime instead of `flick-local`, submits with `xcrun notarytool submit --wait`, and staples the ticket. Check that the hardened runtime still lets Flick load the private WindowManagement framework and install its event tap, and that `spctl -a -vv` accepts a downloaded copy.
- [ ] Publish tagged GitHub Releases: bump `CFBundleShortVersionString` (still 0.1.0), tag, and attach the notarized app as a zip or disk image. Keep the notary credentials in the keychain (`notarytool store-credentials`) rather than in the repository; build in CI only if the signing identity can live in repository secrets.
- [ ] Give installs an update path: a Homebrew cask in a personal tap (the official one wants notarized, reasonably popular apps) or Sparkle in the app. Update the README's Install section to offer the download first and the source build second.
