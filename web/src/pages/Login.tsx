import { useState } from 'react'
import { api } from '../lib/api'

export function Login({ onSuccess }: { onSuccess: () => void }) {
  const [password, setPassword] = useState('')
  const [error, setError] = useState('')
  const [loading, setLoading] = useState(false)

  async function submit(event: React.FormEvent) {
    event.preventDefault()
    setLoading(true)
    setError('')
    try {
      await api.login(password)
      onSuccess()
    } catch (err) {
      setError(err instanceof Error ? err.message : '登录失败')
    } finally {
      setLoading(false)
    }
  }

  return (
    <div className="login">
      <div className="login-brand">
        <div className="login-logo">H</div>
        <h1>HPlayer</h1>
        <p>115 网盘在线播放</p>
      </div>
      <form onSubmit={submit}>
        <input
          type="password"
          value={password}
          onChange={(e) => setPassword(e.target.value)}
          placeholder="访问密码"
          autoFocus
          autoComplete="current-password"
        />
        {error && <div className="error">{error}</div>}
        <button type="submit" disabled={loading || !password}>
          {loading ? '登录中…' : '进入'}
        </button>
      </form>
    </div>
  )
}
