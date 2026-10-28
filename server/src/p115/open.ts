import { createHash, randomBytes } from 'node:crypto'
import { existsSync, readFileSync, renameSync, writeFileSync } from 'node:fs'
import { join } from 'node:path'
import { config } from '../config.js'
import type { DownloadInfo, P115File, QuotaInfo } from './client.js'

// 115 Open Platform device authorization uses PKCE; no AppSecret is sent or stored.
const path = join(config.dataDir, '115-open.json')
interface Saved { clientId: string; accessToken?: string; refreshToken?: string; expiresAt?: number; source?: 'open' | 'cookie' }
interface Pending { uid: string; time: string; sign: string; verifier: string; expiresAt: number }
let pending: Pending | undefined
interface WebPending { state: string; clientId: string; secret?: string; redirectUri: string; expiresAt: number; status: 'pending' | 'authorized' | 'failed'; processing?: boolean }
let webPending: WebPending | undefined
let refreshing: Promise<void> | undefined
let polling: Promise<{ status: 'pending' | 'authorized' | 'expired'; message?: string }> | undefined

function load(): Saved {
  if (!existsSync(path)) return { clientId: '' }
  try { return JSON.parse(readFileSync(path, 'utf8')) as Saved } catch { throw new Error('115 开放平台配置文件无法读取') }
}
function save(data: Saved): void {
  const temp = `${path}.${randomBytes(8).toString('hex')}.tmp`
  writeFileSync(temp, JSON.stringify(data), { mode: 0o600 })
  renameSync(temp, path)
}
export function configureOpen(clientId: string): void {
  const id = clientId.trim()
  if (!id || id.length > 200) throw new Error('请输入有效的 AppID')
  const old = load()
  save(old.clientId === id ? old : { clientId: id })
  pending = undefined
  if (webPending) webPending.secret = undefined
  webPending = undefined
}
export function openState() {
  const saved = load()
  return { configured: !!saved.clientId, authorized: !!saved.refreshToken, source: saved.source ?? (saved.refreshToken ? 'open' : 'cookie') }
}
export function setSource(source: 'open' | 'cookie'): void {
  const saved = load()
  if (source === 'open' && !saved.refreshToken) throw new Error('请先完成开放平台授权')
  save({ ...saved, source })
}
export function useOpen(): boolean { const state = openState(); return state.authorized && state.source === 'open' }

