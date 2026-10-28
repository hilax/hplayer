import cookie from '@fastify/cookie'
import Fastify from 'fastify'
import { config } from './config.js'
import { registerRoutes } from './routes/api.js'

if (!config.password) {
  console.error('缺少 HPLAYER_PASSWORD 环境变量，拒绝以无密码状态启动。')
  process.exit(1)
}

// OAuth 回调的查询参数包含一次性授权码，不把请求 URL 写入日志。
const app = Fastify({ logger: { level: process.env.LOG_LEVEL ?? 'info' }, disableRequestLogging: true })

await app.register(cookie)

// 原生 App 请求后端属于跨域，放行。
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

app.get('/', async () => ({ name: 'HPlayer API', status: 'ok' }))

app.setErrorHandler((error: Error & { statusCode?: number }, _request, reply) => {
  app.log.error(error)
  reply.code(error.statusCode ?? 500).send({ error: error.message })
})

await app.listen({ port: config.port, host: config.host })
app.log.info(`HPlayer 已启动：http://localhost:${config.port}`)
