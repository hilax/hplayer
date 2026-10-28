import { existsSync, readFileSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'
import { config } from '../config.js'

const cookieFile = join(config.dataDir, '115-cookie.txt')

export function getCookie(): string {
  if (process.env.P115_COOKIE) return process.env.P115_COOKIE.trim()
  if (existsSync(cookieFile)) return readFileSync(cookieFile, 'utf8').trim()
  return ''
}

export function setCookie(raw: string): void {
  const normalized = raw.replace(/\s+/g, ' ').trim()
  writeFileSync(cookieFile, normalized, { mode: 0o600 })
}

export function parseCookie(raw: string): Record<string, string> {
  const result: Record<string, string> = {}
  for (const part of raw.split(';')) {
    const idx = part.indexOf('=')
    if (idx === -1) continue
    result[part.slice(0, idx).trim()] = part.slice(idx + 1).trim()
  }
  return result
}

/** 115 登录态由 UID/CID/SEID/KID 四个字段构成 */
export function isCookieComplete(raw: string): boolean {
  const c = parseCookie(raw)
  return Boolean(c.UID && c.CID && c.SEID && c.KID)
}
