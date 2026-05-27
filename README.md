# BitSwitch

A macOS menu bar app that automatically switches your audio output device's sample rate and bit depth to match the currently playing file — so your DAC always runs at the native format with zero resampling.

macOS does not do this on its own. Without BitSwitch, a 96kHz/24-bit FLAC gets resampled to whatever your Audio MIDI Setup is set to (usually 44.1kHz), degrading quality.

## How it works

1. Polls running music player processes every second
2. Inspects their open file descriptors to find audio files
3. Reads the file header (FLAC, WAV, AIFF, MP3) for sample rate and bit depth
4. Switches the output device format via CoreAudio to match

No kernel extensions, no audio hijacking, no player plugins needed.

## Supported formats

| Format | Sample Rate | Bit Depth |
|--------|------------|-----------|
| FLAC   | From STREAMINFO header | From header |
| WAV    | From fmt chunk | From header (including extensible WAV) |
| AIFF   | From COMM chunk | From header |
| MP3    | From frame header | 16-bit (inherent to codec) |

## Supported players

Works with any player that opens audio files directly. Built-in detection for:

foobar2000, VLC, Swinsian, Audirvana, VOX, Decibel, Colibri, IINA, mpv, Cog, Amarra, JRiver

Custom players can be added at runtime.

## Requirements

- macOS 13 (Ventura) or later
- Apple Silicon (arm64)
- A USB DAC or audio interface that supports multiple sample rates

## Install

```bash
git clone https://github.com/YOUR_USERNAME/BitSwitch.git
cd BitSwitch/BitSwitch
chmod +x build.sh
./build.sh build
./build.sh install
```

This builds the app, copies it to `/Applications`, and installs a LaunchAgent so it starts automatically on login.

## Uninstall

```bash
cd BitSwitch/BitSwitch
./build.sh uninstall
```

## Usage

BitSwitch lives in the menu bar. When a supported player is running and playing an audio file:

- The menu bar shows the current format (e.g., `96/24` for 96kHz/24-bit)
- The dropdown shows the source file, its format, and the output device format
- Auto-switching can be toggled on/off
- Output device can be changed from the dropdown

When no player is running, it shows "BitSwitch" and idles.

## Build from source

Requires Xcode Command Line Tools (`xcode-select --install`).

```bash
cd BitSwitch
./build.sh build
open build/BitSwitch.app
```

## License

MIT
