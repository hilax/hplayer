import { createHash, createHmac } from 'node:crypto'
import { openRequest } from './open.js'

const MAX_TORRENT_BYTES = 4 * 1024 * 1024

function sha1(bytes: Buffer): string {
  return createHash('sha1').update(bytes).digest('hex').toUpperCase()
}

function requireSeed(sha: string, pickCode: string): void {
  if (!/^[a-fA-F0-9]{40}$/.test(sha) || !/^[a-zA-Z0-9]{1,128}$/.test(pickCode)) {
    throw new Error('种子文件缺少有效的 SHA1 或提取码，请重新选择')
  }
}

/** 115 要求种子先上传到已授权用户的网盘，才能调用解析接口。 */
export async function uploadTorrent(name: string, encoded: string): Promise<{ sha1: string; pickCode: string }> {
  if (!name || name.length > 255 || !/\.torrent$/i.test(name) || /[\\/\x00-\x1f]/.test(name)) throw new Error('请选择 .torrent 种子文件')
  if (typeof encoded !== 'string' || encoded.length > Math.ceil(MAX_TORRENT_BYTES / 3) * 4 || !/^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/.test(encoded)) throw new Error('种子文件无效或超过 4 MB')
  const data = Buffer.from(encoded, 'base64')
  if (!data.length || data.length > MAX_TORRENT_BYTES || data[0] !== 0x64 || data[data.length - 1] !== 0x65) throw new Error('种子文件无效或超过 4 MB')
  const fileSha = sha1(data)
  const fields: Record<string, string> = { file_name: name, file_size: String(data.length), target: 'U_1_0', fileid: fileSha, preid: sha1(data.subarray(0, 128 * 1024)), topupload: '0' }
  let result = (await openRequest('/open/upload/init', { body: fields })).data
  if ([700, 701, 702].includes(Number(result?.code)) && result?.sign_key && result?.sign_check) {
    const range = /^(\d+)-(\d+)$/.exec(String(result.sign_check))
    if (!range) throw new Error('115 返回了无效的上传校验范围')
    const start = Number(range[1]); const end = Number(range[2])
    if (!Number.isSafeInteger(start) || !Number.isSafeInteger(end) || start < 0 || end < start || end >= data.length) throw new Error('115 返回了无效的上传校验范围')
    result = (await openRequest('/open/upload/init', { body: { ...fields, sign_key: String(result.sign_key), sign_val: sha1(data.subarray(start, end + 1)) } })).data
  }
  if (![1, 2].includes(Number(result?.status))) throw new Error('115 未完成种子上传初始化')
  let pickCode = String(result.pick_code ?? '')
  if (Number(result.status) === 1) {
    const token = (await openRequest('/open/upload/get_token')).data
    const callbackResult = await putObject(data, result, token)
    pickCode = String(callbackResult?.pick_code ?? callbackResult?.pickcode ?? callbackResult?.data?.pick_code ?? callbackResult?.data?.pickcode ?? pickCode)
  }
  requireSeed(fileSha, pickCode)
  return { sha1: fileSha, pickCode }
}

/** 单文件 OSS PUT：使用 115 下发的临时凭证与回调，不持久化或返回凭证。 */
async function putObject(data: Buffer, upload: any, token: any): Promise<any> {
  const endpoint = new URL(String(upload.endpoint ?? ''))
  if (endpoint.protocol !== 'https:' || endpoint.username || endpoint.password || endpoint.port || endpoint.pathname !== '/' || endpoint.search || endpoint.hash || !(endpoint.hostname === '115.com' || endpoint.hostname.endsWith('.115.com'))) throw new Error('115 返回了无效的上传地址')
  const bucket = String(upload.bucket ?? '')
  const object = String(upload.object ?? '')
  const callback = String(upload.callback?.callback ?? '')
  const callbackVar = String(upload.callback?.callback_var ?? '')
  if (!/^[a-z0-9][a-z0-9-]{1,62}$/.test(bucket) || !object || !callback || !token?.AccessKeyId || !token?.AccessKeySecret || !token?.SecurityToken) throw new Error('115 未返回完整的上传参数')
  const date = new Date().toUTCString()
  const headers: Record<string, string> = { 'x-oss-callback': callback, 'x-oss-security-token': String(token.SecurityToken) }
  if (callbackVar) headers['x-oss-callback-var'] = callbackVar
  const rate = Number(token.transfer_config?.rate)
  if (token.transfer_config?.unit === 'bytes_per_second' && Number.isInteger(rate) && rate >= 102400 && rate <= 104857600) headers['x-oss-traffic-limit'] = String(rate * 8)
  const contentType = 'application/octet-stream'
  const canonicalHeaders = Object.entries(headers).sort(([a], [b]) => a.localeCompare(b)).map(([k, v]) => `${k}:${v.trim()}\n`).join('')
  const signature = createHmac('sha1', String(token.AccessKeySecret)).update(`PUT\n\n${contentType}\n${date}\n${canonicalHeaders}/${bucket}/${object}`).digest('base64')
  const objectPath = object.split('/').map(encodeURIComponent).join('/')
  const res = await fetch(`${endpoint.origin}/${objectPath}`, {
    method: 'PUT', headers: { ...headers, Date: date, 'Content-Type': contentType, Authorization: `OSS ${token.AccessKeyId}:${signature}` }, body: new Uint8Array(data), redirect: 'error', signal: AbortSignal.timeout(120_000),
  })
  if (!res.ok) throw new Error(`种子上传失败（HTTP ${res.status}），请稍后重试`)
  const text = await res.text()
  if (!text) return {}
  try {
    const response = JSON.parse(text)
    if (response.state === false || (response.code != null && Number(response.code) !== 0)) throw new Error('115 未确认种子上传成功')
    return response
  } catch (error) {
    if (error instanceof SyntaxError) throw new Error('115 返回了无法识别的上传结果')
    throw error
  }
}

