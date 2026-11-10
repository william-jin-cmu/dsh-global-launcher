/**
 * Host half: runs the hotkey helper, turns each submitted prompt into a new session, and tells open UIs to show it.
 *
 * The helper lives exactly as long as the DSH host does: the hotkeys work while DSH is running and are released
 * when it exits. A prompt starts a session (or continues the last one) the same way typing it into the UI would.
 * The bar chooses the workspace and the model from the lists sent here, and can attach the window the user was in:
 * a screenshot goes in as an image, the window's text as a second text part. What the bar was last set to is kept
 * in $DSH_HOME/global-launcher/state.json.
 */
import { execFile } from 'node:child_process'
import { randomUUID } from 'node:crypto'
import { mkdirSync, readFileSync, writeFileSync } from 'node:fs'
import { readFile, rm } from 'node:fs/promises'
import { homedir } from 'node:os'
import { basename, dirname, join } from 'node:path'
import type { Context } from '@deepseek-ai/cordis'
import Schema from '@deepseek-ai/schemastery'
import { HelperProcess, helperPath } from './helper-process.ts'
import { EVENTS_PATH, LAUNCH_PATH, POLL_HOLD_MS, type PollRequest, type PollResponse } from './protocol.ts'

export const name = 'global-launcher'

export const inject = ['sessionController', 'workspaceRegistry']

export interface Config {
  hotkey: string
  contextHotkey: string
  contextChars: number
  excludeApps: string[]
  workspace: string
  desktopApps: string[]
}

export const Config: Schema<Config> = Schema.object({
  hotkey: Schema.string()
    .default('shift+cmd+space')
    .description('The global hotkey: modifiers (cmd, ctrl, option, shift) and one key joined with +, e.g. shift+cmd+space or cmd+shift+k.'),
  contextHotkey: Schema.string()
    .default('option+cmd+space')
    .description('A second hotkey that goes to the screenshot picker first and opens the bar with the picture attached. Empty turns it off; the chips in the bar still attach a screenshot or the window text. macOS binds option+cmd+space to "Show Finder search window" by default (System Settings, Keyboard, Keyboard Shortcuts, Spotlight); turn that off or pick another key.'),
  contextChars: Schema.number().min(500).max(40_000).default(6000).description('How much of the window\'s text is attached at most.'),
  excludeApps: Schema.array(Schema.string())
    .default(['com.1password.1password', 'com.agilebits.onepassword7', 'com.bitwarden.desktop', 'com.apple.keychainaccess', 'com.apple.Passwords'])
    .description('Bundle ids whose windows are never attached.'),
  workspace: Schema.string().default('').description('Folder new sessions start in when the bar is left on "Recent workspace". Empty uses the workspace you used most recently.'),
  desktopApps: Schema.array(Schema.string())
    .default(['com.deepseek.harness'])
    .description('Bundle id prefixes of DSH desktop apps. When DSH runs inside one, it is brought to the front instead of a browser tab.'),
})

type PromptPart = { type: 'text'; text: string } | { type: 'image'; mediaType: 'image/png'; data: string; name?: string }

/** The window the bar attached, as the helper read it. */
export interface WindowContext {
  app: string
  bundle: string
  title: string
  url: string
  selected: string
  text: string
  truncated: boolean
}

interface ModelChoice {
  provider: string
  id: string
}

interface Submission {
  text: string
  /** A PNG the helper wrote for this submit; the host reads and deletes it. */
  screenshot?: string
  context?: WindowContext
  /** Start a session, or continue the most recent one. */
  target: 'new' | 'last'
  workspaceId?: string
  model?: ModelChoice
  /** Bring DSH forward and show the session afterwards. */
  openMain: boolean
}

/** What the bar was last set to. The helper owns the values; the host only keeps them across restarts. */
type Prefs = Record<string, unknown>

function statePath(): string {
  return join(process.env.DSH_HOME || join(homedir(), '.dsh'), 'global-launcher', 'state.json')
}

function loadPrefs(): Prefs {
  try {
    const parsed = JSON.parse(readFileSync(statePath(), 'utf8')) as unknown
    return parsed !== null && typeof parsed === 'object' && !Array.isArray(parsed) ? (parsed as Prefs) : {}
  } catch {
    return {}
  }
}

