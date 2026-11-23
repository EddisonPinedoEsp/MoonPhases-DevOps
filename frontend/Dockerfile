ARG NODE_IMAGE=node:20-alpine
ARG NGINX_IMAGE=nginxinc/nginx-unprivileged:alpine

FROM ${NODE_IMAGE} AS build

WORKDIR /app

COPY package*.json ./
RUN npm ci

COPY vite.config.ts tsconfig.json ./
COPY index.html ./
COPY src ./src
RUN npm run build

FROM ${NGINX_IMAGE}

COPY nginx.conf /etc/nginx/conf.d/default.conf
COPY --from=build /app/dist /usr/share/nginx/html/MoonPhases

ARG FRONTEND_CONTAINER_PORT=8081
EXPOSE ${FRONTEND_CONTAINER_PORT}
