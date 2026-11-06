import { tool } from "@opencode-ai/plugin/tool"

export type Turn = {
  id: string
  message: string
  status?: "error"
}

type Host<SessionID extends string> = {
  send(sessionID: SessionID, text: string): Promise<void>
  log(message: string): void
}

export const toggleDescription =
  "Enable or disable FluidVoice voice replies for this session. Use this when the user asks to turn voice replies on or off."

export const voiceAction = tool.schema.enum(["enable", "disable"])
const replySchema = tool.schema.object({ text: tool.schema.string() })

export function createVoiceLoop<SessionID extends string>(
  host: Host<SessionID>,
  base = `http://127.0.0.1:${Number(process.env.FLUIDVOICE_PORT ?? 47733)}`,
) {
  const timeout = Number(process.env.FLUIDVOICE_TIMEOUT_MS ?? 310_000)
  const active = new Map<SessionID, AbortController>()
  const lastTurn = new Map<SessionID, string>()
  const disabled = new Set<SessionID>()

  function cancel(sessionID: SessionID) {
    active.get(sessionID)?.abort()
  }

  function setEnabled(sessionID: SessionID, enabled: boolean): string {
    if (enabled) {
      disabled.delete(sessionID)
    } else {
      disabled.add(sessionID)
      cancel(sessionID)
    }
    return `FluidVoice voice replies ${enabled ? "enabled" : "disabled"} for this session.`
  }

  async function ask(turn: Turn, signal: AbortSignal): Promise<string | undefined> {
    const id = crypto.randomUUID()
    const headers = { "Content-Type": "application/json" }
    try {
      const response = await fetch(`${base}/v1/agent/prompt`, {
        method: "POST",
        headers,
        body: JSON.stringify({ id, message: turn.message.slice(0, 3000), status: turn.status }),
        signal: AbortSignal.any([signal, AbortSignal.timeout(timeout)]),
      })
      if (response.status !== 200) {
        if (response.status !== 204) host.log(`FluidVoice returned HTTP ${response.status}`)
        return
      }
      const reply = replySchema.safeParse(await response.json())
      return reply.success ? reply.data.text.trim() : undefined
    } catch (error) {
      host.log(`FluidVoice request ended: ${error}`)
      await fetch(`${base}/v1/agent/cancel`, {
        method: "POST",
        headers,
        body: JSON.stringify({ id }),
        signal: AbortSignal.timeout(1000),
      }).catch(() => {})
    }
  }

  async function notify(sessionID: SessionID, loadTurn: () => Promise<Turn | undefined>) {
    if (disabled.has(sessionID) || active.has(sessionID)) return
    const controller = new AbortController()
    active.set(sessionID, controller)
    let reply: string | undefined
    try {
      const turn = await loadTurn()
      if (!turn || controller.signal.aborted || lastTurn.get(sessionID) === turn.id) return
      lastTurn.set(sessionID, turn.id)
      reply = await ask(turn, controller.signal)
    } catch (error) {
      host.log(`Could not read the OpenCode turn: ${error}`)
    } finally {
      active.delete(sessionID)
    }

    // Submission can trigger the next completion before its API call returns.
    if (!reply || controller.signal.aborted) return
    try {
      await host.send(sessionID, reply)
    } catch (error) {
      host.log(`OpenCode could not accept the voice reply: ${error}`)
    }
  }

  function forget(sessionID: SessionID) {
    cancel(sessionID)
    lastTurn.delete(sessionID)
    disabled.delete(sessionID)
  }

  function dispose() {
    for (const controller of active.values()) controller.abort()
  }

  return { notify, cancel, setEnabled, forget, dispose }
}
