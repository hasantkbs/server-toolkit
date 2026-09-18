# server-toolkit

Bash tabanlı, read-only sunucu tanılama araç seti.

## Devam etme talimatı

Kullanıcı bir terminal oturumunda **"terminal"** dediğinde, bu projeden
(`/home/<user>/server-toolkit`) kaldığımız yerden devam edilecek.

## Durum (Sprint 10 sonu)

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

273/273 test PASS. Tüm komutlar read-only, destructive command yok,
server-specific hardcoding yok.

## Mimari

- `bin/*-info`: her biri bağımsız, çalıştırılabilir komut.
- `lib/*.sh`: `bin/` script'leri tarafından source edilen paylaşılan helper'lar
  (`common.sh` her yerde kullanılır; diğerleri kendi alanına özgü).
- `tests/test.sh`: tek dosyalık test suite, mock/stub kullanır, gerçek sunucu
  state'ine bağımlı değildir.

## Henüz yapılmadı

- Configuration engine (YAML/TOML/shell config formatı seçilmedi)
- TUI
- Plugin sistemi
- Proje adı değişikliği / GitHub dosyaları

Bunlar diagnostic modüller tamamlandıktan sonra ayrı sprint'lerde ele alınacak.
