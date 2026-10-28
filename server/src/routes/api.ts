import type { FastifyInstance } from 'fastify'
import {
  checkPassword,
  clearSessionCookie,
  createToken,
  extractToken,
  requireAuth,
  setSessionCookie,
  verifyToken,
} from '../auth.js'
import {
  getDownloadInfo,
  getFileInfo,
  getQuota,
  getUserInfo,
  listDir,
  P115Error,
  searchFiles,
} from '../p115/client.js'
import { getCookie, isCookieComplete, setCookie } from '../p115/store.js'
import { closeSession, ensureSession, getSession, readPlaylist, readSegment } from '../media/hls.js'
import { probe } from '../media/probe.js'

export async function registerRoutes(app: FastifyInstance): Promise<void> {
  // ---- 登录 ----
  app.post('/api/login', async (request, reply) => {
    const { password } = (request.body ?? {}) as { password?: string }
    if (!password || !checkPassword(password)) {
      return reply.code(401).send({ error: '密码错误' })
    }
    setSessionCookie(reply)
    return { ok: true, token: createToken() }
  })

  app.post('/api/logout', async (_request, reply) => {
    clearSessionCookie(reply)
    return { ok: true }
  })

  app.get('/api/me', async (request) => ({
    authenticated: verifyToken(extractToken(request)),
  }))

  // ---- 115 账号 ----
  app.get('/api/115/status', { preHandler: requireAuth }, async () => {
    const cookie = getCookie()
    if (!isCookieComplete(cookie)) {
      return { configured: false, message: '未配置 Cookie，或缺少 UID/CID/SEID/KID' }
    }
    try {
      const user = await getUserInfo()
      return { configured: true, ...user }
    } catch (error) {
      return {
        configured: true,
        error: error instanceof Error ? error.message : String(error),
        message: 'Cookie 可能已失效，请重新获取',
      }
    }
  })

  app.post('/api/115/cookie', { preHandler: requireAuth }, async (request, reply) => {
    const { cookie } = (request.body ?? {}) as { cookie?: string }
    if (!cookie || !isCookieComplete(cookie)) {
      return reply.code(400).send({ error: 'Cookie 不完整，需要包含 UID、CID、SEID、KID' })
    }
    setCookie(cookie)
    try {
      const user = await getUserInfo()
      return { ok: true, ...user }
    } catch (error) {
      return reply.code(400).send({
        error: error instanceof Error ? error.message : String(error),
      })
    }
  })

  // ---- 容量与搜索 ----
  app.get('/api/115/quota', { preHandler: requireAuth }, async (_request, reply) => {
    try {
      return await getQuota()
    } catch (error) {
      return sendP115Error(reply, error)
    }
  })

  app.get('/api/search', { preHandler: requireAuth }, async (request, reply) => {
    const { q } = request.query as { q?: string }
    if (!q) return reply.code(400).send({ error: '缺少搜索关键词' })
    try {
      return { files: await searchFiles(q) }
    } catch (error) {
      return sendP115Error(reply, error)
    }
  })

  // ---- 文件浏览 ----
  app.get('/api/files', { preHandler: requireAuth }, async (request, reply) => {
    const { cid = '0' } = request.query as { cid?: string }
    try {
      const files = await listDir(cid)
      return { cid, files }
    } catch (error) {
      return sendP115Error(reply, error)
    }
  })

  // ---- 媒体信息 ----
  app.get('/api/probe', { preHandler: requireAuth }, async (request, reply) => {
    const { pickcode } = request.query as { pickcode?: string }
    if (!pickcode) return reply.code(400).send({ error: '缺少 pickcode' })
    try {
      const info = await getDownloadInfo(pickcode)
      const media = await probe(info.url)
      return { ...media, fileName: info.fileName, fileSize: info.fileSize }
    } catch (error) {
      return sendP115Error(reply, error)
    }
  })

  // ---- 直链播放（Safari 原生可播的格式走这里）----
  app.get('/api/play/:pickcode', { preHandler: requireAuth }, async (request, reply) => {
    const { pickcode } = request.params as { pickcode: string }
    try {
      const info = await getDownloadInfo(pickcode)
      return reply.redirect(info.url, 302)
    } catch (error) {
      return sendP115Error(reply, error)
    }
  })

  // ---- HLS 转封装播放（mkv / DTS 等走这里）----
  app.get('/api/hls/:pickcode/index.m3u8', { preHandler: requireAuth }, async (request, reply) => {
    const { pickcode } = request.params as { pickcode: string }
    try {
      let session = getSession(pickcode)
      if (!session) {
        const info = await getDownloadInfo(pickcode)
        session = await ensureSession(pickcode, info.url)
      }
      const playlist = await readPlaylist(pickcode, session)
      // 把登录凭据注入到每个分片 URI，video 元素自己不会带 header
      const token = extractToken(request)
      const body = token ? injectToken(playlist, token) : playlist
      return reply.type('application/vnd.apple.mpegurl').send(body)
    } catch (error) {
      return sendP115Error(reply, error)
    }
  })

  app.get('/api/hls/:pickcode/:segment', { preHandler: requireAuth }, async (request, reply) => {
    const { pickcode, segment } = request.params as { pickcode: string; segment: string }
    const session = getSession(pickcode)
    if (!session) return reply.code(404).send({ error: '会话不存在或已过期' })
    const data = await readSegment(pickcode, session, segment)
    if (!data) return reply.code(404).send({ error: '片段不可用' })
    const type = segment.endsWith('.m4s') ? 'video/iso.segment' : 'video/mp4'
    return reply.type(type).send(data)
  })

  app.delete('/api/hls/:pickcode', { preHandler: requireAuth }, async (request) => {
    const { pickcode } = request.params as { pickcode: string }
    await closeSession(pickcode)
    return { ok: true }
  })

  // ---- 文件详情 ----
  app.get('/api/file/:pickcode', { preHandler: requireAuth }, async (request, reply) => {
    const { pickcode } = request.params as { pickcode: string }
    try {
      const file = await getFileInfo(pickcode)
      if (!file) return reply.code(404).send({ error: '文件不存在' })
      return file
    } catch (error) {
      return sendP115Error(reply, error)
    }
  })
}

/** 给 m3u8 里的 init 分片和普通分片都追加 token 参数 */
function injectToken(playlist: string, token: string): string {
  const query = `token=${encodeURIComponent(token)}`
  const withInit = playlist.replace(
    /(#EXT-X-MAP:URI=")([^"]+)(")/g,
    (_match, head: string, uri: string, tail: string) =>
      `${head}${uri}${uri.includes('?') ? '&' : '?'}${query}${tail}`,
  )
  return withInit
    .split('\n')
    .map((line) => {
      const trimmed = line.trim()
      if (!trimmed || trimmed.startsWith('#')) return line
      return `${trimmed}${trimmed.includes('?') ? '&' : '?'}${query}`
    })
    .join('\n')
}

function sendP115Error(reply: any, error: unknown) {
  const message = error instanceof Error ? error.message : String(error)
  const status = error instanceof P115Error ? 400 : 500
  return reply.code(status).send({ error: message })
}
