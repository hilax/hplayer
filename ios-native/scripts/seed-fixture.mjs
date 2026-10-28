import fs from 'node:fs'
import WebTorrent from 'webtorrent'
import { Server } from 'bittorrent-tracker'

const resultFile = process.argv[2]
const videoFile = process.argv[3]
if (!resultFile || !videoFile) throw new Error('Missing fixture output or media path')
const bytes = fs.readFileSync(videoFile)

const tracker = new Server({ udp: false, ws: false, http: true })
tracker.on('error', (error) => { console.error(error.message); process.exit(1) })
tracker.listen(0, '127.0.0.1', () => {
  const url = `http://127.0.0.1:${tracker.http.address().port}/announce`
  const client = new WebTorrent({ dht: false })
  client.on('error', (error) => { console.error(error.message); process.exit(1) })
  let seeded = false
  let announced = false
  let published = false
  const torrent = client.seed(bytes, { name: 'fixture.mp4', announce: [url], private: true }, () => {
    seeded = true
    publish()
  })
  torrent.on('trackerAnnounce', () => { announced = true; publish() })
  function publish() {
    if (seeded && announced && !published) {
      published = true
      const magnet = `${torrent.magnetURI}&x.pe=127.0.0.1:${client.torrentPort}`
      fs.writeFileSync(resultFile, JSON.stringify({ magnet, size: bytes.length, videoFile }))
    }
  }
})
