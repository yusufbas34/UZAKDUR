# UZAKDUR — Wear OS (Saat) Sürümü

Bu, telefon uygulamasının ayrı bir "flavor"ı — aynı Firebase projesini ve aynı
`devices/{deviceId}` kaydını kullanır, sadece arayüzü saat ekranına göre
küçültülmüş bir giriş ekranı + durum ekranından ibarettir (`lib/main_wear.dart`,
`lib/wear/wear_app.dart`).

## Nasıl çalışıyor?

Saat, telefonda zaten oluşturulmuş bir hesaba (aynı e-posta/şifre ile) ikinci
bir cihazdan giriş yapar. Admin panelinde/eşleştirmede **hiçbir değişiklik
gerekmez** — hangi cihaz (telefon mu saat mi) çalışıyorsa konum o cihazdan
gelir, ikisi de aynı `deviceId`'ye yazar.

Önkoşul: "Uzaklaştırılan" hesabı **önce telefon uygulamasından** normal
şekilde kayıt olmuş olmalı (isim, rol, e-posta/şifre). Saat sadece bu hesapla
**giriş** yapar, yeni kayıt oluşturmaz.

## Gereksinimler

- Saat, **eSIM/LTE ile kendi mobil hattı olan** bir Wear OS 3+ cihaz olmalı
  (Bluetooth-only saatler işe yaramaz — telefon yanında olmayınca saat de
  konum gönderemez, çözmek istediğimiz "telefonu evde bırakma" sorununu
  çözmez).
- Saat Google Play Hizmetleri'ni desteklemeli (çoğu Samsung Galaxy Watch LTE
  modeli ve genel Wear OS 3+ cihazlar destekler).
- Geliştirici bilgisayarında Flutter SDK + Android SDK kurulu olmalı (bu
  ortamda ikisi de yok, bu yüzden derleme buradan yapılamadı — kodun
  derlenip derlenmediği doğrulanamadı, ilk denemede küçük hatalar çıkarsa
  şaşırma).

## Derleme

```bash
flutter pub get
flutter build apk --flavor wear -t lib/main_wear.dart --release
```

**`-t lib/main_wear.dart` kritik** — bu olmadan `--flavor wear` sadece
paket adını/manifest'i değiştirir ama içeride yine telefon arayüzü
(`lib/main.dart`) çalışır. Çıktı:
`build/app/outputs/flutter-apk/app-wear-release.apk`

Normal telefon APK'sını derlemek hâlâ eskisi gibi çalışır (flavor
belirtmezseniz ya da `--flavor phone -t lib/main.dart` ile) — bu değişiklik
telefon build'ini etkilemez.

## Kurulum (sideload)

Saat Play Store'a yayınlanmadığı için `adb` ile saate doğrudan kurulur:

```bash
adb connect <saatin-ip-adresi>:5555   # Geliştirici seçeneklerinden "Kablosuz hata ayıklama" açık olmalı
adb install build/app/outputs/flutter-apk/app-wear-release.apk
```

## Bilinen sınırlamalar (v1 / MVP)

- Sadece konum gönderimi + temel durum ekranı var. Telefon uygulamasındaki
  harita, bölge/rota görüntüleme, kılık değiştirme, biyometrik kilit,
  uygulama silme koruması gibi özellikler saatte **yok** (bilinçli olarak
  kapsam dışı bırakıldı, gerekirse sonra eklenir).
- Yuvarlak ekran düzeni bu ortamda görsel olarak test edilemedi (fiziksel
  Wear OS cihazı/emülatörü yok) — gerçek saatte kenarlarda kırpılma
  olursa haber ver, düzeltilir.
- Uygulama simgesi telefonla aynı (saat için ayrı, yuvarlak/adaptif bir
  simge henüz eklenmedi).
