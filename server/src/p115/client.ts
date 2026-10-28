import { config } from '../config.js'
import { decode, encode, generateKey } from './crypto.js'
import { getCookie } from './store.js'

const API = {
  fileList: 'https://webapi.115.com/files',
  downloadUrl: 'https://proapi.115.com/app/chrome/downurl',
  fileInfo: 'https://webapi.115.com/files/get_info',
  userInfo: 'https://my.115.com/?ct=ajax&ac=nav',
}

export interface P115File {
  id: string
  parentId: string
  name: string
  isDir: boolean
  /** 115 的文件分类：video / folder / image / doc / audio / other */
  kind: string
  size: number
  pickCode: string
  sha1: string
  updatedAt: string
  thumbUrl: string
}

interface RawFile {
  fid?: string
  cid?: string | number
  pid?: string
  n?: string
  ico?: string
  s?: number | string
  pc?: string
  sha?: string
  t?: string
  u?: string
}

export class P115Error extends Error {
  constructor(
    message: string,
    readonly code?: number | string,
  ) {
    super(message)
    this.name = 'P115Error'
  }
}

function headers(): Record<string, string> {
  const cookie = getCookie()
  if (!cookie) throw new P115Error('未配置 115 Cookie')
  return {
    Cookie: cookie,
    'User-Agent': config.userAgent,
    Referer: 'https://115.com/',
    Accept: 'application/json, text/plain, */*',
  }
}

async function checkResponse(res: Response): Promise<any> {
  if (!res.ok) throw new P115Error(`115 接口返回 HTTP ${res.status}`)
  const json = (await res.json()) as any
  // 列表接口用 state，部分接口用 errno/errNo
  const ok = json.state === true || json.state === 1 || json.errno === 0 || json.errNo === 0
  if (!ok) {
    const code = json.errno ?? json.errNo ?? json.code
    const msg = json.error ?? json.msg ?? json.message ?? '未知错误'
    throw new P115Error(`115 接口错误：${msg}${code ? `（${code}）` : ''}`, code)
  }
  return json
}

export async function listDir(cid = '0', offset = 0, limit = 1000): Promise<P115File[]> {
  const params = new URLSearchParams({
    aid: '1',
    cid,
    o: 'user_ptime',
    asc: '0',
    offset: String(offset),
    show_dir: '1',
    limit: String(limit),
    snap: '0',
    natsort: '0',
    record_open_time: '1',
    format: 'json',
    fc_mix: '0',
  })
  const res = await fetch(`${API.fileList}?${params}`, { headers: headers() })
  const json = await checkResponse(res)
  const list = (json.data ?? []) as RawFile[]
  return list.map((f) => {
    // 目录项没有 fid，用 cid 作为 id
    const isDir = !f.fid
    return {
      id: isDir ? String(f.cid ?? '') : String(f.fid),
      parentId: String(f.pid ?? cid),
      name: f.n ?? '',
      isDir,
      kind: f.ico ?? '',
      size: Number(f.s ?? 0),
      pickCode: f.pc ?? '',
      sha1: f.sha ?? '',
      updatedAt: f.t ?? '',
      thumbUrl: f.u ?? '',
    }
  })
}

/** 递归取完一个目录下的所有文件（115 单页上限 1000） */
export async function listDirAll(cid = '0'): Promise<P115File[]> {
  const all: P115File[] = []
  let offset = 0
  for (;;) {
    const page = await listDir(cid, offset)
    all.push(...page)
    if (page.length < 1000) break
    offset += 1000
  }
  return all
}

export interface DownloadInfo {
  fileName: string
  fileSize: number
  pickCode: string
  url: string
}

/**
 * 用 pickcode 换取 CDN 直链。
 * 请求体是 115 私有加密格式，响应同样需要解密。
 */
export async function getDownloadInfo(pickCode: string): Promise<DownloadInfo> {
  const key = generateKey()
  const payload = Buffer.from(JSON.stringify({ pickcode: pickCode }))
  const data = encode(payload, key)

  const res = await fetch(`${API.downloadUrl}?t=${Math.floor(Date.now() / 1000)}`, {
    method: 'POST',
    headers: {
      ...headers(),
      'Content-Type': 'application/x-www-form-urlencoded',
    },
    body: new URLSearchParams({ data }).toString(),
  })
  const json = await checkResponse(res)
  const encoded = json.data
  if (typeof encoded !== 'string') throw new P115Error('115 未返回下载数据')

  const decoded = JSON.parse(decode(encoded, key).toString('utf8')) as Record<
    string,
    { file_name: string; file_size: string | number; pick_code: string; url: { url: string } }
  >
  const info = Object.values(decoded)[0]
  if (!info?.url?.url) throw new P115Error('115 未返回可用直链')

  return {
    fileName: info.file_name,
    fileSize: Number(info.file_size),
    pickCode: info.pick_code,
    url: info.url.url,
  }
}

export async function getUserInfo(): Promise<{ userId: number; userName: string; vip: number }> {
  const res = await fetch(API.userInfo, { headers: headers() })
  const json = await checkResponse(res)
  const d = json.data ?? {}
  return { userId: Number(d.user_id ?? 0), userName: String(d.user_name ?? ''), vip: Number(d.vip ?? 0) }
}

export async function getFileInfo(pickCode: string): Promise<P115File | null> {
  const res = await fetch(`${API.fileInfo}?pick_code=${encodeURIComponent(pickCode)}`, {
    headers: headers(),
  })
  const json = await checkResponse(res)
  const f = (json.data ?? [])[0] as RawFile | undefined
  if (!f) return null
  return {
    id: String(f.fid ?? ''),
    parentId: String(f.pid ?? ''),
    name: f.n ?? '',
    isDir: false,
    kind: f.ico ?? '',
    size: Number(f.s ?? 0),
    pickCode: f.pc ?? pickCode,
    sha1: f.sha ?? '',
    updatedAt: f.t ?? '',
    thumbUrl: f.u ?? '',
  }
}
