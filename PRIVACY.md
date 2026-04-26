# Privacy Policy for TA Client

**Effective date:** April 26, 2026
**Last updated:** April 26, 2026

## Summary

TA Client is a free, open-source iOS and iPadOS client for [Tube Archivist](https://github.com/tubearchivist/tubearchivist), a self-hosted media archiver that you run on your own server. The app is published by Mikhail Zhukov ("we", "us").

**We do not collect, store, or transmit any personal data of our own.** TA Client has no servers, no analytics, no advertising, and no third-party tracking. Your data stays between your device and the Tube Archivist server you provide.

## Information you enter into the app

To use TA Client you must provide:

- **Server URL** — the address of your Tube Archivist instance, for example `https://ta.example.com`.
- **Username and password** — the credentials for your Tube Archivist account.

This information is sent **only to the server URL you entered**, and is used solely to obtain an API token for authenticated requests. We never see it, store it, or have any access to it.

## Information stored on your device

| Where | What | Why |
|---|---|---|
| iOS Keychain | Server URL, username, API token | To keep you signed in across app launches |
| iOS UserDefaults | App preferences (sort order, watch filter, SponsorBlock settings) | To remember your in-app choices |
| In-memory cache | Up to 256 MB of video data while a video plays | To make playback smooth on slow networks; the cache is discarded when the app closes or memory is low |

All of the above is stored locally on your device. None of it is transmitted to us or to any third party. iOS removes all of it automatically when you delete the app.

## Network communication

TA Client communicates **only** with the Tube Archivist server URL you entered. Every request carries your API token as an HTTP `Authorization` header so the server can verify it is you. The app does not contact the developer, Apple (beyond standard iOS platform telemetry that we do not control), or any other third party.

If you provide a server URL on a private or local network, the app will use your local network connection. If you provide a public URL, traffic flows over the public internet. We have no control over the route.

## Permissions and capabilities

| Permission | Reason |
|---|---|
| Network access | To communicate with your Tube Archivist server |
| Background audio | To allow audio playback to continue when the app is backgrounded or the device is locked |
| Local network (when applicable) | To reach a Tube Archivist server running on your home network |

The app **does not** request access to your camera, microphone, photo library, contacts, location, motion, health, calendar, reminders, or any other personal data on your device.

## Third-party software

TA Client includes the [MobileVLCKit](https://code.videolan.org/videolan/VLCKit) framework (LGPL-2.1-or-later) for VP9 video decoding. MobileVLCKit runs entirely on your device and does not contact any external service.

TA Client does **not** use any third-party analytics, crash reporting, advertising, or tracking SDKs.

## Children's privacy

TA Client does not knowingly collect any data from anyone, including children. The app is rated 4+ on the App Store.

## Data retention

We do not retain any of your data, because we do not collect any of your data. Information stored locally on your device (Keychain, UserDefaults, caches) is removed by iOS when you delete the app.

## Your rights

Because we do not collect, store, or process your personal data on our systems, there is nothing for us to delete, export, or correct on request. If you have questions about data stored by your Tube Archivist server, please contact the operator of that server (often this will be you).

## Changes to this policy

If we update this privacy policy, the new version will appear at this URL and the "Last updated" date above will change. Material changes will also be noted in the app's release notes on the App Store.

## Contact

For privacy questions about TA Client:

- **Email:** 51.comings.current@icloud.com
- **GitHub Issues:** https://github.com/MikhailZhukov/TAClient/issues
