# Base: Node.js LTS on Alpine (small, arm64-capable for the Pi).
FROM node:24-alpine

WORKDIR /app

# Copy only package.json first (Docker layer cache). This example app has
# no dependencies; once you add some, uncomment the next line:
COPY package.json ./
# RUN npm install --omit=dev

COPY server.js ./

# Run as an unprivileged user (the Alpine node image comes with "node").
USER node

EXPOSE 3000
CMD ["node", "server.js"]
