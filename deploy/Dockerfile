# Our Free Model 服务器部署版 —— 单容器镜像
# 应用本体（app/）零 npm 运行时依赖，仅需 Node.js 22.19+ / 24+
# 因为服务强制只绑定回环地址，反代必须与之同网络命名空间，故同容器内置 nginx。

FROM node:22-alpine

LABEL org.opencontainers.image.title="our-free-model-server" \
      org.opencontainers.image.source="https://github.com/Ebony-Vinyl/dsh-our-free-model" \
      org.opencontainers.image.licenses="MIT"

RUN apk add --no-cache nginx tzdata curl \
    && rm -rf /var/cache/apk/*

# 应用本体
COPY app/ /opt/ofm/app/
# 上游 MIT 许可证随应用一同分发
COPY app/LICENSE /opt/ofm/LICENSE

# 容器内反代与入口
COPY deploy/docker/nginx.conf /etc/nginx/nginx.conf
COPY deploy/docker/entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

# OFM 服务端口（容器内部回环）与 nginx 对外端口
ENV OFM_HOME=/data \
    OFM_PORT=18900 \
    OFM_PROXY_PORT=8080
EXPOSE 8080
VOLUME ["/data"]

HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=3 \
  CMD curl -fsS http://127.0.0.1:${OFM_PROXY_PORT}/health || exit 1

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