function modelChoice(value: unknown): ModelChoice | undefined {
  if (value === null || typeof value !== 'object') return undefined
  const { provider, id } = value as { provider?: unknown; id?: unknown }
  return typeof provider === 'string' && typeof id === 'string' && provider !== '' && id !== '' ? { provider, id } : undefined
}

/** The attached window as a text part the model can tell apart from what the user typed. */
export function contextPart(context: WindowContext): string {
  const attributes = [['app', context.app], ['title', context.title], ['url', context.url]]
    .filter(([, value]) => value !== '')
    .map(([key, value]) => ` ${key}="${value!.replace(/"/g, '\'').replace(/\s+/g, ' ').slice(0, 300)}"`)
    .join('')
  const sections: string[] = []
  if (context.selected.trim() !== '') sections.push(`Selected text:\n${context.selected.trim()}`)
  if (context.text.trim() !== '') sections.push(`Window text${context.truncated ? ' (cut short)' : ''}:\n${context.text.trim()}`)
  return `<window-context${attributes}>\nThe window the user was looking at when they wrote this.\n\n${sections.join('\n\n')}\n</window-context>`
}

/** A screenshot larger than this is dropped instead of sent. */
const SCREENSHOT_MAX_BYTES = 12 * 1024 * 1024

/** The slices of the host context this plugin uses. */
interface WorkspaceLike {
  readonly id: string
  readonly path: string
  readonly title: string
  readonly updatedAt: string
}
interface FetchRoute {
  path: string
  methods: readonly ('GET' | 'HEAD' | 'POST')[]
  requestBody: 'buffered' | 'streaming'
  fetch: (request: Request) => Promise<Response>
}
interface HostContext extends Context {
  sessionController: {
    create(request: { workspaceId?: string; cwd?: string }): Promise<{ sessionId: string }>
    selectModel(request: { sessionId: string; provider: string; model: string }): Promise<unknown>
    modelCatalog(): Promise<{ default?: { provider: string; model: string }; groups: readonly { id: string; name: string; models: readonly { id: string; name: string }[] }[] }>
    list(request: object, signal: AbortSignal): Promise<{ items: readonly { sessionId: string; updatedAt: number; blank: boolean; origin?: string }[] }>
    prompt(
      request: { requestId: string; sessionId: string; mode: 'queue' | 'steer'; content: readonly PromptPart[]; clientTimeZone?: string },
      signal: AbortSignal,
    ): Promise<{ accepted: true }>
  }
  workspaceRegistry: { list(): WorkspaceLike[]; create(path: string): Promise<WorkspaceLike> }
  connection?: { fetch: { register(route: FetchRoute): () => Promise<void> }; authenticatedUrl?(baseUrl: string): string }
  webApp?: { getAdvertisedUrl(): string }
  webServer?: { getOrigin(): string }
}

/** A launch older than this is not replayed to a UI that connects later. */
const OPEN_FRESH_MS = 60_000
/** A UI counts as open when it polled this recently (its long poll is held for POLL_HOLD_MS). */
const CLIENT_ALIVE_MS = POLL_HOLD_MS + 10_000

