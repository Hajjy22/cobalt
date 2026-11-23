FROM node:24-alpine AS base
ENV PNPM_HOME="/pnpm"
ENV PATH="$PNPM_HOME:$PATH"
ENV CUSTOM_INNERTUBE_CLIENT=VISIONOS

FROM base AS build
WORKDIR /app
COPY . /app

RUN corepack enable
RUN apk add --no-cache python3 alpine-sdk

RUN pnpm install --prod --frozen-lockfile

RUN pnpm deploy --filter=@imput/cobalt-api --prod /prod/api

RUN mkdir -p /app/.git/logs \
    && printf 'ref: refs/heads/main\n' > /app/.git/HEAD \
    && printf '0000000000000000000000000000000000000000 3ce9b3436554e0224e596ceab868cd31a0e1258e Railway <railway@local> 0 +0000\tbuild\n' > /app/.git/logs/HEAD \
    && printf '[remote "origin"]\n\turl = https://github.com/Hajjy22/cobalt.git\n' > /app/.git/config

FROM base AS api
WORKDIR /app

RUN apk add --no-cache curl tar \
    && ARCH="$(uname -m)" \
    && case "$ARCH" in x86_64) GOARCH=amd64 ;; aarch64) GOARCH=arm64 ;; *) GOARCH=amd64 ;; esac \
    && curl -fsSL "https://github.com/ViRb3/wgcf/releases/download/v2.3.1/wgcf_2.3.1_linux_${GOARCH}" -o /usr/local/bin/wgcf \
    && chmod +x /usr/local/bin/wgcf \
    && curl -fsSL "https://github.com/pufferffish/wireproxy/releases/download/v1.1.3/wireproxy_linux_${GOARCH}.tar.gz" -o /tmp/wireproxy.tar.gz \
    && tar -xzf /tmp/wireproxy.tar.gz -C /usr/local/bin wireproxy \
    && chmod +x /usr/local/bin/wireproxy \
    && rm -f /tmp/wireproxy.tar.gz \
    && apk del curl tar

COPY --from=build --chown=node:node /prod/api /app
COPY --from=build --chown=node:node /app/.git /app/.git
COPY start-cobalt.sh /usr/local/bin/start-cobalt.sh
RUN sed -i 's/\r$//' /usr/local/bin/start-cobalt.sh && chmod 755 /usr/local/bin/start-cobalt.sh

USER node

EXPOSE 9000
CMD [ "sh", "/usr/local/bin/start-cobalt.sh" ]
