import { createHmac, timingSafeEqual } from 'node:crypto'
import type { FastifyReply, FastifyRequest } from 'fastify'
import { config } from './config.js'

export const SESSION_COOKIE = 'hplayer_session'
const MAX_AGE_SECONDS = 60 * 60 * 24 * 30 // 30 天

function sign(payload: string): string {
  return createHmac('sha256', config.sessionSecret).update(payload).digest('hex')
}

export function createToken(): string {
  const expiresAt = Date.now() + MAX_AGE_SECONDS * 1000
  const payload = String(expiresAt)
  return `${payload}.${sign(payload)}`
}

export function verifyToken(token: string | undefined): boolean {
  if (!token) return false
  const [payload, signature] = token.split('.')
  if (!payload || !signature) return false
  const expected = sign(payload)
  if (signature.length !== expected.length) return false
  if (!timingSafeEqual(Buffer.from(signature), Buffer.from(expected))) return false
  return Number(payload) > Date.now()
}

export function checkPassword(input: string): boolean {
  if (!config.password) return false
  const a = Buffer.from(input)
  const b = Buffer.from(config.password)
  if (a.length !== b.length) return false
  return timingSafeEqual(a, b)
}

export function setSessionCookie(reply: FastifyReply): void {
  reply.setCookie(SESSION_COOKIE, createToken(), {
    path: '/',
    httpOnly: true,
    sameSite: 'lax',
    maxAge: MAX_AGE_SECONDS,
    // 走 Cloudflare Tunnel / 反向代理时由客户端决定，不强制 secure，
    // 否则局域网 http 调试会登录不上
    secure: false,
  })
}

export function clearSessionCookie(reply: FastifyReply): void {
  reply.clearCookie(SESSION_COOKIE, { path: '/' })
}

/**
 * 取登录凭据：App 内嵌模式（capacitor://localhost）跨域拿不到 cookie，
 * 所以同时支持 Authorization: Bearer。
 */
export function extractToken(request: FastifyRequest): string | undefined {
  const header = request.headers.authorization
  if (header?.startsWith('Bearer ')) return header.slice(7).trim()
  // <video> 发起的 HLS 请求带不了自定义 header，只能走 query
  const query = request.query as Record<string, unknown> | undefined
  if (query && typeof query.token === 'string' && query.token) return query.token
  return request.cookies[SESSION_COOKIE]
}

/** 所有 /api 路由（登录除外）都要过这道 */
export async function requireAuth(request: FastifyRequest, reply: FastifyReply): Promise<void> {
  if (verifyToken(extractToken(request))) return
  reply.code(401).send({ error: 'unauthorized' })
}
