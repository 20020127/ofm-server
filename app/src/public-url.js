/**
 * 反向代理感知的对外基地址。
 *
 * 【本文件是 ofm-server 相对上游的新增模块，不属于上游代码。】
 * 由 tools/build-app.mjs 从 tools/patches/public-url.js 拷入 app/src/，
 * 重新生成 app/ 时会带上，故可直接手改 tools/patches/ 下的源文件。
 *
 * 背景：上游 service.mjs 把 info().baseUrl 硬编码成回环绑定地址
 * （http://127.0.0.1:18900），那是「本机桌面插件」的假设 —— 插件就跑在用户
 * 机器上，回环地址确实可达。但服务器版经 nginx 反向代理 + 域名 + TLS 暴露时，
 * 管理页「API 接入」展示给用户的 API Base URL 与 curl 示例就都成了打不开的
 * 本机地址。实测：经 https://linghui.help 访问，summary.baseUrl 仍返回
 * http://127.0.0.1:18900，用户照抄这个地址必然连不上。
 *
 * 推导优先级：
 *   1. OFM_PUBLIC_BASE_URL 环境变量 —— 显式声明，最高优先，适合反代不方便
 *      透传头的场景（CDN、多层网关）；
 *   2. 反向代理透传的 X-Forwarded-Proto + X-Forwarded-Host —— 自动适配，
 *      域名或证书换了无需改配置；
 *   3. 回环绑定地址 —— 上游原有行为，本机直连场景完全不受影响。
 *
 * 安全说明：X-Forwarded-Host 由客户端可控，因此仅当请求的 Host 本身是回环名时
 * 才采信该头。上游 structuralRejection 对管理端强制要求回环 Host，能走到这里
 * 的请求必然已通过那道闸门，等价于「确认来自受信反代」；直连暴露到公网的部署
 * 则自动落到第 3 优先级，不会被伪造头污染。另外该值只用于界面展示，不参与
 * 任何出网请求，最坏情况只是显示一个错地址，不会把流量导向别处。
 *
 * @module src/public-url.js
 */

/** 回环主机名。判据与 src/trust.js 的 LOOPBACK_NAMES 保持一致。 */
const LOOPBACK_NAMES = new Set(['127.0.0.1', '[::1]', '::1', 'localhost'])

/** 取一个字符串 header 的首个值；Node 对重复头会给出数组。 */
function firstHeader(value) {
  if (typeof value === 'string') return value.trim()
  if (Array.isArray(value) && typeof value[0] === 'string') return value[0].trim()
  return ''
}

/**
 * 反代头是否可采信：请求的 Host 必须是回环名。
 *
 * 经本机 nginx 反代时，上游看到的 Host 被改写成回环地址（管理端硬性要求），
 * 这正好构成「来自受信反代」的判据；直连暴露时 Host 不是回环名，自动不采信。
 */
function fromTrustedProxy(req) {
  const raw = firstHeader(req?.headers?.host)
  if (raw === '') return false
  const authority = raw.toLowerCase()
  const hostname = authority.startsWith('[')
    ? authority.slice(0, authority.indexOf(']') + 1)
    : authority.split(':')[0]
  return LOOPBACK_NAMES.has(hostname)
}

/**
 * host[:port] 形态校验：拒绝空格、路径、用户信息等一切不该出现的东西。
 * 只放行 DNS 名（含 localhost）与方括号 IPv6，各带可选端口（端口须为 1-65535）。
 */
function isPlainAuthority(value) {
  if (value === '' || value.length > 253) return false
  if (/^[A-Za-z0-9._-]+(:[0-9]{1,5})?$/.test(value)) return validPort(value)
  return /^\[[0-9A-Fa-f:.]+\](:[0-9]{1,5})?$/.test(value) && validPort(value)
}

/** 端口段若存在则必须在 1-65535（拒绝 0、前导零超范围与 99999 这类五位数）。 */
function validPort(value) {
  const m = value.match(/:([0-9]{1,5})$/)
  if (m === null) return true
  return Number(m[1]) >= 1 && Number(m[1]) <= 65535
}

/**
 * 推导对外基地址（不带结尾斜杠）。
 *
 * @param {import('node:http').IncomingMessage|null|undefined} req - 当前管理请求，用于读取反代头
 * @param {string} fallbackHost - 服务实际绑定的主机
 * @param {number} fallbackPort - 服务实际监听的端口
 * @returns {string} 形如 https://ofm.example.com 或 http://127.0.0.1:18900
 */
export function publicBaseUrl(req, fallbackHost, fallbackPort) {
  const explicit = (process.env.OFM_PUBLIC_BASE_URL ?? '').trim().replace(/\/+$/, '')
  if (explicit !== '') return explicit

  if (req !== null && req !== undefined && fromTrustedProxy(req)) {
    const proto = firstHeader(req.headers['x-forwarded-proto']).toLowerCase()
    const host = firstHeader(req.headers['x-forwarded-host'])
    if ((proto === 'http' || proto === 'https') && isPlainAuthority(host)) {
      return `${proto}://${host}`
    }
  }

  return `http://${fallbackHost === '::1' ? '[::1]' : fallbackHost}:${fallbackPort}`
}
