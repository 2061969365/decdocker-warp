FROM cloudflare/cloudflared:latest AS cf-source

FROM alpine:latest
RUN apk add --no-cache bash curl busybox-extras unzip jq

RUN curl -sL -o /tmp/sb.tar.gz \
  "https://github.com/SagerNet/sing-box/releases/download/v1.11.6/sing-box-1.11.6-linux-amd64.tar.gz" && \
  tar -xzf /tmp/sb.tar.gz -C /tmp && \
  mv /tmp/sing-box-*/sing-box /usr/bin/sing-box && \
  rm -rf /tmp/sb.tar.gz /tmp/sing-box-*

COPY --from=cf-source /usr/local/bin/cloudflared /usr/local/bin/cloudflared

WORKDIR /app
COPY . .

RUN sed -i 's/\r$//' /app/start.sh
RUN chmod +x /app/start.sh
ENTRYPOINT ["/app/start.sh"]