export async function torrentDirectory(cid: string, offset: number) {
  if (!/^\d+$/.test(cid) || !Number.isSafeInteger(offset) || offset < 0) throw new Error('目录参数无效')
  const limit = 200
  const response = await openRequest('/open/ufile/files', { params: { cid, offset: String(offset), limit: String(limit), show_dir: '1', cur: '1' } })
  const raw = Array.isArray(response.data) ? response.data : []
  const files = raw.filter((f: any) => String(f.fc) === '0' || /\.torrent$/i.test(String(f.fn ?? ''))).map((f: any) => ({ id: String(f.fid ?? ''), name: String(f.fn ?? ''), isDir: String(f.fc) === '0', sha1: String(f.sha1 ?? ''), pickCode: String(f.pc ?? ''), size: Number(f.fs ?? 0) }))
  const count = Number(response.count)
  return { files, nextOffset: offset + raw.length, hasMore: Number.isFinite(count) ? offset + raw.length < count && raw.length > 0 : raw.length === limit }
}

export async function parseTorrent(sha: string, pickCode: string) {
  requireSeed(sha, pickCode)
  const data = (await openRequest('/open/offline/torrent', { body: { torrent_sha1: sha, pick_code: pickCode } })).data
  if (!data || !Array.isArray(data.torrent_filelist) || !data.info_hash) throw new Error('115 未返回完整的种子信息')
  const files = data.torrent_filelist.map((file: any, index: number) => ({ index, path: String(file.path ?? ''), size: Number(file.size ?? 0), wanted: Number(file.wanted) === 1 }))
  return { name: String(data.torrent_name ?? ''), infoHash: String(data.info_hash), sha1: sha, pickCode, size: Number(data.file_size ?? 0), files }
}

export async function addTorrent(body: Record<string, unknown>) {
  const sha = String(body.sha1 ?? ''); const pickCode = String(body.pickCode ?? ''); const infoHash = String(body.infoHash ?? '')
  const wanted = String(body.wanted ?? ''); const savePath = String(body.savePath ?? '').trim(); const folder = String(body.folderId ?? '0')
  requireSeed(sha, pickCode)
  if (!/^[a-fA-F0-9]{40}$/.test(infoHash) || !/^\d+(,\d+)*$/.test(wanted) || wanted.length > 20000 || !/^\d+$/.test(folder) || !savePath || savePath.length > 512 || /[\x00-\x1f\\]/.test(savePath) || savePath.split('/').some((part) => !part || part === '.' || part === '..')) throw new Error('任务参数无效，请检查选中文件和保存路径')
  await openRequest('/open/offline/add_task_bt', { body: { info_hash: infoHash, wanted, save_path: savePath, torrent_sha1: sha, pick_code: pickCode, wp_path_id: folder } })
}

export async function torrentTasks(page: number) {
  if (!Number.isSafeInteger(page) || page < 1) throw new Error('页码无效')
  const data = (await openRequest('/open/offline/get_task_list', { params: { page: String(page) } })).data ?? {}
  return { page: Number(data.page ?? page), pageCount: Number(data.page_count ?? 0), count: Number(data.count ?? 0), tasks: (Array.isArray(data.tasks) ? data.tasks : []).map((t: any) => ({ id: String(t.info_hash ?? ''), name: String(t.name ?? ''), progress: Number(t.percentDone ?? 0), size: Number(t.size ?? 0), status: Number(t.status ?? 0) })) }
}
