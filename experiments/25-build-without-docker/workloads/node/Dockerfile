# The shape of a real application build, and the one the answer hangs on.
#
# Dependencies are installed from a manifest copied on its own, above the
# source, so editing the source hits cache on everything expensive. That is
# the edit-rebuild loop, and it is the number that decides whether a builder
# is pleasant to use -- not the cold build, which happens once a day.
FROM node:22-alpine
WORKDIR /app
COPY package.json ./
RUN npm install --no-audit --no-fund
COPY src ./src
CMD ["node", "src/index.js"]
