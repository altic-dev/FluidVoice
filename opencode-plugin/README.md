# FluidVoice for OpenCode

FluidVoice opens a floating recording HUD when OpenCode finishes a turn. Speak as soon as the HUD says **Listening**, then click **Send** or press **Return**. Your transcript becomes the next message in the same OpenCode session. Press **Esc** to dismiss the HUD. You can also start the next turn in OpenCode to dismiss a pending voice reply.

## Local setup

1. Set up a speech model and grant FluidVoice microphone access. Then enable **Settings → Experimental → Voice Agent API**. This enables the loopback Local API and allows OpenCode to start recording when a turn finishes.
2. From this plugin directory, run `bun install --frozen-lockfile` and `bun run build`.
3. Add the built plugin directory to your OpenCode config. Use the project’s `opencode.json` for one project, or `~/.config/opencode/opencode.json` for all projects.

OpenCode 2 uses `plugins`.

```json
{
  "plugins": ["file:///absolute/path/to/FluidVoice/opencode-plugin"]
}
```

OpenCode 1 uses `plugin`.

```json
{
  "plugin": ["file:///absolute/path/to/FluidVoice/opencode-plugin"]
}
```

Restart OpenCode, including its background service if you use one. Keep FluidVoice running on the same Mac. The `fluidvoice_toggle` tool lets you ask OpenCode to turn voice replies off or back on for the current session.

## Behavior

- The plugin listens for a completed turn in a top-level session. It can also show an OpenCode error so you can give a follow-up. Use OpenCode’s UI to answer its permission dialogs and structured questions.
- One HUD can record at a time. The HUD closes on Send, dismissal, or a five-minute timeout. Dismissal and empty recordings leave the session waiting for your next message.
- FluidVoice uses your selected speech model and configured dictation post-processing. Only the transcript goes back to OpenCode over the loopback API.

| Environment variable | Default | Purpose |
| --- | --- | --- |
| `FLUIDVOICE_PORT` | `47733` | FluidVoice Local API port |
| `FLUIDVOICE_TIMEOUT_MS` | `310000` | Plugin deadline for a voice reply |
| `FLUIDVOICE_DEBUG` | unset | Set to `1` for plugin diagnostics |

## Development

Run `bun run typecheck`, `bun test`, and `bun run build` from this directory.
