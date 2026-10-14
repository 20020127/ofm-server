# syntax=docker/dockerfile:1.7
#
# Our Free Model 服务器部署版 —— 单容器镜像（生产加固版）
#
# 为什么「一个容器里同时装 nginx 和 Node」：
#   上游 startStandalone 只允许绑定回环地址（app/src/trust.js 的 isLoopbackHost 校验，
#   这是上游设计，不可绕过）。容器网络的 DNAT 无法把发布端口的流量送进容器的
#   127.0.0.1，所以反代必须与服务同网络命名空间 —— 同容器是最简单可靠的落地方式。
#
# 构建（在项目根目录 ofm-server/ 下执行）：
#   docker build -f deploy/Dockerfile -t ofm-server:1.0.0 \
#     --build-arg OFM_VERSION=1.0.0 \
#     --build-arg OFM_REVISION="$(git rev-parse --short HEAD 2>/dev/null || echo unknown)" .
#
# 生产环境请把基础镜像固定到 digest（tag 可被重新推送，digest 不可变）：
#   docker buildx imagetools inspect node:22.19.0-alpine | grep -i digest
#   docker build -f deploy/Dockerfile \
#     --build-arg NODE_IMAGE=node@sha256:<上一步得到的 digest> -t ofm-server:1.0.0 .
#
# 相对上一版的加固要点：
#   1) 非 root（uid/gid 10001）运行 —— 应用被攻破也拿不到 root；
#   2) tini 作 PID1 —— 回收僵尸进程，并把 docker stop 的 SIGTERM 可靠送到入口脚本；
#   3) 移除 npm / npx —— 本项目运行时零 npm 依赖，留着只是多一份可被利用的攻击面；
#   4) nginx 临时目录 + 数据目录预建并降权 —— 兼容 compose 的 read_only: true；
#   5) 入口改为「监督模式」—— 任一子进程死掉就退出容器，让重启策略/告警真正生效
#      （详见 deploy/docker/entrypoint.sh 顶部的两起事故复盘）。

ARG NODE_IMAGE=node:22.19.0-alpine
FROM ${NODE_IMAGE}

# OFM_VERSION / OFM_REVISION 只进 OCI 标签，用于回溯源站与排查「线上跑的是哪个版本」
ARG OFM_VERSION=1.0.0
ARG OFM_REVISION=unknown

LABEL org.opencontainers.image.title="our-free-model-server" \
      org.opencontainers.image.description="Our Free Model 独立部署版：OpenAI 兼容网关（服务仅绑回环 + 内置 nginx 反代）" \
      org.opencontainers.image.source="https://github.com/Ebony-Vinyl/dsh-our-free-model" \
      org.opencontainers.image.licenses="MIT" \
      org.opencontainers.image.version="${OFM_VERSION}" \
      org.opencontainers.image.revision="${OFM_REVISION}" \
      org.opencontainers.image.base.name="${NODE_IMAGE}"

