<p align="center">
  <img src="Resources/AppIcon-1024.png" width="96" height="96" alt="Auxmo app icon" />
</p>
<h1 align="center">Auxmo</h1>
<p align="center"><strong>Your Mac. Your Sound. Your Rules.</strong></p>
<p align="center">Per-app volume, audio routing, headphone controls, and listening statistics for your Mac.</p>
<p align="center"><strong>English</strong> · <a href="README.zh-CN.md">简体中文</a></p>
<p align="center">
  <a href="https://github.com/Colin0v0/Auxmo/releases/latest"><img src="https://img.shields.io/github/v/release/Colin0v0/Auxmo" alt="Latest release" /></a>
  <img src="https://img.shields.io/badge/macOS-15.4%2B-000000?logo=apple&amp;logoColor=white" alt="macOS 15.4 or later" />
  <img src="https://img.shields.io/badge/Apple_Silicon-arm64-555555" alt="Apple Silicon arm64" />
  <a href="https://github.com/Colin0v0/Auxmo/actions/workflows/release.yml"><img src="https://github.com/Colin0v0/Auxmo/actions/workflows/release.yml/badge.svg?branch=main" alt="Release checks" /></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/License-MIT-blue" alt="MIT License" /></a>
</p>
<p align="center">
  <a href="https://github.com/Colin0v0/Auxmo/releases/latest"><strong>Download for Apple Silicon</strong></a> ·
  <a href="#compatibility--installation">Before you install</a> ·
  <a href="docs/CHANGELOG.md">What's changed</a>
</p>
<p align="center">
  <a href="docs/images/hero-en.png"><img src="docs/images/hero-en.png?v=0.4.9" width="440" alt="Auxmo output panel with speaker and headphone controls, independent Chrome and Music volumes, and per-app route buttons" /></a>
</p>
<p align="center"><sub>UI previews use sample devices and apps rendered by Auxmo 0.4.9, not a live audio session. <a href="docs/images/README.md">Image sources</a>.</sub></p>

