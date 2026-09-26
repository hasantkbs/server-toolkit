# server-toolkit

Bash tabanlı, read-only sunucu tanılama araç seti.

## Devam etme talimatı

Kullanıcı bir terminal oturumunda **"terminal"** dediğinde, bu projeden
(server-toolkit reposundan) kaldığımız yerden devam edilecek.

## Durum (Sprint 17 Phase 3 sonu)

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
- Sprint 16: public release metadata (`README.md`, `LICENSE` — MIT) eklendi.
- Sprint 17 (privacy/release hazırlığı, 3 faz):
  - Phase 1: read-only audit — internal AI-agent sprint-planning dokümanlarının (`docs/superpowers/plans/`) gerçek kullanıcı adı/home path/iki internal kod adı içerdiğini, `.gitignore`'ın `.claude/`'ı korumadığını, ve dört öncelikli güvenlik bulgusunu tespit etti.
  - Phase 2: Phase 1'in 4 öncelikli güvenlik bulgusu düzeltildi — `storage-info` RCE-şekilli bug, installer wrapper injection, `purge-config` over-broad deletion, CLI/TUI hang riski. Hepsi regresyon testiyle doğrulandı.
  - Phase 3 (bu commit'ler): `docs/superpowers/plans/` git tracking'den çıkarıldı (diskte duruyor, sadece gelecekte commit edilmeyecek — geçmiş commit'lerde hâlâ mevcut, bkz. aşağıdaki "Bilinen durum"), `.gitignore`'a `.claude/` ve `docs/superpowers/` eklendi, `tests/test.sh`'ın kendi privacy-scan canary'si gerçek kullanıcı adını/kod adlarını literal grep pattern'i olarak taşıyordu — artık `$(whoami)` ile runtime'da türetiliyor. README/docs'taki abartılı "hiçbir şeyi değiştirmez" iddiası somutlaştırıldı (installer + opt-in custom-modules istisnaları adlandırıldı), `network-info`'nun tek gerçek dış prob'u (1.1.1.1 ping) adlandırıldı, `bin/tui`'nin ayrı `TOOLKIT_TUI_VERSION` sabiti kaldırıldı — artık `bin/server-toolkit`'in tek `TOOLKIT_VERSION`'ını `lib/common.sh::toolkit_version()` üzerinden okuyor. `tests/test.sh`'a `TEST_TMP_ROOT` (mktemp -d + EXIT trap) eklendi, 437 `/tmp/toolkit_test_*` yolu ve tüm `*-pwned` güvenlik canary'leri buna taşındı. `install.sh` artık +x (diğer her entry point gibi). `SECURITY.md`, `CHANGELOG.md`, `.github/workflows/ci.yml` eklendi.

tests/test.sh: 526/526, tests/test-install.sh: 37/37. Tüm komutlar
read-only, destructive command yok, server-specific hardcoding yok.

Bilinen durum (abartısız): git geçmişinde (yaklaşık son commit'ten önceki
~50 commit) gerçek kullanıcı adı/home path hâlâ recoverable — bu bilinçli
olarak bu fazda rewrite edilmedi (history rewrite = ayrı, deferred karar;
gerekirse `git filter-repo` ile ilk public push'tan önce, remote henüz
yokken). `tests/test.sh`'daki tüm sabit (predictable) `/tmp/...` yolları
`TEST_TMP_ROOT` altına taşındı; kalan ~60 `mktemp -d` çağrısı zaten
argümansız (rastgele, öngörülemez isim) olduğu için ek risk taşımıyor,
migrate edilmedi.

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
- `SECURITY.md`: güvenlik açığı bildirme prosedürü.
- `CHANGELOG.md`: public-facing sprint milestone özeti.
- `.github/workflows/ci.yml`: push/PR'da `tests/test.sh` + `tests/test-install.sh` + `shellcheck -S warning` çalıştırır.

## Henüz yapılmadı

- Plugin sistemi
- Proje adı değişikliği
- Git geçmişinin sanitize edilmesi (deferred karar — bkz. yukarıdaki "Bilinen durum")

Bunlar diagnostic modüller tamamlandıktan sonra ayrı sprint'lerde ele alınacak.
