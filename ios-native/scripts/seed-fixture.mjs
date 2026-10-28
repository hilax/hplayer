import fs from 'node:fs'
import WebTorrent from 'webtorrent'
import { Server } from 'bittorrent-tracker'

const resultFile = process.argv[2]
if (!resultFile) throw new Error('Missing fixture output path')
const bytes = Buffer.alloc(256 * 1024)
for (let i = 0; i < bytes.length; i++) bytes[i] = i % 251

const tracker = new Server({ udp: false, ws: false, http: true })
tracker.on('error', (error) => { console.error(error.message); process.exit(1) })
tracker.listen(0, '127.0.0.1', () => {
  const url = `http://127.0.0.1:${tracker.http.address().port}/announce`
  const client = new WebTorrent({ dht: false })
  client.on('error', (error) => { console.error(error.message); process.exit(1) })
  client.seed(bytes, { name: 'fixture.mp4', announce: [url], private: true }, (torrent) => {
    fs.writeFileSync(resultFile, JSON.stringify({ magnet: torrent.magnetURI, size: bytes.length }))
  })
})
