FROM teddysun/xray:latest AS xray-source
FROM cloudflare/cloudflared:latest AS cf-source

FROM alpine:latest
RUN apk add --no-cache bash curl busybox-extras unzip jq

COPY --from=xray-source /usr/bin/xray /usr/bin/xray
COPY --from=cf-source /usr/local/bin/cloudflared /usr/local/bin/cloudflared

WORKDIR /app
COPY . .

RUN sed -i 's/\r$//' /app/start.sh
RUN chmod +x /app/start.sh
ENTRYPOINT ["/app/start.sh"]
