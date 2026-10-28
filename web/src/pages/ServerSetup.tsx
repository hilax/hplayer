import { useState } from 'react'
import { setBaseUrl } from '../lib/api'

export function ServerSetup({ onDone }: { onDone: () => void }) {
  const [url, setUrl] = useState('')
  const [error, setError] = useState('')

  function save(event: React.FormEvent) {
    event.preventDefault()
    const trimmed = url.trim()
    if (!/^https?:\/\//i.test(trimmed)) {
      setError('请填写完整地址，例如 https://hplayer.example.com')
      return
    }
    setBaseUrl(trimmed)
    onDone()
  }

  return (
    <div className="login">
      <div className="login-brand">
        <div className="login-logo">H</div>
        <h1>连接服务器</h1>
        <p>填写 HPlayer 后端地址</p>
      </div>
      <form onSubmit={save}>
        <input
          type="url"
          value={url}
          onChange={(e) => setUrl(e.target.value)}
          placeholder="https://hplayer.example.com"
          autoFocus
          autoCapitalize="none"
          autoCorrect="off"
          spellCheck={false}
        />
        {error && <div className="error">{error}</div>}
        <button type="submit" disabled={!url.trim()}>
          保存
        </button>
      </form>
    </div>
  )
}
