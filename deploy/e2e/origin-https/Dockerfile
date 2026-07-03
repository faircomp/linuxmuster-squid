# HTTPS-Origin für den E2E (self-signed). Liefert 200 auf https://secure.example.internal/.
FROM nginx:alpine
RUN apk add --no-cache openssl \
 && openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
      -subj "/CN=secure.example.internal" \
      -keyout /etc/nginx/tls.key -out /etc/nginx/tls.crt 2>/dev/null \
 && printf 'server {\n  listen 443 ssl;\n  server_name secure.example.internal;\n  ssl_certificate /etc/nginx/tls.crt;\n  ssl_certificate_key /etc/nginx/tls.key;\n  location / { return 200 "ok"; }\n}\n' > /etc/nginx/conf.d/tls.conf
EXPOSE 443
