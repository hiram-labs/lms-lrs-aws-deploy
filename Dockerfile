# syntax=docker/dockerfile:1.3-labs

# -- Stage 1: Build the application
FROM public.ecr.aws/debian/debian:12 as BUILDER
ARG IMAGE_VERSION

ENV DEBIAN_FRONTEND=noninteractive
# assists ./nginx.conf file envsubst
ENV DOLLAR=$
ENV IMAGE_VERSION=${IMAGE_VERSION}
# node >16 dropped md4 support this bypasses it (https://github.com/webpack/webpack/issues/14532)
ENV NODE_OPTIONS="--openssl-legacy-provider --max-old-space-size=8192"

RUN echo 'APT::Install-Suggests "0";' >> /etc/apt/apt.conf.d/00-docker
RUN echo 'APT::Install-Recommends "0";' >> /etc/apt/apt.conf.d/00-docker

RUN set -uex \
    && apt-get update \
    && apt-get install -y git curl gnupg ca-certificates python3 python-is-python3 build-essential xvfb apt-transport-https gettext \
    && mkdir -p /etc/apt/keyrings \
    && curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key \
        | gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg \
    && NODE_MAJOR=18 \
    && echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_$NODE_MAJOR.x nodistro main" \
        | tee /etc/apt/sources.list.d/nodesource.list \
    && apt-get update \
    && apt-get install -y nodejs

COPY .env /tmp/.env
COPY nginx.conf /tmp/nginx.conf.template

WORKDIR /opt

RUN git clone --depth 1 --branch main https://github.com/hiram-labs/lms-directus.git \
    && cd lms-directus \
    && cp /tmp/.env .\
    && corepack enable \
    # Pin pnpm version as there is a known corepack issue https://github.com/nodejs/corepack/issues/612
    && corepack prepare pnpm@10.0.0 --activate \
    && pnpm fetch \
    && pnpm install --recursive --offline --frozen-lockfile \
    && npm_config_workspace_concurrency=1 pnpm run build \
    && pnpm --filter directus deploy --prod dist \
    && rm -rf ./node_modules/.cache \
    && cd dist \
    # Regenerate package.json file with essential fields only (see https://github.com/directus/directus/issues/20338)
    && node -e ' \
        const f = "package.json", {name, version, type, exports, bin} = require(`./${f}`), {packageManager} = require(`../${f}`); \
        fs.writeFileSync(f, JSON.stringify({name, version, type, exports, bin, packageManager}, null, 2)); \
    ' \
    && cd /opt

RUN git clone --depth 1 --branch main https://github.com/hiram-labs/lms-studio.git \
    && cd lms-studio \
    && cp /tmp/.env .\
    && npm ci \
    && npm run build \
    && rm -rf ./node_modules/.cache \
    && cd /opt

RUN git clone --depth 1 --branch main https://github.com/hiram-labs/lrs-core.git \
    && cd lrs-core \
    && cp /tmp/.env .\
    && npm ci \
    && npm run build-all \
    && rm -rf ./node_modules/.cache \
    && cd /opt

RUN git clone --depth 1 --branch main https://github.com/hiram-labs/lrs-xapi-service.git \
    && cd lrs-xapi-service \
    && cp /tmp/.env .\
    && npm ci \
    && npm run build \
    && rm -rf ./node_modules/.cache \
    && cd /opt

RUN set -a && . /tmp/.env && set +a \
    && envsubst < /tmp/nginx.conf.template > /tmp/nginx.conf



# -- Stage 2: Create web services image
FROM public.ecr.aws/debian/debian:12-slim as WEB

ENV HOST=0.0.0.0
ENV PATH=/usr/lib/node_modules/npm/bin:$PATH
ENV DEBIAN_FRONTEND=noninteractive

COPY --from=builder /usr/bin/node /usr/bin/node
COPY --from=builder /usr/lib/node_modules /usr/lib/node_modules

WORKDIR /app/lms-directus
COPY --from=BUILDER /opt/lms-directus/dist ./dist
COPY --from=BUILDER /opt/lms-directus/directus-extensions/lms/dist ./dist/extensions/lms/dist
COPY --from=BUILDER /opt/lms-directus/directus-extensions/lms/package.json ./dist/extensions/lms/

