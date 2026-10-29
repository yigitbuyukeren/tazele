<a href="https://github.com/yigitbuyukeren/tazele">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/banner-dark.jpg">
    <img src="docs/banner-light.jpg" width="100%" alt="Tazele: Mac'teki her şeyi tek yerden güncelleyen menü çubuğu uygulaması. Homebrew, App Store ve npm, bağımlılıksız, MIT lisanslı.">
  </picture>
</a>

# Tazele

Mac'teki her şeyi tek yerden güncelleyen menü çubuğu uygulaması. Homebrew (formül ve cask), App Store ve global npm paketlerini tarar, nelerin eski olduğunu listeler, istediğini tek tek ya da hepsini birden günceller. macOS güncellemeleri yalnızca listelenir. pipx/uv, rustup ve Oh-My-Zsh planlanıyor.

> Durum: MVP geliştiriliyor. Homebrew, App Store ve npm taranıyor ve güncelleniyor; macOS güncellemeleri listelenip Sistem Ayarları açılıyor.

```bash
swift build && swift test
.build/debug/Tazele           # menü çubuğu
.build/debug/Tazele --window  # aynı arayüz sıradan pencerede
scripts/build-app.sh          # build/Tazele.app
```

## Plan

[docs/PLAN.md](docs/PLAN.md)

## Lisans

MIT
