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
Yapıldı: Homebrew (formül, cask, kendi güncelleyen cask), App Store (`mas` ile tarama; yalnızca root'a ait, yazılamayan bir konumdaki `mas` ile kurulum, diğerlerinde App Store'a yönlendirme), npm, rustup, RubyGems (sistem Ruby'si hariç), pipx/uv (PyPI), Oh My Zsh, Sparkle uygulamaları (appcast + Homebrew cask yedeği), macOS güncellemeleri (yeniden başlatma istemeyenler kurulabilir, diğerleri Sistem Ayarları). Arama, yoksay/sabitle, ayarlar (otomatik kontrol, bildirim, Dock rozeti, oturum açılışı), TR/EN arayüz.

Ayrıca: Sparkle uygulamalarını Tazele kendisi kurar (EdDSA imza doğrulama, kod imzası ve ekip kimliği kontrolü, geri alma); `.pkg` ile kurulanlar (WARP, Tailscale) satıcı beslemesiyle denetlenir; yönetici izni yerel yetki penceresiyle (Touch ID) istenir.

Eklendi (30 Ekim 2026): alt çubukta yönetici izni düğmesi (Touch ID/parola, boşta 5 dakika); yeniden başlatma isteyen macOS güncellemeleri için onaylı "Kur ve yeniden başlat" (`softwareupdate -i --restart`, gerçek OS kurulumu denenmedi); güvenlik incelemesi düzeltmeleri `main`'de (149 test); varsayılan pencere 480×680.

Yapılmadı: Developer ID imzası ve notarization; yetki penceresi, gerçek Sparkle kurulumu ve DMG çıkarma gerçek bir uygulamada denenmedi.


## Güvenlik sınırları
- Yönetici yetkisiyle yalnızca güvenilir konumdaki, root'a ait araçlar ve doğrulanmış argümanlar çalıştırılır. Güvenilir `mas` yoksa App Store'dan güncelleme yapılır.
- Sparkle arşivi imza, dosya kimliği ve özetle denetlenir; ZIP ve tar içeriği diske çıkarılmadan akışla boyut sınırına tabi tutulur; ZIP verisinin sağlama toplamı da sınanır. Disk görüntüsündeki uygulama kopyalanmadan önce denetlenir. Açılan paket kod imzası ve ekip kimliğiyle doğrulanır. Root sahipli uygulamalarda root'a ait kopya ayrıca doğrulanır.
- Aynı kullanıcıyla çalışan başka bir süreç, arşivi veya parola yardımcısını son kontrolden sonra değiştirebilir. Bu yarışlar tamamen giderilmedi; gerçek yetkili kurulum ve bağımsız güvenlik incelemesi tamamlanmadan güvenlik doğrulaması tamamlanmış sayılmaz.
- Akış ve cask listesi istekleri HTTPS kullanır ve boyut sınırına tabidir.
