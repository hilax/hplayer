import type { MediaInfo, P115File, P115Status } from './types'

const TOKEN_KEY = 'hplayer_token'
const BASE_KEY = 'hplayer_base'

export class UnauthorizedError extends Error {
  constructor() {
    super('未登录')
    this.name = 'UnauthorizedError'
  }
}

/** App 内嵌模式下后端地址由用户填写；浏览器/PWA 下为空表示同源 */
export function getBaseUrl(): string {
  return localStorage.getItem(BASE_KEY) ?? ''
}

export function setBaseUrl(url: string): void {
  const trimmed = url.trim().replace(/\/+$/, '')
  if (trimmed) localStorage.setItem(BASE_KEY, trimmed)
  else localStorage.removeItem(BASE_KEY)
}

export function getToken(): string | null {
  return localStorage.getItem(TOKEN_KEY)
}

export function setToken(token: string | null): void {
  if (token) localStorage.setItem(TOKEN_KEY, token)
  else localStorage.removeItem(TOKEN_KEY)
}

/** 判断是否跑在 Capacitor 壳里 */
export function isNativeShell(): boolean {
  return location.protocol === 'capacitor:' || location.protocol === 'ionic:'
}

export function mediaUrl(path: string): string {
  return `${getBaseUrl()}${path}`
}

/** <video> 发起的请求带不了 header，只能把凭据拼进 URL */
export function withToken(url: string): string {
  const token = getToken()
  if (!token) return url
  return `${url}${url.includes('?') ? '&' : '?'}token=${encodeURIComponent(token)}`
}

async function request<T>(path: string, init?: RequestInit): Promise<T> {
  const token = getToken()
  const res = await fetch(`${getBaseUrl()}${path}`, {
    ...init,
    headers: {
      'Content-Type': 'application/json',
      ...(token ? { Authorization: `Bearer ${token}` } : {}),
      ...(init?.headers ?? {}),
    },
  })
  if (res.status === 401) {
    setToken(null)
    throw new UnauthorizedError()
  }
  const data = (await res.json().catch(() => ({}))) as Record<string, unknown>
  if (!res.ok) {
    throw new Error(typeof data.error === 'string' ? data.error : `请求失败 (${res.status})`)
  }
  return data as T
}

export const api = {
  me: () => request<{ authenticated: boolean }>('/api/me'),

  login: async (password: string) => {
    const result = await request<{ ok: true; token: string }>('/api/login', {
      method: 'POST',
      body: JSON.stringify({ password }),
    })
    setToken(result.token)
    return result
  },

  logout: async () => {
    setToken(null)
    await request<{ ok: true }>('/api/logout', { method: 'POST' }).catch(() => {})
  },

  status: () => request<P115Status>('/api/115/status'),

  setCookie: (cookie: string) =>
    request<{ ok: true; userName: string }>('/api/115/cookie', {
      method: 'POST',
      body: JSON.stringify({ cookie }),
    }),

  files: (cid: string) =>
    request<{ cid: string; files: P115File[] }>(`/api/files?cid=${encodeURIComponent(cid)}`),

  probe: (pickCode: string) =>
    request<MediaInfo>(`/api/probe?pickcode=${encodeURIComponent(pickCode)}`),

  closeHls: (pickCode: string) =>
    request<{ ok: true }>(`/api/hls/${encodeURIComponent(pickCode)}`, { method: 'DELETE' }),
}
