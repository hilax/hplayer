import { spawn, type ChildProcess } from 'node:child_process'
import { mkdtemp, readFile, rm, stat } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { config } from '../config.js'

/**
 * 把 115 直链实时转封装成 HLS（fMP4 分片）。
 *
 * 只做 remux：视频流直接 copy，音频转 AAC。这样 mkv / DTS 这类
 * Safari 播不了的组合也能在 iOS 上播放，CPU 开销很小。
 */

interface Session {
  dir: string
  proc: ChildProcess
  finished: boolean
  error: string | null
  lastAccess: number
  stderr: string
}

const sessions = new Map<string, Session>()
const IDLE_MS = 30 * 60 * 1000

const sleep = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms))

export function getSession(id: string): Session | undefined {
  const session = sessions.get(id)
  if (session) session.lastAccess = Date.now()
  return session
}

export async function ensureSession(id: string, url: string): Promise<Session> {
  const existing = sessions.get(id)
  if (existing) {
    existing.lastAccess = Date.now()
    return existing
  }

  const dir = await mkdtemp(join(tmpdir(), 'hplayer-'))
  // -user_agent / -headers 只对 http(s) 输入有效，本地文件带上会直接报错
  const isRemote = /^https?:\/\//i.test(url)
  const args = [
    '-hide_banner',
    '-loglevel',
    'error',
    ...(isRemote
      ? ['-user_agent', config.userAgent, '-headers', 'Referer: https://115.com/\r\n']
      : []),
    '-i',
    url,
    '-map',
    '0:v:0',
    '-map',
    '0:a:0?',
    '-c:v',
    'copy',
    '-c:a',
    'aac',
    '-ac',
    '2',
    '-b:a',
    '192k',
    '-f',
    'hls',
    '-hls_time',
    '6',
    '-hls_list_size',
    '0',
    '-hls_playlist_type',
    'event',
    '-hls_segment_type',
    'fmp4',
    '-hls_fmp4_init_filename',
    'init.mp4',
    '-hls_segment_filename',
    join(dir, 'seg%d.m4s'),
    join(dir, 'index.m3u8'),
  ]

  const proc = spawn(config.ffmpeg, args, { stdio: ['ignore', 'ignore', 'pipe'] })
  const session: Session = {
    dir,
    proc,
    finished: false,
    error: null,
    lastAccess: Date.now(),
    stderr: '',
  }

  proc.stderr?.on('data', (chunk: Buffer) => {
    session.stderr = (session.stderr + chunk.toString()).slice(-4000)
  })
  proc.on('exit', (code) => {
    session.finished = true
    if (code !== 0) {
      session.error = session.stderr.trim().split('\n').slice(-3).join(' | ') || `ffmpeg exit ${code}`
    }
  })
  proc.on('error', (err) => {
    session.finished = true
    session.error = err.message
  })

  sessions.set(id, session)
  return session
}

async function waitForFile(path: string, session: Session, timeoutMs: number): Promise<boolean> {
  const deadline = Date.now() + timeoutMs
  while (Date.now() < deadline) {
    try {
      await stat(path)
      return true
    } catch {
      if (session.finished && session.error) return false
      await sleep(150)
    }
  }
  return false
}

export async function readPlaylist(id: string, session: Session): Promise<string> {
  const path = join(session.dir, 'index.m3u8')
  const ready = await waitForFile(path, session, 25_000)
  if (!ready) {
    throw new Error(session.error ?? '转封装超时，可能是 115 直链失效')
  }
  return readFile(path, 'utf8')
}

export async function readSegment(id: string, session: Session, name: string): Promise<Buffer | null> {
  if (!/^(init\.mp4|seg\d+\.m4s)$/.test(name)) return null
  const path = join(session.dir, name)
  const ready = await waitForFile(path, session, 25_000)
  if (!ready) return null
  return readFile(path)
}

export async function closeSession(id: string): Promise<void> {
  const session = sessions.get(id)
  if (!session) return
  sessions.delete(id)
  if (!session.finished) session.proc.kill('SIGKILL')
  await rm(session.dir, { recursive: true, force: true }).catch(() => {})
}

// 定期清理长时间无人访问的会话，避免临时文件堆积
setInterval(() => {
  const now = Date.now()
  for (const [id, session] of sessions) {
    if (now - session.lastAccess > IDLE_MS) {
      void closeSession(id)
    }
  }
}, 5 * 60 * 1000).unref()
