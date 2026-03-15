FROM ghcr.io/cirruslabs/flutter:stable AS build

WORKDIR /app

COPY pubspec.yaml pubspec.lock ./
RUN flutter pub get

COPY . .

RUN flutter build web --release --no-wasm-dry-run

FROM node:20-alpine AS runtime

WORKDIR /app

COPY --from=build /app/build/web ./build/web
COPY railway-server.js ./railway-server.js

ENV PORT=8080

EXPOSE 8080

CMD ["node", "railway-server.js"]