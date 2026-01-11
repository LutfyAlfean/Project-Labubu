# Dokumentasi Otomatis dan Monitoring (Labubu)
Dokumen ini merangkum setup **HAProxy (failover)** + **Nginx Proxy Manager (SSL + reverse proxy)** + **Uptime Kuma (monitoring + status page)** berbasis **Docker Compose** pada **1 VPS Ubuntu**.

> Contoh domain: `labubu.my.id` dan IP VPS: `167.71.221.147`.

---

## 1) Prasyarat
- VPS Ubuntu dengan akses `root` / user sudo.
- Docker & Docker Compose plugin terinstall.
- Domain sudah pointing ke IP VPS.
- Port terbuka di firewall/security group:
  - `80/tcp`, `443/tcp` untuk website + SSL
  - `81/tcp` untuk panel Nginx Proxy Manager
  - (opsional) `3001/tcp` untuk debug akses langsung Uptime Kuma
  - (opsional) `8404/tcp` bila ingin expose HAProxy stats langsung (lebih aman lewat NPM)

### Install Docker (jika belum)
```bash
curl -fsSL https://get.docker.com | sh
systemctl enable --now docker
docker --version
docker compose version
```

### Buka port UFW (jika pakai UFW)
```bash
ufw allow 80/tcp
ufw allow 443/tcp
ufw allow 81/tcp
# opsional:
ufw allow 3001/tcp
ufw reload
ufw status
```

---

## 2) DNS (WAJIB agar SSL sukses)
Di DNS provider (mis. IDWebhost), pastikan record A mengarah ke IP VPS:

- `labubu.my.id`  → `ip_vps`
- `status.labubu.my.id` → `ip_vps`
- `haproxy.labubu.my.id` → `ip_vps`

Verifikasi propagasi:
```bash
apt update && apt install -y dnsutils
dig @1.1.1.1 +short labubu.my.id A
dig @1.1.1.1 +short status.labubu.my.id A
dig @1.1.1.1 +short haproxy.labubu.my.id A
```
Output harus IP VPS.

---

## 3) Kondisi Web App (existing containers)
Contoh kondisi app kamu (dua container):
- `labubu-app1` publish ke host port `7903`
- `labubu-app2` publish ke host port `7904`

Cek:
```bash
docker ps --format "table {{.Names}}\t{{.Ports}}\t{{.Status}}"
curl -I http://127.0.0.1:7903
curl -I http://127.0.0.1:7904
```

---

## 4) Struktur Folder Project
Semua service infra disimpan di:
- `/opt/labubu/`

Buat folder:
```bash
sudo mkdir -p /opt/labubu/{haproxy,npm,mysql,kuma}
cd /opt/labubu
```

---

## 5) HAProxy (Failover Web1 → Web2 + Stats)
### 5.1 Config HAProxy
Buat file:
`/opt/labubu/haproxy/haproxy.cfg`
```cfg
global
  log stdout format raw local0
  maxconn 4000

defaults
  log global
  mode http
  option httplog
  option dontlognull
  timeout connect 5s
  timeout client  60s
  timeout server  60s

frontend fe_http
  bind :8080
  default_backend be_apps

backend be_apps
  balance roundrobin

  # health check (ubah ke /health kalau ada)
  option httpchk GET /
  http-check expect status 200

  # 3 server aktif (load balance)
  server app1 host.docker.internal:7903 check inter 2s fall 2 rise 2
  server app2 host.docker.internal:7904 check inter 2s fall 2 rise 2
  server app3 host.docker.internal:7905 check inter 2s fall 2 rise 2

  # 1 server backup (dipakai kalau semua primary down)
  server app4 host.docker.internal:7906 check inter 2s fall 2 rise 2 backup

# (opsional) HAProxy stats
listen stats
  bind :8404
  mode http
  stats enable
  stats uri /stats
  stats refresh 5s
  stats realm HAProxy\ Stats
  stats auth admin:PasswordKuatGantiIni

```

> Jika aplikasi tidak 200 di `/`, ganti `GET /` menjadi endpoint health mis. `GET /health`.

---

## 6) Docker Compose (NPM + DB + HAProxy + Kuma)
Buat file:
`/opt/labubu/docker-compose.yml`

