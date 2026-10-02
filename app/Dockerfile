# syntax=docker/dockerfile:1.7

# Pin this to a digest before going to production:
#   docker buildx imagetools inspect node:22-bookworm-slim --format '{{json .Manifest.Digest}}'
# and use node:22-bookworm-slim@sha256:<digest>. Dependabot (see .github/dependabot.yml)
# keeps it moving after that.
ARG NODE_IMAGE=node:22-bookworm-slim

FROM ${NODE_IMAGE} AS deps
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci --omit=dev --ignore-scripts && npm cache clean --force

FROM ${NODE_IMAGE} AS runtime
ENV NODE_ENV=production \
    PORT=3000
WORKDIR /app

# The runtime only ever runs `node`. npm, npx and corepack are not used after
# the build, but they ship a large bundled dependency tree of their own that
# shows up in every image scan (brace-expansion, pacote, sigstore, ...) and is
# attack surface for anything that gets code execution in the container.
# Removing them is both a smaller image and a quieter, more honest scan.
RUN rm -rf /usr/local/lib/node_modules/npm \
           /usr/local/lib/node_modules/corepack \
           /usr/local/bin/npm /usr/local/bin/npx /usr/local/bin/corepack

COPY --from=deps --chown=root:root /app/node_modules ./node_modules
COPY --chown=root:root package.json ./
COPY --chown=root:root src ./src

# Code is owned by root and only readable by the runtime user, so a compromised
# process can't rewrite itself.
USER node

ARG APP_VERSION=dev
ENV APP_VERSION=${APP_VERSION}
LABEL org.opencontainers.image.source="https://github.com/ytushar24/gsp-ops" \
      org.opencontainers.image.revision="${APP_VERSION}"

EXPOSE 3000
HEALTHCHECK --interval=5s --timeout=3s --start-period=10s --retries=3 \
  CMD ["node", "src/healthcheck.js"]

# exec form so SIGTERM reaches node directly (compose sets init: true for zombie reaping)
CMD ["node", "src/server.js"]
