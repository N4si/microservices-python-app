# Stage 1 — Build React app
FROM node:18-alpine AS builder
WORKDIR /app
COPY package.json ./
RUN npm install
COPY . .
# VITE_* vars are baked into the bundle at build time. Pass the Grafana NodePort
# URL so the Dashboard page's iframe/links point at the live Grafana, not the
# fallback localhost:30007. Supplied via --build-arg (kept out of git so it can
# track the current node IP); falls back to the in-code default if unset.
ARG VITE_GRAFANA_URL
ENV VITE_GRAFANA_URL=$VITE_GRAFANA_URL
RUN npm run build

# Stage 2 — Serve with nginx as non-root
FROM nginx:1.25-alpine
RUN addgroup -g 1001 appgroup && adduser -u 1001 -G appgroup -D appuser
COPY --from=builder /app/dist /usr/share/nginx/html
COPY nginx.conf /etc/nginx/conf.d/default.conf
RUN chown -R appuser:appgroup /usr/share/nginx/html \
    && chown -R appuser:appgroup /var/cache/nginx \
    && chown -R appuser:appgroup /var/log/nginx \
    && touch /var/run/nginx.pid \
    && chown appuser:appgroup /var/run/nginx.pid
USER appuser
EXPOSE 8080
CMD ["nginx", "-g", "daemon off;"]
