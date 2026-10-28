export interface P115File {
  id: string
  parentId: string
  name: string
  isDir: boolean
  kind: string
  size: number
  pickCode: string
  sha1: string
  updatedAt: string
  thumbUrl: string
}

export interface MediaInfo {
  container: string
  videoCodec: string
  audioCodec: string
  duration: number
  width: number
  height: number
  directPlay: boolean
  fileName: string
  fileSize: number
}

export interface P115Status {
  configured: boolean
  userId?: number
  userName?: string
  vip?: number
  error?: string
  message?: string
}
