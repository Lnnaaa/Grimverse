# Grimverse

Kumpulan script Lua untuk Roblox, dijalankan lewat executor menggunakan `loadstring`.

## Daftar Script

### ViolenceDistrict.lua
```lua
https://raw.githubusercontent.com/Lnnaaa/Grimverse/refs/heads/main/ViolenceDistrict.lua
```
> **TODO:** isi deskripsi di sini — game apa, fitur apa saja, ada UI atau tidak, dependency khusus (kalau ada).

- Game: `<isi nama game>`
- Fitur:
  - `<fitur 1>`
  - `<fitur 2>`

### Freecam.lua
```lua
https://raw.githubusercontent.com/Lnnaaa/Grimverse/refs/heads/main/Freecam.lua
```
Cinematic free camera standalone untuk spectating dan keperluan video, tanpa dependency eksternal.

- Game: universal (tidak terikat game tertentu)
- Fitur:
  - Toggle kamera bebas dengan **Shift+L**, **F**, atau **DPadLeft** (gamepad)
  - Kontrol gerak kamera: keyboard (WASD/HJKL-style), mouse pan, scroll untuk FOV, gamepad thumbstick/trigger
  - Tilt/roll kamera dengan **Z/C** atau bumper gamepad, double-tap untuk reset tilt
  - Depth of Field manual via **Backslash** untuk toggle, **+/-** dan **Shift/Ctrl** untuk atur intensitas/fokus
  - Kontrol kecepatan navigasi, FOV, dan smoothness spring secara real-time (bracket keys, semicolon/quote, dll — lihat source untuk binding lengkap)
  - Otomatis menyembunyikan semua GUI (CoreGui + ScreenGui custom) saat aktif, dan mengembalikannya saat freecam dimatikan
  - Kill-switch internal: kalau script dijalankan ulang (re-`loadstring`), instance lama otomatis di-shutdown bersih (unbind semua koneksi/render step) sebelum instance baru jalan, mencegah dua Freecam aktif bersamaan

---

## Catatan

- Semua script ini dijalankan client-side via executor, bukan dimaksudkan untuk dipasang langsung sebagai LocalScript di Roblox Studio tanpa modifikasi (terutama soal asumsi environment seperti variabel `script`).
- Pastikan domain `raw.githubusercontent.com` tidak diblok oleh whitelist HTTP executor kamu.
