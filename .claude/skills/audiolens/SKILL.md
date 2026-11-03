---
name: audiolens
description: Drive AudioLens, the per-app volume app on this Mac, from the shell with the `audiolens` command: list the apps playing and the output devices, set an app's volume, mute or output, a device's volume and EQ, the system output, several outputs at once and multi-room AirPlay. Use when the user asks about app volumes, what's playing, their speakers or headphones, or names AudioLens.
---

# AudioLens

`audiolens` runs commands in the AudioLens app. Changes show in its window at once.
If the app is closed, the command opens it in the background (its window stays shut). If
`audiolens` isn't on PATH, use `/Applications/AudioLens.app/Contents/MacOS/AudioLens` the same way.

## Rules

- Always add `--json` and read the JSON. Exit 0 is ok; otherwise read `error.code` and
  `error.message`, and do what the message says.
- Name apps by bundle ID (from `audiolens apps list --all`), by name, or `playing` (the app the
  hotkeys act on). Name devices by UID or name (from `audiolens outputs list`), or `system`.
- Writes change what the person hears right away. Only run them when asked, and when unsure,
  add `--dry-run` first and show the person `wouldChange`.
- `group set` and `multiroom set` send every app through AudioLens. Ask before turning them on.
- Multi-room AirPlay speakers are picked by the person in the window; no command can pick them.
- To try something without real audio, run a Debug build with `APP_STORE=/tmp/audiolens-test`
  in front: a test copy with its own settings and no devices.

## Main commands

| Command | Does |
| --- | --- |
| `audiolens status --json` | Version, system output and volume, the playing app, counts, permission |
| `audiolens apps list [--all] [--playing] --json` | Apps with volume (percent), muted, pinned, ignored, output |
| `audiolens apps set <app> [--volume 0-150] [--muted] [--output <device>\|system] [--dry-run] --json` | Change one app |
| `audiolens outputs list [--all] --json` | Devices with volume, EQ preset, restore, lock, group |
| `audiolens outputs set <device> [--volume 0-100] [--eq-preset NAME] [--eq false] [--dry-run] --json` | Change a device |
| `audiolens outputs use <device> [--dry-run] --json` | Make it the system output |

Also `group show/set`, `multiroom show/set` and `window open`. Everything else:
`audiolens help`, and `audiolens help <command>` for its options.
