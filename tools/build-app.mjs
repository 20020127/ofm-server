#!/usr/bin/env node
/**
 * 从上游仓库 dsh-our-free-model 提取 standalone 运行时闭包，扁平化为可独立部署的 app/。
 *
 * 背景：上游 packages/standalone 官方支持脱离 DSH 运行，但依赖完整仓库的相对路径
 * （../../src、../../../vendor）。本脚本把运行时闭包复制到 app/ 并改写这些路径，
 * 使 app/ 成为自包含、零 npm 运行时依赖的服务目录。
 *
 * 用法：node tools/build-app.mjs [上游仓库路径] [输出目录]
 * 默认：上游 = ../upstream/src/dsh-our-free-model-main，输出 = ./app
 */
import fs from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

const here = path.dirname(fileURLToPath(import.meta.url))
const upstream = path.resolve(process.argv[2] ?? path.join(here, '..', 'upstream', 'src', 'dsh-our-free-model-main'))
const out = path.resolve(process.argv[3] ?? path.join(here, '..', 'app'))

if (!fs.existsSync(path.join(upstream, 'packages', 'standalone', 'cli.mjs'))) {
  console.error(`上游目录无效：${upstream}`)
  process.exit(1)
}

/** 相对导入闭包：从入口出发，沿静态 import/export-from/createRequire 遍历。 */
function closure(entries) {
  const seen = new Set()
  const missing = []
  const resolveRel = (fromFile, spec) => path.resolve(path.dirname(fromFile), spec)
  const walk = file => {
    if (seen.has(file)) return
    seen.add(file)
    if (!fs.existsSync(file)) { missing.push(file); return }
    const src = fs.readFileSync(file, 'utf8')
    const specs = new Set()
    const patterns = [
      /import\s+(?:[\s\S]*?from\s*)?['"]([^'"]+)['"]/g,
      /export\s+(?:[\s\S]*?from\s*)?['"]([^'"]+)['"]/g,
      /createRequire\([^)]*\)\s*\(\s*['"]([^'"]+)['"]\s*\)/g,
    ]
    for (const re of patterns) { let m; while ((m = re.exec(src)) !== null) specs.add(m[1]) }
    for (const spec of specs) {
      if (spec.startsWith('node:') || spec.startsWith('data:') || /^https?:/.test(spec)) continue
      if (spec.startsWith('.') || spec.startsWith('/')) {
        const target = resolveRel(file, spec)
        const candidates = [target, target + '.mjs', target + '.js', target + '.json', target + '.wasm',
          path.join(target, 'index.mjs'), path.join(target, 'index.js')]
        const found = candidates.find(c => fs.existsSync(c) && fs.statSync(c).isFile())
        if (found) walk(found); else missing.push(`${path.relative(upstream, file)} -> ${spec}`)
      }
    }
  }
  for (const e of entries) walk(path.resolve(upstream, e))
  return { files: [...seen].sort(), missing }
}

/** 把上游文件映射到扁平化后的 app/ 目标路径。 */
function targetOf(abs) {
  const rel = path.relative(upstream, abs)
  if (rel.startsWith(`packages${path.sep}standalone${path.sep}channels${path.sep}`)) {
    return path.join(out, 'channels', rel.slice(`packages${path.sep}standalone${path.sep}channels${path.sep}`.length))
  }
  if (rel.startsWith(`packages${path.sep}standalone${path.sep}`)) {
    return path.join(out, rel.slice(`packages${path.sep}standalone${path.sep}`.length))
  }
  return path.join(out, rel) // src/**、vendor/** 保持原结构
}

/** 路径改写：packages/standalone 深层相对引用 → 扁平化后的相对引用。 */
function rewrite(relTarget, text) {
  const rel = relTarget.replaceAll(path.sep, '/')
  if (rel.startsWith('channels/')) {
    // channels/*.mjs：../../../src → ../src；../../../vendor → ../vendor
    text = text.replaceAll('../../../src/', '../src/')
    text = text.replaceAll('../../../vendor/', '../vendor/')
  } else if (!rel.startsWith('src/') && !rel.startsWith('vendor/')) {
    // app/*.mjs 与 app/src/ 同级：../../src → ./src
    text = text.replaceAll("'../../src/", "'./src/")
    text = text.replaceAll('"../../src/', '"./src/')
  }
  return text
}

