import type { CapacitorConfig } from '@capacitor/cli'

const config: CapacitorConfig = {
  appId: 'app.hplayer.mobile',
  appName: 'HPlayer',
  // 前端构建产物内嵌进 App，后端地址在 App 内首次启动时填写
  webDir: 'web/dist',
  ios: {
    contentInset: 'always',
  },
}

export default config
