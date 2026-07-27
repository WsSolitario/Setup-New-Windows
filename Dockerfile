FROM node:22-alpine

WORKDIR /app
COPY package*.json ./
RUN npm ci --omit=dev

COPY src ./src
COPY powershell ./powershell
RUN mkdir -p /app/artifacts

ENV NODE_ENV=production
EXPOSE 3000
USER node
CMD ["node", "src/server.js"]