async function json(url: string, init?: RequestInit): Promise<any> {
  const res = await fetch(url, { ...init, signal: AbortSignal.timeout(30000) })
  if (!res.ok) throw new Error(`115 开放平台返回 HTTP ${res.status}`)
  const result: any = await res.json()
  if ((result.code != null && Number(result.code) !== 0) || result.error || result.state === false) {
    const error = new Error(`115 开放平台：${result.message || result.error || '请求失败'}${result.code ? `（${result.code}）` : ''}`)
    ;(error as Error & { code?: number }).code = Number(result.code || result.errno)
    throw error
  }
  return result
}
function form(data: Record<string, string>): FormData {
  const result = new FormData()
  for (const [key, value] of Object.entries(data)) result.set(key, value)
  return result
}
function storeTokens(data: any): void {
  if (!data?.access_token || !data?.refresh_token) throw new Error('115 未返回完整的授权令牌')
  save({ ...load(), accessToken: String(data.access_token), refreshToken: String(data.refresh_token), expiresAt: Date.now() + Number(data.expires_in || 7200) * 1000 })
}
export async function startOpenAuth() {
  const { clientId } = load()
  if (!clientId) throw new Error('请先填写 AppID')
  const verifier = randomBytes(32).toString('base64url')
  const challenge = createHash('sha256').update(verifier).digest('base64url')
  const result = await json('https://passportapi.115.com/open/authDeviceCode', {
    method: 'POST', body: new URLSearchParams({ client_id: clientId, code_challenge: challenge, code_challenge_method: 'sha256' }),
  })
  const d = result.data
  if (!d?.uid || !d?.time || !d?.sign || !d?.qrcode) throw new Error('115 未返回完整的扫码授权信息')
  if (webPending) webPending.secret = undefined
  webPending = undefined
  // The endpoint does not supply an expiry; cap the local session to five minutes.
  pending = { uid: String(d.uid), time: String(d.time), sign: String(d.sign), verifier, expiresAt: Date.now() + 300_000 }
  return { verificationUri: String(d.qrcode), userCode: '', expiresIn: 300 }
}
export async function pollOpenAuth(): Promise<{ status: 'pending' | 'authorized' | 'expired'; message?: string }> {
  if (!polling) polling = doPollOpenAuth().finally(() => { polling = undefined })
  return polling
}
async function doPollOpenAuth() {
  if (!pending || Date.now() >= pending.expiresAt) { pending = undefined; return { status: 'expired' as const } }
  const current = pending
  const q = new URLSearchParams({ uid: current.uid, time: current.time, sign: current.sign })
  let result: any
  try { result = await json(`https://qrcodeapi.115.com/get/status/?${q}`) }
  catch (error) {
    if (error instanceof Error && (error.name === 'TimeoutError' || error.name === 'AbortError')) return { status: 'pending' as const }
    throw error
  }
  if (result.state === 0) { pending = undefined; return { status: 'expired' as const, message: '二维码已失效' } }
  const d = result.data
  const status = Number(d?.status)
  if (status === -1 || status === -2) { pending = undefined; return { status: 'expired' as const, message: '二维码已失效或授权已取消' } }
  if (status !== 2) return { status: 'pending' as const, message: status === 1 ? '已扫码，请在 115 中确认授权' : '等待扫码' }
  const tokens = await json('https://passportapi.115.com/open/deviceCodeToToken', { method: 'POST', body: new URLSearchParams({ uid: current.uid, code_verifier: current.verifier }) })
  if (pending !== current) throw new Error('授权请求已被新的配置替换，请重新开始')
  storeTokens(tokens.data)
  setSource('open')
  pending = undefined
  return { status: 'authorized' as const }
}
async function refresh(): Promise<void> {
  if (!refreshing) refreshing = (async () => {
    const saved = load()
    if (!saved.refreshToken) throw new Error('请先授权 115 开放平台')
    const result = await json('https://passportapi.115.com/open/refreshToken', { method: 'POST', body: new URLSearchParams({ refresh_token: saved.refreshToken }) })
    const current = load()
    if (current.clientId !== saved.clientId || current.refreshToken !== saved.refreshToken) throw new Error('115 授权已变更，请重试')
    storeTokens(result.data)
  })().finally(() => { refreshing = undefined })
  return refreshing
}
async function request(endpoint: string, options: { params?: Record<string, string>; body?: Record<string, string>; ua?: string } = {}, retried = false): Promise<any> {
  let saved = load()
  if (!saved.accessToken || (saved.expiresAt && Date.now() >= saved.expiresAt - 60_000)) { await refresh(); saved = load() }
  const query = options.params ? `?${new URLSearchParams(options.params)}` : ''
  try {
    return await json(`https://proapi.115.com${endpoint}${query}`, {
      method: options.body ? 'POST' : 'GET',
      headers: { Authorization: `Bearer ${saved.accessToken}`, 'User-Agent': options.ua || config.userAgent },
      body: options.body ? form(options.body) : undefined,
    })
  } catch (error) {
    const code = (error as Error & { code?: number }).code
    if (!retried && (code === 40140125 || code === 40140126)) {
      if (load().accessToken === saved.accessToken) await refresh()
      return request(endpoint, options, true)
    }
    throw error
  }
}
export const openRequest = request

/** 授权码模式需要已登记的 HTTPS 回调；secret 只在本次授权期间保存在内存。 */
export function startWebAuth(secret: string, redirectUri: string) {
  const { clientId } = load()
  if (!clientId) throw new Error('请先保存 AppID')
  if (!secret || secret.length > 1024) throw new Error('请填写 AppSecret')
  let url: URL
  try { url = new URL(redirectUri) } catch { throw new Error('请填写有效的 HTTPS 回调地址') }
  if (url.protocol !== 'https:' || url.username || url.password || url.pathname !== '/api/115/open/auth/callback' || url.search || url.hash) throw new Error('回调地址必须是已在 115 登记的 HTTPS 域名，并以 /api/115/open/auth/callback 结尾')
  const state = randomBytes(32).toString('base64url')
  pending = undefined
  if (webPending) webPending.secret = undefined
  const current: WebPending = { state, clientId, secret, redirectUri: url.toString(), expiresAt: Date.now() + 10 * 60_000, status: 'pending' }
  webPending = current
  setTimeout(() => { if (webPending === current) { current.secret = undefined; webPending = undefined } }, 10 * 60_000).unref()
  const authorization = new URL('https://passportapi.115.com/open/authorize')
  authorization.search = new URLSearchParams({ client_id: clientId, redirect_uri: url.toString(), response_type: 'code', state }).toString()
  return { authorizationUrl: authorization.toString(), expiresIn: 600 }
}

