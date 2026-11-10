/** Client half (browser): opens the session the launcher just started, in whichever DSH window is open. */
import { EVENTS_PATH, type PollRequest, type PollResponse } from './protocol.ts'

interface ClientContext {
  /** Slice of `ctx.uiWorkspace` (@deepseek-ai/dsh-client-ui-workspace). */
  uiWorkspace: { openSession(sessionId: string): void }
  effect(execute: () => () => void, label?: string): void
}

export const inject = ['uiWorkspace']

/** POST to the plugin's /api route. Document-relative so a prefix-mounting proxy still works. */
async function poll(body: PollRequest, signal: AbortSignal): Promise<PollResponse> {
  const response = await fetch(EVENTS_PATH.slice(1), {
    method: 'POST',
    credentials: 'same-origin',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify(body),
    signal,
  })
  if (!response.ok) throw new Error(`HTTP ${response.status}`)
  return (await response.json()) as PollResponse
}

export function apply(ctx: ClientContext) {
  ctx.effect(() => {
    const abort = new AbortController()
    void (async () => {
      let cursor = -1
      let failures = 0
      while (!abort.signal.aborted) {
        try {
          const answer = await poll({ cursor }, abort.signal)
          cursor = answer.cursor
          failures = 0
          if (answer.open !== null) ctx.uiWorkspace.openSession(answer.open.sessionId)
        } catch {
          if (abort.signal.aborted) return
          // Host restarting or the plugin unloaded: back off instead of spinning.
          failures += 1
          await new Promise((resolve) => setTimeout(resolve, Math.min(30_000, 1000 * 2 ** failures)))
        }
      }
    })()
    return () => abort.abort()
  }, 'global-launcher: follow launched sessions')
}