/**
 * 密钥脱敏：上游 business.mjs 逆向自带的第三方硬编码凭据，公开仓库不再分发。
 * 替换为环境变量覆盖 + 空默认值（未配置时对应渠道不可用，属预期行为）。
 *
 * 规则按「变量名/属性名 + 引号字符串」的**结构**匹配，而不是按密钥字面量匹配：
 * 若写成字面量，脱敏脚本自身就把四个真实凭据写进了公开仓库，脚本反倒成了泄漏源。
 * 结构匹配同时更耐上游轮换——密钥值换了仍然命中。
 *
 * 两层防呆（任一触发即构建失败）：
 *   1) 替换后规则仍能命中 → 说明脱敏未生效；
 *   2) FORBIDDEN_SHAPES 形态扫描 → 兜住「上游改了变量名但凭据形态不变」的漏网情况。
 * 已知边界：Loomy / Raccoon 两处凭据没有可辨识前缀，若上游同时改掉变量名与取值，
 * 形态扫描无法覆盖，只能靠人工复核（见 docs/COMPLIANCE.md 第 1b 节）。
 */
const REDACTIONS = [
  [/accessKeyId:\s*"[A-Za-z0-9]{16}"/, 'accessKeyId: process.env.OFM_LOOMY_ACCESS_KEY_ID || ""'],
  [/accessKeySecret:\s*"[A-Za-z0-9]{32}"/, 'accessKeySecret: process.env.OFM_LOOMY_ACCESS_KEY_SECRET || ""'],
  [/var RACCOON_PHONE_CIPHER_SECRET = "[^"]*"/, 'var RACCOON_PHONE_CIPHER_SECRET = process.env.OFM_RACCOON_PHONE_CIPHER_SECRET || ""'],
  [/var GEMINI_DEFAULT_CLIENT_SECRET = "GOCSPX-[A-Za-z0-9_-]+"/, 'var GEMINI_DEFAULT_CLIENT_SECRET = process.env.CMDC_PAK_GOOGLE_CLIENT_SECRET || ""'],
]

/** 凭据「形态」清单：只描述形状，不含任何真实密钥，供二次兜底扫描使用。 */
const FORBIDDEN_SHAPES = [
  ['Google OAuth 客户端密钥', /GOCSPX-[A-Za-z0-9_-]{20,}/],
  ['OpenAI 风格 API Key', /sk-[A-Za-z0-9]{32,}/],
  ['JWT', /eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}/],
]

function redactSecrets(text, relFor) {
  for (const [re, rep] of REDACTIONS) {
    if (!new RegExp(re.source).test(text)) continue
    text = text.replace(new RegExp(re.source, 'g'), rep)
    console.log(`  redact: ${relFor} <- ${rep.replace(/process\.env\./, '')}`)
  }
  for (const [re] of REDACTIONS) {
    if (new RegExp(re.source).test(text)) {
      console.error(`脱敏失败：${relFor} 仍匹配规则 ${re.source}`)
      process.exit(1)
    }
  }
  for (const [name, shape] of FORBIDDEN_SHAPES) {
    const m = text.match(shape)
    if (m) {
      console.error(`脱敏失败：${relFor} 残留疑似${name}（形态 ${shape.source}，命中 ${m[0].length} 字符）`)
      console.error('  如确认不是凭据，请更新 FORBIDDEN_SHAPES；否则应先补脱敏规则。')
      process.exit(1)
    }
  }
  return text
}

/**
 * 服务器部署补丁：让管理端展示的对外基地址具备「反向代理感知」能力。
 *
 * 这是本仓库相对上游的**唯一行为改动**，故在此打补丁而不是去改上游仓库
 * （上游目录在仓库外，改了不会随提交保留）。
 *
 * 要解决的问题：上游 service.mjs 把 info().baseUrl 硬编码成回环绑定地址，
 * 那是「本机桌面插件」的假设。服务器版经 nginx 反代 + 域名 + TLS 暴露时，
 * 管理页「API 接入」展示的 API Base URL 与 curl 示例会变成用户打不开的本机
 * 地址（实测经 https://linghui.help 访问，summary.baseUrl 仍返回
 * http://127.0.0.1:18900）。详见 tools/patches/public-url.js 顶部说明。
 *
 * 防呆与脱敏同纪律：锚点未命中、或命中次数与预期不符，一律构建失败。
 * 上游若重构了这些代码，我们宁可构建报错，也不要静默产出「补丁没打上」的 app/。
 */
