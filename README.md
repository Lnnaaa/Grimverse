# Grimverse Script

Kumpulan script Lua untuk Roblox, dijalankan lewat executor menggunakan `loadstring`.

## Daftar Script

### ViolenceDistrict.lua
```lua
https://raw.githubusercontent.com/Lnnaaa/Grimverse/refs/heads/main/ViolenceDistrict.lua
```
Violance Disctrict exploit script

- Game: **Violance District**
- Fitur:
  - **UI & Sistem**
    - Window draggable dengan 4 tab: Home, Player, Visuals, Configs
    - Toggle UI via keybind custom (default `T`, bisa di-rebind)
    - Notifikasi toast, cursor dot custom overlay
    - Save/load/set-default/delete config profile ke file JSON lokal
    - Self-cleanup otomatis saat script di-load ulang
  - **Tab Home**
    - Info akun (username, display name, UserId, account age, avatar)
    - Live display Team/Health/Speed
    - Prediksi "Next Killer" berdasarkan attribute game
  - **Tab Player**
    - Auto Skill Check
    - Speed Boost (toggle + value custom)
    - Override volume chase/heartbeat sound
  - **Tab Visuals**
    - Fullbright (override Lighting)
    - ESP Killer / Survivor / Generator
    - ESP Names (nametag + jarak), Gen Progress (persentase perbaikan)
    - Color picker custom (HSV slider) untuk 6 state: Killer, Survivor, Generator, Hooked, Knocked, Injured
  - **Tab Configs**
    - Toggle notifikasi
    - Manajemen profile config
    - Rebind menu keybind

### Freecam.lua
```lua
https://raw.githubusercontent.com/Lnnaaa/Grimverse/refs/heads/main/Freecam.lua
```
Cinematic free camera standalone untuk spectating dan keperluan video, tanpa dependency eksternal.

- Game: **All Map**
- Fitur:
  - Toggle kamera bebas dengan **Shift+L**, **F**, atau **DPadLeft** (gamepad)
  - Kontrol gerak kamera: keyboard (WASD/HJKL-style), mouse pan, scroll untuk FOV, gamepad thumbstick/trigger
  - Tilt/roll kamera dengan **Z/C** atau bumper gamepad, double-tap untuk reset tilt
  - Depth of Field manual via **Backslash** untuk toggle, **+/-** dan **Shift/Ctrl** untuk atur intensitas/fokus
  - Kontrol kecepatan navigasi, FOV, dan smoothness spring secara real-time (bracket keys, semicolon/quote, dll — lihat source untuk binding lengkap)
  - Otomatis menyembunyikan semua GUI (CoreGui + ScreenGui custom) saat aktif, dan mengembalikannya saat freecam dimatikan
  - Kill-switch internal: kalau script dijalankan ulang (re-`loadstring`), instance lama otomatis di-shutdown bersih (unbind semua koneksi/render step) sebelum instance baru jalan, mencegah dua Freecam aktif bersamaan

---
