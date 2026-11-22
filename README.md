# dockerinstall

Script installer **Docker CE** yang canggih. Sebelum menginstal, skrip ini
**mendeteksi dan melaporkan spesifikasi serta sistem operasi** komputer yang
akan di-instal — hanya setelah laporan itu lolos pengecekan kompatibilitas pun
ierupis proses instalasi.

Ditulis untuk Linux. Windows dan macOS tidak didukung — gunakan **Docker
Desktop** di platform tersebut.

## Fitur

- **Deteksi penuh spesifikasi**: OS (ID, family, versi, codename), architektur,
  CPU (model & core), RAM, disk (total/free), kernel, init system, cgroup
  (v1/v2), virtualisasi, privileges, dan konektivitas repositori resmi.
- **Matriks kompatibilitas**: memvalidasi versi minimum OS, versi kernel, RAM,
  kapasitas disk, ketersediaan package manager, dan ketersediaan arsitektur —
  dengan status `ok` / `warn` / `error` untuk tiap bagian.
- **Mode dry-run** (`--dry-run`): menampilkan seluruh perintah yang akan
  dieksekusi tanpa mengubah apa pun di sistem.
- **Laporan JSON** (`--json`): keluaran machine-readable untuk otomasi/CI.
- **Mode ketat** (`--strict`): setiap peringatan membuat skrip berhenti
  (exit code 2) sebelum instalasi dimulai.
- **Mode non-interaktif** (`--yes`) untuk otomasi di lingkungan tanpa TTY.
- **Instalasi via repositori resmi Docker** (apt/dnf/zypper) atau **paket
  distro** (`--from-distro`), serta instalasi alpine/pacman lewat package
  manager bawaan.
- **Instal ulang / upgrade**: bila Docker sudah terpasang, skrip melaporkannya
  dan melanjutkan install ulang (refresh/upgrade).
- **Pembersihan**: `--uninstall` untuk menghapus Docker, dan `--purge` (dengan
  konfirmasi ganda) untuk juga menghapus `/var/lib/docker`.

## Persyaratan

- Linux dengan bash >= 4 (distro didukung: Ubuntu 20.04+, Debian 11+, RHEL 8/9,
  Rocky Linux, AlmaLinux, Oracle Linux, Amazon Linux 2/2023, Fedora, CentOS
  Stream 8/9, openSUSE Leap 15.x/Tumbleweed, SLES 15, Alpine 3.14+, Arch Linux /
  Manjaro / EndeavourOS).
- Root atau `sudo`.
- Koneksi internet ke repositori resmi Docker (untuk mode default) — diperiksa
  di tahap deteksi dan dilaporkan sebagai peringatan (bukan error) bila tidak
  dapat dijangkau.

## Cara pakai

```bash
chmod +x install-docker.sh

# 1) Cukup lihat laporan deteksi, tanpa mengubah apa pun:
./install-docker.sh --detect-only

# 2) Simulasi rencana instalasi (tidak ada yang diubah):
./install-docker.sh --dry-run --yes

# 3) Laporan JSON (berguna untuk CI/otomasi):
./install-docker.sh --json

# 4) Instal dengan konfirmasi (interaktif):
./install-docker.sh

# 5) Instal non-interaktif (CI/automation):
./install-docker.sh --yes

# 6) Instal via paket distro (mis. docker.io di Debian/Ubuntu):
./install-docker.sh --from-distro --yes

# 7) Mode ketat — gagal jika ada peringatan:
./install-docker.sh --strict --yes

# 8) Uninstall (tanpa menghapus data Docker):
./install-docker.sh --uninstall

# 9) Uninstall + hapus data Docker (hati-hati, tidak bisa dibatalkan):
./install-docker.sh --uninstall --purge --yes
```

### Opsi lain

