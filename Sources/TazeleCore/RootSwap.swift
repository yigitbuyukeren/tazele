import Foundation

// Yönetici izniyle uygulama değiştirme (root'a ait, örn. .pkg ile kurulmuş /Applications uygulamaları).
//
// Akış: indirme, EdDSA, arşivi açma, paket kimliği / sürüm / kod imzası / ekip / Apple kökü denetimleri
// kullanıcı yetkisiyle `SparkleInstaller` içinde yapılır. Yalnızca son adım (değiştirme) root olarak çalışır:
// `PrivilegedRunner.runSwap` → mevcut yöntem zinciri (authorizationServices → osascript → sudoAskpass)
// → `/bin/zsh -f -p -c <sabit betik> tazele-swap <kurulu> <hazırlanan> <paket kimliği> <sürüm> <ekip> <CDHash>`.
//
// Tehdit modeli: hazırlanan (staged) paket kullanıcının yazabildiği bir klasördedir; aynı kullanıcıyla
// çalışan bir süreç, kullanıcı düzeyindeki doğrulamadan SONRA onu değiştirebilir (TOCTOU). Bu yüzden root
// betik hazırlanan klasöre güvenmez:
//  (a) argümanları yeniden doğrular (kurulu yol tam olarak "/Applications/<ad>.app", "..", sembolik bağ,
//      realpath karşılaştırması; hazırlanan yol mutlak bir `.app` klasörü; değerlerin karakter kümeleri),
//  (b) paketi `ditto --noacl` ile root'a ait, 0700 kipinde yeni bir `mktemp -d` klasörüne kopyalar,
//      sahibini root:wheel yapar, ACL'leri, grup/diğer yazma izinlerini ve setuid/setgid bitlerini kaldırır
//      (kullanıcı artık kopyaya dokunamaz); bu klasör /Applications ile aynı birimde olmalıdır,
//  (c) root olarak, bu kopya üzerinde `codesign --verify --deep --strict` ve Apple köklü ekip gereksinimini
//      (`anchor apple generic and certificate leaf[subject.OU] = "<ekip>"`) denetler; kopyanın CDHash'i
//      kullanıcı düzeyinde doğrulanan paketinkiyle aynı olmalıdır (doğrulamadan sonra aynı ekibin başka bir
//      paketi konsa bile yalnızca doğrulanan içerik kurulur); kurulu uygulamanın ekip ve paket kimliğini
//      root olarak yeniden okur; sürüm, kullanıcı düzeyinde "daha yeni" bulunan sürümle aynı olmalıdır
//      (eski sürüme dönme engeli). Herhangi biri tutmazsa kurulu uygulamaya dokunmadan sıfırdan farklı
//      kodla çıkar,
//  (d) eski paketi root'a ait yedeğe, yenisini yerine `mv` ile (aynı birimde yeniden adlandırma) taşır;
//      her taşıma inode karşılaştırmasıyla doğrulanır, böylece hedefe yarışla konmuş bir girdi (ör. sahte
//      Info.plist'li bir klasör) başarı sayılmaz ve yedek silinmez; yerleştirme başarısızsa yedeği geri koyar,
//      geri koyamazsa yedeği root klasöründe bırakır ve yolunu yazar. Bu bölüm ayrı bir alt kabukta,
//      TERM/INT/HUP/PIPE yok sayılarak çalışır: sarmalayıcıların iptaldeki KILL'i yalnızca ana kabuğu
//      durdurur, alt kabuk değiştirmeyi (ya da geri yüklemeyi) tamamlar,
//  (e) Swift tarafının okuduğu işaret satırları yazar (`__TAZELE_SWAP__ …`).
//
// Neden ekip kimliği yanında Apple kökü? `codesign --verify` kendinden imzalı bir sertifikayı da geçerli
// sayar ve böyle bir sertifikanın OU alanı herhangi bir ekip kimliğini taklit edebilir. Gereksinim dizesi
// zinciri Apple köküne bağlar; böylece yalnızca o ekibin Apple'dan aldığı sertifika kabul edilir.
//
// Kabuk seçimi: betik üç yöntemde de aynı yorumlayıcıyla, SIP korumalı `/bin/zsh -f -p` ile çalışır
// (`/bin/sh` ise /private/var/select/sh ile değişebilir). Gövde yine de POSIX `sh` ile de uyumlu
// yazılmıştır ve testler her iki kabukta çalıştırır. `-p`: authorizationServices yolunda etkin kimlik root
// olsa da zsh yetkiyi bırakmasın (sarmalayıcı zaten gerçek kimliği de root yapar). `-f`: başlangıç
// dosyası okunmaz.
//
// Betik sabit bir dizedir (Swift ham dizesi; enterpolasyon yoktur). Veriler yalnızca konumsal parametre
// olarak geçer, hiçbir yerde `eval` ya da kabukça yeniden ayrıştırma yoktur.
//
// Kalan riskler (belgelenmiş):
//  - /Applications root:admin 775'tir; yönetici olan kullanıcı (ve onun adına çalışan bir süreç) bu
//    klasördeki girdileri zaten yeniden adlandırabilir. Betik bu yarışlarda kullanıcının kendi başına
//    yapamayacağı bir şey yapmaz; en kötü durumda yedek root klasöründe kalır (çıkış 21, yol bildirilir).
//  - Aynı kullanıcıyla çalışan bir süreç, arşiv açıldıktan sonra ama kullanıcı düzeyindeki denetimden ÖNCE
//    hazırlanan paketi değiştirirse, CDHash o pakete ait olur. Yine de paket Apple köklü, aynı ekip, aynı
//    paket kimliği ve kurulu olandan yeni sürüm olmak zorundadır (yani satıcının gerçek bir sürümü).
//  - Hazırlanan klasördeki FIFO gibi özel dosyalar `ditto`yu bekletebilir (yalnızca hizmet engelleme;
//    iptal ile durdurulur). İptalden sonra ana kabuk KILL ile ölürse root klasörü /private/var/tmp'de kalabilir.

