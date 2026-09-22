# server-toolkit

Bash tabanlı, read-only sunucu tanılama araç seti.

## Devam etme talimatı

Kullanıcı bir terminal oturumunda **"terminal"** dediğinde, bu projeden
(`/home/<user>/server-toolkit`) kaldığımız yerden devam edilecek.

## Durum (Sprint 15 sonu)

- Sprint 1: `info` + `gpu-info`
- Sprint 2: `docker-info`
- Sprint 3: `network-info`
- Sprint 4: `storage-info`
- Sprint 5: `services-info`
- Sprint 6: `security-info`
- Sprint 7: `process-info`
- Sprint 8: `logs-info`
- Sprint 9: `backup-info`
- Sprint 10: `info` v2 (hızlı dashboard) + `lib/status.sh` (ortak status/alert contract)
- Sprint 11: configuration engine (`lib/config.sh`, opsiyonel `~/.config/server-toolkit/config` — bkz. `docs/config.md`), `info`'nin RAM_ALERT_PCT eşiği bu engine'e bağlandı.
- Sprint 12: custom module system (`lib/modules.sh`, opsiyonel `~/.config/server-toolkit/modules/` — bkz. `docs/modules.md`), `info`'ye `CUSTOM_MODULES_ENABLED` ile aç/kapa özel modül desteği eklendi.
- Sprint 13: CLI dispatcher (`bin/server-toolkit` — `server-toolkit info`, `gpu`, `docker`, ... ve `modules`/`config`/`version`/`help` — bkz. `docs/cli.md`), eski bağımsız komutlar (`info`, `gpu-info`, ...) değişmeden çalışmaya devam ediyor.
- Sprint 14: terminal dashboard (`bin/server-toolkit tui` / `bin/tui` — canlı yenilenen, klavye kontrollü panel; TUI_ONCE=1 ile non-interactive render — bkz. `docs/tui.md`), aynı diagnostic core'u (`lib/*.sh`, `lib/status.sh`, `lib/modules.sh`) yeniden kullanıyor, hiçbir tanılama mantığı tekrar yazılmadı.
- Sprint 15: user-level install/update/uninstall sistemi (`install.sh` — repo kökünde; `bash install.sh install|update|uninstall` — bkz. `docs/install.md`). Whole-tree copy + fixed-path wrapper: `bin/+lib/+docs`, `${XDG_DATA_HOME:-~/.local/share}/server-toolkit-<version>/` içine kopyalanıyor, stabil bir symlink (`.../server-toolkit`) güncel versiyona işaret ediyor, `${TOOLKIT_BIN_DIR:-~/.local/bin}/server-toolkit` sabit-yollu bir wrapper. Update tek bir atomik `ln -sfn` ile versiyon değiştiriyor. Her silme işlemi `.server-toolkit-install` marker dosyasıyla doğrulanıyor. `~/.bashrc`/`~/.zshrc`/`~/.profile` sadece açıkça `--add-to-path` verilirse değişiyor. Config her zaman korunuyor, sadece `uninstall --purge-config` siliyor. Hiçbir `bin/*`/`lib/*.sh` dosyası değiştirilmedi — sadece kopyalanıyor.

tests/test.sh: 501/501, tests/test-install.sh: 23/23 (yeni, izole
HOME/PATH testleri — bkz. `tests/test-install.sh`). Tüm komutlar
read-only, destructive command yok, server-specific hardcoding yok.
Bilinen hata kalmadı.

## Mimari

- `bin/*-info`: her biri bağımsız, çalıştırılabilir komut.
- `lib/*.sh`: `bin/` script'leri tarafından source edilen paylaşılan helper'lar
  (`common.sh` her yerde kullanılır; diğerleri kendi alanına özgü).
- `tests/test.sh`: tek dosyalık test suite, mock/stub kullanır, gerçek sunucu
  state'ine bağımlı değildir.
- `docs/config.md`: opsiyonel configuration engine'in format/kullanım referansı.
- `docs/modules.md`: opsiyonel custom module sisteminin format/güvenlik referansı.
- `docs/cli.md`: `bin/server-toolkit` dispatcher'ının komut/güvenlik referansı.
- `docs/tui.md`: terminal dashboard'ının kontrol/güvenlik referansı.
- `docs/install.md`: install/update/uninstall sisteminin kurulum/PATH/config referansı.

## Henüz yapılmadı

- Plugin sistemi
- Proje adı değişikliği / GitHub dosyaları

Bunlar diagnostic modüller tamamlandıktan sonra ayrı sprint'lerde ele alınacak.
