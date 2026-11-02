FROM node:22-alpine AS build

RUN apk add --no-cache git python3 make g++
WORKDIR /app

COPY UPSTREAM_REF /tmp/UPSTREAM_REF
RUN git init && git remote add origin https://github.com/DSpace/dspace-angular.git \
    && git fetch --depth 1 origin "$(cat /tmp/UPSTREAM_REF)" \
    && git checkout --detach FETCH_HEAD

COPY oidc-return-page.patch /tmp/oidc-return-page.patch
RUN git apply --check /tmp/oidc-return-page.patch && git apply /tmp/oidc-return-page.patch
RUN npm ci
ENV NODE_OPTIONS="--max_old_space_size=4096"
RUN npm run build:prod

FROM node:22-alpine
RUN npm install --global pm2
COPY --chown=node:node --from=build /app/dist /app/dist
COPY --chown=node:node --from=build /app/config /app/config
COPY --chown=node:node --from=build /app/docker/dspace-ui.json /app/dspace-ui.json
WORKDIR /app
USER node
ENV NODE_ENV=production
EXPOSE 4000
ENTRYPOINT ["pm2-runtime", "start", "dspace-ui.json"]
CMD ["--json"]