> Free and open source. No account required. Current downloads are ad-hoc signed and **not notarized by Apple**; macOS may block launch. [Distribution details](docs/TRUST_AND_TESTING.md#distribution-and-permissions).

## Why Auxmo?

**Turn down your browser without turning down your music.** Auxmo puts separate app volumes and output choices in one menu bar panel, so you don't have to keep opening player controls or macOS Sound settings.

Start with volume and mute. Enable multi-device output, effects, or headphone controls in Settings when you need them; these features are off by default.

Use **Mute All** at the top-right of the main panel to temporarily mute app audio that Auxmo can observe and manage. Newly playing apps may be audible briefly before they are detected, and system sounds are not included; **this is not a guarantee against audio leaks**. Turning it off restores each app's own mute state.

## Core features

<table>
<tr>
<td width="50%" valign="top">
<h3>Mix apps independently</h3>
<p>Give Chrome and Music different volumes, mute either app, and see live levels while the panel is open.</p>
<a href="docs/images/mixer-en.png"><img src="docs/images/mixer-en.png?v=0.4.9" width="440" alt="Separate Chrome and Music volume sliders with effects and routing buttons" /></a>
</td>
<td width="50%" valign="top">
<h3>Choose more than one output</h3>
<p>Build a speaker-and-headphone group, keep individual device controls, and choose a different subset for each app.</p>
<a href="docs/images/outputs-en.png"><img src="docs/images/outputs-en.png?v=0.4.9" width="440" alt="Multi-device output editor with speakers and AirPods Pro selected" /></a>
</td>
</tr>
<tr>
<td width="50%" valign="top">
<h3>Shape each app's sound</h3>
<p>A 10-band EQ, spatial effects, volume leveling, and channel controls. Save presets and compare with the original.</p>
<a href="docs/images/effects-en.png"><img src="docs/images/effects-en.png?v=0.4.9" width="440" alt="Music effects window showing the ten-band equalizer, response preview, and Compare Original control" /></a>
</td>
<td width="50%" valign="top">
<h3>Keep headphone controls nearby</h3>
<p>Check battery levels and change the listening modes your exact model exposes. Controls vary by device and firmware.</p>
<a href="docs/images/headphones-en.png"><img src="docs/images/headphones-en.png?v=0.4.9" width="440" alt="Example headphone battery readings with noise cancellation, transparency, and adaptive controls" /></a>
</td>
</tr>
</table>

## See your listening habits

Open the detail window from the menu bar and choose **Insights → Statistics** to see listening totals, daily trends, device and app rankings, listening hours, and session details. Choose today, yesterday, this week, last week, this month, this year, or a custom range; select a device or app to see its own details and related rankings.

<p align="center">
  <a href="docs/images/statistics-en.png"><img src="docs/images/statistics-en.png?v=0.4.9" width="820" alt="Auxmo listening statistics preview with time range, listening totals, daily chart, output devices, app rankings, and listening-hours heatmap" /></a>
</p>
<p align="center"><sub>Statistics preview rendered from version 0.4.9 with sample data, not a real user's records. <a href="docs/images/README.md">Image sources</a>.</sub></p>

Statistics record audio activity observed while Auxmo runs on the Mac and are stored locally. They are not complete screen-time data and do not read iPhone Health data. App-to-device associations use confirmed output routes; historical records, sampling intervals, and session boundaries remain estimates. In **Settings → Statistics Data**, you can see the first recorded date, export JSON, or clear the records after confirmation.

## How it works

Browser audio on the speakers. Music on the headphones. With both devices connected:

<p align="center">
  <img src="docs/images/routing-en.svg?v=0.4.1" width="820" alt="Routing example: Chrome passes through Auxmo to speakers; Music passes through Auxmo to headphones. Both devices belong to the same output group." />
</p>

1. In Settings, enable **Show Multi-Device Output**.
2. Add your speakers and headphones to the output group.
3. Start playback in both apps. In each app's route menu, choose a custom output: speakers for Chrome, headphones for Music.

An app can also use **All Outputs** to follow the whole group. Per-app choices apply within the current group, not to arbitrary disconnected devices. The illustration shows the intended configuration, not a hardware test result.

> **Custom routing is not system-wide privacy isolation.** In 0.4.1, when all selected targets are unavailable, Auxmo pauses that app’s replay and retains mute capture instead of using other group outputs. The player’s timeline is not paused. This does not cover quitting Auxmo, permission revocation, or every hardware transition. Older releases such as 0.3.8 may use other group outputs. [Behavior and limits](docs/TRUST_AND_TESTING.md#known-limits).

## Compatibility / installation

| Check | Current scope |
| --- | --- |
| Mac | Apple Silicon, macOS **15.4 or later**. Intel release builds are not provided. |
| Headphones | Selected models from **Apple / Beats, Bowers & Wilkins, Sony, OPPO, Bose, and Sennheiser**. Brand recognition does not mean every model is supported. |
| Evidence | Many listed models are **upstream verified** or **experimental**, not independently verified in Auxmo. See the [model-by-model matrix](docs/HEADPHONE_COMPATIBILITY.md). |
| Permissions | System audio recording for app processing; Bluetooth for headphone controls. The microphone page controls hardware settings, not microphone recording. |

### Install

1. Download the arm64 DMG from [GitHub Releases](https://github.com/Colin0v0/Auxmo/releases/latest).
2. Open it and drag Auxmo into **Applications**. Quit an older running copy before replacing it.
3. Launch Auxmo and follow the system permission prompts. The current startup flow requires system audio recording access to enter the main interface.
4. Play audio in an app, then open Auxmo from the menu bar. Optional features are in Settings.

Release assets include SHA-256 files. Current builds are ad-hoc signed, without Developer ID signing or Apple notarization. Follow macOS security prompts; this project does not ask you to disable Gatekeeper or SIP.

### Before relying on it

- Switching outputs can cause a brief audio gap. Bluetooth devices can have different latency; multi-device output is not a promise of synchronized playback.
- Sleep, disconnects, or processing errors can require **Reapply**. Test reconnect behavior at a low device volume before using a setup in public.
- Protected audio, third-party aggregates, and some duplex or multi-stream interfaces are not supported by per-app processing. The current PCM path supports native Float32 mono or stereo.
- Automated tests cover state transitions and synthetic audio, **not every physical device, long-running session, or real-world leak scenario**. [Testing scope and hardware checklist](docs/TRUST_AND_TESTING.md).

## Technical details

### Local audio, explicit diagnostics

Audio processing stays on your Mac. Auxmo does not save recordings, upload audio, require an account, or collect telemetry. It contacts GitHub to check for updates and download releases.

When something goes wrong, use **Settings → Diagnostics → Export Diagnostics…**. The JSON report stays local until you share it. It contains current audio state and recent in-memory events, not audio samples. Device names, UIDs, Bluetooth addresses, and application identities can be included; review the file before posting it publicly.

### Build and inspect

Requires a Swift 6 toolchain and macOS 15.4 or later:

```sh
git clone https://github.com/Colin0v0/Auxmo.git
cd Auxmo
./Scripts/check.sh
open 'dist/build/debug/Auxmo (develop).app'
```

`check.sh` runs tests, builds the app, checks the local signature, and reads output/input diagnostics on the host Mac. Hardware-independent release checks run in [GitHub Actions](https://github.com/Colin0v0/Auxmo/actions/workflows/release.yml). A green build is evidence of those checks, not Apple certification or complete hardware acceptance.

| Read more | |
| --- | --- |
| [Trust, limits, and testing](docs/TRUST_AND_TESTING.md) | Known risks, validation scope, and reporting a reproducible problem |
| [Headphone compatibility](docs/HEADPHONE_COMPATIBILITY.md) | Exact models, protocol evidence, and experimental support |
| [Development and diagnostics](docs/DEVELOPMENT.md) | Source structure, commands, and local builds |
| [Audio permission implementation](docs/audio-capture-permission.md) | Permission handling and its non-public API dependency |
| [Release checklist](docs/RELEASING.md) · [Changelog](docs/CHANGELOG.md) | Packaging requirements and the fixes shipped in each version |
| [Third-party notices](THIRD_PARTY_NOTICES.md) · [MIT License](LICENSE) | Code origins and license terms |

Found a problem? [Open an issue](https://github.com/Colin0v0/Auxmo/issues/new?template=bug_report.yml) with your version, exact devices, and steps to reproduce. Attach a diagnostic report only after removing private information. For the UI previews above, see the [reproducible image sources](docs/images/README.md).
