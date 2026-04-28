# Hyperledger Fabric — 2 Org / 3 Orderer Network

Mạng Fabric cục bộ với 2 tổ chức (Org1, Org2), 3 orderer Raft, 4 peer và CouchDB.

---

## Yêu cầu

| Công cụ | Phiên bản tối thiểu |
|---------|---------------------|
| Docker | 24+ |
| Docker Compose plugin | v2 |
| bash | 5+ |
| curl, jq | tuỳ chọn (dùng trong health-check) |

> **Không cần** cài Fabric binary trên host — mọi lệnh Fabric chạy qua container (MODE B).  
> Nếu muốn dùng binary host (MODE A), xem phần [Cài binary host](#cài-binary-host-mode-a).

---

## Khởi động nhanh (one command)

```bash
# Clone repo và vào thư mục code
cd /path/to/your/code

# Chạy toàn bộ pipeline (CA → enroll → network → channel)
./scripts/run-network.sh
```

Script sẽ tự động:
1. Kiểm tra file cấu hình và tạo `.env.network` mặc định nếu chưa có
2. Khởi động CA stack (ca_org1, ca_org2, ca_orderer)
3. Enroll danh tính cho Org1, Org2, Orderer
4. Validate cấu hình (configtx + compose syntax)
5. Khởi động orderer + peer + CouchDB
6. Tạo channel `mychannel` và join tất cả peer
7. Smoke test kiểm tra channel trên orderer

```bash
# Kết thúc thành công:
Channel:     mychannel
Healthcheck: ./scripts/health-check.sh
Tear down:   ./scripts/clean-reset.sh --all --yes
```

---

## Tùy chọn run-network.sh

```bash
./scripts/run-network.sh                    # full pipeline (mặc định)
./scripts/run-network.sh --skip-enroll      # bỏ qua enroll (đã enroll trước rồi)
./scripts/run-network.sh --skip-channel     # chỉ start container, không tạo channel
./scripts/run-network.sh --reset            # clean toàn bộ rồi chạy lại từ đầu
./scripts/run-network.sh --no-smoke         # bỏ smoke test cuối
```

**Biến môi trường:**

```bash
CHANNEL_NAME=mychannel        # tên channel (default: mychannel)
FABRIC_CA_TAG=1.5.8           # image tag fabric-ca
FABRIC_TOOLS_TAG=2.5          # image tag fabric-tools
```

---

## Kiểm tra sức khoẻ mạng

```bash
./scripts/health-check.sh           # kiểm tra toàn diện
./scripts/health-check.sh --quick   # bỏ qua channel/peer probe
./scripts/health-check.sh --no-color
```

Script kiểm tra theo thứ tự:
- Prerequisites (docker, bash, jq, curl)
- File cấu hình và thư mục MSP/TLS
- Trạng thái và health của từng container
- Port đang lắng nghe trên host
- CouchDB reachable qua HTTP
- Channel có trên orderer (osnadmin)
- Từng peer đã join channel

---

## Dừng và khởi động lại

```bash
# Dừng (giữ nguyên ledger volume — khởi động lại nhanh)
./scripts/stop-network.sh

# Khởi động lại nhanh sau khi stop
./scripts/run-network.sh --skip-enroll

# Dừng và xoá cả volume ledger
./scripts/stop-network.sh --with-volumes --yes

# Dừng và xoá toàn bộ (volume + channel artifacts + MSP/TLS)
./scripts/stop-network.sh --all --yes
```

---

## Reset hoàn toàn

```bash
# Dọn sạch hoàn toàn: stack + volume + artifacts + organizations/ MSP/TLS
./scripts/clean-reset.sh --all --yes

# Chỉ xem sẽ làm gì, không thực thi
./scripts/clean-reset.sh --all --dry-run
```

Các flag của `clean-reset.sh`:

| Flag | Xoá gì |
|------|---------|
| `--with-volumes` | Docker named volumes (ledger orderer/peer) |
| `--with-artifacts` | `channel-artifacts/*.block`, `*.tx`, `anchor-updates/` |
| `--with-orgs` | `organizations/` — MSP/TLS certs + CA database (root-owned, dùng Docker busybox) |
| `--all` | Tất cả 3 ở trên |

> **Lưu ý:** Files trong `organizations/` và `channel-artifacts/` được tạo bên trong container Docker nên thuộc sở hữu root. Script tự động dùng Docker busybox để xóa, không cần `sudo`.

Sau khi reset, chạy lại:

```bash
./scripts/run-network.sh
```

---

## Cài binary host (MODE A)

Nếu muốn chạy lệnh Fabric trực tiếp trên host thay vì qua container:

```bash
# Cài binary vào .tools/bin
./scripts/install-binaries.sh

# Thêm vào PATH
export PATH="$(pwd)/.tools/bin:$PATH"
export FABRIC_CFG_PATH="$(pwd)/config"

# Kiểm tra
peer version
configtxgen --version
fabric-ca-client version
```

Tuỳ chọn:

```bash
./scripts/install-binaries.sh --check   # chỉ kiểm tra, không tải
./scripts/install-binaries.sh --force   # tải lại dù đã có archive
```

Biến môi trường:

```bash
FABRIC_VERSION=2.5.12       # mặc định
FABRIC_CA_VERSION=1.5.15    # mặc định
INSTALL_ROOT=./.tools       # thư mục cài đặt
```

---

## Backup ledger

```bash
# Tạo backup volume orderer/peer vào ./backups/
./scripts/backup-ledger.sh

# Backup theo thời gian: backups/fabric-volumes-YYYYMMDD-HHMMSS.tar.gz
BACKUP_DIR=/mnt/nas ./scripts/backup-ledger.sh
```

---

## Cấu trúc dự án

```
.
├── config/
│   ├── configtx.yaml               # channel & organization policy
│   ├── core.yaml                   # peer core config
│   ├── docker-compose-ca.yaml      # CA stack
│   ├── docker-compose-network.yaml # orderer + peer + couchdb
│   └── .env.network                # runtime env (tự tạo nếu chưa có)
├── organizations/
│   ├── peerOrganizations/          # MSP/TLS org1 + org2 (sinh sau enroll)
│   └── ordererOrganizations/       # MSP/TLS orderer (sinh sau enroll)
├── channel-artifacts/              # genesis block + anchor tx (sinh sau setup)
├── scripts/
│   ├── run-network.sh              # orchestrator chính
│   ├── health-check.sh             # kiểm tra sức khoẻ
│   ├── stop-network.sh             # dừng mạng
│   ├── clean-reset.sh              # reset hoàn toàn
│   ├── install-binaries.sh         # cài Fabric binary host
│   ├── enroll-org.sh               # enroll MSP/TLS từng org
│   ├── setup_channel.sh            # tạo + join channel + anchor peers
│   ├── validate-stack.sh           # kiểm tra syntax config
│   ├── update-anchor-peers.sh      # cập nhật anchor peer
│   └── backup-ledger.sh            # backup volume Docker
└── docs/
    ├── 01-tong-quan-kien-truc.md
    ├── 02-quy-trinh-trien-khai.md
    └── 03-van-hanh-su-co-va-test.md
```

---

## Port mapping

| Port | Dịch vụ |
|------|---------|
| 7054 | ca_org1 |
| 8054 | ca_org2 |
| 9054 | ca_orderer |
| 7050 | orderer1 (gRPC) |
| 8050 | orderer2 (gRPC) |
| 9050 | orderer3 (gRPC) |
| 9443 | orderer1 (admin REST) |
| 10443 | orderer2 (admin REST) |
| 11443 | orderer3 (admin REST) |
| 7051 | peer0.org1 |
| 8051 | peer1.org1 |
| 9051 | peer0.org2 |
| 10051 | peer1.org2 |
| 5984 | couchdb0.org1 |
| 6984 | couchdb1.org1 |
| 7984 | couchdb0.org2 |
| 8984 | couchdb1.org2 |

---

## Troubleshooting nhanh

| Triệu chứng | Lệnh kiểm tra |
|-------------|---------------|
| `Permission denied` khi chạy script | `chmod +x scripts/*.sh` rồi thử lại |
| CA không lên | `docker compose -f config/docker-compose-ca.yaml logs -f` |
| Enroll lỗi TLS | `ls organizations/fabric-ca/*/tls-cert.pem` |
| Peer/orderer unhealthy | `docker compose --env-file config/.env.network -f config/docker-compose-network.yaml logs -f` |
| Channel chưa tạo | `./scripts/health-check.sh` → xem mục Channel/Peer |
| Port conflict | `ss -tln \| grep <port>` |
| Permission Docker | `sudo usermod -aG docker $USER && newgrp docker` |

Docs chi tiết: [`docs/03-van-hanh-su-co-va-test.md`](docs/03-van-hanh-su-co-va-test.md)
