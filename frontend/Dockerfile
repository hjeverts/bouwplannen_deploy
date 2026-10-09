# Bouwt de Angular-app (context "app" = ../bouwplannen_frontend) en serveert hem met nginx.

FROM node:22-alpine AS build
WORKDIR /app
COPY --from=app package.json package-lock.json ./
# --legacy-peer-deps: de lockfile is zo aangemaakt; npm 10 struikelt anders over een peer-dependency.
RUN npm ci --legacy-peer-deps --no-audit --no-fund
COPY --from=app . .
RUN npx ng build --configuration production

FROM nginx:1.27-alpine
COPY nginx.conf /etc/nginx/conf.d/default.conf
COPY --from=build /app/dist/bouwplannen-frontend/browser /usr/share/nginx/html
EXPOSE 80
