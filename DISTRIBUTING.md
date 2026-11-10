# Sharing Device Studio

Device Studio runs on macOS 14 or later. The setup wizard handles first launch, selected features, device capability checks, macOS permission guidance, matching Granola's shortcut, and a live test. It cannot grant macOS permissions on someone's behalf.

## For people installing a release

1. Download and unzip `DeviceStudio-macOS.zip` from the project's release page.
2. Move `Device Studio.app` into Applications before opening it. Avoid launching multiple copies.
3. Follow the setup wizard. Install Granola separately if choosing voice typing.
4. In Granola → Settings → Voice typing, enable voice typing and inspect **Hold to talk**. Match that exact shortcut in Device Studio.
5. Complete the live test. Seeing a button event alone does not confirm successful dictation; the wizard asks the user to confirm words appeared and recording stopped.

The wizard saves progress, preserves existing profiles and presets, and can be reopened from the sidebar or menu bar. Test-field text is not saved. Camera-only and standard mouse-only setup do not require Granola. Camera hardware controls can be used without preview when supported.

## Building a public release

A local `build-app.sh` build uses ad-hoc signing. It is intended for development, and rebuilding may invalidate existing macOS permissions. Do not describe that build as notarized. A stable Developer ID signature is needed for the normal distribution and update path.

Use your Apple Developer **Developer ID Application** certificate installed in Keychain. Set `DEVICE_STUDIO_SIGN_IDENTITY` to its identity name. Store notarization credentials with Apple's `notarytool store-credentials` outside the repository, then set `DEVICE_STUDIO_NOTARY_PROFILE` to that keychain profile name. Do not commit certificate private keys or Apple credentials.

```sh
export DEVICE_STUDIO_SIGN_IDENTITY='Developer ID Application: Your Name (TEAMID)'
export DEVICE_STUDIO_NOTARY_PROFILE='device-studio-notary'
./scripts/package-release.sh
```

The release script builds for Apple silicon and Intel, enables the hardened runtime with camera access, signs, submits to Apple, staples the notarization ticket, checks Gatekeeper acceptance, and creates `dist/DeviceStudio-macOS.zip` plus a checksum. Signing and notarization are not performed unless credentials are configured and the script is run. Choose a stable bundle identifier and signing team before your first public release; changing identity later can require new permissions.

## Hardware scope

Verified on the development Mac:

- MX Master 4 through its Logitech receiver: device identity, battery, sensor DPI, haptic thumb hold/release, and live Granola voice typing.
- Elgato Facecam MK.2 over USB: standard UVC image controls and same-value setting write/readback.

The wizard queries the connected Logitech device for supported haptic/gesture thumb controls. Other models and Bluetooth connections are not certified by these checks. Camera preview may work on cameras without supported UVC controls. Generic button and wheel mappings affect all mice because standard macOS events do not identify their originating device.

## Release checklist

- Run `./scripts/test.sh` and build the universal app.
- Test on a clean macOS account: fresh settings, denied permissions, granting permissions, returning after installing Granola, and resuming after quitting mid-setup.
- Verify Option and Command matching, physical thumb down/up, actual dictation output, and stop on release. Try an unsupported device and a missing camera.
- Test a signed app update and confirm existing permissions still function.
- Check the notarized download on a separate Apple-silicon Mac and Intel Mac. A universal binary alone does not constitute hardware or OS validation.
- Add the owner's chosen open-source license before publishing source. No license choice is made by the setup wizard.

Clean-machine, Intel runtime, and notarized-download checks still require those environments and signing credentials; automated policy tests are not substitutes for them.
