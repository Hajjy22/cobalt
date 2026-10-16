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

COPY --from=build --chown=node:node /prod/api /app
COPY --from=build --chown=node:node /app/.git /app/.git

USER node

EXPOSE 9000
CMD [ "node", "src/cobalt" ]