export function apply(ctx: HostContext, config: Config) {
  if (process.platform !== 'darwin') {
    ctx.logger.info('dsh-global-launcher only supports macOS; no hotkey on %s', process.platform)
    return
  }
  const path = helperPath(import.meta.url, 'dsh-global-launcher-helper')
  if (path === undefined) {
    ctx.logger.warn('dsh-global-launcher: bin/dsh-global-launcher-helper is missing (run the package build); no hotkey')
    return
  }

  let seq = 0
  let lastOpen: { sessionId: string; at: number } | undefined
  let lastPollAt = 0
  const waiters = new Set<() => void>()
  let disposed = false

  let prefs = loadPrefs()

  async function targetWorkspace(workspaceId: string | undefined): Promise<WorkspaceLike> {
    const chosen = workspaceId === undefined ? undefined : ctx.workspaceRegistry.list().find((workspace) => workspace.id === workspaceId)
    if (chosen !== undefined) return chosen
    if (config.workspace !== '') return ctx.workspaceRegistry.create(config.workspace)
    const recent = [...ctx.workspaceRegistry.list()].sort((a, b) => b.updatedAt.localeCompare(a.updatedAt))[0]
    return recent ?? ctx.workspaceRegistry.create(process.cwd())
  }

  /** The web UI's address with its one-time sign-in token, when this profile serves one. */
  function uiUrl(): string | undefined {
    try {
      const base = ctx.get('webApp' as any)?.getAdvertisedUrl() ?? ctx.get('webServer' as any)?.getOrigin()
      if (typeof base !== 'string') return undefined
      const connection = ctx.get('connection' as any) as HostContext['connection']
      return connection?.authenticatedUrl?.(base) ?? base
    } catch {
      return undefined
    }
  }

  /** The session a "Last" prompt continues: the one worked in most recently, whoever started it. */
  async function lastSession(): Promise<string | undefined> {
    const { items } = await ctx.sessionController.list({}, new AbortController().signal)
    return [...items].filter((item) => !item.blank && item.origin !== 'subagent').sort((a, b) => b.updatedAt - a.updatedAt)[0]?.sessionId
  }

  /** Tells the bar what it can offer. The lists change while DSH runs, so this goes out each time the bar opens. */
  async function sendOptions() {
    const recent = [...ctx.workspaceRegistry.list()].sort((a, b) => b.updatedAt.localeCompare(a.updatedAt))
    const workspaces = recent.slice(0, 30).map((workspace) => ({ id: workspace.id, title: workspace.title }))
    // The bar names the workspace and model a prompt will really get, so it needs the ones used when nothing is picked.
    const defaultWorkspaceId = (recent.find((workspace) => workspace.path === config.workspace) ?? recent[0])?.id ?? ''
    const catalog = await ctx.sessionController.modelCatalog().catch(() => undefined)
    const models = (catalog?.groups ?? []).flatMap((group) => group.models.map((model) => ({ provider: group.id, id: model.id, name: model.name, group: group.name })))
    const defaultModel = catalog?.default === undefined ? undefined : { provider: catalog.default.provider, id: catalog.default.model }
    const hasLast = await lastSession().then((sessionId) => sessionId !== undefined).catch(() => false)
    helper.send({ op: 'options', workspaces, models, defaultWorkspaceId, ...(defaultModel !== undefined ? { defaultModel } : {}), hasLast, prefs })
  }

  function savePrefs(next: Prefs) {
    prefs = next
    try {
      mkdirSync(dirname(statePath()), { recursive: true })
      writeFileSync(statePath(), JSON.stringify(next, null, 2))
    } catch (error) {
      ctx.logger.warn('global launcher could not save its settings: %s', error instanceof Error ? error.message : String(error))
    }
  }

  function bringToFront() {
    // Inside the desktop app, that app is the UI. Otherwise an open browser tab navigates on its own (it cannot be
    // raised from here), and with no tab open a new one is.
    helper.send({ op: 'activate', bundlePrefixes: config.desktopApps })
    if (Date.now() - lastPollAt < CLIENT_ALIVE_MS) return
    const url = uiUrl()
    if (url !== undefined) execFile('/usr/bin/open', [url], () => {})
  }

  /** Reads the helper's screenshot and removes it. Only the helper's own files: its output is the one input here. */
  async function takeScreenshot(path: string): Promise<PromptPart | undefined> {
    if (!/^dsh-launcher-[0-9A-Fa-f-]+\.png$/.test(basename(path))) return undefined
    try {
      const bytes = await readFile(path)
      if (bytes.length === 0 || bytes.length > SCREENSHOT_MAX_BYTES) return undefined
      return { type: 'image', mediaType: 'image/png', data: bytes.toString('base64'), name: 'screenshot.png' }
    } catch {
      return undefined
    } finally {
      await rm(path, { force: true }).catch(() => {})
    }
  }

  async function launch(submission: Submission) {
    try {
      const continued = submission.target === 'last' ? await lastSession() : undefined
      if (submission.target === 'last' && continued === undefined) throw new Error('No session to continue')
      const workspace = continued === undefined ? await targetWorkspace(submission.workspaceId) : undefined
      const content: PromptPart[] = [{ type: 'text', text: submission.text }]
      // The UI shows the parts run together, so the blank line keeps the attachment off the user's last word.
      if (submission.context !== undefined) content.push({ type: 'text', text: `\n\n${contextPart(submission.context)}` })
      const image = submission.screenshot === undefined ? undefined : await takeScreenshot(submission.screenshot)
      if (image !== undefined) content.push(image)
      const sessionId = continued ?? (await ctx.sessionController.create({ workspaceId: workspace!.id })).sessionId
      if (continued === undefined && submission.model !== undefined) {
        // A model that has gone since the bar listed it is no reason to lose the prompt: the default one answers.
        await ctx.sessionController.selectModel({ sessionId, provider: submission.model.provider, model: submission.model.id })
          .catch((error) => ctx.logger.warn('global launcher could not select %s: %s', submission.model!.id, error instanceof Error ? error.message : String(error)))
      }
      const send = (parts: PromptPart[]) => ctx.sessionController.prompt(
        { requestId: randomUUID(), sessionId, mode: 'queue', content: parts, clientTimeZone: Intl.DateTimeFormat().resolvedOptions().timeZone },
        new AbortController().signal,
      )
      let sentImage = image !== undefined
      try {
        await send(content)
      } catch (error) {
        // A text-only model refuses the whole prompt over the picture. The words still matter: send them without it.
        if (image === undefined || !/image input/i.test(error instanceof Error ? error.message : String(error))) throw error
        await send(content.filter((part) => part.type !== 'image'))
        sentImage = false
      }
      const where = workspace === undefined ? 'Sent to the last session' : `Started in ${workspace.title}`
      helper.send({ op: 'done', message: image !== undefined && !sentImage ? `${where} · this model takes no screenshots` : where })
      if (submission.openMain) {
        lastOpen = { sessionId, at: Date.now() }
        seq += 1
        for (const wake of [...waiters]) wake()
        bringToFront()
      }
      ctx.logger.info('global launcher %s session %s%s%s%s', continued === undefined ? 'started' : 'continued', sessionId, workspace === undefined ? '' : ` in ${workspace.path}`,
        submission.context !== undefined ? ` with the text of ${submission.context.app || 'a window'}` : '', sentImage ? ' and a screenshot' : '')
    } catch (error) {
      if (submission.screenshot !== undefined) await rm(submission.screenshot, { force: true }).catch(() => {})
      const message = error instanceof Error ? error.message : String(error)
      ctx.logger.warn('global launcher could not start a session: %s', message)
      helper.send({ op: 'failed', message: message.slice(0, 120) })
    }
  }

  const helperArgs = ['--hotkey', config.hotkey, '--max-chars', String(config.contextChars)]
  if (config.contextHotkey !== '') helperArgs.push('--context-hotkey', config.contextHotkey)
  // DSH's own window is never the one to attach: the window behind it is.
  for (const prefix of config.desktopApps) helperArgs.push('--ignore-bundle', `${prefix}*`)
  for (const bundle of config.excludeApps) helperArgs.push('--exclude-bundle', bundle)

  const helper = new HelperProcess({
    path,
    args: helperArgs,
    onMessage: (message) => {
      if (message.ready === true) {
        const context = typeof message.contextHotkey === 'string' ? `, ${message.contextHotkey} with the current window` : ''
        ctx.logger.info('global launcher ready on %s%s (screenshot %s, window text %s)', config.hotkey, context,
          message.screenRecording === true ? 'allowed' : 'needs Screen Recording', message.accessibility === true ? 'allowed' : 'needs Accessibility')
      } else if (message.warn === 'context_hotkey_unavailable') ctx.logger.warn('global launcher: the hotkey %s is taken by another app', config.contextHotkey)
      else if (message.error === 'bad_hotkey') ctx.logger.warn('global launcher: "%s" is not a valid hotkey (use modifiers and one key, e.g. shift+cmd+space)', config.hotkey)
      else if (message.error === 'hotkey_unavailable') ctx.logger.warn('global launcher: the hotkey %s is taken by another app', config.hotkey)
      if (message.ready === true || message.shown === true) void sendOptions().catch(() => {})
      if (message.prefs !== null && typeof message.prefs === 'object') savePrefs(message.prefs as Prefs)
      const submit = message.submit as { text?: unknown; screenshot?: unknown; context?: unknown; target?: unknown; workspaceId?: unknown; model?: unknown; openMain?: unknown } | undefined
      if (submit && typeof submit.text === 'string' && submit.text.trim() !== '') {
        const model = modelChoice(submit.model)
        void launch({
          text: submit.text.trim(),
          target: submit.target === 'last' ? 'last' : 'new',
          openMain: submit.openMain !== false,
          ...(typeof submit.workspaceId === 'string' && submit.workspaceId !== '' ? { workspaceId: submit.workspaceId } : {}),
          ...(model !== undefined ? { model } : {}),
          ...(typeof submit.screenshot === 'string' ? { screenshot: submit.screenshot } : {}),
          ...(submit.context !== null && typeof submit.context === 'object' ? { context: submit.context as WindowContext } : {}),
        })
      }
    },
    onExit: ({ code, expected, stderr }) => {
      if (!expected && !disposed && code !== 2) ctx.logger.warn('global launcher helper exited (code %s)%s', String(code), stderr ? `: ${stderr.trim().slice(-300)}` : '')
    },
  })
  helper.start()
  ctx.effect(() => () => {
    disposed = true
    helper.stop()
    for (const wake of [...waiters]) wake()
  }, 'global-launcher: stop the helper and release pollers')

  async function poll(cursor: number, signal: AbortSignal): Promise<PollResponse> {
    lastPollAt = Date.now()
    // A first poll (cursor -1) only syncs the cursor: a tab that just loaded must not jump to an old launch,
    // unless the launch is fresh, which is the tab the launcher itself just opened.
    if (cursor === seq && !signal.aborted) {
      await new Promise<void>((resolve) => {
        const done = () => {
          clearTimeout(timer)
          signal.removeEventListener('abort', done)
          waiters.delete(done)
          resolve()
        }
        const timer = setTimeout(done, POLL_HOLD_MS)
        signal.addEventListener('abort', done, { once: true })
        waiters.add(done)
      })
      lastPollAt = Date.now()
    }
    const fresh = lastOpen !== undefined && Date.now() - lastOpen.at < OPEN_FRESH_MS
    return { cursor: seq, open: cursor !== seq && fresh ? { sessionId: lastOpen!.sessionId } : null }
  }

  ctx.inject(['connection'], (scope) => {
    void (scope as HostContext).connection!.fetch.register({
      path: LAUNCH_PATH,
      methods: ['POST'],
      requestBody: 'buffered',
      fetch: async (request) => {
        const body = (await request.json().catch(() => undefined)) as { text?: unknown; screenshot?: unknown; context?: unknown; pid?: unknown; target?: unknown; workspaceId?: unknown; model?: unknown; openMain?: unknown } | undefined
        if (!body || typeof body.text !== 'string' || body.text.trim() === '') return Response.json({ error: 'Expected {text}' }, { status: 400 })
        // Through the helper, so a scripted launch takes exactly the path a typed one does.
        const accepted = helper.send({
          op: 'submit',
          text: body.text,
          screenshot: body.screenshot === true,
          context: body.context === true,
          ...(typeof body.pid === 'number' ? { pid: body.pid } : {}),
          options: { target: body.target, workspaceId: body.workspaceId, model: body.model, openMain: body.openMain },
        })
        return Response.json({ accepted }, { status: accepted ? 202 : 503 })
      },
    })
    void (scope as HostContext).connection!.fetch.register({
      path: EVENTS_PATH,
      methods: ['POST'],
      requestBody: 'buffered',
      fetch: async (request) => {
        const body = (await request.json().catch(() => undefined)) as Partial<PollRequest> | undefined
        if (!body || typeof body.cursor !== 'number') return Response.json({ error: 'Expected {cursor}' }, { status: 400 })
        return Response.json(await poll(body.cursor, request.signal), { headers: { 'Cache-Control': 'no-store' } })
      },
    })
  })
}
