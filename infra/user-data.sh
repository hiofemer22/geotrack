#!/bin/bash
# Arranque inicial de la instancia EC2 (Amazon Linux 2023).
# Instala Node.js 22 y Nginx, y deja listo el servicio systemd de GeoTrack.
set -euxo pipefail

dnf install -y nginx tar gzip
if dnf install -y nodejs22 nodejs22-npm; then
  alternatives --set node /usr/bin/node-22 || true
  [ -e /usr/bin/npm ] || ln -sf /usr/bin/npm-22 /usr/bin/npm
else
  dnf install -y nodejs npm
fi

useradd --system --home /opt/geotrack --shell /sbin/nologin geotrack || true
mkdir -p /opt/geotrack/app
chown -R geotrack:geotrack /opt/geotrack

cat >/etc/systemd/system/geotrack.service <<'EOF'
[Unit]
Description=GeoTrack API
After=network-online.target

[Service]
User=geotrack
WorkingDirectory=/opt/geotrack/app
EnvironmentFile=/opt/geotrack/app/.env
ExecStart=/usr/bin/node src/server.js
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

# Nginx como proxy inverso (HTTP + WebSockets de Socket.IO)
cat >/etc/nginx/conf.d/geotrack.conf <<'EOF'
map $http_upgrade $connection_upgrade { default upgrade; '' close; }
server {
  listen 80 default_server;
  server_name _;
  client_max_body_size 10m;
  location / {
    proxy_pass http://127.0.0.1:8080;
    proxy_http_version 1.1;
    proxy_set_header Upgrade $http_upgrade;
    proxy_set_header Connection $connection_upgrade;
    proxy_set_header Host $host;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_read_timeout 3600s;
  }
}
EOF

systemctl daemon-reload
systemctl enable --now nginx
systemctl enable geotrack
touch /opt/geotrack/ready
