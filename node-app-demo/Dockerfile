# A plain Linux application image -- the ordinary Docker case, built here
# with buildkit in a ferry pod instead of a Docker daemon. See ../build.sh
# and docs/RUNTIMES.md#building-an-image-without-docker.
#
# package.json is copied and installed on its own, above the source, so
# editing src/ hits cache on everything expensive (npm install).
FROM node:22-alpine
WORKDIR /app
COPY package.json ./
RUN npm install --omit=dev --no-audit --no-fund
COPY src ./src
EXPOSE 8080
CMD ["node", "src/index.js"]
