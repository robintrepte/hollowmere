FROM node:22-alpine
WORKDIR /app
COPY package.json server.mjs ./
EXPOSE 8787
HEALTHCHECK --interval=10s --timeout=3s --retries=8 CMD wget -qO- http://127.0.0.1:8787/health || exit 1
CMD ["node", "server.mjs"]
