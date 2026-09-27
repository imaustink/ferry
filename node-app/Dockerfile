# A plain Linux application image -- the ordinary Docker case, built here
# with buildkit in a ferry pod instead of a Docker daemon. See ../build.sh
# and docs/RUNTIMES.md#building-an-image-without-docker. This is the same
# Dockerfile a `docker build` or `docker buildx build` would use; nothing
# about it is ferry-specific, which is the point.
#
# Two stages so the shipped image carries only production dependencies and
# never a copy of the npm cache. package.json and the lockfile are copied
# and installed on their own, above the source, so editing src/ hits cache
# on everything expensive (npm ci).
FROM node:22-alpine AS deps
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci --omit=dev --no-audit --no-fund

FROM node:22-alpine AS runtime
# tini reaps zombies and forwards signals correctly to node as pid 1 --
# without it, SIGTERM from the kubelet either does not reach the app or
# leaves defunct children behind, depending on what the app spawns.
RUN apk add --no-cache tini
WORKDIR /app
ENV NODE_ENV=production
# node:22-alpine already ships an unprivileged "node" user (uid/gid 1000);
# reusing it is one less thing to get wrong versus rolling a fresh one.
COPY --from=deps --chown=node:node /app/node_modules ./node_modules
COPY --chown=node:node package.json ./
COPY --chown=node:node src ./src
USER node
EXPOSE 8080
HEALTHCHECK --interval=30s --timeout=3s CMD node -e "require('http').get('http://127.0.0.1:8080/healthz',r=>process.exit(r.statusCode===200?0:1)).on('error',()=>process.exit(1))"
ENTRYPOINT ["/sbin/tini", "--"]
CMD ["node", "src/index.js"]