/// Yönetici izniyle değiştirme: doğrulama kuralları, sabit root betiği ve sonuç yorumlama.
enum RootSwap {
    /// Kök değiştirmenin kabul ettiği tek klasör.
    static let applicationsDirectory = "/Applications"
    static let shell = "/bin/zsh"

    /// Kullanıcı düzeyinde doğrulanmış, root adımına geçirilecek istek.
    struct Request: Sendable, Equatable {
        /// Kurulu uygulama: tam olarak `/Applications/<ad>.app`.
        let installed: URL
        /// Tazele'nin çalışma klasöründe açılmış yeni sürüm.
        let staged: URL
        /// Tazele'nin oluşturduğu çalışma klasörü (hazırlanan paket bunun içinde olmalı).
        let workDirectory: URL
        let bundleID: String
        /// Kullanıcı düzeyinde "daha yeni" bulunan `CFBundleVersion`.
        let version: String
        /// Kurulu uygulamanın ekip kimliği (10 karakter).
        let team: String
        /// Kullanıcı düzeyinde doğrulanan yeni paketin CDHash'i: root kopyası bununla aynı olmalı
        /// (doğrulamadan sonra başka bir paket konursa bile yalnızca doğrulanan içerik kurulur).
        let cdhash: String

        var appName: String { installed.deletingPathExtension().lastPathComponent }
    }

    // MARK: - Doğrulama (izin penceresinden önce)

    /// `^[A-Za-z0-9._ +()-]+$`, "." ya da "-" ile başlamayan, ".." içermeyen uygulama adı (uzantısız).
    static func isAppName(_ s: String) -> Bool {
        !s.isEmpty && !s.hasPrefix(".") && !s.hasPrefix("-") && !s.contains("..") && PrivilegedCommand.isSafeArgument(s)
    }

    /// `^/Applications/[A-Za-z0-9._ +()-]+\.app$` (yalnızca biçim; dosya sistemine bakmaz).
    static func isInstalledPathShape(_ path: String, applications: String = applicationsDirectory) -> Bool {
        let prefix = applications + "/"
        guard path.hasPrefix(prefix), path.hasSuffix(".app") else { return false }
        let name = String(path.dropFirst(prefix.count).dropLast(".app".count))
        return isAppName(name)
    }

    /// Apple ekip kimliği: 10 büyük harf / rakam.
    static func isTeamID(_ s: String) -> Bool {
        s.utf8.count == 10 && s.unicodeScalars.allSatisfy { $0.isASCII && (("A"..."Z").contains($0) || ("0"..."9").contains($0)) }
    }

