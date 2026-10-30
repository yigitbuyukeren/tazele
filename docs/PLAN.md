# Tazele: plan

## Fikir
Tek native arayüzde sistem, App Store, Homebrew, Sparkle uygulamaları ve geliştirici araçları için "neler eski" listesi ve tek tuşla güncelleme. Önizleme, tek tek seçim ve canlı log var.

## İlke
Tazele dosya kurmaz, mevcut araçları yönetir (`brew`, `mas`, `npm`, uygulamaların kendi güncelleyicisi). Arka planda yalnızca kontrol eder; kurulum kullanıcı tıklayınca yapılır. Açık kaynak ve ücretsiz.

## Neden
MacUpdater geliştirmeyi bıraktı (sunucu desteği 2026-12-31'e kadar). Topgrade yalnızca komut satırı, Latest yalnızca App Store ve Sparkle, Cork ve Applite yalnızca Homebrew.

## Aşamalar
1. **MVP:** menü çubuğu listesi, tek tek ve "hepsini güncelle", canlı log. Kaynaklar: Homebrew (formül, cask, greedy anahtarı), `mas`, npm, pipx/uv, rustup, Oh-My-Zsh. macOS sistem güncellemeleri yalnızca listelenir, kurulum için Sistem Ayarları açılır.
2. Sparkle uygulama tespiti (`SUFeedURL` + appcast), gem/go/cargo, yoksay ve sabitle, bildirimler.
3. Ayrıcalıklı yardımcı süreç, kendi sürüm veritabanı.

## Teknik
- SwiftPM, Swift 6, SwiftUI + AppKit, macOS 15+. Sandbox dışı; Developer ID ile imza ve notarization.
- `Process` + `Pipe` → `AsyncStream`, iptalde `terminate()`; çalıştırıcı bir `actor`, arayüz `@MainActor`.
- `PATH` açıkça ayarlanır (`/opt/homebrew/bin`, nvm/asdf/mise); `HOMEBREW_NO_AUTO_UPDATE`, `NONINTERACTIVE=1`, `CI=1`. Brew gibi kilitli araçlar sırayla çalışır.
- Kontrol: `brew outdated --json=v2`, `mas outdated`, `npm outdated -g --json`, `pipx list --json`, `uv tool list`, `rustup check`, `softwareupdate -l`.
- Giriş öğesi `SMAppService.mainApp`; kontroller `NSBackgroundActivityScheduler` ile.

## Riskler
Kullanıcının Node/Python ortamını bozmak, cask `auto_updates` çakışması, `softwareupdate` metin çıktısı ayrıştırma, `mas` davranış değişikliği.

## Doğrulanacaklar
Komut bayrakları (`softwareupdate`, `brew`, `pipx`, `uv`, `npm`) ve `SMAppService` davranışı macOS 26/27'de elle denenmeli.

## Durum (30 Ekim 2026)
Yapıldı: Homebrew (formül, cask, kendi güncelleyen cask), App Store (`mas`, sudo parola penceresi), npm, rustup, RubyGems (sistem Ruby'si hariç), pipx/uv (PyPI), Oh My Zsh, Sparkle uygulamaları (appcast + Homebrew cask yedeği), macOS güncellemeleri (yeniden başlatma istemeyenler kurulabilir, diğerleri Sistem Ayarları). Arama, yoksay/sabitle, ayarlar (otomatik kontrol, bildirim, Dock rozeti, oturum açılışı), TR/EN arayüz.

Yapılmadı: Sparkle uygulamalarını Tazele'nin kendisinin kurması (imza doğrulamalı), Developer ID imzası ve notarization, adresi okunamayan `.pkg` ile kurulan uygulamalar (WARP, Tailscale), Touch ID ile yetkilendirme.
