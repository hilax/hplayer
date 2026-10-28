/**
 * 用本地视频验证 HLS 转封装链路，不依赖 115。
 * 用法：npx tsx scripts/test-hls.ts <视频文件绝对路径>
 */
import { ensureSession, readPlaylist, readSegment, closeSession } from '../src/media/hls.js'

const input = process.argv[2]
if (!input) {
  console.error('用法: npx tsx scripts/test-hls.ts <视频文件>')
  process.exit(1)
}

const id = `selftest-${Date.now()}`
const session = await ensureSession(id, input)

try {
  const playlist = await readPlaylist(id, session)
  console.log('--- playlist ---')
  console.log(playlist.trim())

  const segment = playlist
    .split('\n')
    .map((line) => line.trim())
    .find((line) => line && !line.startsWith('#'))

  if (segment) {
    const data = await readSegment(id, session, segment)
    console.log(`\n--- 首个分片 ${segment}: ${data?.length ?? 0} 字节 ---`)
  }
} finally {
  await closeSession(id)
}