WORKDIR /app/lms-studio
COPY --from=BUILDER /opt/lms-studio/package.json /opt/lms-studio/package-lock.json ./
COPY --from=BUILDER /opt/lms-studio/node_modules ./node_modules
COPY --from=BUILDER /opt/lms-studio/dist ./dist

WORKDIR /app/lrs-core
COPY --from=BUILDER /opt/lrs-core/package.json /opt/lrs-core/package-lock.json ./
COPY --from=BUILDER /opt/lrs-core/node_modules ./node_modules
COPY --from=BUILDER /opt/lrs-core/cli/dist ./cli/dist
COPY --from=BUILDER /opt/lrs-core/worker/dist ./worker/dist
COPY --from=BUILDER /opt/lrs-core/api/dist ./api/dist
COPY --from=BUILDER /opt/lrs-core/ui/dist ./ui/dist

WORKDIR /app/lrs-xapi-service
COPY --from=BUILDER /opt/lrs-xapi-service/package.json /opt/lrs-xapi-service/package-lock.json ./
COPY --from=BUILDER /opt/lrs-xapi-service/node_modules ./node_modules
COPY --from=BUILDER /opt/lrs-xapi-service/dist ./xapi/dist

WORKDIR /app
COPY --from=BUILDER /opt/lrs-core/lib ./lib
COPY --from=BUILDER /tmp/nginx.conf /etc/nginx/conf.d/
COPY --from=BUILDER /tmp/.env ./

COPY static/ /var/www/html/
COPY certs/ /etc/ssl/certs/
COPY pm2.json ctl.sh ./

RUN ln -s /usr/lib/node_modules /usr/bin/node_modules \
    && apt-get update \
    && apt-get install -y --no-install-recommends nginx \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/* /usr/share/doc/* /usr/share/man/* /usr/share/locale/* \
    && npm install --global pm2 \
    && pm2 logrotate -u root \
    && cd /app/lms-studio \
    && npm prune --production \
    && cd /app/lrs-core \
    && npm prune --production \
    && cd /app/lrs-xapi-service \
    && npm prune --production \
    && cd /app \
    && chmod +x ctl.sh \
    && ln -s /app/ctl.sh /usr/local/bin/ctl \
    && ln -s /app/.env /app/lms-directus/dist/.env \
    && ln -s /app/.env /app/lrs-core/.env \
    && ln -s /app/.env /app/lrs-xapi-service/.env \
    && rm /etc/nginx/sites-enabled/default \
    && mkdir -p /app/storage/tmp

EXPOSE 80
ENTRYPOINT [ "ctl", "start" ]



# -- Stage 3: Create cli service image
FROM web as CLI

RUN rm -rf /app/lms-studio /app/lrs-xapi-service /app/lrs-core/worker /app/lrs-core/api /app/lrs-core/ui

ENTRYPOINT ["sh", "-c"]
CMD [ "ctl", "help" ]



# -- Stage 4: Create proxy service image
FROM public.ecr.aws/docker/library/haproxy:2.8-alpine as PROXY

ENV STAGING_SERVICE_NAME=public_xrtemis_staging
ENV PROD_SERVICE_NAME=public_xrtemis_production
ENV ECS_DNS_NAMESPACE=tf-xrtemis.local

COPY <<EOF /usr/local/etc/haproxy/haproxy.cfg
global
    # log stdout format raw local0
    maxconn 4096

defaults
    log global
    mode http
    timeout connect 5s
    timeout client 50s
    timeout server 50s

frontend http_front
    bind *:80
    acl is_staging hdr_beg(host) -i staging.
    use_backend staging_backend if is_staging
    default_backend production_backend

backend staging_backend
    http-request set-header Host %[req.hdr(host),regsub(^staging\.,,)]
    server staging \${STAGING_SERVICE_NAME}.\${ECS_DNS_NAMESPACE}:80 check

backend production_backend
    server production \${PROD_SERVICE_NAME}.\${ECS_DNS_NAMESPACE}:80 check
EOF

USER root
EXPOSE 80
