import { useCallback, useEffect, useState } from 'react'
import { api, getBaseUrl, isNativeShell } from './lib/api'
import type { P115File } from './lib/types'
import { Library } from './pages/Library'
import { Login } from './pages/Login'
import { Player } from './pages/Player'
import { ServerSetup } from './pages/ServerSetup'
import { Settings } from './pages/Settings'

type View = { name: 'library' } | { name: 'player'; file: P115File } | { name: 'settings' }

export default function App() {
  const [needServer, setNeedServer] = useState(() => isNativeShell() && !getBaseUrl())
  const [authenticated, setAuthenticated] = useState<boolean | null>(null)
  const [view, setView] = useState<View>({ name: 'library' })

  const checkAuth = useCallback(() => {
    api
      .me()
      .then((r) => setAuthenticated(r.authenticated))
      .catch(() => setAuthenticated(false))
  }, [])

  useEffect(() => {
    if (isNativeShell() && !getBaseUrl()) return
    checkAuth()
  }, [checkAuth])

  if (needServer) {
    return (
      <ServerSetup
        onDone={() => {
          setNeedServer(false)
          checkAuth()
        }}
      />
    )
  }

  if (authenticated === null) {
    return <div className="splash">加载中…</div>
  }

  if (!authenticated) {
    return <Login onSuccess={() => setAuthenticated(true)} />
  }

  if (view.name === 'player') {
    return <Player file={view.file} onBack={() => setView({ name: 'library' })} />
  }

  if (view.name === 'settings') {
    return <Settings onBack={() => setView({ name: 'library' })} />
  }

  return (
    <Library
      onPlay={(file) => setView({ name: 'player', file })}
      onSettings={() => setView({ name: 'settings' })}
    />
  )
}
