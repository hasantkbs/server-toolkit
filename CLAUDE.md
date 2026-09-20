# server-toolkit

Bash tabanlı, read-only sunucu tanılama araç seti.

## Devam etme talimatı

Kullanıcı bir terminal oturumunda **"terminal"** dediğinde, bu projeden
(`/home/<user>/server-toolkit`) kaldığımız yerden devam edilecek.

## Durum (Sprint 13 sonu)

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

406/407 test PASS. Tüm komutlar read-only, destructive command yok,
server-specific hardcoding yok. Bilinen 1 hata: "info v2 mocked scenarios"
bölümündeki "healthy mocked system" testi, gerçek host swap kullanımı
%10 eşiğini geçtiğinde başarısız olur (bu test RAM/swap/disk'i mock'lamıyor,
gerçek `/proc` verisini okuyor) — Sprint 13'ten bağımsız, önceden var olan
bir ortam bağımlılığı, kod hatası değil. `free -m` ile swap kontrol edip
gerekirse bu testin mock kapsamını genişletmek ayrı bir iş.

## Mimari

- `bin/*-info`: her biri bağımsız, çalıştırılabilir komut.
- `lib/*.sh`: `bin/` script'leri tarafından source edilen paylaşılan helper'lar
  (`common.sh` her yerde kullanılır; diğerleri kendi alanına özgü).
- `tests/test.sh`: tek dosyalık test suite, mock/stub kullanır, gerçek sunucu
  state'ine bağımlı değildir.
- `docs/config.md`: opsiyonel configuration engine'in format/kullanım referansı.
- `docs/modules.md`: opsiyonel custom module sisteminin format/güvenlik referansı.
- `docs/cli.md`: `bin/server-toolkit` dispatcher'ının komut/güvenlik referansı.

## Henüz yapılmadı

- TUI
- Plugin sistemi
- Proje adı değişikliği / GitHub dosyaları

Bunlar diagnostic modüller tamamlandıktan sonra ayrı sprint'lerde ele alınacak.
