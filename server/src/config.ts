import 'dotenv/config'
import { existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs'
import { join, resolve } from 'node:path'

const dataDir = resolve(process.env.HPLAYER_DATA ?? join(process.cwd(), 'data'))
if (!existsSync(dataDir)) mkdirSync(dataDir, { recursive: true })

export const config = {
  port: Number(process.env.PORT ?? 8787),
  host: process.env.HOST ?? '0.0.0.0',
  dataDir,
  /** 访问密码，未设置时拒绝启动，避免公网裸奔 */
  password: process.env.HPLAYER_PASSWORD ?? '',
  /** 会话签名密钥，首次启动生成后持久化 */
  sessionSecret: loadOrCreateSecret(join(dataDir, 'session.key')),
  ffmpeg: process.env.FFMPEG_PATH ?? 'ffmpeg',
  ffprobe: process.env.FFPROBE_PATH ?? 'ffprobe',
  /** 115 请求使用的 UA，CDN 会据此返回不同的直链 */
  userAgent:
    process.env.HPLAYER_UA ??
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36',
}

function loadOrCreateSecret(path: string): string {
  if (existsSync(path)) return readFileSync(path, 'utf8').trim()
  const secret = Array.from({ length: 32 }, () =>
    Math.floor(Math.random() * 256).toString(16).padStart(2, '0'),
  ).join('')
  writeFileSync(path, secret, { mode: 0o600 })
  return secret
}
