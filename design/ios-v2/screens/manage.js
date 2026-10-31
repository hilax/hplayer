/* HPlayer iOS redesign — library maintenance and settings. */
(() => {
  const caption = text => `<p class="form-note" style="margin:10px 2px 22px">${text}</p>`;
  const title = text => `<div class="list-title" style="margin:24px 2px 10px">${text}</div>`;
  const toastButton = (text, message, destructive = false) => `<button class="${destructive ? 'danger-text' : 'primary-text'}" data-toast="${message}" style="border:0;background:none;font:inherit;font-weight:600;min-height:46px;padding:0 16px;width:100%;text-align:left;color:${destructive ? '#ef6c70' : 'var(--accent)'}">${text}</button>`;
  const smallCover = (name, label, sub, tail = '') => `<div style="display:flex;gap:13px;align-items:center;padding:13px 15px"><img src="${art(name)}" alt="${label}" style="width:46px;height:66px;object-fit:cover;border-radius:7px"><div style="min-width:0;flex:1"><div style="font-size:15px;font-weight:650;line-height:1.45">${label}</div><div class="muted" style="font-size:12px;line-height:1.6;margin-top:3px">${sub}</div></div>${tail}</div>`;
  const stats = (value, label) => `<div class="metric"><div class="number" style="font-size:25px">${value}</div><div class="muted tiny" style="margin-top:6px">${label}</div></div>`;
  const choice = (label, selected, mode, color, foreground) => `<button data-theme-mode="${mode}" style="flex:1;min-width:0;border:${selected ? '2px solid var(--accent)' : '1px solid var(--line)'};border-radius:18px;padding:10px 8px 12px;background:var(--surface);color:var(--text);font:inherit;text-align:center"><div style="height:127px;border:1px solid ${mode === 'dark' ? '#303238' : '#dce0e8'};border-radius:10px;overflow:hidden;background:${color};padding:12px 7px"><div style="height:7px;width:26px;border-radius:5px;background:${foreground};opacity:.55;margin-bottom:15px"></div><div style="height:40px;background:linear-gradient(145deg,#c8a378,#4a6273);border-radius:5px;margin-bottom:8px"></div><div style="display:flex;gap:4px"><div style="height:32px;flex:1;border-radius:4px;background:${foreground};opacity:.17"></div><div style="height:32px;flex:1;border-radius:4px;background:${foreground};opacity:.25"></div><div style="height:32px;flex:1;border-radius:4px;background:${foreground};opacity:.12"></div></div></div><div style="font-size:13px;font-weight:600;margin-top:11px">${label}</div><div style="width:18px;height:18px;border-radius:50%;border:1px solid ${selected ? 'var(--accent)' : 'var(--line)'};background:${selected ? 'var(--accent)' : 'transparent'};margin:9px auto 0;color:white;display:flex;align-items:center;justify-content:center">${selected ? icon('check') : ''}</div></button>`;
  const appearanceOptions = mode => `<div style="display:flex;gap:10px">${choice('浅色', mode === 'light', 'light', '#f8f9fb', '#20232c')}${choice('深色', mode === 'dark', 'dark', '#13151b', '#fff')}${choice('跟随系统', mode === 'system', 'system', 'linear-gradient(90deg,#f8f9fb 50%,#13151b 50%)', '#7f8aa2')}</div>`;

  window.PAGES.push(
    {
      id: 'manage', title: '媒体库管理', group: '资料与设置',
      note: '扫描、未匹配封面、资料来源与诊断集中管理；首页只展示可浏览的影视内容。扫描和匹配各自保留状态。',
      html: `<div class="content">${navTop('媒体库管理', 'library')}
        <div class="pad">
          <div style="margin:12px 0 16px;display:flex;align-items:center;justify-content:space-between">${pill('115 已连接', 'success')}<span class="muted tiny">电影文件夹 · 扫描中</span></div>
          <div class="card" style="padding:17px">
            <div style="display:flex;align-items:center;gap:12px"><div style="width:42px;height:42px;border-radius:13px;background:var(--accent-soft);color:var(--accent);display:grid;place-items:center">${icon('scan')}</div><div style="flex:1"><div style="font-size:17px;font-weight:700">正在扫描媒体库</div><div class="tiny muted" style="margin-top:5px">115 网盘 · 电影</div></div><span class="pulse-dot"></span></div>
            <div style="margin-top:16px;display:flex;justify-content:space-between;font-size:11px"><span class="muted">已扫描 128 个文件夹</span><span class="primary-text">扫描中</span></div>
            <div style="margin:9px 0 10px">${progress(68)}</div>
            <div class="tiny muted" style="overflow:hidden;white-space:nowrap;text-overflow:ellipsis">当前目录　电影 / 科幻 / 2024</div>
            <div class="metric-grid" style="display:grid;grid-template-columns:repeat(3,1fr);margin:17px 0 16px;gap:10px">${stats('128', '已扫描目录')}${stats('186', '已发现目录')}${stats('324', '发现视频')}</div>
            <button data-toast="扫描已暂停，进度已保存；可随时继续扫描" style="width:100%;height:43px;border:1px solid var(--line);border-radius:12px;background:var(--surface-2);color:var(--text);font:inherit;font-size:14px;font-weight:650;display:flex;align-items:center;justify-content:center;gap:8px">${icon('pause')}暂停扫描</button>
          </div>
          ${group(row('image', '未匹配影片', '查看、播放或手动校正', '43', 'unmatched') + row('folder', '选择文件夹扫描', '只整理你选定的目录', '', 'folder-picker'))}
          ${caption('文件夹总数会持续发现。文件扫描与封面匹配分别进行。')}
          ${title('封面与影片资料')}
          <div class="card" style="padding:17px 18px"><div style="display:flex;justify-content:space-between;align-items:center"><span style="font-weight:650;font-size:15px">自动匹配进行中</span>${pill('281 / 324 部')}</div><div style="margin:15px 0 12px">${progress(87)}</div><div class="muted tiny">已有封面的影片会自动出现在首页。</div></div>
          <div style="height:10px"></div>
          ${group(row('refresh', '重新匹配未识别封面', '', '', '', 'data-toast="已加入匹配队列"') + row('stop', '停止匹配', '', '', '', 'data-toast="已停止本轮匹配，已有资料会保留"') + row('refresh', '重新扫描全盘', '', '', '', 'data-toast="将从头扫描 115 网盘，已有资料会保留"'))}
          ${title('资料与工具')}
          ${group(row('user', '补全演员资料', '已识别影片中 63 / 78 部有演员信息', '', '', 'data-toast="已开始补全缺失的演员资料"') + row('settings', '资料来源', '番号匹配、TMDB 与 FANZA', '', 'metadata') + row('copy', '复制匹配诊断信息', '', '', '', 'data-toast="匹配诊断信息已复制"'))}
          ${caption('扫描只读取文件列表，不下载视频，也不删除网盘文件。扫描在前台进行，退出后可继续。')}
        </div></div>`
    },
    {
      id: 'folder-picker', title: '选择扫描目录', group: '资料与设置',
      note: '通过现有 115 文件夹列表逐级选择扫描范围，底部按钮对当前目录生效。',
      html: `<div class="content">${navTop('选择扫描目录', 'manage')}
        <div class="pad">
          <div style="display:flex;gap:8px;align-items:center;margin:20px 0 18px;font-size:13px"><span class="primary-text" data-toast="已返回 115 网盘根目录" style="cursor:pointer">115 网盘</span>${icon('chevron')}<span>电影</span></div>
          <div class="card" style="padding:20px;display:flex;gap:14px;align-items:center"><div style="width:48px;height:48px;display:grid;place-items:center;background:var(--accent-soft);color:var(--accent);border-radius:14px">${icon('folder')}</div><div><div style="font-size:18px;font-weight:700">电影</div><div class="muted tiny" style="margin-top:5px">扫描此目录及所有子文件夹</div></div></div>
          ${title('子文件夹')}
          ${group(row('folder', '科幻', '', '', '', 'data-toast="已进入 科幻 文件夹"') + row('folder', '剧情', '', '', '', 'data-toast="已进入 剧情 文件夹"') + row('folder', '动画', '', '', '', 'data-toast="已进入 动画 文件夹"') + row('folder', '纪录片', '', '', '', 'data-toast="已进入 纪录片 文件夹"') + row('folder', '待整理', '', '', '', 'data-toast="已进入 待整理 文件夹"'))}
          ${caption('建议选择存放影片的文件夹。网盘文件较多时，全盘扫描需要更长时间。')}
          <div style="height:45px"></div>${button('扫描“电影”文件夹', 'manage', 'primary', 'scan')}
          <button data-toast="将扫描整个 115 网盘" style="font:inherit;font-size:14px;color:var(--accent);border:0;background:none;min-height:50px;width:100%">扫描整个网盘</button>
        </div></div>`
    },
    {
      id: 'unmatched', title: '未匹配影片', group: '资料与设置',
      note: '首页不显示此页的数量或提示。未匹配文件仍可播放，也能逐个搜索并校正资料。',
      html: `<div class="content">${navTop('未匹配影片', 'manage', `<button class="icon-btn" data-toast="已重新匹配这 43 部未识别影片" aria-label="重新匹配">${icon('refresh')}</button>`)}
        <div class="pad">
          <div style="margin:21px 0 23px"><div class="eyebrow">资料整理</div><div style="font-size:30px;font-weight:750;letter-spacing:-1px;margin:8px 0">43 <span style="font-size:18px;font-weight:500;letter-spacing:0">部等待识别</span></div><p class="muted" style="font-size:13px;line-height:1.65;margin:8px 0 0">选择影片匹配封面，或直接打开播放。<br>源文件和播放记录都会保留。</p></div>
          ${group([
            ['Dune.Part.Two.2024.2160p.WEB-DL.mkv', '115 网盘 · 电影 / 科幻', '3.8 GB'],
            ['The.Planet.Earth.S01E03.1080p.mkv', '115 网盘 · 纪录片', '1.9 GB'],
            ['录制视频_20241012_2035.mp4', '本机视频', '624 MB'],
            ['Arrival.2016.BluRay.1080p.mkv', '115 网盘 · 电影 / 科幻', '2.7 GB'],
            ['Silo.S02E01.2160p.WEB.mkv', '115 网盘 · 剧集', '2.2 GB']
          ].map(([name, source, size]) => `<div style="padding:16px;display:flex;gap:12px;align-items:flex-start"><div style="width:39px;height:48px;flex-shrink:0;border-radius:9px;background:var(--surface-2);color:var(--muted);display:grid;place-items:center">${icon('file')}</div><div style="min-width:0;flex:1"><div style="font-size:13px;font-weight:600;line-height:1.5;overflow-wrap:anywhere">${name}</div><div class="tiny muted" style="margin-top:5px;line-height:1.5">${source}<br>${size}</div><div style="display:flex;gap:18px;margin-top:12px"><button class="primary-text" data-go="match" style="border:0;background:none;font:inherit;font-size:12px;font-weight:600;padding:0">匹配资料</button><button data-go="player" style="border:0;background:none;font:inherit;font-size:12px;font-weight:600;padding:0;color:var(--muted)">直接播放</button></div></div></div>`).join('<div class="divider" style="margin:0 16px"></div>'))}
          ${caption('这里仅管理尚未识别的文件；完成匹配后，影片会进入对应的电影、剧集与演员合集。')}
        </div></div>`
    },
    {
      id: 'match', title: '匹配封面与资料', group: '资料与设置',
      note: '从现有资料来源搜索候选项，选择后绑定当前文件。支持中文名、英文名、番号和可选 TMDB。',
      html: `<div class="content">${navTop('匹配封面', 'unmatched', `<button data-go="metadata" class="icon-btn" aria-label="资料来源">${icon('settings')}</button>`)}
        <div class="pad">
          <div class="card" style="padding:14px 15px;margin:18px 0 19px"><div class="eyebrow" style="font-size:10px">源文件 · 115 网盘</div><div style="font-size:12px;line-height:1.6;margin-top:7px;overflow-wrap:anywhere">Dune.Part.Two.2024.2160p.WEB-DL.mkv</div></div>
          <div style="display:flex;align-items:center;gap:9px;background:var(--surface-2);border-radius:13px;padding:13px;color:var(--muted)">${icon('search')}<input aria-label="输入片名或番号" value="沙丘2" placeholder="输入片名或番号" style="background:none;color:var(--text);border:0;outline:none;width:100%;font:inherit;font-size:15px"><button class="icon-btn" style="width:24px;height:24px" data-toast="已清空搜索条件" aria-label="清空">${icon('close')}</button></div>
          <div style="margin:13px 0 22px">${chips(['沙丘2', 'Dune Part Two'], 0)}</div>
          <div style="display:flex;align-items:center;justify-content:space-between;margin:0 2px 10px"><span class="list-title">搜索结果</span><span class="tiny muted">按匹配度排序</span></div>
          <div class="card"><button data-toast="已将《沙丘2》的封面与资料应用到该文件" style="width:100%;border:0;background:none;color:var(--text);padding:0;text-align:left;font:inherit">${smallCover('dune', '沙丘2', 'Dune: Part Two · 2024<br>电影 · TMDB · ★ 8.5', `<span class="primary-text">${icon('check')}</span>`)}</button><div class="divider" style="margin:0 15px"></div><div style="padding:13px 15px 17px;font-size:12px;line-height:1.7" class="muted">保罗与契妮和弗雷曼人并肩作战，在爱情与宇宙命运之间，作出自己的选择。</div></div>
          <div style="height:11px"></div>
          <div class="card"><button data-toast="已选择 IMDb 资料，可确认应用" style="width:100%;border:0;background:none;color:var(--text);padding:0;text-align:left;font:inherit">${smallCover('dune', 'Dune: Part Two', '2024 · 电影 · IMDb · ★ 8.5')}</button></div>
          <div style="margin-top:19px">${button('使用所选资料', 'portrait', 'primary', 'check')}</div>
          ${caption('选择后会更新封面与影片资料，不会修改源文件名。')}
          ${group(row('settings', '资料来源设置', '番组计划、IMDb、TMDB 与番号匹配', '', 'metadata'))}
        </div></div>`
    },
    {
      id: 'metadata', title: '资料来源', group: '资料与设置',
      note: '现有影视来源及番号匹配开关集中配置。TMDB 与 DMM 凭证均为可选，只保存在本机钥匙串。',
      html: `<div class="content">${navTop('资料来源', 'manage')}
        <div class="pad">
          <p class="muted" style="font-size:14px;line-height:1.65;margin:19px 2px 26px">为你的影片补全封面、片名与演员资料。</p>
          ${title('影视资料')}
          ${group(row('image', '番组计划', '动画与剧集资料', '已启用') + row('image', 'IMDb', '电影与剧集资料', '已启用') + row('lock', 'TMDB', '可选 API Key 或读取令牌', '已开启', 'credentials'))}
          ${caption('多个来源会同时搜索，优先展示已返回的结果。')}
          ${title('番号匹配')}
          <div class="card"><div style="padding:17px 16px;display:flex;gap:12px;align-items:center"><div style="flex:1"><div style="font-size:15px;font-weight:600">按番号匹配成人影片</div><div class="tiny muted" style="margin-top:6px;line-height:1.5">识别番号后查找封面与资料</div></div><div aria-label="切换番号匹配">${toggle(true)}</div></div><div class="divider" style="margin:0 16px"></div>${row('cloud', 'R18.dev', '按番号查找影片资料', '已启用')}${row('lock', 'FANZA（DMM）', '官方接口，可选配置', '未开启', 'credentials')}</div>
          ${caption('开启后优先使用 R18.dev 与可选的 FANZA（DMM）；查不到时继续尝试影视来源。关闭后，已匹配资料仍会保留。')}
          <div style="display:flex;align-items:flex-start;gap:10px;padding:17px 3px;color:var(--muted);font-size:12px;line-height:1.7">${icon('shield')}<span>搜索仅向资料来源发送片名或番号，不发送 115 Cookie、文件路径或视频内容。封面由第三方图片服务提供。</span></div>
        </div></div>`
    },
    {
      id: 'credentials', title: '资料接口凭证', group: '资料与设置',
      note: '可选的 TMDB 和 DMM 配置。所有值为原型示例，保存与删除展示反馈，不触发真实网络请求。',
      html: `<div class="content">${navTop('接口凭证', 'metadata', `<button class="primary-text" data-toast="接口凭证已保存到本机" style="background:none;border:0;font:inherit;font-size:14px;font-weight:650">保存</button>`)}
        <div class="pad">
          <div class="card" style="padding:18px;margin:19px 0 26px;display:flex;gap:13px;align-items:center"><div style="color:var(--accent)">${icon('lock')}</div><div><div style="font-weight:650;font-size:14px">仅存储在你的设备</div><div class="tiny muted" style="line-height:1.6;margin-top:5px">凭证保存在 iOS 钥匙串，用于检索影片资料。</div></div></div>
          ${title('TMDB')}
          <div class="group" style="padding:2px 16px">${field('API Key 或 API 读访问令牌', '••••••••••••••••••••••••', '填写 TMDB API Key')}</div>
          ${caption('在 themoviedb.org 的“设置 → API”申请。支持 v3 API Key 或 v4 API 读访问令牌。连接失败时会继续使用其他资料来源。')}
          ${title('FANZA（DMM）')}
          <div class="group" style="padding:2px 16px">${field('API ID', '', '填写 API ID')}${field('Affiliate ID', '', '以 990–999 结尾')}</div>
          ${caption('可前往 affiliate.dmm.com 的 Web サービス申请。只向 api.dmm.com 发送番号，用于查询片名、演员与封面。此配置为可选。')}
          <div data-toast="接口凭证已保存到本机">${button('保存凭证', '', 'primary', 'check')}</div>
          <div style="height:10px"></div>${group(toastButton('删除已保存的 TMDB Key', '已删除 TMDB Key，可继续使用其他资料来源', true))}
          <p class="tiny muted center" style="margin:24px 0">Powered by DMM.com Web サービス</p>
        </div></div>`
    },
    {
      id: 'settings', title: '设置', group: '资料与设置', tab: 'settings',
      note: '保留当前真实设置范围：115 账号、外观和关于。播放偏好仍放在播放器内。',
      html: `<div class="content has-tabs"><div class="topbar" style="padding-left:22px"><b style="font-size:23px;font-weight:720">设置</b></div>
        <div class="pad">
          <div style="margin:24px 0 29px;display:flex;align-items:center;gap:14px"><div style="width:58px;height:58px;border-radius:18px;display:grid;place-items:center;background:linear-gradient(145deg,#84b6ec,#4c7cff);box-shadow:0 9px 25px #4c7cff28;color:white">${icon('play')}</div><div><div style="font-size:23px;font-weight:750;letter-spacing:-.6px">HPlayer</div><div class="muted" style="font-size:13px;margin-top:6px">让每一次播放，更简单。</div></div></div>
          ${title('账号与连接')}
          <div class="card"><div style="padding:19px 16px;display:flex;align-items:center;gap:13px"><div style="background:#317cf51c;color:#4389f8;width:45px;height:45px;border-radius:13px;display:grid;place-items:center;font-weight:800;font-size:15px">115</div><div style="flex:1"><div style="font-size:16px;font-weight:650">我的 115 网盘</div><div style="font-size:12px;margin-top:6px;display:flex;align-items:center;gap:6px" class="muted"><span style="width:6px;height:6px;border-radius:50%;background:#62c39a"></span>已连接</div></div>${icon('cloud')}</div><div class="divider" style="margin:0 16px"></div>${row('user', '重新登录 115', '', '', 'connect115')}${toastButton('退出 115', '已退出 115；媒体资料与本机视频仍会保留', true)}</div>
          ${title('外观')}
          ${group(row('moon', '显示方式', '', '跟随系统', 'appearance'))}
          ${title('关于')}
          ${group(row('info', 'HPlayer', '版本 1.0', '') + row('file', '开源许可', '', '', 'licenses'))}
          <div class="center" style="padding:29px 0 34px"><span class="tiny muted">你的私人影库，随时随地。</span></div>
        </div></div>`
    },
    {
      id: 'appearance', title: '外观', group: '资料与设置',
      note: '外观对应现有跟随系统、浅色、深色三种模式；播放器始终深色。点击模式可切换原型主题。',
      html: `<div class="content">${navTop('外观', 'settings')}
        <div class="pad">
          <div style="margin:24px 0 28px"><h2 style="font-size:25px;letter-spacing:-.7px;margin:0 0 10px">你喜欢的观看氛围</h2><p class="muted" style="font-size:14px;line-height:1.65;margin:0">选择 HPlayer 的显示方式。</p></div>
          <!--appearance-options-->${appearanceOptions(new URLSearchParams(location.search).get('theme') === 'light' ? 'light' : 'dark')}<!--/appearance-options-->
          <div class="card" style="margin-top:27px;padding:20px"><div class="eyebrow" style="margin-bottom:17px">界面预览</div><div style="display:flex;align-items:center;justify-content:space-between"><div style="font-size:18px;font-weight:700">继续观看</div><span class="tiny primary-text">查看全部</span></div><div style="display:flex;gap:12px;margin-top:16px"><img src="${art('interstellar','background')}" style="width:100px;height:66px;object-fit:cover;border-radius:10px" alt="星际穿越"><div style="flex:1;padding-top:7px"><div style="font-size:14px;font-weight:650">星际穿越</div><div class="tiny muted" style="margin:7px 0 10px">还剩 52 分钟</div>${progress(68)}</div></div></div>
          <div style="display:flex;gap:10px;padding:21px 3px;align-items:flex-start" class="muted">${icon('moon')}<p style="margin:0;font-size:12px;line-height:1.7">播放页面始终使用深色外观，让注意力留在画面上。选择“跟随系统”时，应用随 iOS 外观自动切换。</p></div>
        </div></div>`
    },
    {
      id: 'connect115', title: '连接 115', group: '资料与设置',
      note: '对应独立的 115 官方网页登录会话；完成后自动验证并连接。原型不读取 Cookie 或提交真实登录。',
      html: `<div class="content">${navTop('连接 115', 'settings')}
        <div class="pad">
          <div style="padding:31px 0 28px;text-align:center"><div style="width:72px;height:72px;border-radius:22px;display:grid;place-items:center;background:#317cf51c;color:#4389f8;font-weight:800;font-size:26px;margin:0 auto 22px">115</div><h2 style="font-size:25px;letter-spacing:-.7px;margin:0 0 12px">让网盘成为你的影库</h2><p class="muted" style="font-size:13px;line-height:1.8;margin:0">使用 115 官方网页完成登录。<br>连接后即可浏览与播放网盘中的视频。</p></div>
          <div class="card" style="padding:21px">
            <div style="display:flex;align-items:center;gap:8px;color:var(--muted);font-size:11px;padding-bottom:15px;border-bottom:1px solid var(--line)">${icon('lock')}115.com · 官方登录</div>
            <div style="padding:25px 0 7px;text-align:center"><div style="font-size:19px;font-weight:700;margin-bottom:9px">登录你的 115 账号</div><p class="muted tiny" style="line-height:1.7;margin:0 0 22px">在安全的官方网页会话中继续</p><button data-toast="原型演示：正式应用将在此加载 115 官方登录网页" style="border:0;background:#2d80f6;color:white;border-radius:12px;min-height:46px;width:100%;font:inherit;font-size:14px;font-weight:650">打开官方登录页</button></div>
          </div>
          <div style="display:flex;gap:11px;margin:23px 2px;color:var(--muted);font-size:12px;line-height:1.8">${icon('shield')}<span>登录完成后会自动连接，无需手动复制 Cookie。账号连接信息仅保存在设备中。</span></div>
          <div class="card" style="padding:17px;display:flex;align-items:center;gap:12px"><div style="width:28px;height:28px;border:2px solid var(--line);border-top-color:var(--accent);border-radius:50%;flex-shrink:0"></div><div><div style="font-size:14px;font-weight:600">正在验证登录状态</div><div class="muted tiny" style="margin-top:5px">完成后自动返回资源库</div></div></div>
          <button data-toast="已重新检查 115 登录状态" style="color:var(--accent);background:none;border:0;min-height:52px;width:100%;font:inherit;font-size:13px">已登录但没有连接？重试</button>
        </div></div>`
    },
    {
      id: 'official', title: '115 官方授权', group: '资料与设置',
      note: 'BT 云下载单独使用开放平台授权；保留 AppID、PKCE 扫码、复制验证码与授权状态，不需要 AppSecret。',
      html: `<div class="content">${navTop('115 官方授权', 'torrent')}
        <div class="pad">
          <div style="margin:19px 0 25px;display:flex;gap:12px;align-items:center"><div style="height:42px;width:42px;border-radius:13px;display:grid;place-items:center;color:var(--accent);background:var(--accent-soft)">${icon('shield')}</div><div><div style="font-size:16px;font-weight:650">等待账号授权</div><div class="tiny muted" style="margin-top:5px">完成授权后使用 BT 云下载</div></div></div>
          ${title('应用凭证')}
          <div class="group" style="padding:2px 16px">${field('AppID / Client ID', '100000000', '填写已批准的 AppID')}</div>
          ${caption('需在 115 开放平台申请 AppID，以及上传和云下载权限。扫码授权使用 PKCE，无需 AppSecret。')}
          <button data-toast="应用凭证已保存" style="width:100%;min-height:40px;border:1px solid var(--line);border-radius:11px;background:var(--surface);color:var(--text);font:inherit;font-size:13px;font-weight:600">保存应用凭证</button>
          ${title('扫码授权')}
          <div class="card" style="padding:22px;text-align:center"><div style="font-size:14px;font-weight:650">使用 115 扫描二维码</div><div style="width:156px;height:156px;padding:10px;margin:19px auto 16px;background:white;border-radius:12px">${qr()}</div><div class="tiny muted" style="margin-bottom:13px">验证码</div><div style="display:flex;gap:15px;justify-content:center;align-items:center"><span style="font-family:ui-monospace,monospace;font-size:24px;font-weight:700;letter-spacing:4px">H7KP 2N</span><button class="icon-btn" data-toast="授权验证码已复制" aria-label="复制验证码">${icon('copy')}</button></div><p class="muted tiny" style="margin:15px 0 0;line-height:1.7">授权码有效期内完成扫码。<br>返回此页面后，连接状态会自动更新。</p></div>
          <div style="height:12px"></div>${group(row('link', '打开 115 授权页面', '', '', '', 'data-toast="原型演示：打开 115 官方授权页面"') + row('copy', '复制授权内容', '', '', '', 'data-toast="授权内容已复制"') + row('refresh', '重新获取授权码', '', '', '', 'data-toast="已刷新授权二维码"'))}
          ${caption('二维码和验证码为原型展示，不包含真实授权信息。')}
        </div></div>`
    },
    {
      id: 'licenses', title: '开源许可', group: '资料与设置',
      note: '关于页中的真实开源许可清单；点选条目展示文本阅读状态。',
      html: `<div class="content">${navTop('开源许可', 'settings')}
        <div class="pad">
          <div style="padding:24px 2px 6px"><div style="font-size:24px;font-weight:750;letter-spacing:-.6px">致谢开源社区</div><p class="muted" style="font-size:13px;line-height:1.7;margin:12px 0 20px">HPlayer 的播放体验，离不开这些开源项目。</p></div>
          ${group([
            ['mpv / MPVKit', '视频播放内核'], ['Nuvio Engine', '磁力播放引擎'], ['Nuvio 第三方声明', '第三方许可与版权声明'], ['libtorrent', 'BitTorrent 库'], ['libtorrent COPYING', '版权与许可文本'], ['Boost', 'C++ 库'], ['OpenSSL', '加密与安全通信'], ['try_signal', '信号处理库']
          ].map(([name, sub]) => row('file', name, sub, '', '', `data-toast="已打开 ${name} 许可文本"`)).join(''))}
          ${caption('许可文件随应用打包，可在离线状态下阅读。')}
        </div></div>`
    }
  );

  document.addEventListener('click', event => {
    const target = event.target.closest('[data-theme-mode]');
    if (!target) return;
    const page = window.PAGES.find(item => item.id === 'appearance');
    page.html = page.html.replace(/<!--appearance-options-->[\s\S]*?<!--\/appearance-options-->/,
      `<!--appearance-options-->${appearanceOptions(target.dataset.themeMode)}<!--/appearance-options-->`);
  });

  function qr() {
    const blocks = [];
    const finder = (x, y) => `<rect x="${x}" y="${y}" width="7" height="7" fill="#111"/><rect x="${x+1}" y="${y+1}" width="5" height="5" fill="white"/><rect x="${x+2}" y="${y+2}" width="3" height="3" fill="#111"/>`;
    for (let y = 0; y < 29; y++) for (let x = 0; x < 29; x++) {
      if ((x < 8 && y < 8) || (x > 20 && y < 8) || (x < 8 && y > 20)) continue;
      if (((x * 17 + y * 11 + x * y * 3) % 11) < 5) blocks.push(`<rect x="${x}" y="${y}" width="1" height="1"/>`);
    }
    return `<svg viewBox="-1 -1 31 31" width="100%" height="100%" fill="#111" aria-label="授权二维码示意">${blocks.join('')}${finder(0,0)}${finder(22,0)}${finder(0,22)}</svg>`;
  }
})();
