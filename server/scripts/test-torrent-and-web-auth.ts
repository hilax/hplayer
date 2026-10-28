import assert from 'node:assert/strict'
import { createHash, createHmac } from 'node:crypto'
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import Fastify from 'fastify'
import cookie from '@fastify/cookie'

const dir = mkdtempSync(join(tmpdir(), 'hplayer-torrent-test-'))
process.env.HPLAYER_DATA = dir
process.env.HPLAYER_PASSWORD = 'test-password'
const bytes = Buffer.from('d4:infod4:name4:testee')
const fileSha = createHash('sha1').update(bytes).digest('hex').toUpperCase()
const infoHash = 'A'.repeat(40)
let initCount = 0
let added = 0
const ok = (data: unknown, extra: object = {}) => new Response(JSON.stringify({ state: true, code: 0, data, ...extra }), { status: 200, headers: { 'content-type': 'application/json' } })
globalThis.fetch = async (input, init) => {
  const url = new URL(String(input))
  const body = init?.body as FormData | URLSearchParams | Uint8Array | undefined
  const headers = new Headers(init?.headers)
  if (url.hostname === 'up-file.115.com') {
    assert.equal(url.pathname, '/folder/object')
    assert.deepEqual(Buffer.from(body as Uint8Array), bytes)
    const canonical = ['x-oss-callback', 'x-oss-callback-var', 'x-oss-security-token', 'x-oss-traffic-limit'].map((key) => `${key}:${headers.get(key)}\n`).join('')
    const signed = `PUT\n\napplication/octet-stream\n${headers.get('date')}\n${canonical}/bucket/folder/object`
    const signature = createHmac('sha1', 'temporary-secret').update(signed).digest('base64')
    assert.equal(headers.get('authorization'), `OSS temporary-id:${signature}`)
    assert.equal(headers.get('x-oss-traffic-limit'), '819200')
    return ok({ pick_code: 'seed123' })
  }
  switch (url.pathname) {
    case '/open/upload/init': {
      assert.ok(body instanceof FormData)
      assert.equal(body.get('fileid'), fileSha)
      assert.equal(body.get('target'), 'U_1_0')
      initCount++
      if (initCount === 1) return ok({ status: 7, code: 701, sign_key: 'check', sign_check: '0-3' })
      assert.equal(body.get('sign_key'), 'check')
      assert.equal(body.get('sign_val'), createHash('sha1').update(bytes.subarray(0, 4)).digest('hex').toUpperCase())
      return ok({ status: 1, code: 0, pick_code: 'seed123', endpoint: 'https://up-file.115.com', bucket: 'bucket', object: 'folder/object', callback: { callback: 'callback', callback_var: 'callbackvar' } })
    }
    case '/open/upload/get_token':
      return ok({ AccessKeyId: 'temporary-id', AccessKeySecret: 'temporary-secret', SecurityToken: 'temporary-token', transfer_config: { rate: 102400, unit: 'bytes_per_second' } })
    case '/open/ufile/files':
      return ok([{ fid: '1', fc: '0', fn: 'Folder' }, { fid: '2', fc: '1', fn: 'seed.torrent', pc: 'seed123', sha1: fileSha, fs: 22 }, { fid: '3', fc: '1', fn: 'other.txt' }], { count: 3 })
    case '/open/offline/torrent':
      assert.ok(body instanceof FormData)
      assert.equal(body.get('torrent_sha1'), fileSha)
      assert.equal(body.get('pick_code'), 'seed123')
      return ok({ torrent_name: 'Example', info_hash: infoHash, file_size: 30, torrent_filelist: [{ path: 'movie.mkv', size: 20, wanted: 1 }, { path: 'readme.txt', size: 10, wanted: 0 }] })
    case '/open/offline/add_task_bt':
      assert.ok(body instanceof FormData)
      assert.equal(body.get('wanted'), '0')
      assert.equal(body.get('save_path'), 'HPlayer')
      assert.equal(body.get('wp_path_id'), '0')
      assert.equal(body.get('info_hash'), infoHash)
      added++
      return ok([])
    case '/open/offline/get_task_list':
      return ok({ page: 1, page_count: 1, count: 1, tasks: [{ info_hash: infoHash, name: 'Example', status: 1, percentDone: 25, size: 30 }] })
    case '/open/authCodeToToken':
      assert.ok(body instanceof URLSearchParams)
      assert.equal(body.get('client_id'), 'app-id')
      assert.equal(body.get('client_secret'), 'private-secret')
      assert.equal(body.get('code'), 'code-once')
      assert.equal(body.get('redirect_uri'), 'https://hplayer.example.com/api/115/open/auth/callback')
      return ok({ access_token: 'new-access', refresh_token: 'new-refresh', expires_in: 3600 })
    default: throw new Error(`Unexpected test request: ${url.pathname}`)
  }
}