```yaml
services:
  npm-db:
    image: jc21/mariadb-aria:latest
    container_name: npm-db
    restart: unless-stopped
    environment:
      MYSQL_ROOT_PASSWORD: "npm_root_ChangeThis!"
      MYSQL_DATABASE: "npm"
      MYSQL_USER: "npm"
      MYSQL_PASSWORD: "npm_ChangeThis!"
      MARIADB_AUTO_UPGRADE: "1"
    volumes:
      - ./mysql:/var/lib/mysql
    networks:
      - labubu-net

  nginx-proxy-manager:
    image: jc21/nginx-proxy-manager:latest
    container_name: nginx-proxy-manager
    restart: unless-stopped
    depends_on:
      - npm-db
    ports:
      - "80:80"
      - "443:443"
      - "81:81"
    environment:
      TZ: Asia/Jakarta
      DB_MYSQL_HOST: npm-db
      DB_MYSQL_PORT: 3306
      DB_MYSQL_USER: npm
      DB_MYSQL_PASSWORD: "npm_ChangeThis!"
      DB_MYSQL_NAME: npm
    volumes:
      - ./npm/data:/data
      - ./npm/letsencrypt:/etc/letsencrypt
    networks:
      - labubu-net

  haproxy:
    image: haproxy:2.9
    container_name: labubu-haproxy
    restart: unless-stopped
    ports:
      - "8080:8080"
      - "8404:8404"   # opsional publish stats (lebih aman via NPM)
    volumes:
      - ./haproxy/haproxy.cfg:/usr/local/etc/haproxy/haproxy.cfg:ro
    extra_hosts:
      - "host.docker.internal:host-gateway"
    networks:
      - labubu-net

  uptime-kuma:
    image: louislam/uptime-kuma:1
    container_name: uptime-kuma
    restart: unless-stopped
    volumes:
      - ./kuma/data:/app/data
    networks:
      - labubu-net
    # opsional publish untuk debug akses langsung
    ports:
      - "3001:3001"
    extra_hosts:
      - "host.docker.internal:host-gateway"

networks:
  labubu-net:
    name: labubu-net
```

Naikkan service:
```bash
cd /opt/labubu
docker compose up -d
docker ps --format "table {{.Names}}\t{{.Ports}}\t{{.Status}}"
```

Test lokal:
```bash
curl -I http://127.0.0.1:8080
curl -I http://127.0.0.1:3001
curl -I http://127.0.0.1:8404/stats
```

---

## 7) Setup Nginx Proxy Manager (Reverse Proxy + SSL)
Buka panel:
- `http://IP_VPS:81`

### 7.1 Buat Proxy Host: `labubu.my.id` (ke HAProxy)
NPM → **Hosts → Proxy Hosts → Add Proxy Host**
- Domain Names: `labubu.my.id`
- Scheme: `http`
- Forward Hostname / IP: `labubu-haproxy`
- Forward Port: `8080`
- (opsional) Websockets Support

Tab **SSL**:
- Request a new SSL Certificate
- Force SSL
- HTTP/2 Support
- Agree TOS
- Save

### 7.2 Proxy Host Kuma: `status.labubu.my.id`
- Domain: `status.labubu.my.id`
- Forward Hostname: `uptime-kuma`
- Forward Port: `3001`
- SSL: Request cert + Force SSL

### 7.3 Proxy Host HAProxy stats: `haproxy.labubu.my.id`
- Domain: `haproxy.labubu.my.id`
- Forward Hostname: `labubu-haproxy`
- Forward Port: `8404`
- SSL: Request cert + Force SSL

Akses stats:
- `https://haproxy.labubu.my.id/stats`

---

## 8) Auth untuk HAProxy Stats (pilih salah satu)
### Opsi A (Auth dari HAProxy)
Gunakan:
```cfg
stats auth admin:PasswordKuatGantiIni
```
Login user `admin` + password tersebut.

### Opsi B (lebih rapi): Auth dari NPM (Access List)
1) NPM → **Access Lists** → **Add Access List**
2) Tab **Authorizations**: pilih Basic Auth, buat user/pass
3) Apply Access List ke Proxy Host `haproxy.labubu.my.id`

Jika pakai Opsi B, hapus `stats auth ...` di HAProxy agar tidak double login.

---

## 9) Setup Uptime Kuma (Monitoring + Notifikasi + Status Page)
Akses:
- `https://status.labubu.my.id`

### 9.1 Monitor yang disarankan
Buat monitor (Add New Monitor):
1) **Labubu Web (Main)** → HTTP(s) → `https://labubu.my.id`
2) **HAProxy Frontend (internal)** → HTTP(s) → `http://labubu-haproxy:8080/`
3) **App1** → HTTP(s) → `http://host.docker.internal:7903/` (atau TCP 7903)
4) **App2** → HTTP(s) → `http://host.docker.internal:7904/` (atau TCP 7904)
5) **NPM Admin** (opsional) → HTTP(s) → `http://nginx-proxy-manager:81/`

### 9.2 Status Page
Kuma → Status Pages → New Status Page
- Name: `Labubu Status`
- Slug: `labubu`
URL contoh:
- `https://status.labubu.my.id/status/labubu`

---

## 10) Troubleshooting Cepat
### SSL subdomain gagal
Pastikan DNS subdomain resolve benar:
```bash
dig @1.1.1.1 +short status.labubu.my.id A
dig @1.1.1.1 +short haproxy.labubu.my.id A
```
Ambil log NPM:
```bash
docker logs nginx-proxy-manager --since 60m | tail -n 200
```

### HAProxy 503/Bad gateway
```bash
curl -I http://127.0.0.1:7903
curl -I http://127.0.0.1:7904
docker logs labubu-haproxy --tail 200
```

---

## 11) Perintah Operasional
Restart semua:
```bash
cd /opt/labubu
docker compose restart
```

Update image:
```bash
cd /opt/labubu
docker compose pull
docker compose up -d
```

Lihat log:
```bash
cd /opt/labubu
docker compose logs -f --tail 200
```
