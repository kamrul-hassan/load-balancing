# syntax=docker/dockerfile:1
# Build context: web/  ->  docker build -t loadbalancing-web web

FROM node:22-alpine AS build
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci --no-audit --no-fund
COPY . .
RUN npx ng build --configuration production

# Unprivileged nginx listens on 8080 and runs as uid 101.
FROM nginxinc/nginx-unprivileged:1.29-alpine AS runtime
# Rendered by the image's entrypoint (envsubst) into /etc/nginx/conf.d/default.conf at start-up.
COPY nginx/default.conf.template /etc/nginx/templates/default.conf.template
COPY --from=build /app/dist/web/browser /usr/share/nginx/html

# Where /api/* is proxied. Docker Compose uses Docker's embedded DNS; Kubernetes overrides both.
ENV API_UPSTREAM=http://api:8080 \
    DNS_RESOLVER=127.0.0.11 \
    NGINX_ENVSUBST_FILTER="^(API_UPSTREAM|DNS_RESOLVER)$"

EXPOSE 8080