    static func isBundleID(_ s: String) -> Bool {
        !s.isEmpty && !s.hasPrefix("-") && !s.hasPrefix(".") && s.unicodeScalars.allSatisfy {
            $0.isASCII && (CharacterSet.alphanumerics.contains($0) || "._-".unicodeScalars.contains($0))
        }
    }

    static func isVersion(_ s: String) -> Bool {
        !s.isEmpty && !s.hasPrefix("-") && s.unicodeScalars.allSatisfy {
            $0.isASCII && (CharacterSet.alphanumerics.contains($0) || "._+-".unicodeScalars.contains($0))
        }
    }

    /// CDHash: 40-64 küçük harf onaltılık karakter.
    static func isCDHash(_ s: String) -> Bool {
        (40...64).contains(s.utf8.count) && s.unicodeScalars.allSatisfy { ("0"..."9").contains($0) || ("a"..."f").contains($0) }
    }

    /// `codesign -dv --verbose=4` çıktısındaki `CDHash=` değeri.
    static func cdhash(fromCodesignOutput text: String) -> String? {
        for line in text.split(whereSeparator: \.isNewline) where line.hasPrefix("CDHash=") {
            let value = String(line.dropFirst("CDHash=".count)).trimmingCharacters(in: .whitespaces)
            return isCDHash(value) ? value : nil
        }
        return nil
    }

