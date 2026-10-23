# AudioLens

**Set each app's volume separately from your Mac's volume, and give every output device its own remembered volume and EQ.**

macOS has one volume for everything. A video call ends up as loud as the music behind it, a notification blasts through your headphones, and switching from AirPods to a HomePod leaves you hunting for the right level again. AudioLens gives every app that's playing its own slider (up to 150%), sends any app to the speaker or headphones you choose, and remembers each device's volume and EQ so they come back the moment it connects.

## Download

### [⬇︎ Download AudioLens.dmg](https://github.com/smanke-org/AudioLens/releases/latest/download/AudioLens.dmg)

1. Open the downloaded **AudioLens.dmg**.
2. Drag **AudioLens** onto the **Applications** folder.
3. Open AudioLens from Applications. The first time you change an app's volume, macOS asks for **System Audio Recording** permission; allow it.

Requires macOS 26 or later.

## What it does

- **Per-app volume.** Every app that's playing gets a slider, from silent to 150%. A soft limiter keeps boosted audio from distorting. Volumes are remembered across restarts.
- **No jump when it quits.** AudioLens keeps your Mac's own volume at the level of the loudest app it's adjusting and turns quieter apps down from there. If AudioLens quits or crashes, the loudest app keeps its level and the others rise only to it, never to full volume. (Settings › General, on by default.)
- **Per-app output.** Send an app to a different device than the system output, for example a call to your AirPods while music plays on the speakers.
- **Device memory.** Each output device (speakers, headphones, AirPods, HomePods, displays) keeps its own volume on each Mac. When it becomes the output again, AudioLens puts the volume back. Lock a device to keep it at that level.
- **Equalizer per device.** A 10-band EQ with presets for each output device, plus **headphone correction**: pick your headphone model from thousands of measurements in the [AutoEQ](https://github.com/jaakkopasanen/AutoEq) project, or import a ParametricEQ.txt file.
- **Recent apps.** Apps that played before stay in a Recent list until you remove them, so you can set their volume or output before they play again.
- **Pin and ignore.** Pin an app to keep it listed while it's silent. Ignore an app and AudioLens leaves it completely alone.
- **Several outputs at once.** Play on the Mac's speakers and an AirPlay HomePod (or any outputs) together. AudioLens holds the faster outputs back to match AirPlay's delay, with a sync slider to fine-tune. Several HomePods join together through Control Center as one AirPlay output.
- **AirPlay.** HomePods, Apple TVs and other AirPlay speakers on your network are listed with a Connect button. macOS only lets its own Sound settings connect them, so Connect opens Sound settings and shows which speaker to click. Once connected, a speaker is an ordinary output with its own remembered volume and EQ.
- **Global hotkeys.** Turn the playing app up or down, or mute it, from anywhere (⌃⌥↑, ⌃⌥↓, ⌃⌥M by default).
- **Choose your layout.** Source List (the default), Mixing Desk, Dial Board or Device Inspector, from Settings or the View menu (⌘1 to ⌘4). Any of them shrinks to the compact panel with ⇧⌘C, and the menu bar icon opens the same compact panel.
- **Dock, menu bar, both or neither.** Turn either icon off in Settings. With both off, open AudioLens again from Applications or Spotlight to get the window back.
- **Encrypted sync.** Turn on sync to keep app volumes, device EQ and options the same on all your Macs through iCloud Drive, end-to-end encrypted with your own passphrase. Device volumes and the window layout stay per Mac.

## How it works

AudioLens uses Core Audio process taps (macOS 14.4 and later). For an app whose sound needs changing, it captures the app's audio, mutes the original, applies the volume, EQ and limiter, and plays the result on the right device. Apps at 100% on the system output with no EQ are left untouched, so AudioLens costs nothing until you use it. Nothing is recorded or sent anywhere; the sound only passes through on your Mac.

When AudioLens quits, every app goes straight back to normal macOS output, at the level the Mac's own volume was carrying.

## Updates

AudioLens checks GitHub for new versions once a day (you can change how often, or turn it off, in Settings › Updates). It can ask first or install automatically. Automatic installs wait until no adjusted app is playing and your Mac is idle, and every download must be signed by the same developer and notarized by Apple before it's installed.

## Automation

- `audiolens://show` opens the window, `audiolens://compact` the compact panel, `audiolens://settings` Settings.

## Building

```bash
swift test          # the AudioLensKit tests: EQ math, the audio processor, AutoEQ parsing
./build_app.sh      # builds and signs .build/app/AudioLens.app with your Developer ID
./release.sh 1.0.1  # build, notarize, disk image and GitHub release
```

Headphone correction data comes from the AutoEQ project by Jaakko Pasanen (MIT License).

## License

© 2026 Steve Manke. All rights reserved.