export function webAuthStatus() {
  if (!webPending || Date.now() >= webPending.expiresAt) { if (webPending) webPending.secret = undefined; webPending = undefined; return { status: 'expired' } }
  return { status: webPending.status }
}

export function failWebAuth(state: string): void {
  if (webPending && webPending.state === state && webPending.status === 'pending' && !webPending.processing) {
    webPending.secret = undefined
    webPending.status = 'failed'
  }
}

export async function completeWebAuth(state: string, code: string): Promise<boolean> {
  const current = webPending
  if (!current || Date.now() >= current.expiresAt || current.state !== state || current.status !== 'pending' || current.processing || !code || code.length > 4096) return false
  current.processing = true
  try {
    const result = await json('https://passportapi.115.com/open/authCodeToToken', { method: 'POST', body: new URLSearchParams({ client_id: current.clientId, client_secret: current.secret ?? '', code, redirect_uri: current.redirectUri, grant_type: 'authorization_code' }) })
    if (webPending !== current || load().clientId !== current.clientId) return false
    storeTokens(result.data)
    setSource('open')
    current.status = 'authorized'
    return true
  } catch {
    if (webPending === current) current.status = 'failed'
    return false
  } finally {
    current.secret = undefined
  }
}
function listFile(f: any, parent: string): P115File {
  const isDir = String(f.fc) === '0'
  return { id: String(f.fid ?? ''), parentId: String(f.pid ?? parent), name: String(f.fn ?? ''), isDir,
    kind: isDir ? 'folder' : Number(f.isv) === 1 ? 'video' : String(f.ico ?? ''), size: Number(f.fs ?? 0),
    pickCode: String(f.pc ?? ''), sha1: String(f.sha1 ?? ''), updatedAt: String(f.uet ?? ''), thumbUrl: String(f.thumb ?? f.v_img ?? '') }
}
export async function openList(cid: string, offset: number, limit: number): Promise<P115File[]> {
  const result = await request('/open/ufile/files', { params: { cid, offset: String(offset), limit: String(limit), show_dir: '1', cur: '1' } })
  return (Array.isArray(result.data) ? result.data : []).map((f: any) => listFile(f, cid))
}
export async function openSearch(keyword: string): Promise<P115File[]> {
  const result = await request('/open/ufile/search', { params: { search_value: keyword, limit: '100', offset: '0' } })
  return (Array.isArray(result.data) ? result.data : []).map((f: any) => ({
    id: String(f.file_id ?? ''), parentId: String(f.parent_id ?? '0'), name: String(f.file_name ?? ''),
    isDir: String(f.file_category) === '0', kind: String(f.file_category) === '0' ? 'folder' : /\.(mp4|mkv|mov|m4v|avi|ts|webm|wmv|flv)$/i.test(String(f.file_name)) ? 'video' : String(f.ico ?? ''),
    size: Number(f.file_size ?? 0), pickCode: String(f.pick_code ?? ''), sha1: String(f.sha1 ?? ''), updatedAt: String(f.user_utime ?? ''), thumbUrl: '',
  }))
}
export async function openDownload(pickCode: string, ua?: string): Promise<DownloadInfo> {
  const result = await request('/open/ufile/downurl', { body: { pick_code: pickCode }, ua })
  const info: any = Object.values(result.data ?? {})[0]
  if (!info?.url?.url) throw new Error('115 未返回可用直链')
  return { fileName: String(info.file_name ?? ''), fileSize: Number(info.file_size ?? 0), pickCode: String(info.pick_code ?? pickCode), url: String(info.url.url) }
}
export async function openUser(): Promise<{ userId: number; userName: string; vip: number; quota: QuotaInfo }> {
  const result = await request('/open/user/info')
  const d = result.data ?? {}; const space = d.rt_space_info ?? {}
  return { userId: Number(d.user_id ?? 0), userName: String(d.user_name ?? ''), vip: 0,
    quota: { usedText: String(space.all_use?.size_format ?? ''), totalText: String(space.all_total?.size_format ?? ''), usedBytes: Number(space.all_use?.size ?? 0), totalBytes: Number(space.all_total?.size ?? 0) } }
}