const app = Fastify()
try {
  await app.register(cookie)
  const { registerRoutes } = await import('../src/routes/api.js')
  const { createToken } = await import('../src/auth.js')
  writeFileSync(join(dir, '115-open.json'), JSON.stringify({ clientId: 'app-id', source: 'open', accessToken: 'access', refreshToken: 'refresh', expiresAt: Date.now() + 3600000 }))
  await registerRoutes(app)
  const authorization = `Bearer ${createToken()}`
  const send = (method: 'GET' | 'POST', url: string, payload?: unknown) => app.inject({ method, url, payload, headers: { authorization } })
  assert.equal((await app.inject({ method: 'GET', url: '/api/115/torrent/tasks' })).statusCode, 401)
  const list = (await send('GET', '/api/115/torrent/files?cid=0')).json()
  assert.deepEqual(list.files.map((file: any) => file.name), ['Folder', 'seed.torrent'])
  assert.equal(list.hasMore, false)
  const upload = await send('POST', '/api/115/torrent/upload', { name: 'seed.torrent', data: bytes.toString('base64') })
  assert.equal(upload.statusCode, 200, upload.body)
  assert.equal(upload.json().sha1, fileSha)
  assert.equal(upload.json().pickCode, 'seed123')
  const parsed = await send('POST', '/api/115/torrent/parse', upload.json())
  assert.equal(parsed.statusCode, 200, parsed.body)
  assert.deepEqual(parsed.json().files.map((file: any) => file.index), [0, 1])
  const payload = { ...parsed.json(), wanted: '0', savePath: 'HPlayer', folderId: '0' }
  assert.equal((await send('POST', '/api/115/torrent/tasks', payload)).statusCode, 200)
  assert.equal(added, 1)
  assert.equal((await send('GET', '/api/115/torrent/tasks?page=1')).json().tasks[0].progress, 25)
  assert.notEqual((await send('POST', '/api/115/torrent/tasks', { ...payload, wanted: '' })).statusCode, 200)
  assert.notEqual((await send('POST', '/api/115/torrent/upload', { name: 'bad.txt', data: bytes.toString('base64') })).statusCode, 200)
  const redirect = 'https://hplayer.example.com/api/115/open/auth/callback'
  assert.notEqual((await send('POST', '/api/115/open/auth/web/start', { clientSecret: 'private-secret', redirectUri: 'http://localhost/callback' })).statusCode, 200)
  const started = await send('POST', '/api/115/open/auth/web/start', { clientSecret: 'private-secret', redirectUri: redirect })
  assert.equal(started.statusCode, 200, started.body)
  const authorizationURL = new URL(started.json().authorizationUrl)
  assert.equal(authorizationURL.hostname, 'passportapi.115.com')
  assert.equal(authorizationURL.searchParams.get('redirect_uri'), redirect)
  const state = authorizationURL.searchParams.get('state')!
  const bad = await app.inject({ method: 'GET', url: '/api/115/open/auth/callback?state=incorrect&code=code-once' })
  assert.match(bad.body, /授权未完成/)
  assert.equal((await send('GET', '/api/115/open/auth/web/status')).json().status, 'pending')
  const completed = await app.inject({ method: 'GET', url: `/api/115/open/auth/callback?state=${state}&code=code-once` })
  assert.match(completed.body, /授权成功/)
  assert.doesNotMatch(completed.body, /code-once|private-secret/)
  assert.equal((await send('GET', '/api/115/open/auth/web/status')).json().status, 'authorized')
  const saved = readFileSync(join(dir, '115-open.json'), 'utf8')
  assert.match(saved, /new-refresh/)
  assert.doesNotMatch(saved, /private-secret|code-once/)
  console.log('115 torrent and web OAuth mock regression passed')
} finally {
  await app.close()
  rmSync(dir, { recursive: true, force: true })
}