    /// Kontrol karakteri (satır sonu dahil) içeriyor mu?
    static func hasControlCharacters(_ s: String) -> Bool {
        s.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) || $0.value == 0x7F }
    }

    /// Sembolik bağları çözen gerçek yol (`realpath(3)`); yol yoksa nil.
    static func realPath(_ path: String) -> String? {
        guard let p = realpath(path, nil) else { return nil }
        defer { free(p) }
        return String(cString: p)
    }

    static func isSymlink(_ path: String) -> Bool {
        var st = stat()
        return lstat(path, &st) == 0 && (st.st_mode & S_IFMT) == S_IFLNK
    }

    static func isDirectory(_ path: String) -> Bool {
        var st = stat()
        return lstat(path, &st) == 0 && (st.st_mode & S_IFMT) == S_IFDIR
    }

    /// Yalnızca üst klasörü gerçek yola çevirir (/var → /private/var); son bileşen olduğu gibi kalır,
    /// böylece hazırlanan paketin kendisi sembolik bağsa bu gizlenmez ve doğrulamada reddedilir.
    static func canonicalParent(of url: URL) -> String {
        let path = url.path
        guard path.hasPrefix("/") else { return path }
        let parent = (path as NSString).deletingLastPathComponent
        let last = (path as NSString).lastPathComponent
        guard let real = realPath(parent) else { return path }
        return real == "/" ? "/" + last : real + "/" + last
    }

    /// Kurulu yol: biçim + gerçek klasör + sembolik bağ yok + realpath kendisi.
    static func validateInstalled(_ path: String) -> Bool {
        guard !hasControlCharacters(path), isInstalledPathShape(path) else { return false }
        guard !isSymlink(applicationsDirectory), realPath(applicationsDirectory) == applicationsDirectory else { return false }
        return isDirectory(path) && !isSymlink(path) && realPath(path) == path
    }

    /// Hazırlanan yol: mutlak, `.app`, Tazele'nin çalışma klasörü içinde, sembolik bağ değil, gerçek klasör.
    /// `workDirectory` sembolik bağ içerebilir (/var → /private/var); karşılaştırma gerçek yollarla yapılır.
    static func validateStaged(_ path: String, workDirectory: URL) -> Bool {
        guard path.hasPrefix("/"), path.hasSuffix(".app"), !hasControlCharacters(path) else { return false }
        let components = path.split(separator: "/", omittingEmptySubsequences: false).dropFirst()
        guard !components.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else { return false }
        guard let work = realPath(workDirectory.path), work != "/" else { return false }
        guard path.hasPrefix(work + "/"), !path.hasPrefix(applicationsDirectory + "/") else { return false }
        return isDirectory(path) && !isSymlink(path) && realPath(path) == path
    }

    /// İsteği doğrular ve root olarak çalışacak komutu kurar. Geçersizse pencere açılmadan `PrivilegeError` fırlatır.
    static func command(for request: Request) throws -> [String] {
        let installed = request.installed.path
        // Göreli bileşenler gerçek yola çevrilmeden önce reddedilir (gizli dizin geçişi olmasın).
        let rawStaged = request.staged.path
        guard !rawStaged.split(separator: "/", omittingEmptySubsequences: false).dropFirst()
            .contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else { throw PrivilegeError.rejectedCommand(rawStaged) }
        let staged = canonicalParent(of: request.staged)
        guard validateInstalled(installed) else { throw PrivilegeError.rejectedCommand(installed) }
        guard validateStaged(staged, workDirectory: request.workDirectory) else { throw PrivilegeError.rejectedCommand(staged) }
        guard (staged as NSString).lastPathComponent.lowercased() == (installed as NSString).lastPathComponent.lowercased()
        else { throw PrivilegeError.rejectedCommand(staged) }
        guard isBundleID(request.bundleID) else { throw PrivilegeError.rejectedCommand(request.bundleID) }
        guard isVersion(request.version) else { throw PrivilegeError.rejectedCommand(request.version) }
        guard isTeamID(request.team) else { throw PrivilegeError.rejectedCommand(request.team) }
        guard isCDHash(request.cdhash) else { throw PrivilegeError.rejectedCommand(request.cdhash) }
        return arguments(script: Script.production, installed: installed, staged: staged,
                         bundleID: request.bundleID, version: request.version, team: request.team, cdhash: request.cdhash)
    }

    /// `zsh -f -p -c <betik> tazele-swap $1…$6`. Veriler ayrı argümanlardır; tırnaklanmaz, birleştirilmez.
    static func arguments(script: String, installed: String, staged: String, bundleID: String,
                          version: String, team: String, cdhash: String) -> [String] {
        [shell, "-f", "-p", "-c", script, "tazele-swap", installed, staged, bundleID, version, team, cdhash]
    }

    /// Apple köklü, belirli ekibe ait imza gereksinimi (ekip önceden `isTeamID` ile doğrulanmalı).
    static func requirement(team: String) -> String {
        "=anchor apple generic and certificate leaf[subject.OU] = \"\(team)\""
    }

    // MARK: - Sabit root betiği

    enum Script {
        /// Üretimde kullanılan TEK betik: başlık sabitleri + gövde. Veri içermez.
        static let production = productionHeader + body

        /// Üretim sabitleri. Test sürümü bu başlığı değiştirir; gövde ortaktır.
        static let productionHeader = #"""
        tz_apps=/Applications
        tz_base=/private/var/tmp
        tz_uid=0
        tz_owner=root:wheel
        tz_team_of() { /usr/bin/codesign -dv --verbose=2 "$1" 2>&1 | /usr/bin/sed -n 's/^TeamIdentifier=//p' | /usr/bin/head -n 1; }
        tz_verify() { /usr/bin/codesign --verify --deep --strict -R "=anchor apple generic and certificate leaf[subject.OU] = \"$2\"" "$1"; }
        tz_hook() { :; }

        """#

        /// Ortak gövde. `$1` kurulu yol, `$2` hazırlanan yol, `$3` paket kimliği, `$4` sürüm, `$5` ekip,
        /// `$6` CDHash. Çıkış kodları: 0 başarı, 10 argüman, 11 root değil, 12 kopyalama, 13 kod imzası,
        /// 14 ekip, 15 paket kimliği, 16 sürüm, 17 CDHash, 20 değiştirilemedi (eski sürüm yerinde),
        /// 21 yedek korunuyor, 143 iptal.
        static let body = #"""
        LC_ALL=C; export LC_ALL
        PATH=/usr/bin:/bin:/usr/sbin:/sbin; export PATH
        umask 022
        tz_work=''
        tz_child=''
        tz_say() { printf '%s\n' "__TAZELE_SWAP__ $*"; }
        tz_cleanup() {
          if [ -n "$tz_work" ] && [ -d "$tz_work" ] && [ ! -L "$tz_work" ]; then /bin/rm -rf "$tz_work"; fi
          tz_work=''
        }
        tz_fail() { tz_say "fail $1"; tz_cleanup; exit "$2"; }
        tz_cancel() {
          if [ -n "$tz_child" ]; then kill -TERM "$tz_child" 2>/dev/null; wait "$tz_child" 2>/dev/null; fi
          tz_fail cancelled 143
        }
        trap tz_cancel TERM INT HUP
        tz_is_team() {
          case "$1" in
            [A-Z0-9][A-Z0-9][A-Z0-9][A-Z0-9][A-Z0-9][A-Z0-9][A-Z0-9][A-Z0-9][A-Z0-9][A-Z0-9]) return 0 ;;
          esac
          return 1
        }
        tz_plist() { /usr/bin/plutil -extract "$2" raw -o - "$1/Contents/Info.plist" 2>/dev/null; }
        tz_cdhash() { /usr/bin/codesign -dv --verbose=4 "$1" 2>&1 | /usr/bin/sed -n 's/^CDHash=//p' | /usr/bin/head -n 1; }
        tz_ino() { /usr/bin/stat -f %i "$1" 2>/dev/null; }
        tz_dev() { /usr/bin/stat -f %d "$1" 2>/dev/null; }
        tz_bg() { "$@" & tz_child=$!; wait "$tz_child"; tz_rc=$?; tz_child=''; return "$tz_rc"; }

        [ "$#" -eq 6 ] || tz_fail args 10
        [ "$(/usr/bin/id -u)" = "$tz_uid" ] || tz_fail notroot 11
        tz_inst=$1; tz_staged=$2; tz_id=$3; tz_ver=$4; tz_team=$5; tz_cd=$6

        # a) Argümanlar yeniden doğrulanır.
        case "$tz_inst$tz_staged$tz_id$tz_ver$tz_team$tz_cd" in *[[:cntrl:]]*) tz_fail args 10 ;; esac
        case "$tz_inst" in "$tz_apps"/*.app) ;; *) tz_fail args 10 ;; esac
        tz_name=${tz_inst#"$tz_apps"/}
        case "$tz_name" in */*|.*|-*|*..*|*[!A-Za-z0-9._\ +\(\)-]*) tz_fail args 10 ;; esac
        case "$tz_staged" in /*.app) ;; *) tz_fail args 10 ;; esac
        case "$tz_staged" in */../*|*/./*|*//*|"$tz_apps"/*) tz_fail args 10 ;; esac
        case "$tz_id" in ''|-*|.*|*[!A-Za-z0-9._-]*) tz_fail args 10 ;; esac
        case "$tz_ver" in ''|-*|*[!A-Za-z0-9._+-]*) tz_fail args 10 ;; esac
        case "$tz_cd" in ''|*[!0-9a-f]*) tz_fail args 10 ;; esac
        [ "${#tz_cd}" -ge 40 ] && [ "${#tz_cd}" -le 64 ] || tz_fail args 10
        tz_is_team "$tz_team" || tz_fail args 10
        [ -d "$tz_apps" ] && [ ! -L "$tz_apps" ] && [ "$(/bin/realpath "$tz_apps")" = "$tz_apps" ] || tz_fail args 10
        [ -d "$tz_inst" ] && [ ! -L "$tz_inst" ] && [ "$(/bin/realpath "$tz_inst")" = "$tz_inst" ] || tz_fail symlink 10
        [ -d "$tz_staged" ] && [ ! -L "$tz_staged" ] && [ "$(/bin/realpath "$tz_staged")" = "$tz_staged" ] || tz_fail args 10
        [ ! -e "$tz_inst/Contents/_MASReceipt" ] || tz_fail args 10

        # Kurulu uygulama root olarak okunur: ekip ve paket kimliği beklenenle aynı olmalı.
        tz_t_old=$(tz_team_of "$tz_inst")
        tz_is_team "$tz_t_old" && [ "$tz_t_old" = "$tz_team" ] || tz_fail team 14
        [ "$(tz_plist "$tz_inst" CFBundleIdentifier)" = "$tz_id" ] || tz_fail bundle 15

        # b) Root'a ait, 0700 kipinde yeni klasöre kopya; kullanıcı artık değiştiremez.
        tz_say "step copy"
        tz_work=$(/usr/bin/mktemp -d "$tz_base/tazele-swap.XXXXXXXX") || { tz_work=''; tz_fail copy 12; }
        [ -d "$tz_work" ] && [ ! -L "$tz_work" ] && [ -O "$tz_work" ] || { tz_work=''; tz_fail copy 12; }
        /bin/chmod 700 "$tz_work" || tz_fail copy 12
        # Taşımalar atomik yeniden adlandırma olmalı: aynı birim şart (yoksa hiçbir şeye dokunmadan çık).
        [ -n "$(tz_dev "$tz_work")" ] && [ "$(tz_dev "$tz_work")" = "$(tz_dev "$tz_apps")" ] || tz_fail copy 12
        /bin/mkdir "$tz_work/new" "$tz_work/backup" || tz_fail copy 12
        tz_new="$tz_work/new/$tz_name"
        tz_bg /usr/bin/ditto --noacl "$tz_staged" "$tz_new" || tz_fail copy 12
        [ -d "$tz_new" ] && [ ! -L "$tz_new" ] || tz_fail copy 12
        /usr/sbin/chown -R "$tz_owner" "$tz_new" || tz_fail copy 12
        /bin/chmod -R -N "$tz_new" 2>/dev/null
        /bin/chmod -R go-w,ug-s "$tz_new" || tz_fail copy 12
        /bin/chmod 755 "$tz_new" || tz_fail copy 12

        # c) Doğrulama root'a ait kopya üzerinde, root olarak.
        tz_say "step verify"
        tz_bg tz_verify "$tz_new" "$tz_team" || tz_fail signature 13
        [ "$(tz_cdhash "$tz_new")" = "$tz_cd" ] || tz_fail cdhash 17
        tz_t_new=$(tz_team_of "$tz_new")
        [ "$tz_t_new" = "$tz_team" ] || tz_fail team 14
        [ "$(tz_plist "$tz_new" CFBundleIdentifier)" = "$tz_id" ] || tz_fail bundle 15
        [ "$(tz_plist "$tz_new" CFBundleVersion)" = "$tz_ver" ] || tz_fail version 16

        # d) Yedekli değiştirme, ayrı bir alt kabukta: sarmalayıcı iptalde bu kabuğu önce TERM, 2 sn sonra
        # KILL ile durdurur; KILL yalnızca bu kabuğa gider, alt kabuk işini (gerekirse geri yüklemeyi) bitirir.
        # Her taşıma, inode karşılaştırmasıyla doğrulanır (hedefe yarışla konan başka bir girdi kabul edilmez).
        tz_swap() {
          trap '' TERM INT HUP PIPE
          tz_backup="$tz_work/backup/$tz_name"
          tz_ino_old=$(tz_ino "$tz_inst"); tz_ino_new=$(tz_ino "$tz_new")
          [ -n "$tz_ino_old" ] && [ -n "$tz_ino_new" ] || tz_fail swap 20
          if ! /bin/mv "$tz_inst" "$tz_backup"; then
            if [ "$(tz_ino "$tz_inst")" = "$tz_ino_old" ] && [ ! -e "$tz_backup" ]; then tz_fail swap 20; fi
          fi
          tz_hook after-backup
          if [ "$(tz_ino "$tz_backup")" = "$tz_ino_old" ] && [ ! -e "$tz_inst" ] && [ ! -L "$tz_inst" ] \
            && /bin/mv "$tz_new" "$tz_inst" && [ ! -L "$tz_inst" ] && [ "$(tz_ino "$tz_inst")" = "$tz_ino_new" ] \
            && [ "$(tz_plist "$tz_inst" CFBundleIdentifier)" = "$tz_id" ] && [ "$(tz_plist "$tz_inst" CFBundleVersion)" = "$tz_ver" ]; then
            tz_say ok
            tz_cleanup
            exit 0
          fi
          # Geri yükleme: yerdeki bizim yeni paketimizse kenara alınır; yedek yerine konur.
          if [ ! -L "$tz_inst" ] && [ "$(tz_ino "$tz_inst")" = "$tz_ino_new" ]; then /bin/mv "$tz_inst" "$tz_work/failed-$tz_name"; fi
          if [ "$(tz_ino "$tz_backup")" = "$tz_ino_old" ] && [ ! -e "$tz_inst" ] && [ ! -L "$tz_inst" ] \
            && /bin/mv "$tz_backup" "$tz_inst"; then
            if [ ! -L "$tz_inst" ] && [ "$(tz_ino "$tz_inst")" = "$tz_ino_old" ]; then
              tz_say restored
              tz_cleanup
              exit 20
            fi
            # Yarışla konmuş bir klasörün içine taşındı.
            tz_say "kept $tz_inst/$tz_name"
            exit 21
          fi
          # Yedek tek kopyadır; silinmez.
          tz_say "kept $tz_backup"
          exit 21
        }
        tz_say "step swap"
        trap '' TERM INT HUP PIPE
        tz_swap &
        tz_child=$!
        wait "$tz_child"
        exit "$?"
        """#

        #if DEBUG
        /// YALNIZCA TESTLER: aynı gövde, root gerektirmeyen başlıkla. Klasörler ortam değişkenlerinden okunur
        /// (betiğe veri gömülmez); ekip kimliği Info.plist'teki `TazeleTestTeam` anahtarından gelir, imza
        /// denetimi Apple kökü istemeden yapılır (ad-hoc imzalı sahte uygulamalar için). Sürüm derlemesinde
        /// bu işlev yoktur ve `command(for:)` hiçbir koşulda bunu kullanmaz.
        static func testVariant() -> String {
            #"""
            tz_apps=${TAZELE_TEST_APPS:?}
            tz_base=${TAZELE_TEST_BASE:?}
            tz_uid=$(/usr/bin/id -u)
            tz_owner="$(/usr/bin/id -u):$(/usr/bin/id -g)"
            tz_team_of() { /usr/bin/plutil -extract TazeleTestTeam raw -o - "$1/Contents/Info.plist" 2>/dev/null; }
            tz_verify() {
              case "${TAZELE_TEST_HOOK:-}" in slow-verify) /bin/sleep 30 ;; esac
              /usr/bin/codesign --verify --deep --strict "$1"
            }
            tz_hook() {
              case "${TAZELE_TEST_HOOK:-}" in
                remove-new) /bin/rm -rf "$tz_new" ;;
                block-target) : > "$tz_inst" ;;
                term-self) kill -TERM $$ ;;
                kill-parent) kill -KILL $$; /bin/sleep 1 ;;
              esac
            }

            """# + body
        }
        #endif
    }

    // MARK: - Sonuç

    /// Betiğin çıkış kodlarının anlamı.
    enum Outcome: Equatable, Sendable {
        case success, invalidArguments, notRoot, copyFailed, codeSignature, team, bundleID, version, codeHash
        case restored, backupKept, cancelled, unknown(Int32)

        init(status: Int32) {
            switch status {
            case 0: self = .success
            case 10: self = .invalidArguments
            case 11: self = .notRoot
            case 12: self = .copyFailed
            case 13: self = .codeSignature
            case 14: self = .team
            case 15: self = .bundleID
            case 16: self = .version
            case 17: self = .codeHash
            case 20: self = .restored
            case 21: self = .backupKept
            case 143: self = .cancelled
            default: self = .unknown(status)
            }
        }
    }

    static let marker = "__TAZELE_SWAP__ "

    /// Betik çıktısını günlük satırlarına çevirir; işaret satırlarını yerelleştirir ve "ok" görülüp görülmediğini tutar.
    final class LineTranslator: @unchecked Sendable {
        private let lock = NSLock()
        private var _sawOK = false
        private let onLine: @Sendable (String) -> Void

        init(onLine: @escaping @Sendable (String) -> Void) { self.onLine = onLine }

        var sawOK: Bool { lock.withLock { _sawOK } }

        func feed(_ line: String) {
            guard line.hasPrefix(RootSwap.marker) else { onLine(line); return }
            let rest = String(line.dropFirst(RootSwap.marker.count))
            switch rest {
            case "ok": lock.withLock { _sawOK = true }
            case "step copy":
                onLine(String(localized: "Yönetici olarak korumalı klasöre kopyalanıyor", bundle: .main))
            case "step verify":
                onLine(String(localized: "Yönetici olarak yeniden denetleniyor (kod imzası, ekip, paket kimliği, sürüm)", bundle: .main))
            case "step swap":
                onLine(String(localized: "Uygulama değiştiriliyor", bundle: .main))
            case "restored":
                onLine(String(localized: "Eski sürüm geri yüklendi", bundle: .main))
            default:
                if rest.hasPrefix("kept ") {
                    let path = String(rest.dropFirst("kept ".count))
                    onLine(String(localized: "Eski sürüm şurada korunuyor: \(path)", bundle: .main))
                }
                // "fail …" satırları gösterilmez; hata Swift tarafında çıkış koduyla bildirilir.
            }
        }
    }
}