| Opsi | Deskripsi |
| --- | --- |
| `--detect-only` | Cetak laporan deteksi dan keluar |
| `--dry-run` | Cetak rencana instalasi tanpa mengubah apa pun |
| `--json` | Cetak laporan deteksi dalam format JSON (butuh python3) |
| `--strict` | Setiap peringatan dianggap fatal (exit code 2) |
| `--yes` / `-y` | Lewati prompt konfirmasi (wajib untuk TTY-less) |
| `--no-service` | Jangan enable/start service Docker |
| `--from-distro` | Gunakan paket distro (apt: `docker.io`, dnf: `docker`) |
| `--codename <nama>` | Override codename repository apt (mis. `bookworm`) |
| `--skip-network-check` | Lewati pengecekan konektivitas repositori |
| `--use-convenience-script` | Fallback ke `get.docker.com` untuk OS/arsitektur tak dikenal |
| `--uninstall` | Hapus Docker |
| `--purge` | Bersama `--uninstall`: hapus `/var/lib/docker` juga |
| `--version` | Tampilkan versi skrip |
| `--help` | Tampilkan bantuan ini |

### Exit codes

| Kode | Arti |
| --- | --- |
| 0 | Sukses (atau laporan deteksi berhasil) |
| 1 | Deteksi gagal, konfigurasi tidak didukung, atau instalasi gagal |
| 2 | Mode `--strict`: ada peringatan, proses dibatalkan |

## Contoh keluaran deteksi

```
# install-docker.sh v1.0.0
────────────────────────────────────────────────────────────────────────

 Environment report
  ✔  ok   OS: Debian GNU/Linux 12 (bookworm) (ID: debian, family: apt)
  ✔  ok   Package manager: apt
  ✔  ok   Architecture: x86_64 (repo basearch: x86_64)
  ✔  ok   Kernel: 6.1.158+
  ✔  ok   CPU: Intel(R) Xeon(R) Processor @ 2.60GHz (2 core(s))
  ✔  ok   Memory: 3.8 GiB total (3.6 GiB available)
  ✔  ok   Disk: 19.3 GiB free on / (20.3 GiB total)
  ✔  ok   Init system: systemd
  ✔  ok   Cgroups: v2
  ✔  ok   Virtualization: kvm
  ✔  ok   Privilege: non-root (user) with sudo
  ⚠  warn Network: official repository unreachable — install may fail
  ✔  ok   Docker: not installed (fresh install)
────────────────────────────────────────────────────────────────────────
```

## Perhatian & catatan

- Skrip ini tidak menjalankan `docker` untuk dijalankan dengan root di luar
  instalasi. User saat ini ditambahkan ke group `docker` — **log out/in** agar
  keanggotaan group berlaku sebelum menggunakan Docker tanpa `sudo`.
- Mode default menginstall dari repositori resmi Docker (`download.docker.com`).
  Gunakan `--from-distro` jika Anda ingin paket yang disertakan distro
  (biasanya versi lebih lama, tapi lebih diuji di ekosistem distro).
- `--purge` menghapus **seluruh data** Docker di `/var/lib/docker`. Buat
  backup dulu. Di mode interaktif, ada **dua** prompt konfirmasi sebelum
  data dihapus.
- Skrip `--uninstall` tidak menghapus group `docker` atau daftar user yang
  masuk dalam group tersebut secara otomatis.
- Pada OS yang tidak didukung (atau fallback `--use-convenience-script`
  digunakan), perilaku pelayanan/sistem init tidak dijamin.
- Skrip ini **tidak** menginstal Docker Desktop (Windows/macOS) dan **tidak**
  mengaktifkan Docker sebagai daemon rootless secara default.
- Deteksi butuh menjalankan perintah kecil read-only (`uname`, `df`,
  `awk`, `nproc`) — tidak meng-install apa pun sebelum menampilkan laporan
  dan sebelum Anda mengonfirmasi (tergantung mode).

## Struktur proyek

```
.
├── install-docker.sh    # skrip utama: deteksi + instalasi + uninstall
└── README.md             # dokumentasi ini
```