# bash ：入口与运维脚本用了 bash 专有特性（wait -n / [[ ]] / 数组），alpine 默认 dash 不够用
# tini ：PID1 信号转发与僵尸回收
# curl ：入口的就绪探测 + HEALTHCHECK（无 curl 时无法判断「反代链路是否通」）
# tzdata：让日志时间戳与本地时区一致，否则排障时时间对不上
RUN set -eux; \
    apk add --no-cache nginx tini bash tzdata curl ca-certificates; \
    rm -rf /var/cache/apk/* /tmp/*

# 非 root 运行账号：UID/GID 固定为 10001
# （固定数字很关键 —— 宿主机挂 bind mount 时授权只认这两个数字，不认用户名）
RUN set -eux; \
    addgroup -g 10001 -S ofm; \
    adduser  -u 10001 -S -G ofm -h /opt/ofm -s /sbin/nologin ofm

# ── 应用本体：运行时零 npm 依赖（纯 Node 内置模块 + 一个 Qoder WASM）──
COPY app/ /opt/ofm/app/
# 上游 MIT 许可证随应用一同分发
COPY app/LICENSE /opt/ofm/LICENSE

# ── 容器内反代与入口 ──
COPY deploy/docker/nginx.conf             /etc/nginx/nginx.conf
# 两个关键请求头（Host 必须回环名 / Origin-Referer 置空）抽成共享片段，被各 location include
COPY deploy/docker/ofm-proxy-headers.conf /etc/nginx/ofm-proxy-headers.conf
COPY deploy/docker/entrypoint.sh          /opt/ofm/entrypoint.sh
# 运维脚本进镜像：陈旧锁清理 / 部署预检 / 健康检查 / 诊断快照
# 进镜像的意义是「线上排障不用把脚本拷进容器」—— docker exec ofm /opt/ofm/scripts/diagnostics.sh
COPY deploy/scripts/                      /opt/ofm/scripts/

# ── 预建运行时目录并降权 ──
# /data              ：状态目录（卷挂载点）—— 明文凭据、API Key、账目统计都在这里
# /var/lib/nginx/tmp ：nginx 的 client_body / proxy 临时目录
#                      （非 root 运行 + 根文件系统只读时必需，默认路径没有写权限）
# 同时移除 npm/npx：确认过全仓库运行时零 npm 调用（唯一的 "npm" 字样是权限提示词的
# 字符串常量），去掉可再减一个攻击面并省下约 15MB 镜像体积。
RUN set -eux; \
    mkdir -p /var/lib/nginx/tmp/client_body /var/lib/nginx/tmp/proxy /data; \
    chmod +x /opt/ofm/entrypoint.sh /opt/ofm/scripts/*.sh; \
    chown -R ofm:ofm /opt/ofm /var/lib/nginx /data; \
    chmod 0750 /opt/ofm/scripts /opt/ofm/entrypoint.sh; \
    rm -rf /usr/local/lib/node_modules/npm /usr/local/bin/npm /usr/local/bin/npx

# ── 运行时参数 ──
# NODE_OPTIONS 的默认堆上限必须显式压低：V8 按「宿主机物理内存」而不是 cgroup 上限
# 推算默认堆大小。2G 限额的容器跑在 64G 宿主机上，V8 会允许约 4G 堆 —— 结果是还没等到
# GC 就被 cgroup 的 OOM Killer 直接杀掉（容器表现为 exit 137 + 无任何错误日志）。
# 经验值：max-old-space-size ≈ 容器内存上限的 50%~60%。用 compose/环境变量可覆盖。
ENV OFM_HOME=/data \
    OFM_PORT=18900 \
    OFM_PROXY_PORT=8080 \
    OFM_STARTUP_TIMEOUT=60 \
    OFM_STOP_TIMEOUT=25 \
    NODE_ENV=production \
    NODE_OPTIONS=--max-old-space-size=1024
EXPOSE 8080
VOLUME ["/data"]

# 健康检查刻意走 nginx 端口而不是服务端口：这样能覆盖「nginx 活着但后端已死」的半边故障
# （那种状态下服务端口探测会通过、而所有真实请求都是 502）。
HEALTHCHECK --interval=30s --timeout=5s --start-period=60s --retries=3 \
  CMD curl -fsS --max-time 4 "http://127.0.0.1:${OFM_PROXY_PORT}/health" || exit 1

USER ofm
WORKDIR /opt/ofm

# tini 作 PID1 的原因：容器内 PID1 默认不接收默认动作的信号处理、也不回收孤儿进程；
# 没有 tini 时 docker stop 的 SIGTERM 可能落不到 shell 脚本的 trap 上，服务会被 SIGKILL，
# 留下陈旧的 service.lock（详见 entrypoint.sh 的事故 2）。
ENTRYPOINT ["/sbin/tini", "--", "/opt/ofm/entrypoint.sh"]
