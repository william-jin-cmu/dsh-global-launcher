/** Wire contract between the host half (index.ts) and the browser half (client.tsx). */

/** Long-poll: answers at once when a session was launched since `cursor`, else holds up to POLL_HOLD_MS. */
export const EVENTS_PATH = '/api/global-launcher/events'
export const POLL_HOLD_MS = 25_000

export interface PollRequest {
  /** The cursor of the last answer, or -1 on the first poll. */
  cursor: number
}

export interface PollResponse {
  cursor: number
  /** The session the launcher started most recently, when it is newer than `cursor` and still fresh. */
  open: { sessionId: string } | null
}

/**
 * Submits a prompt as if it had been typed into the bar (for scripts and other launchers).
 * Body: `{ text, screenshot?, context?, pid?, target?, workspaceId?, model?, openMain? }`. `screenshot` and `context`
 * attach the frontmost window, or the front window of the app `pid`. `target` is `new` (default) or `last`, `model`
 * is `{ provider, id }`, and `openMain: false` leaves DSH in the background.
 */
export const LAUNCH_PATH = '/api/global-launcher/launch'
