import { useEffect, useState } from 'react'
import { api, getBaseUrl, setBaseUrl } from '../lib/api'
import type { P115Status } from '../lib/types'

export function Settings({ onBack }: { onBack: () => void }) {
  const [status, setStatus] = useState<P115Status | null>(null)
  const [baseUrl, setBaseUrlState] = useState(getBaseUrl())
  const [cookie, setCookie] = useState('')
  const [message, setMessage] = useState('')
  const [error, setError] = useState('')
  const [saving, setSaving] = useState(false)

  useEffect(() => {
    api
      .status()
      .then(setStatus)
      .catch((err) => setError(err instanceof Error ? err.message : '状态获取失败'))
  }, [])

  async function save() {
    setSaving(true)
    setError('')
    setMessage('')
    try {
      const result = await api.setCookie(cookie)
      setMessage(`已连接：${result.userName}`)
      setCookie('')
      setStatus(await api.status())
    } catch (err) {
      setError(err instanceof Error ? err.message : '保存失败')
    } finally {
      setSaving(false)
    }
  }

  async function logout() {
    await api.logout()
    location.reload()
  }

  return (
    <div className="page">
      <header className="topbar">
        <button className="icon-btn" onClick={onBack} aria-label="返回">
          ‹
        </button>
        <div className="player-title">设置</div>
        <span style={{ width: 40 }} />
      </header>

      <section className="card">
        <h2>服务器地址</h2>
        <p className="muted-text">
          App 内嵌模式下必填，浏览器/PWA 访问时留空即可。修改后需要重新登录。
        </p>
        <input
          value={baseUrl}
          onChange={(e) => setBaseUrlState(e.target.value)}
          placeholder="https://hplayer.example.com"
          autoCapitalize="none"
          autoCorrect="off"
          spellCheck={false}
        />
        <button
          onClick={() => {
            setBaseUrl(baseUrl)
            location.reload()
          }}
        >
          保存地址
        </button>
      </section>

      <section className="card">
        <h2>115 账号</h2>
        {!status && <div className="hint">检查中…</div>}
        {status && !status.configured && <div className="hint">{status.message}</div>}
        {status?.configured && status.error && (
          <div className="error-box">
            {status.message}
            <br />
            <small>{status.error}</small>
          </div>
        )}
        {status?.configured && !status.error && (
          <div className="ok-box">
            已连接：{status.userName}（ID {status.userId}）
          </div>
        )}
      </section>

      <section className="card">
        <h2>更新 Cookie</h2>
        <p className="muted-text">
          在浏览器登录 115 后，从开发者工具复制请求头里的 Cookie，需要包含 UID、CID、SEID、KID 四项。
          Cookie 会过期，失效后在这里更新即可。
        </p>
        <textarea
          value={cookie}
          onChange={(e) => setCookie(e.target.value)}
          placeholder="UID=...; CID=...; SEID=...; KID=..."
          rows={5}
        />
        {error && <div className="error">{error}</div>}
        {message && <div className="ok-box">{message}</div>}
        <button onClick={save} disabled={saving || !cookie.trim()}>
          {saving ? '验证中…' : '保存并验证'}
        </button>
      </section>

      <section className="card">
        <button className="danger" onClick={logout}>
          退出登录
        </button>
      </section>
    </div>
  )
}
