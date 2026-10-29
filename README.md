# Tazele

Mac'teki her şeyi tek yerden güncelleyen menü çubuğu uygulaması. Homebrew, App Store, npm, pipx/uv, rustup ve daha fazlasını tarar, nelerin eski olduğunu önizlemeyle gösterir, istediğini tek tek ya da hepsini birden günceller.

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