const SERVER_PATCHES = [
  {
    file: 'service.mjs',
    find: "import { isLoopbackHost } from './src/trust.js'",
    replace: "import { isLoopbackHost } from './src/trust.js'\nimport { publicBaseUrl } from './src/public-url.js'",
    what: '引入 publicBaseUrl',
  },
  {
    file: 'service.mjs',
    find: "        baseUrl: `http://${host === '::1' ? '[::1]' : host}:${listener?.port ?? requestedPort}`,",
    replace: '        baseUrl: publicBaseUrl(req, host, listener?.port ?? requestedPort),',
    what: 'baseUrl 改为反向代理感知',
  },
  {
    file: 'service.mjs',
    find: '      info: () => ({',
    replace: '      info: req => ({',
    what: 'info 接收请求上下文',
  },
  {
    file: 'management.mjs',
    find: '  const summary = () => {',
    replace: '  const summary = req => {',
    what: 'summary 接收请求上下文',
  },
  {
    file: 'management.mjs',
    find: '      ...info(),',
    replace: '      ...info(req),',
    what: 'summary 透传 req 给 info',
  },
  {
    file: 'management.mjs',
    find: '        const base = new URL(info().baseUrl)',
    replace: '        const base = new URL(info(req).baseUrl)',
    what: 'gateway.getEnabled 透传 req',
  },
  {
    // /summary 与 /models/refresh 两处，数量写死为 2，多一处少一处都算漂移
    file: 'management.mjs',
    find: 'json(res, 200, summary())',
    replace: 'json(res, 200, summary(req))',
    what: 'summary 调用点透传 req',
    all: true,
    expect: 2,
  },
]

function patchServerDeployment(relTarget, text) {
  for (const patch of SERVER_PATCHES) {
    if (patch.file !== relTarget) continue
    const count = text.split(patch.find).length - 1
    const expect = patch.expect ?? 1
    if (count !== expect) {
      console.error(`服务器补丁失败：${relTarget} 锚点「${patch.what}」出现 ${count} 次，期望 ${expect} 次`)
      console.error(`  期望匹配：${patch.find}`)
      console.error('  上游代码可能已重构；请更新 SERVER_PATCHES 后重试，不要绕过该校验。')
      process.exit(1)
    }
    text = patch.all ? text.replaceAll(patch.find, patch.replace) : text.replace(patch.find, patch.replace)
    console.log(`  patch: ${relTarget} <- ${patch.what}${patch.all ? `（${count} 处）` : ''}`)
  }
  return text
}

const entries = ['packages/standalone/cli.mjs', 'packages/standalone/channels/worker.mjs']
const { files, missing } = closure(entries)
if (missing.length > 0) {
  console.error('闭包存在未解析导入：')
  for (const m of missing) console.error('  ' + m)
  process.exit(1)
}

fs.rmSync(out, { recursive: true, force: true })
const copied = []
for (const abs of files) {
  const target = targetOf(abs)
  fs.mkdirSync(path.dirname(target), { recursive: true })
  const rel = path.relative(upstream, abs)
  if (abs.endsWith('.mjs') || abs.endsWith('.js')) {
    const relFor = path.relative(out, target).replaceAll(path.sep, '/')
    let text = fs.readFileSync(abs, 'utf8')
    text = rewrite(relFor, text)
    text = patchServerDeployment(relFor, text)
    text = redactSecrets(text, relFor)
    fs.writeFileSync(target, text)
  } else {
    fs.copyFileSync(abs, target)
  }
  copied.push(path.relative(out, target).replaceAll(path.sep, '/'))
}

