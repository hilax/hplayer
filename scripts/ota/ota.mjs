#!/usr/bin/env node
/**
 * HPlayer OTA — 一键把未签名 IPA 变成「点链接就装」的分发页。
 *
 *   node scripts/ota/ota.mjs check     检查 signing/ 里的证书，判定企业签 / UDID 绑定
 *   node scripts/ota/ota.mjs site      只部署静态安装页 + workflow + Pages + Release（不需要证书）
 *   node scripts/ota/ota.mjs publish   本机签名：p12 不上传 GitHub，签完直接推 Release
 *   node scripts/ota/ota.mjs setup     CI 签名：证书存 GitHub Secrets，以后每次构建自动重签
 *
 * 证书三件套放 signing/：
 *   cert.p12  cert.mobileprovision  password.txt（或环境变量 OTA_CERT_PASSWORD）
 */
import { spawnSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const REPO = process.env.OTA_REPO || 'hilax/hplayer';
const BRANCH = process.env.OTA_BRANCH || 'main';
const TAG = 'ota';
const OWNER = REPO.split('/')[0];
const NAME = REPO.split('/')[1];
const PAGE_URL = `https://${OWNER}.github.io/${NAME}/`;
const MANIFEST_URL = `${PAGE_URL}manifest.plist`;
const IPA_URL = `https://github.com/${REPO}/releases/download/${TAG}/HPlayer-signed.ipa`;
const ITMS = `itms-services://?action=download-manifest&url=${encodeURIComponent(MANIFEST_URL)}`;
const GH = process.platform === 'win32' ? 'gh.exe' : 'gh';
const DEFAULT_BUNDLE = 'app.hplayer.native';

// ---------------------------------------------------------------- process helpers
function run(exe, args, opts = {}) {
  const base = { encoding: 'utf8', maxBuffer: 128 * 1024 * 1024, ...opts };
  let r = spawnSync(exe, args, base);
  if (r.error && (r.error.code === 'ENOENT' || r.error.code === 'EINVAL')) {
    const quoted = args.map(a => (/[\s"&|<>^%]/.test(String(a)) ? JSON.stringify(String(a)) : String(a)));
    r = spawnSync(`${exe} ${quoted.join(' ')}`, [], { ...base, shell: true });
  }
  if (r.error) throw new Error(`${exe} 启动失败：${r.error.message}`);
  return r;
}
function must(exe, args, opts = {}) {
  const r = run(exe, args, opts);
  if (r.status !== 0) throw new Error(`${exe} ${args.slice(0, 3).join(' ')} 失败(${r.status})：\n${(r.stderr || r.stdout || '').trim()}`);
  return r.stdout.trim();
}
function gh(args, opts = {}) { return must(GH, args, opts); }
let apiBodySeq = 0;
function ghApi(endpoint, method = 'GET', body = null) {
  const args = ['api'];
  if (method !== 'GET') args.push('--method', method);
  let tmp = null;
  if (body !== null) {
    // gh.exe 在 Windows 上用 spawnSync 传大 stdin 会 EOF，改成临时文件 + --input <file>
    tmp = path.join(os.tmpdir(), `hplayer-ota-body-${process.pid}-${++apiBodySeq}.json`);
    fs.writeFileSync(tmp, JSON.stringify(body), 'utf8');
    args.push('-H', 'Content-Type: application/json', '--input', tmp);
  }
  args.push(endpoint);
  try {
    const out = gh(args);
    return out ? JSON.parse(out) : {};
  } finally {
    if (tmp) { try { fs.unlinkSync(tmp); } catch {} }
  }
}
function ghTry(args) { return run(GH, args); }
const P = (...a) => path.join(ROOT, ...a);
const read = f => fs.readFileSync(P(f));

// ---------------------------------------------------------------- provisioning profile
function parseProfile(buf) {
  const s = buf.indexOf('<?xml');
  const e = buf.indexOf('</plist>');
  if (s < 0 || e < 0) throw new Error('这不是有效的 .mobileprovision（找不到内嵌 XML plist）');
  const xml = buf.subarray(s, e + 8).toString('utf8');
  const str = key => {
    const m = xml.match(new RegExp(`<key>${key}</key>\\s*<string>([^<]*)</string>`));
    return m ? m[1].trim() : null;
  };
  const date = key => {
    const m = xml.match(new RegExp(`<key>${key}</key>\\s*<date>([^<]*)</date>`));
    return m ? m[1].trim() : null;
  };
  const allDevices = /<key>ProvisionsAllDevices<\/key>\s*<true\s*\/>/.test(xml);
  const devBlock = xml.match(/<key>ProvisionedDevices<\/key>\s*<array>([\s\S]*?)<\/array>/);
  const udids = devBlock ? [...devBlock[1].matchAll(/<string>([^<]*)<\/string>/g)].map(m => m[1].trim()) : [];
  const appId = str('application-identifier') || '';
  const team = (xml.match(/<key>TeamIdentifier<\/key>\s*<array>\s*<string>([^<]*)<\/string>/) || [])[1] || null;
  let tail = appId.includes('.') ? appId.slice(appId.indexOf('.') + 1) : '';
  const wildcard = !tail || tail === '*' || tail.endsWith('.*');
  const bundleId = wildcard ? DEFAULT_BUNDLE : tail;
  const devMode = /<key>get-task-allow<\/key>\s*<true\s*\/>/.test(xml);
  return {
    allDevices, udids, appId, team, wildcard, bundleId, devMode,
    name: str('Name'), appIdName: str('AppIDName'),
    expires: date('ExpirationDate'), created: date('CreationDate'),
  };
}

function loadSigning() {
  const dir = P('signing');
  if (!fs.existsSync(dir)) throw new Error('找不到 signing/ 目录，请先创建并放入证书三件套');
  const files = fs.readdirSync(dir);
  const find = re => files.find(f => re.test(f));
  const p12Name = find(/\.p12$/i);
  const provName = find(/\.mobileprovision$/i);
  const pwName = find(/^password\.txt$/i);
  if (!p12Name) throw new Error('signing/ 缺少 .p12 文件');
  if (!provName) throw new Error('signing/ 缺少 .mobileprovision 描述文件');
  const password = process.env.OTA_CERT_PASSWORD || (pwName ? fs.readFileSync(path.join(dir, pwName), 'utf8').trim() : '');
  if (!password) throw new Error('缺少证书密码：放 signing/password.txt 或设环境变量 OTA_CERT_PASSWORD');
  const p12 = fs.readFileSync(path.join(dir, p12Name));
  const prov = fs.readFileSync(path.join(dir, provName));
  return { p12, prov, password, p12Name, provName, profile: parseProfile(prov) };
}

function report(s) {
  const p = s.profile;
  console.log('\n证书检查');
  console.log('─'.repeat(52));
  console.log(`  p12              ${s.p12Name} (${(s.p12.length / 1024).toFixed(1)} KB)`);
  console.log(`  mobileprovision  ${s.provName} (${(s.prov.length / 1024).toFixed(1)} KB)`);
  console.log(`  名称             ${p.name || '—'} / ${p.appIdName || '—'}`);
  console.log(`  Team ID          ${p.team || '—'}`);
  console.log(`  App ID           ${p.appId || '—'}`);
  console.log(`  ProvisionsAllDevices  ${p.allDevices ? 'true' : 'false'}`);
  console.log(`  ProvisionedDevices    ${p.udids.length} 台`);
  console.log(`  到期             ${p.expires || '—'}`);
  console.log(`  需要开发者模式   ${p.devMode ? '是' : '否'}`);
  console.log(`  签名 bundle id   ${p.bundleId}${p.wildcard ? '（通配 App ID，沿用原 bundle）' : '（显式 App ID，必须改写 bundle）'}`);
  console.log('─'.repeat(52));
  if (p.allDevices) {
    console.log('  ✅ 企业签 / In-House：不绑设备，任何 iPhone 点链接都能装。');
  } else if (p.udids.length) {
    console.log(`  ⚠️  UDID 绑定型：只有 ${p.udids.length} 台登记设备能装。`);
    console.log('     其他手机会报「完整性无法验证」。要放开给几个人，必须把他们的 UDID');
    console.log('     加进描述文件并重新生成 .mobileprovision，再用同一份 p12 重签。');
  } else {
    console.log('  ⚠️  既无 ProvisionsAllDevices 也无 ProvisionedDevices，请确认描述文件类型。');
  }
  return p;
}

// ---------------------------------------------------------------- generated site files
function renderManifest(bundleId, version = '1.4') {
  return `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
\t<key>items</key>
\t<array>
\t\t<dict>
\t\t\t<key>assets</key>
\t\t\t<array>
\t\t\t\t<dict>
\t\t\t\t\t<key>kind</key><string>software-package</string>
\t\t\t\t\t<key>url</key><string>${IPA_URL}</string>
\t\t\t\t</dict>
\t\t\t\t<dict>
\t\t\t\t\t<key>kind</key><string>display-image</string>
\t\t\t\t\t<key>needs-shine</key><false/>
\t\t\t\t\t<key>url</key><string>${PAGE_URL}icon-57.png</string>
\t\t\t\t</dict>
\t\t\t\t<dict>
\t\t\t\t\t<key>kind</key><string>full-size-image</string>
\t\t\t\t\t<key>needs-shine</key><false/>
\t\t\t\t\t<key>url</key><string>${PAGE_URL}icon-512.png</string>
\t\t\t\t</dict>
\t\t\t\t<dict>
\t\t\t\t\t<key>kind</key><string>ipad-image</string>
\t\t\t\t\t<key>needs-shine</key><false/>
\t\t\t\t\t<key>url</key><string>${PAGE_URL}icon-512.png</string>
\t\t\t\t</dict>
\t\t\t</array>
\t\t\t<key>metadata</key>
\t\t\t<dict>
\t\t\t\t<key>bundle-identifier</key><string>${bundleId}</string>
\t\t\t\t<key>bundle-version</key><string>${version}</string>
\t\t\t\t<key>kind</key><string>software</string>
\t\t\t\t<key>title</key><string>HPlayer</string>
\t\t\t\t<key>subtitle</key><string>HPlayer</string>
\t\t\t</dict>
\t\t</dict>
\t</array>
</dict>
</plist>
`;
}
function renderMeta(p) {
  return JSON.stringify({
    app: 'HPlayer', bundleIdentifier: p.bundleId, version: '1.4', build: '23', minOS: '16.1',
    profileType: p.allDevices ? 'enterprise' : 'udid-bound',
    udidBound: !p.allDevices, udidCount: p.udids.length,
    devModeRequired: p.devMode, manifestUrl: MANIFEST_URL, ipaUrl: IPA_URL, installUrl: PAGE_URL,
    releaseApi: `https://api.github.com/repos/${REPO}/releases/tags/${TAG}`,
  }, null, 2) + '\n';
}

// ---------------------------------------------------------------- GitHub push (single atomic commit via Git Data API)
function pushFiles(files, message) {
  const ref = ghApi(`repos/${REPO}/git/ref/heads/${BRANCH}`);
  const baseSha = ref.object.sha;
  const baseCommit = ghApi(`repos/${REPO}/git/commits/${baseSha}`);
  const tree = [];
  for (const [remote, buf] of files) {
    const blob = ghApi(`repos/${REPO}/git/blobs`, 'POST', { content: buf.toString('base64'), encoding: 'base64' });
    tree.push({ path: remote, mode: '100644', type: 'blob', sha: blob.sha });
    console.log(`  ↑ ${remote} (${(buf.length / 1024).toFixed(1)} KB)`);
  }
  const newTree = ghApi(`repos/${REPO}/git/trees`, 'POST', { base_tree: baseCommit.tree.sha, tree });
  const newCommit = ghApi(`repos/${REPO}/git/commits`, 'POST', { message, tree: newTree.sha, parents: [baseSha] });
  ghApi(`repos/${REPO}/git/refs/heads/${BRANCH}`, 'PATCH', { sha: newCommit.sha, force: false });
  console.log(`  ✅ 已提交到 ${REPO}@${BRANCH}：${newCommit.sha.slice(0, 7)}`);
}

function siteFiles(profile) {
  const p = profile || { bundleId: DEFAULT_BUNDLE, allDevices: true, udids: [], devMode: false };
  const files = [
    ['.github/workflows/ota.yml', read('.github/workflows/ota.yml')],
    ['docs/index.html', read('docs/index.html')],
    ['docs/manifest.plist', Buffer.from(renderManifest(p.bundleId), 'utf8')],
    ['docs/meta.json', Buffer.from(renderMeta(p), 'utf8')],
    ['docs/.nojekyll', Buffer.from('\n', 'utf8')],
    ['docs/icon.png', read('docs/icon.png')],
    ['docs/icon-57.png', read('docs/icon-57.png')],
    ['docs/icon-512.png', read('docs/icon-512.png')],
    ['docs/qr.png', read('docs/qr.png')],
    ['docs/OTA.md', read('docs/OTA.md')],
    ['scripts/ota/ota.mjs', read('scripts/ota/ota.mjs')],
  ];
  return files;
}

function enablePages() {
  const body = { build_type: 'legacy', source: { branch: BRANCH, path: '/docs' } };
  const cur = ghTry(['api', `repos/${REPO}/pages`]);
  if (cur.status === 0) {
    try {
      const cfg = JSON.parse(cur.stdout);
      if (cfg.source && cfg.source.branch === BRANCH && cfg.source.path === '/docs') {
        console.log('  ✅ GitHub Pages 已启用（main /docs）');
        return;
      }
    } catch {}
    ghApi(`repos/${REPO}/pages`, 'PUT', { source: body.source, build_type: body.build_type });
    console.log('  ✅ GitHub Pages 源已更新为 main /docs');
  } else {
    try {
      ghApi(`repos/${REPO}/pages`, 'POST', body);
      console.log('  ✅ GitHub Pages 已启用（main /docs）');
    } catch (e) {
      console.log(`  ⚠️  Pages 启用返回：${String(e.message).split('\n')[0]}`);
      console.log('     若已启用请手动确认：Settings → Pages → Deploy from a branch → main /docs');
    }
  }
}

function ensureRelease() {
  const v = ghTry(['release', 'view', TAG, '-R', REPO]);
  if (v.status === 0) { console.log(`  ✅ Release「${TAG}」已存在`); return; }
  gh(['release', 'create', TAG, '-R', REPO, '--title', 'HPlayer OTA',
      '--notes', 'Fixed tag for OTA installs. The IPA asset is replaced in place on every build.']);
  console.log(`  ✅ 已创建 Release「${TAG}」`);
}

function deploySite(profile) {
  console.log('\n部署静态安装页');
  pushFiles(siteFiles(profile), 'chore(ota): add one-click IPA install page and signing workflow');
  enablePages();
  ensureRelease();
}

// ---------------------------------------------------------------- secrets + CI
function setSecrets(s) {
  console.log('\n写入 GitHub Secrets（p12 私钥仅存于 GitHub Actions 加密仓库）');
  const secrets = {
    OTA_CERT_P12_B64: s.p12.toString('base64'),
    OTA_CERT_PROV_B64: s.prov.toString('base64'),
    OTA_CERT_PASSWORD: s.password,
    OTA_BUNDLE_ID: s.profile.bundleId,
  };
  for (const [k, v] of Object.entries(secrets)) {
    gh(['secret', 'set', k, '-R', REPO], { input: v });
    console.log(`  ✓ ${k}`);
  }
}
function latestBuildRun() {
  const out = gh(['run', 'list', '-R', REPO, '-w', 'Build unsigned iOS IPA', '-s', 'success', '-L', '1',
                  '--json', 'databaseId', '-q', '.[0].databaseId']);
  return out.trim();
}
function triggerCi() {
  const rid = latestBuildRun();
  console.log(`\n触发签名 workflow（构建产物 run ${rid}）`);
  try {
    gh(['workflow', 'run', 'ota.yml', '-R', REPO, '--ref', BRANCH, '-f', `run_id=${rid}`]);
    console.log('  ✅ 已触发');
  } catch (e) {
    console.log(`  ⚠️  ${String(e.message).split('\n')[0]}`);
    console.log(`     手动触发：gh workflow run ota.yml -R ${REPO} --ref ${BRANCH}`);
  }
}

// ---------------------------------------------------------------- local signing (Mode B)
function zsignPath() {
  const local = P('scripts/ota/bin', process.platform === 'win32' ? 'zsign.exe' : 'zsign');
  if (fs.existsSync(local)) return local;
  throw new Error('缺少 scripts/ota/bin/zsign(.exe)，请先下载 https://github.com/zhlynn/zsign/releases/tag/v1.1.3');
}
function resolveUnsignedIpa() {
  const arg = process.argv.indexOf('--ipa');
  if (arg > -1 && process.argv[arg + 1]) {
    const f = path.resolve(process.argv[arg + 1]);
    if (!fs.existsSync(f)) throw new Error(`找不到 IPA：${f}`);
    return f;
  }
  const cached = P('dist/input/HPlayer-unsigned.ipa');
  if (fs.existsSync(cached)) return cached;
  console.log('  ↓ 本地没有缓存的未签名 IPA，从最新成功的构建下载…');
  const rid = latestBuildRun();
  fs.mkdirSync(P('dist/input'), { recursive: true });
  gh(['run', 'download', rid, '-R', REPO, '-n', 'HPlayer-unsigned-ipa', '-D', 'dist/input']);
  const found = fs.readdirSync(P('dist/input')).find(f => f.endsWith('.ipa'));
  if (!found) throw new Error('下载的 artifact 里没有 .ipa');
  return P('dist/input', found);
}
function signLocally(s) {
  const unsigned = resolveUnsignedIpa();
  const out = P('dist/HPlayer-signed.ipa');
  fs.mkdirSync(P('dist'), { recursive: true });
  console.log(`\n本机签名（p12 不离开这台电脑）`);
  console.log(`  输入 ${unsigned}`);
  const r = run(zsignPath(), [
    '-f', '-k', P('signing', s.p12Name), '-p', s.password,
    '-m', P('signing', s.provName), '-b', s.profile.bundleId, '-z', '9', '-o', out, unsigned,
  ], { cwd: ROOT });
  if (r.status !== 0 || !fs.existsSync(out)) throw new Error(`zsign 失败：\n${(r.stderr || r.stdout || '').slice(-2500)}`);
  console.log(`  ✅ 签名完成：${(fs.statSync(out).size / 1048576).toFixed(1)} MB`);
  return out;
}
function uploadIpa(file) {
  console.log('\n上传到 Release');
  gh(['release', 'upload', TAG, file, '-R', REPO, '--clobber']);
  console.log(`  ✅ ${IPA_URL}`);
}

// ---------------------------------------------------------------- finish
function finish(extra) {
  console.log('\n' + '═'.repeat(56));
  console.log('分发完成，把下面任意一条发给你的用户即可：');
  console.log(`  安装页（推荐，手机 Safari 打开）  ${PAGE_URL}`);
  console.log(`  二维码                          ${PAGE_URL}qr.png`);
  console.log(`  直接安装协议                    ${ITMS}`);
  console.log(`  IPA 直链                        ${IPA_URL}`);
  console.log(`  manifest                        ${MANIFEST_URL}`);
  if (extra) console.log(extra);
  console.log('═'.repeat(56) + '\n');
}

// ---------------------------------------------------------------- main
const cmd = process.argv[2] || 'check';
try {
  if (cmd === 'check') {
    report(loadSigning());
    console.log('\n接下来：node scripts/ota/ota.mjs publish（本机签名）或 setup（CI 自动签名）');
  } else if (cmd === 'site') {
    deploySite(null);
    finish('当前还没有上传签名包，页面会显示「尚未上传」。放好证书后运行 publish 或 setup。');
  } else if (cmd === 'publish') {
    const s = loadSigning();
    report(s);
    deploySite(s.profile);
    uploadIpa(signLocally(s));
    finish('模式：本机签名，p12 从未上传到 GitHub。以后出新包重复本命令即可。');
  } else if (cmd === 'setup') {
    const s = loadSigning();
    report(s);
    setSecrets(s);
    deploySite(s.profile);
    triggerCi();
    finish('模式：CI 自动签名，以后每次 Build unsigned iOS IPA 成功都会自动重签并覆盖 Release 里的 IPA。');
  } else {
    console.error(`未知子命令：${cmd}\n可用：check | site | publish | setup`);
    process.exit(2);
  }
} catch (e) {
  console.error('\n✗ ' + e.message + '\n');
  process.exit(1);
}
