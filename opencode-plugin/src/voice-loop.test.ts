import { afterEach, expect, test } from "bun:test"
import { createVoiceLoop } from "./voice-loop.js"

type RequestBody = { id: string; message?: string }

const servers: Array<{ stop(): void }> = []
afterEach(() => {
  for (const server of servers.splice(0)) server.stop()
})

function endpoint(handler: (path: string, body: RequestBody) => Response | Promise<Response>): string {
  const server = Bun.serve({
    hostname: "127.0.0.1",
    port: 0,
    async fetch(request) {
      return handler(new URL(request.url).pathname, await request.json() as RequestBody)
    },
  })
  servers.push(server)
  return server.url.origin
}

test("a reply can immediately lead to another voice prompt in the same session", async () => {
  const messages: string[] = []
  const sent: string[][] = []
  const base = endpoint((path, body) => {
    expect(path).toBe("/v1/agent/prompt")
    messages.push(body.message!)
    return Response.json({ text: ` reply ${messages.length} ` })
  })
  const voice = createVoiceLoop({
    async send(sessionID, text) {
      sent.push([sessionID, text])
      if (text === "reply 1") {
        await voice.notify(sessionID, async () => ({ id: "turn-2", message: "second" }))
      }
    },
    log() {},
  }, base)

  const first = async () => ({ id: "turn-1", message: "first" })
  await Promise.all([voice.notify("session", first), voice.notify("session", first)])
  await voice.notify("session", async () => ({ id: "turn-2", message: "second" }))
  expect(messages).toEqual(["first", "second"])
  expect(sent).toEqual([["session", "reply 1"], ["session", "reply 2"]])
})

test("starting another turn cancels only the pending request and suppresses its reply", async () => {
  const opened = Promise.withResolvers<string>()
  const reply = Promise.withResolvers<Response>()
  const cancelled: string[] = []
  const sent: string[] = []
  const base = endpoint((path, { id }) => {
    if (path === "/v1/agent/prompt") {
      opened.resolve(id)
      return reply.promise
    }
    expect(path).toBe("/v1/agent/cancel")
    cancelled.push(id)
    reply.resolve(Response.json({ text: "stale voice reply" }))
    return new Response(null, { status: 204 })
  })
  const voice = createVoiceLoop({
    async send(_sessionID, text) { sent.push(text) },
    log() {},
  }, base)

  const pending = voice.notify("session", async () => ({ id: "turn", message: "finished" }))
  const id = await opened.promise
  voice.cancel("session")
  await pending
  expect(cancelled).toEqual([id])
  expect(sent).toEqual([])
})

test("a dismissed or invalid response never submits a prompt", async () => {
  const responses = [
    new Response(null, { status: 204 }),
    Response.json({ text: 42 }),
  ]
  const sent: string[] = []
  const base = endpoint(() => responses.shift()!)
  const voice = createVoiceLoop({
    async send(_sessionID, text) { sent.push(text) },
    log() {},
  }, base)
  for (const id of ["one", "two"]) {
    await voice.notify("session", async () => ({ id, message: "finished" }))
  }
  expect(responses).toEqual([])
  expect(sent).toEqual([])
})
