<a href="https://github.com/yigitbuyukeren/tazele">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/banner-dark.jpg">
    <img src="docs/banner-light.jpg" width="100%" alt="Tazele: Mac'teki her şeyi tek yerden güncelleyen menü çubuğu uygulaması. Homebrew, App Store ve npm, bağımlılıksız, MIT lisanslı.">
  </picture>
</a>

# Tazele

Mac'teki her şeyi tek yerden güncelleyen uygulama; menü çubuğunda ve pencerede çalışır. Homebrew (formül, cask ve kendi güncelleyen cask'ler), App Store, npm, rustup, RubyGems, pipx/uv, Oh My Zsh ve kendi güncelleyicisi olan (Sparkle) uygulamaları tarar; seçtiklerini canlı günlükle günceller. Yeniden başlatma gerektirmeyen macOS güncellemeleri kurulabilir; yeniden başlatma isteyenler için açık onaydan sonra "Kur ve yeniden başlat" ya da Sistem Ayarları kullanılır. Alt çubuktaki kilit düğmesiyle Touch ID veya parola bir kez verilir; yönetici gerektiren adımlar boşta 5 dakika yeniden sormaz (kalıcı sudo kuralı yazılmaz). Kurulu olmayan araçlar atlanır. Arayüz Türkçe ve İngilizce, sistem diline göre seçilir.

App Store güncellemeleri için `mas` aracı root sahibi ve kullanıcı tarafından değiştirilemeyen bir konumda olmalıdır. Homebrew ile kurulan kullanıcıya ait `mas` güncellemeleri listeler; yüklemek için App Store açılır.

> Durum: MVP. Arka planda yalnızca kontrol eder, güncellemeleri sen onaylayınca yükler; henüz imzalı/noter onaylı bir sürüm yok, kaynaktan derlenir.

```bash
swift build && swift test
.build/debug/Tazele    # pencere + menü çubuğu
scripts/build-app.sh   # build/Tazele.app (simge, dil dosyaları dahil)
python3 scripts/check-strings.py   # çeviri tablosu denetimi
```

## Plan

[docs/PLAN.md](docs/PLAN.md)

## Lisans

MIT
