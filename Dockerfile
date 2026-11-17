# 1) Compila la app web de Flutter
FROM --platform=$BUILDPLATFORM ghcr.io/cirruslabs/flutter:stable AS web
WORKDIR /src
COPY app/ app/
COPY ci/ ci/
RUN bash ci/prepare.sh web \
 && cd app && flutter build web --release --no-web-resources-cdn

# 2) Servidor ligero que sirve la web y sincroniza los apuntes
FROM node:22-slim
WORKDIR /app
COPY server/server.js ./
COPY --from=web /src/app/build/web ./web
ENV DATA_DIR=/data PORT=8080 NODE_NO_WARNINGS=1
VOLUME /data
EXPOSE 8080
CMD ["node", "server.js"]
