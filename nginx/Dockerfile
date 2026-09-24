# syntax=docker/dockerfile:1

# Reverse proxy for all public DMP hosts. Also serves the seller SPA, which is built here
# from the "seller" build context (the dmp.seller repository, see compose.yaml).

FROM node:24-alpine AS seller-build
ARG VAR_ENV=production
WORKDIR /usr/src/app

COPY --from=seller package.json package-lock.json ./
RUN npm ci

COPY --from=seller --exclude=node_modules --exclude=dist --exclude=.git . .
RUN case "$VAR_ENV" in \
        development) npm run build:dev ;; \
        staging) npm run build:staging ;; \
        *) npm run build:prod ;; \
    esac


FROM nginx:1.30

# Lets the nginx worker user match a host UID (for files shared through bind mounts).
ARG UID=1000
RUN usermod -u "$UID" nginx

# Server blocks are rendered from /etc/nginx/templates at container start (envsubst of DMP_* vars).
RUN rm -f /etc/nginx/conf.d/default.conf
COPY nginx.conf /etc/nginx/nginx.conf
COPY include/ /etc/nginx/include/
COPY templates/ /etc/nginx/templates/

COPY --from=seller-build /usr/src/app/dist /usr/share/nginx/html

EXPOSE 80 443
