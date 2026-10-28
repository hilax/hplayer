import assert from 'node:assert/strict'
import { createHash } from 'node:crypto'
import { mkdtempSync, readFileSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import Fastify from 'fastify'
import cookie from '@fastify/cookie'

const dir = mkdtempSync(join(tmpdir(), 'hplayer-open-test-'))
process.env.HPLAYER_DATA = dir
process.env.HPLAYER_PASSWORD = 'test-password'
let challenge = ''
let verifier = ''
let refreshCount = 0
let downloadUA = ''
const ok = (data: unknown, extra: object = {}) => new Response(JSON.stringify({ state: true, code: 0, data, ...extra }), { status: 200, headers: { 'content-type': 'application/json' } })
globalThis.fetch = async (input, init) => {
  const url = new URL(String(input)); const body = init?.body as FormData | undefined
  const headers = new Headers(init?.headers)
  switch (url.pathname) {
    case '/open/authDeviceCode':
      assert.equal(body?.get('client_id'), 'test-app-id')
      assert.equal(body?.get('code_challenge_method'), 'sha256')
      challenge = String(body?.get('code_challenge'))
      return ok({ uid: 'test-uid', time: 1234, sign: 'test-sign', qrcode: 'https://115.com/qr-test' })
    case '/get/status/':
      assert.equal(url.searchParams.get('uid'), 'test-uid')
      return ok({ status: 2 }, { state: 1 })
    case '/open/deviceCodeToToken':
      verifier = String(body?.get('code_verifier'))
      assert.equal(challenge, createHash('sha256').update(verifier).digest('base64url'))
      return ok({ access_token: 'access-1', refresh_token: 'refresh-1', expires_in: 3600 })
    case '/open/refreshToken':
      assert.equal(body?.get('refresh_token'), refreshCount === 0 ? 'refresh-1' : 'refresh-2')
      refreshCount++
      return ok({ access_token: `access-${refreshCount + 1}`, refresh_token: `refresh-${refreshCount + 1}`, expires_in: 3600 })
    case '/open/ufile/files':
      assert.equal(headers.get('authorization'), `Bearer access-${refreshCount + 1}`)
      return ok([{ fid: '10', pid: '0', fc: '0', fn: 'Folder' }, { fid: '11', pid: '0', fc: '1', fn: 'Movie.mp4', pc: 'pick', isv: 1, fs: 123 }])
    case '/open/ufile/search':
      assert.equal(url.searchParams.get('search_value'), 'Movie')
      return ok([{ file_id: '11', parent_id: '0', file_category: '1', file_name: 'Movie.mp4', pick_code: 'pick', file_size: '123' }])
    case '/open/ufile/downurl':
      assert.equal(body?.get('pick_code'), 'pick')
      downloadUA = headers.get('user-agent') ?? ''
      return ok({ '11': { file_name: 'Movie.mp4', file_size: 123, pick_code: 'pick', url: { url: 'https://cdn.example/video' } } })
    case '/open/user/info':
      if (headers.get('authorization') === 'Bearer access-invalid') return ok(null, { state: false, code: 40140125, message: 'access token invalid' })
      return ok({ user_id: 1, user_name: 'Tester', rt_space_info: { all_use: { size: 5, size_format: '5 B' }, all_total: { size: 10, size_format: '10 B' } } })
    case '/open/video/play':
      return ok({ video_url: [{ url: 'https://cdn.example/hls', title: '1080P', definition: '3', width: 1920, height: 1080 }] })
    case '/':
      assert.match(headers.get('cookie') ?? '', /UID=new/)
      return ok({ user_id: 2, user_name: 'Cookie user' })
    case '/files':
      assert.match(headers.get('cookie') ?? '', /UID=123/)
      return ok([{ fid: '12', n: 'Legacy.mp4', pc: 'old' }])
    default: throw new Error(`Unexpected URL: ${url}`)
  }
}
const app = Fastify()
try {
  await app.register(cookie)
  const { registerRoutes } = await import('../src/routes/api.js')
  const { createToken } = await import('../src/auth.js')
  const { setCookie } = await import('../src/p115/store.js')
  await registerRoutes(app)
  const authorization = `Bearer ${createToken()}`
  const send = (method: 'GET' | 'POST', url: string, payload?: unknown, headers: Record<string, string> = {}) => app.inject({ method, url, payload, headers: { authorization, ...headers } })
  assert.equal((await app.inject({ method: 'GET', url: '/api/files' })).statusCode, 401)
  assert.equal((await send('POST', '/api/115/open/config', { clientId: 'test-app-id', clientSecret: 'must-not-be-stored' })).statusCode, 200)
  const start = (await send('POST', '/api/115/open/auth/start')).json()
  assert.equal(start.verificationUri, 'https://115.com/qr-test')
  assert.equal((await send('POST', '/api/115/open/auth/poll')).json().status, 'authorized')
  const storedPath = join(dir, '115-open.json')
  const saved = JSON.parse(readFileSync(storedPath, 'utf8'))
  assert.equal(JSON.stringify(saved).includes('must-not-be-stored'), false)
  // Trigger the proactive refresh path and verify both rotated tokens are persisted.
  const { writeFileSync } = await import('node:fs')
  writeFileSync(storedPath, JSON.stringify({ ...saved, expiresAt: 1 }))
  const list = (await send('GET', '/api/files?cid=0')).json().files
  assert.equal(list[0].isDir, true)
  assert.equal(list[1].kind, 'video')
  assert.equal(list[1].pickCode, 'pick')
  assert.equal(refreshCount, 1)
  assert.equal(JSON.parse(readFileSync(storedPath, 'utf8')).refreshToken, 'refresh-2')
  assert.equal((await send('GET', '/api/search?q=Movie')).json().files[0].name, 'Movie.mp4')
  const redirect = await send('GET', '/api/play/pick', undefined, { 'user-agent': 'test-player-UA' })
  assert.equal(redirect.statusCode, 302)
  assert.equal(redirect.headers.location, 'https://cdn.example/video')
  assert.equal(downloadUA, 'test-player-UA')
  assert.equal((await send('GET', '/api/115/quota')).json().usedBytes, 5)
  assert.equal((await send('GET', '/api/115/open/play?pickCode=pick')).json().qualities[0].title, '1080P')
  const rotated = JSON.parse(readFileSync(storedPath, 'utf8'))
  writeFileSync(storedPath, JSON.stringify({ ...rotated, accessToken: 'access-invalid' }))
  assert.equal((await send('GET', '/api/115/quota')).json().usedBytes, 5)
  assert.equal(refreshCount, 2)
  assert.equal(JSON.parse(readFileSync(storedPath, 'utf8')).refreshToken, 'refresh-3')
  setCookie('UID=123; CID=456; SEID=789; KID=000')
  assert.equal((await send('POST', '/api/115/open/source', { source: 'cookie' })).statusCode, 200)
  assert.equal((await send('GET', '/api/files')).json().files[0].name, 'Legacy.mp4')
  assert.equal((await send('POST', '/api/115/open/source', { source: 'open' })).statusCode, 200)
  assert.equal((await send('GET', '/api/files')).json().files[1].name, 'Movie.mp4')
  assert.equal((await send('POST', '/api/115/cookie', { cookie: 'UID=new; CID=456; SEID=789; KID=000' })).json().userName, 'Cookie user')
  assert.equal((await send('GET', '/api/115/open/status')).json().source, 'cookie')
  console.log('115 Open API mock regression passed')
} finally {
  await app.close()
  rmSync(dir, { recursive: true, force: true })
}
