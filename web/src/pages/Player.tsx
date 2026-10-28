import { useEffect, useState } from 'react'
import { api, mediaUrl, withToken } from '../lib/api'
import type { MediaInfo, P115File } from '../lib/types'

interface Props {
  file: P115File
  onBack: () => void
}

export function Player({ file, onBack }: Props) {
  const [media, setMedia] = useState<MediaInfo | null>(null)
  const [error, setError] = useState('')
  const [preparing, setPreparing] = useState(false)
  const [ready, setReady] = useState(false)

  useEffect(() => {
    let cancelled = false
    setMedia(null)
    setError('')
    setReady(false)
    setPreparing(false)

    api
      .probe(file.pickCode)
      .then(async (info) => {
        if (cancelled) return
        setMedia(info)

        if (!info.directPlay) {
          // 先请求一次 playlist，让后端开始转封装；完成后 video 再请求时就直接命中缓存
          setPreparing(true)
          const res = await fetch(
            withToken(mediaUrl(`/api/hls/${encodeURIComponent(file.pickCode)}/index.m3u8`)),
            { credentials: 'include' },
          )
          if (!res.ok) {
            const data = (await res.json().catch(() => ({}))) as { error?: string }
            throw new Error(data.error ?? '转封装失败')
          }
          if (cancelled) return
          setPreparing(false)
        }
        setReady(true)
      })
      .catch((err) => {
        if (cancelled) return
        setError(err instanceof Error ? err.message : '播放失败')
        setPreparing(false)
      })

    return () => {
      cancelled = true
    }
  }, [file.pickCode])

  const src =
    ready && media
      ? media.directPlay
        ? withToken(mediaUrl(`/api/play/${encodeURIComponent(file.pickCode)}`))
        : withToken(mediaUrl(`/api/hls/${encodeURIComponent(file.pickCode)}/index.m3u8`))
      : undefined

  return (
    <div className="player-page">
      <header className="topbar player-topbar">
        <button className="icon-btn" onClick={onBack} aria-label="返回">
          ‹
        </button>
        <div className="player-title">{file.name}</div>
        <span style={{ width: 40 }} />
      </header>

      <div className="video-wrap">
        {src ? (
          <video src={src} controls autoPlay playsInline preload="auto" />
        ) : (
          <div className="video-placeholder">
            {error ? (
              <div className="error-box">{error}</div>
            ) : (
              <div className="hint">
                {preparing ? '正在转封装，首次播放需要几十秒…' : '正在探测媒体信息…'}
              </div>
            )}
          </div>
        )}
      </div>

      {media && (
        <div className="media-info">
          <div>
            {media.width}×{media.height} · {media.videoCodec.toUpperCase()}
            {media.audioCodec ? ` · ${media.audioCodec.toUpperCase()}` : ''}
          </div>
          <div className="muted-text">
            {media.directPlay ? '直连 115 CDN 播放' : '服务端转封装播放'}
          </div>
        </div>
      )}
    </div>
  )
}
