# gview

A macOS menu bar app that shows where your GitLab merge requests stand.

gview sits in the menu bar with a count of the merge requests that need you. Click it to open a dashboard that sorts your open MRs into:

- **Waiting on me**: MRs where someone actually asked you for a review or a reply. MRs you were only added to by approval rules or CODEOWNERS are left out.
- **Changes requested**: your MRs where a reviewer reviewed without approving, or where someone else opened a thread that is still unresolved and you have not replied to it yet.
- **Ready to merge**: your MRs that GitLab says can be merged (or only need a rebase).
- **Waiting for review**: your MRs that nobody has acted on yet.
- **Drafts**: your draft MRs.

It refreshes every 5 minutes and sends a macOS notification when an MR lands in *Waiting on me*, *Changes requested* or *Ready to merge*.

The dashboard also shows a few stats for the last 30 days: MRs merged, merge streak, median and fastest time to merge, lines changed, the person who approves your work most often, your favourite merge day, and your oldest open MR.

## Setup

gview works with gitlab.com or a self-hosted GitLab. On first launch it asks for your GitLab host and a personal access token with the `read_api` scope. The setup screen has a button that opens GitLab's token page with that scope already selected. The token is kept in your macOS keychain. If it expires or is revoked, gview notifies you and asks for a new one.

## Build

Requires Flutter.

```sh
flutter run -d macos   # run from source
./package.sh           # release build signed with a local self-signed identity, output in build/gview-<version>.dmg
./package.sh --install # same, and copy the app to /Applications
```

The app is not notarized. On another Mac, open it once via System Settings > Privacy & Security > Open Anyway.
