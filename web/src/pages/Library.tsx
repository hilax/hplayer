import { useEffect, useMemo, useState } from 'react'
import { api, UnauthorizedError } from '../lib/api'
import type { P115File } from '../lib/types'

interface Props {
  onPlay: (file: P115File) => void
  onSettings: () => void
}

interface Crumb {
  cid: string
  name: string
}

function formatSize(bytes: number): string {
  if (!bytes) return ''
  const units = ['B', 'KB', 'MB', 'GB', 'TB']
  let value = bytes
  let index = 0
  while (value >= 1024 && index < units.length - 1) {
    value /= 1024
    index++
  }
  return `${value.toFixed(value >= 10 || index === 0 ? 0 : 1)} ${units[index]}`
}

export function Library({ onPlay, onSettings }: Props) {
  const [stack, setStack] = useState<Crumb[]>([{ cid: '0', name: '全部文件' }])
  const [files, setFiles] = useState<P115File[]>([])
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState('')

  const current = stack[stack.length - 1]!

  useEffect(() => {
    let cancelled = false
    setLoading(true)
    setError('')
    api
      .files(current.cid)
      .then((r) => {
        if (!cancelled) setFiles(r.files)
      })
      .catch((err) => {
        if (cancelled) return
        if (err instanceof UnauthorizedError) {
          location.reload()
          return
        }
        setError(err instanceof Error ? err.message : '加载失败')
      })
      .finally(() => {
        if (!cancelled) setLoading(false)
      })
    return () => {
      cancelled = true
    }
  }, [current.cid])

  const sorted = useMemo(() => {
    const rank = (f: P115File) => (f.isDir ? 0 : f.kind === 'video' ? 1 : 2)
    return [...files].sort((a, b) => {
      const byRank = rank(a) - rank(b)
      if (byRank !== 0) return byRank
      return a.name.localeCompare(b.name, 'zh-Hans-CN')
    })
  }, [files])

  const playable = sorted.filter((f) => f.isDir || f.kind === 'video')
  const others = sorted.filter((f) => !f.isDir && f.kind !== 'video')

  return (
    <div className="page">
      <header className="topbar">
        <div className="crumbs">
          {stack.map((crumb, index) => (
            <button
              key={`${crumb.cid}-${index}`}
              className="crumb"
              onClick={() => setStack(stack.slice(0, index + 1))}
              disabled={index === stack.length - 1}
            >
              {crumb.name}
            </button>
          ))}
        </div>
        <button className="icon-btn" onClick={onSettings} aria-label="设置">
          ⚙
        </button>
      </header>

      {loading && <div className="hint">加载中…</div>}
      {error && <div className="error-box">{error}</div>}
      {!loading && !error && playable.length === 0 && others.length === 0 && (
        <div className="hint">这个目录是空的</div>
      )}

      <ul className="file-list">
        {playable.map((file) => (
          <li key={file.id}>
            <button
              className="file-row"
              onClick={() =>
                file.isDir
                  ? setStack([...stack, { cid: file.id, name: file.name }])
                  : onPlay(file)
              }
            >
              <span className="file-icon">{file.isDir ? '📁' : '▶'}</span>
              <span className="file-name">{file.name}</span>
              <span className="file-meta">{file.isDir ? '' : formatSize(file.size)}</span>
            </button>
          </li>
        ))}
      </ul>

      {others.length > 0 && (
        <>
          <div className="section-title">其他文件</div>
          <ul className="file-list muted">
            {others.map((file) => (
              <li key={file.id}>
                <div className="file-row">
                  <span className="file-icon">📄</span>
                  <span className="file-name">{file.name}</span>
                  <span className="file-meta">{formatSize(file.size)}</span>
                </div>
              </li>
            ))}
          </ul>
        </>
      )}
    </div>
  )
}
