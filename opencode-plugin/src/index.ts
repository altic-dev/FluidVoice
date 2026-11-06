import type { Plugin } from "@opencode-ai/plugin"
import { tool } from "@opencode-ai/plugin/tool"
import { createVoiceLoop, toggleDescription, voiceAction } from "./voice-loop.js"

const server: Plugin = async ({ client }) => {
  const voice = createVoiceLoop({
    async send(sessionID, text) {
      const result = await client.session.promptAsync({
        path: { id: sessionID },
        body: { parts: [{ type: "text", text }] },
      })
      if (result.error) throw new Error(JSON.stringify(result.error))
    },
    log(message) {
      if (process.env.FLUIDVOICE_DEBUG) {
        void client.app.log({ body: { service: "fluidvoice", level: "debug", message } }).catch(() => {})
      }
    },
  })

  return {
    tool: {
      fluidvoice_toggle: tool({
        description: toggleDescription,
        args: { action: voiceAction },
        execute: async ({ action }, { sessionID }) => voice.setEnabled(sessionID, action === "enable"),
      }),
    },
    event: async ({ event }) => {
      switch (event.type) {
        case "session.status":
          if (event.properties.status.type === "busy") voice.cancel(event.properties.sessionID)
          break
        case "session.deleted":
          voice.forget(event.properties.info.id)
          break
        case "session.idle":
        case "session.error": {
          const { sessionID } = event.properties
          const error = event.type === "session.error" ? event.properties.error : undefined
          if (!sessionID || error?.name === "MessageAbortedError") break
          void voice.notify(sessionID, async () => {
            const session = await client.session.get({ path: { id: sessionID } })
            if (!session.data || session.data.parentID) return
            const messages = await client.session.messages({ path: { id: sessionID }, query: { limit: 2 } })
            const last = messages.data?.findLast(({ info }) => info.role === "assistant")
            if (error) {
              return {
                id: `error:${last?.info.id ?? error.name}`,
                message: `OpenCode hit an error: ${error.data.message || error.name}`,
                status: "error",
              }
            }
            if (!last || last.info.role !== "assistant" || last.info.error) return
            const finish = last.parts.findLast((part) => part.type === "step-finish")?.reason ?? last.info.finish
            if (finish !== "stop" && finish !== "end_turn") return
            const message = last.parts.filter((part) => part.type === "text").map((part) => part.text).join("\n").trim()
            return { id: last.info.id, message: message || "OpenCode finished the turn." }
          })
          break
        }
      }
    },
  }
}

export default server
