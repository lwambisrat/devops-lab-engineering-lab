# Node.js API image for the Regional Health service.
FROM node:20-alpine AS deps

WORKDIR /usr/src/app

COPY package.json package-lock.json ./
RUN npm ci --omit=dev \
    && npm cache clean --force

FROM alpine:3.23

# Runtime needs node for the API and mysql-client/bash for the seed script.
RUN apk add --no-cache nodejs bash mysql-client \
    && addgroup -S node \
    && adduser -S node -G node

WORKDIR /usr/src/app

COPY --from=deps --chown=node:node /usr/src/app/node_modules ./node_modules
COPY --chown=node:node . .

# The seed script lives in ../data-seed and is bind-mounted at runtime by
# docker-compose to /usr/local/bin/seed.sh (it is outside this build context,
# so it cannot be COPYed here).

EXPOSE 3000

USER node

CMD ["node", "server.js"]
