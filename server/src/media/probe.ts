import { execFile } from 'node:child_process'
import { promisify } from 'node:util'
import { config } from '../config.js'

const exec = promisify(execFile)

export interface MediaInfo {
  container: string
  videoCodec: string
  audioCodec: string
  duration: number
  width: number
  height: number
  /** Safari 能否不转码直接播放 */
  directPlay: boolean
}

interface FFProbeStream {
  codec_type?: string
  codec_name?: string
  width?: number
  height?: number
}

/** 判定 Safari 原生可播：mp4 容器 + H.264/HEVC + AAC/MP3 */
function canDirectPlay(container: string, video?: string, audio?: string): boolean {
  const containerOk = /mp4|mov|m4v/.test(container)
  const videoOk = video === 'h264' || video === 'hevc'
  const audioOk = !audio || audio === 'aac' || audio === 'mp3'
  return containerOk && videoOk && audioOk
}

export async function probe(url: string): Promise<MediaInfo> {
  const isRemote = /^https?:\/\//i.test(url)
  const { stdout } = await exec(
    config.ffprobe,
    [
      '-v',
      'error',
      '-print_format',
      'json',
      '-show_format',
      '-show_streams',
      ...(isRemote
        ? ['-user_agent', config.userAgent, '-headers', 'Referer: https://115.com/\r\n']
        : []),
      url,
    ],
    { timeout: 45_000, maxBuffer: 8 * 1024 * 1024 },
  )

  const data = JSON.parse(stdout) as {
    format?: { format_name?: string; duration?: string }
    streams?: FFProbeStream[]
  }
  const streams = data.streams ?? []
  const video = streams.find((s) => s.codec_type === 'video')
  const audio = streams.find((s) => s.codec_type === 'audio')
  const container = data.format?.format_name ?? ''

  return {
    container,
    videoCodec: video?.codec_name ?? '',
    audioCodec: audio?.codec_name ?? '',
    duration: Number(data.format?.duration ?? 0),
    width: video?.width ?? 0,
    height: video?.height ?? 0,
    directPlay: canDirectPlay(container, video?.codec_name, audio?.codec_name),
  }
}
