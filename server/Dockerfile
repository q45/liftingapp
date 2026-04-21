# syntax=docker/dockerfile:1.7
#
# Multi-stage build: compile TS in a builder image, then copy only the
# built JS + production deps into a slim runtime image. Runs as a
# non-root user and respects $PORT (Fly/Cloud Run/Railway all set it).

ARG NODE_VERSION=20

# -- builder ---------------------------------------------------------------
FROM node:${NODE_VERSION}-bookworm-slim AS builder
WORKDIR /app

COPY package.json package-lock.json ./
RUN npm ci

COPY tsconfig.json ./
COPY src ./src
RUN npm run build

# Drop devDependencies so we can copy a clean node_modules into runtime.
RUN npm prune --omit=dev

# -- runtime ---------------------------------------------------------------
FROM node:${NODE_VERSION}-bookworm-slim AS runtime
WORKDIR /app

ENV NODE_ENV=production

COPY --from=builder /app/node_modules ./node_modules
COPY --from=builder /app/dist ./dist
COPY package.json ./

USER node
EXPOSE 3000

CMD ["node", "dist/index.js"]