// 运行时通过 readFileSync(new URL(...)) 读取、不走静态导入的资产
const extras = [
  'packages/standalone/web',
  'src/providers/registry.json',
  'vendor/channel-pack/qoder-auth-wasm.wasm',
  'vendor/channel-pack/NOTICE.md',
  'vendor/channel-pack/LICENSE',
  'LICENSE',
]
for (const rel of extras) {
  const from = path.join(upstream, rel)
  const to = rel.startsWith('packages/standalone/') ? path.join(out, rel.slice('packages/standalone/'.length)) : path.join(out, rel)
  if (!fs.existsSync(from)) { console.error('缺少额外资产：' + rel); process.exit(1) }
  fs.mkdirSync(path.dirname(to), { recursive: true })
  if (fs.statSync(from).isDirectory()) {
    fs.cpSync(from, to, { recursive: true })
    for (const f of walkDir(from)) copied.push(path.relative(out, path.join(to, f)).replaceAll(path.sep, '/'))
  } else {
    fs.copyFileSync(from, to)
    copied.push(path.relative(out, to).replaceAll(path.sep, '/'))
  }
}
function walkDir(dir) {
  const out = []
  for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
    if (e.isDirectory()) out.push(...walkDir(path.join(dir, e.name)).map(f => path.join(e.name, f)))
    else out.push(e.name)
  }
  return out
}

// 服务器部署新增模块：反向代理感知的对外基地址（本仓库独有，非上游代码）。
// 放这里而不是 extras，是因为它没有上游来源，纯粹是本仓库的增量。
{
  const from = path.join(here, 'patches', 'public-url.js')
  const to = path.join(out, 'src', 'public-url.js')
  if (!fs.existsSync(from)) { console.error('缺少补丁模块：tools/patches/public-url.js'); process.exit(1) }
  fs.mkdirSync(path.dirname(to), { recursive: true })
  fs.copyFileSync(from, to)
  copied.push('src/public-url.js')
  console.log('  patch: + src/public-url.js（反向代理感知的对外基地址）')
}

// 重写 package.json：去掉插件/构建相关字段，保留 engines 与版本
const pkg = JSON.parse(fs.readFileSync(path.join(upstream, 'packages', 'standalone', 'package.json'), 'utf8'))
const upstreamVersion = JSON.parse(fs.readFileSync(path.join(upstream, 'package.json'), 'utf8')).version
const appPkg = {
  name: 'our-free-model-server',
  version: pkg.version,
  private: false,
  type: 'module',
  description: 'Our Free Model 独立服务（服务器部署版）——OpenAI 兼容网关，聚合匿名免费通道、Kilo 免费池、EAC 协付渠道与十三个账号渠道',
  main: './cli.mjs',
  engines: pkg.engines,
  license: 'MIT',
  scripts: { start: 'node cli.mjs' },
}
fs.writeFileSync(path.join(out, 'package.json'), JSON.stringify(appPkg, null, 2) + '\n')

// 来源与溯源信息
const provenance = `# 来源与溯源

本目录由 tools/build-app.mjs 自动生成，请勿手工编辑（重新生成会覆盖）。

- 上游项目：Ebony-Vinyl/dsh-our-free-model（MIT License）
- 上游版本：dsh-our-free-model@${upstreamVersion}；standalone 包版本 ${pkg.version}
- 上游地址：https://github.com/Ebony-Vinyl/dsh-our-free-model
- 提取内容：packages/standalone 运行时闭包 + src/ 核心 + vendor/channel-pack 资产 + web/ 预构建前端
- 路径改写：packages/standalone 的深层相对导入（../../src、../../../vendor）已扁平化为 ../src、../vendor
- 密钥脱敏：上游内置的 4 处第三方硬编码凭据已替换为环境变量覆盖（见 docs/COMPLIANCE.md 第 1b 节）
- 服务器补丁：新增 src/public-url.js，令管理端展示的对外基地址具备反向代理感知能力（原为硬编码回环地址）；service.mjs / management.mjs 的对应改动见 tools/build-app.mjs 的 SERVER_PATCHES
- 运行时依赖：无（仅 Node.js 内置模块，engines: ${JSON.stringify(pkg.engines.node)}）

上游 LICENSE 见本目录 LICENSE 文件，保留其版权声明即满足 MIT 要求。
`
fs.writeFileSync(path.join(out, 'UPSTREAM.md'), provenance)

console.log(`app/ 构建完成：${copied.length} 个文件`)
console.log(`  入口：${path.relative(process.cwd(), path.join(out, 'cli.mjs'))}`)
const byTop = {}
for (const f of copied) { const t = f.includes('/') ? f.slice(0, f.indexOf('/')) : '(root)'; byTop[t] = (byTop[t] ?? 0) + 1 }
for (const [t, n] of Object.entries(byTop)) console.log(`  ${t}: ${n}`)
