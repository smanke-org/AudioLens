# AudioLens

Drive the app with `audiolens` (the app binary; `audiolens help`). See `.claude/skills/audiolens/SKILL.md`. Commands live in
`Sources/AudioLens/Agent/AgentCommands.swift`; test them on a Debug build (`swift build`) with `APP_STORE=/tmp/<name>`, which
starts a test copy on its own defaults suite (`com.smanke.AudioLens.agenttest`) that never taps apps, touches audio devices,
starts AirPlay or syncs (Release builds ignore it). Never run volume or routing writes in tests: use `--dry-run`.
