<p align="center">
  <img src="Resources/AppIcon.svg" width="120" alt="Tandem app icon">
</p>

<h1 align="center">Tandem</h1>

<p align="center">Brightness and volume controls for the screen under your pointer.</p>

<p align="center">
  <a href="https://github.com/oguzhandemirelx/tandem/releases/latest"><img alt="Download for macOS" src="https://img.shields.io/badge/Download-macOS-202124?style=flat-square&logo=apple&logoColor=white"></a>
  <img alt="macOS 14 or later" src="https://img.shields.io/badge/macOS-14%2B-555?style=flat-square">
  <img alt="Apple Silicon" src="https://img.shields.io/badge/Apple_Silicon-arm64-555?style=flat-square">
</p>

<p align="center">
  <img src="docs/screenshots/controls.png" width="300" alt="Brightness and volume controls for each display">
  <img src="docs/screenshots/headphones.png" width="300" alt="Display brightness controls with selected headphones">
</p>

Move your pointer to a display and use the brightness, volume or mute keys. Tandem adjusts that screen’s brightness and speakers. Selected headphones take priority for volume and mute, while your playback output stays unchanged.

## Features

- Keyboard controls that follow your pointer.
- Menu bar sliders with precise percentage readouts.
- Automatic display detection and support for selected headphones.
- Launch at login and an optional menu bar icon.

## Install

**[Download the latest release →](https://github.com/oguzhandemirelx/tandem/releases/latest)**

1. Unzip the download and move **Tandem.app** to **Applications**.
2. Open the app and follow the setup steps.
3. Enable **Tandem** in **System Settings → Privacy & Security → Accessibility** to use keyboard controls.

Requires **macOS 14+** and an **Apple Silicon Mac**. Releases are Developer ID signed and notarized by Apple.

## Usage

Click the menu bar icon to adjust brightness and volume, or open Settings with the gear button. Hold **Shift + Option** with a brightness or volume key for smaller adjustments. If you hide the icon, reopen the app from Applications to access the controls.

External display controls require **DDC/CI** support from your monitor and connection. Available controls vary by hardware. Software dimming and virtual-display brightness are not supported. Enable DDC/CI in your monitor’s settings if needed. Some monitors report a different brightness value in their own on-screen menu.

## Build

With Xcode or Apple’s Command Line Tools installed:

```sh
git clone https://github.com/oguzhandemirelx/tandem.git
cd tandem
bash scripts/build.sh
bash scripts/test.sh
open build/Tandem.app
```

Built with Swift, C and native macOS frameworks. No third-party runtime dependencies.

[Report an issue](https://github.com/oguzhandemirelx/tandem/issues) · [Acknowledgments](THIRD_PARTY.md)
