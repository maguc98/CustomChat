# CustomChat

A native SwiftUI chat composer for creating and previewing conversations with two editable identities.

## Features
- Switch the active sender between **Me** and **Other**.
- Messages are aligned automatically by sender.
- Edit both identities' display names and initials-based avatars.
- Edit or delete messages; conversation state persists locally.
- iOS 18+.

## Build
Open `CustomChat.xcodeproj` in Xcode and run the `CustomChat` scheme on an iOS 18+ simulator or device.

GitHub Actions builds an unsigned simulator app and an unsigned device IPA artifact. The device IPA is not signed and cannot be installed until signed with a valid Apple development/distribution identity.
