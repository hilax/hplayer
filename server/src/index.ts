import { existsSync } from 'node:fs'
import { join } from 'node:path'
import cookie from '@fastify/cookie'
import fastifyStatic from '@fastify/static'
import Fastify from 'fastify'
import { config } from './config.js'
import { registerRoutes } from './routes/api.js'

if (!config.password) {
  console.error('缺少 HPLAYER_PASSWORD 环境变量，拒绝以无密码状态启动。')
  process.exit(1)
}

const app = Fastify({ logger: { level: process.env.LOG_LEVEL ?? 'info' } })

await app.register(cookie)

// App 内嵌模式跑在 capacitor://localhost，请求后端属于跨域，必须放行。
// 鉴权走 Bearer token 而不是 cookie，所以用 * 即可，不涉及 credentials。
app.addHook('onRequest', async (request, reply) => {
  reply.header('Access-Control-Allow-Origin', '*')
  reply.header('Access-Control-Allow-Headers', 'Content-Type, Authorization')
  reply.header('Access-Control-Allow-Methods', 'GET, POST, DELETE, OPTIONS')
  reply.header('Access-Control-Max-Age', '86400')
  if (request.method === 'OPTIONS') {
    return reply.code(204).send()
  }
})

await registerRoutes(app)

// 生产模式下由后端直接托管前端构建产物；开发时用 Vite dev server
const webDist = join(process.cwd(), '..', 'web', 'dist')
if (existsSync(webDist)) {
  await app.register(fastifyStatic, { root: webDist, prefix: '/' })
  app.setNotFoundHandler((request, reply) => {
    if (request.url.startsWith('/api/')) {
      return reply.code(404).send({ error: 'not found' })
    }
    return reply.sendFile('index.html')
  })
} else {
  app.log.warn(`未找到前端构建产物 ${webDist}，仅提供 API`)
}

app.setErrorHandler((error: Error & { statusCode?: number }, _request, reply) => {
  app.log.error(error)
  reply.code(error.statusCode ?? 500).send({ error: error.message })
})

await app.listen({ port: config.port, host: config.host })
app.log.info(`HPlayer 已启动：http://localhost:${config.port}`)
