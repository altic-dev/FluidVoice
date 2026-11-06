import { setTimeout as delay } from "node:timers/promises"
import type { Plugin } from "@opencode-ai/plugin-v2"
import { tool } from "@opencode-ai/plugin/tool"
import server from "./index.js"
import { createVoiceLoop, toggleDescription, voiceAction } from "./voice-loop.js"

const id = "@fluidvoice/opencode"

const setup: Plugin.Plugin["setup"] = async (context) => {
  const voice = createVoiceLoop<Parameters<typeof context.session.get>[0]["sessionID"]>({
    async send(sessionID, text) {
      await context.session.prompt({ sessionID, text })
    },
    log(message) {
      if (process.env.FLUIDVOICE_DEBUG) console.error(`[fluidvoice] ${message}`)
    },
  })
  const stream = new AbortController()

  await context.tool.transform((editor) => {
    editor.add({
      name: "fluidvoice_toggle",
      description: toggleDescription,
      input: tool.schema.object({ action: voiceAction }),
      options: { codemode: false },
      async execute({ action }, { sessionID }) {
        return { content: voice.setEnabled(sessionID, action === "enable") }
      },
    })
  })

  void (async () => {
    while (!stream.signal.aborted) {
      try {
        for await (const event of context.event.subscribe({ signal: stream.signal })) {
          switch (event.type) {
            case "session.execution.started":
              voice.cancel(event.data.sessionID)
              break
            case "session.deleted":
              voice.forget(event.data.sessionID)
              break
            case "session.execution.succeeded":
            case "session.execution.failed": {
              const { sessionID } = event.data
              void voice.notify(sessionID, async () => {
                const session = await context.session.get({ sessionID })
                if (session.parentID) return
                if (event.type === "session.execution.failed") {
                  return { id: event.id, message: `OpenCode hit an error: ${event.data.error.message}`, status: "error" }
                }
                const messages = await context.session.context({ sessionID })
                const last = messages.findLast((message) => message.type === "assistant")
                if (!last) return
                const text = last.content.filter((part) => part.type === "text").map((part) => part.text).join("\n").trim()
                return { id: last.id, message: text || "OpenCode finished the turn." }
              })
              break
            }
          }
        }
      } catch (error) {
        if (!stream.signal.aborted && process.env.FLUIDVOICE_DEBUG) console.error(`[fluidvoice] Event stream ended: ${error}`)
      }
      if (!stream.signal.aborted) await delay(1000)
    }
  })()

  return () => {
    stream.abort()
    voice.dispose()
  }
}

export default { id, server, setup }
