# SafeHood: nagrania zdarzeń AI z prebuforem

Ten etap dodaje filmy do historii i szczegółów wykryć w docelowej aplikacji
mobilnej. Backendem jest Firebase, a nagrywanie i analiza działają w Bridge.
Łatka jest przygotowana na commit `64ac124` z gałęzi `main`.

## Co dostaje użytkownik

- Przełącznik **Nagrywaj zdarzenia** w ustawieniach kamery, w sekcji
  **Analiza AI**. Początkowo jest wyłączony, również dla starszych kamer.
- Prywatny film MP4 H.264: do 5 sekund przed potwierdzeniem wykrycia i
  10 sekund po nim, bez dźwięku.
- Odtwarzanie, pauza, przewijanie i pełny ekran w szczegółach zdarzenia.
- Informacja o rzeczywistym czasie obrazu sprzed wykrycia. Pierwsze zdarzenie
  po uruchomieniu lub włączeniu nagrywania może mieć krótszy prebufor.
- Film pojawia się po zebraniu dalszego obrazu, zakodowaniu i wysłaniu.
  Zapis zdjęcia i analizowanie kolejnych klatek działają niezależnie.

Nagrywanie wymaga włączonego globalnego AI i AI tej kamery. Monitoring ONVIF
może pozostać wyłączony. W tym etapie obsługiwane są kamery ONVIF przypisane
do Bridge, z pobranym przez ONVIF adresem RTSP. Zdarzenia czystego ONVIF nie
uruchamiają filmów AI.

## Zastosowanie łatki

Zapisz `safehood_ai_event_recordings.patch` w `~/safehood`. Zatrzymaj działający
Bridge przez Ctrl+C. Nie usuwaj jego katalogu `bridge/data`.

```bash
cd ~/safehood
git --no-pager log -1 --oneline
git status --short
git apply --check safehood_ai_event_recordings.patch && git apply safehood_ai_event_recordings.patch
```

Nie stosuj ponownie wcześniejszych łatek outboxa ani zdjęć. Obecny commit
zawiera już tamte zmiany. Jeśli `git apply --check` zgłasza konflikt, zatrzymaj
się przed nakładaniem łatki i sprawdź commit oraz lokalne zmiany.

## Automatyczne sprawdzenie na komputerze

Przy przygotowaniu łatki przeszły: 76 testów backendu, 99 testów Bridge,
73 testy reguł Firestore, 9 testów reguł Storage oraz po jednym rzeczywistym
teście FFmpeg i integracji zapisu do Firebase. Lint i kontrola składni Node
również przeszły. Składnię Dart sprawdził formatter; pełne `flutter analyze`
i testy Fluttera pozostają do uruchomienia na Twoim komputerze, ponieważ
środowisko przygotowania nie mogło pobrać zależności z pub.dev.

Zależności Node i Flutter są takie same jak przed tą łatką. Do testów nagrań
potrzebny jest FFmpeg z `libx264`. Testy emulatorów wymagają Firebase CLI
i zgodnej wersji Java; obecny Firebase CLI wymaga Java 21 lub nowszej.

```bash
cd ~/safehood
npm --prefix functions test
npm --prefix functions run lint
npm --prefix bridge run test:ai
npm --prefix bridge run check
npm --prefix bridge run test:recording
npm --prefix functions run test:rules
npm --prefix functions run test:storage-rules
npm --prefix functions run test:clips:backend
flutter pub get
flutter analyze
flutter test test/features/cameras/domain/camera_test.dart test/features/camera_events/domain/camera_event_clip_test.dart
git diff --check
```

Testy reguł korzystają z osobnych lokalnych portów 8081 i 9198 oraz projektów
`demo-…`. Nie testują na danych produkcyjnych i nie wymagają zatrzymania
Twoich zwykłych emulatorów na 8080 i 9199.

`test:recording` uruchamia prawdziwy FFmpeg i zajmuje około 20 sekund.
Sprawdza pełne 5 + 10 sekund filmu, obraz sprzed wykrycia, późniejszy obraz,
kodek i odczyt MP4 przez walidator backendu. Wynik **skipped** oznacza brak
FFmpeg, a nie zaliczony test nagrań.

`test:clips:backend` używa rzeczywistych emulatorów Firestore i Storage,
tworzy MP4, symuluje błąd Firestore po zapisie pliku oraz sprawdza ponowny
upload. Pierwszy film i licznik wykryć mają pozostać niezmienione.

## Test w aplikacji na telefonie

1. Zachowaj działające emulatory i MediaMTX. Poczekaj, aż emulator Functions
   przeładuje nowe definicje i pokaże `uploadBridgeCameraEventClip`.
   Firebase i telefon muszą korzystać z tego samego środowiska.
2. Uruchom zmienioną aplikację w trybie debug, podając adres komputera.
   W dotychczasowych logach był to `192.168.1.10`; jeżeli adres się zmienił,
   podstaw obecny adres.

```bash
cd ~/safehood
flutter run --dart-define=USE_FIREBASE_EMULATORS=true --dart-define=FIREBASE_EMULATOR_HOST=192.168.1.10
```

3. W ustawieniach właściwej kamery włącz AI, wykrywanie osób lub pojazdów
   i **Nagrywaj zdarzenia**. Globalne AI również musi być włączone.
4. Zatrzymaj stary proces publikujący obraz testowy. Strumień z samymi
   kolorami nie dostarczy wykrycia osoby ani autobusu. W osobnym terminalu
   uruchom znany obraz testowy z autobusem i ludźmi:

```bash
cd ~/safehood
ffmpeg -re -loop 1 -framerate 10 -i tools/ai_person_test.jpg -vf scale=-2:720 -c:v libx264 -preset ultrafast -tune zerolatency -g 10 -pix_fmt yuv420p -f rtsp -rtsp_transport tcp rtsp://127.0.0.1:8554/fake-stream
```

Obraz `tools/ai_person_test.jpg` jest Twoim dotychczasowym lokalnym plikiem
testowym. Łatka go nie dodaje do repozytorium.

5. Uruchom Bridge w kolejnym terminalu, korzystając ze zwykłego backendu
   testowego na porcie 5001:

```bash
cd ~/safehood
SAFEHOOD_AI_DEBUG=true SAFEHOOD_FUNCTIONS_BASE_URL=http://127.0.0.1:5001/safehood-security-app/europe-central2 npm --prefix bridge start
```

6. Oczekuj logów `BRIDGE AI BUFFER` ze stanami `buffering`, `recording`,
   `queued`, a następnie `BRIDGE AI CLIP` z identyfikatorem zdarzenia,
   rozmiarem filmu i `prebufferMs`. Na początku trzeba poczekać na obraz,
   potwierdzenie obiektu i około 10 sekund dalszego nagrania.
7. Otwórz **nowe** zdarzenie w historii. Sprawdź obraz, odtwarzanie,
   przewijanie, pełny ekran oraz pauzę po przejściu aplikacji w tło.
   Pierwszy film może mieć mniej niż 5 sekund prebufora, zgodnie z opisem.

Włączenie samego nagrywania nie tworzy nowego zdarzenia dla obiektu już
potwierdzonego przez tracker. Dlatego w tym teście Bridge uruchamiamy po
zapisaniu ustawienia. Na statycznym obrazie nie powinien tworzyć nowych
zdarzeń z tego samego śladu na każdej klatce.

Do ręcznego sprawdzenia pełnych 5 sekund można przygotować ciągły film:
20 sekund pustego obrazu, następnie 20 sekund autobusu. Zapewnia to czas
na uruchomienie Bridge i napełnienie bufora, bez rozłączania RTSP:

```bash
ffmpeg -hide_banner -loglevel error -y -f lavfi -i color=c=black:s=640x640:r=10:d=20 -loop 1 -framerate 10 -i tools/ai_person_test.jpg -filter_complex "[1:v]scale=640:640:force_original_aspect_ratio=decrease,pad=640:640:(ow-iw)/2:(oh-ih)/2,setsar=1,fps=10,trim=duration=20,setpts=PTS-STARTPTS[bus];[0:v][bus]concat=n=2:v=1:a=0[v]" -map "[v]" -t 40 -c:v libx264 -preset ultrafast -g 10 -pix_fmt yuv420p rtsp_clip_test.mp4
ffmpeg -re -stream_loop -1 -i rtsp_clip_test.mp4 -c:v copy -an -f rtsp -rtsp_transport tcp rtsp://127.0.0.1:8554/fake-stream
```

To alternatywny publisher: uruchamiaj tylko jeden proces publikujący na tej
samej ścieżce. W filmie zdarzenia początek powinien pokazywać pusty obraz,
a późniejsza część autobus i ludzi.

## Jak działa zapis i ponawianie

- Wykrycie najpierw trafia do trwałego outboxa. Dopiero po zatwierdzeniu
  zapisu na dysku uruchamia się przechwytywanie filmu z tym samym UUID.
- Gotowy film i jego metadane są zapisywane lokalnie przed wysyłką.
  Restart odtwarza kolejkę i wysyła te same bajty, bez nagrywania nowej sceny
  w miejsce dawnego zdarzenia.
- Upload czeka na potwierdzenie przyjęcia wykrycia. Backend wybiera zdarzenie
  na podstawie UUID, właściciela, kamery i uwierzytelnionego Bridge.
- Pierwszy film zagregowanego zdarzenia pozostaje zachowany. Kolejne uploady
  nie zwiększają licznika wykryć i nie nadpisują istniejącego MP4.
- W chmurze działa warunek GCS `ifGenerationMatch: 0`. Przed uploadem backend
  sprawdza również istniejący plik, co zapobiega jego ponownemu wysłaniu
  przy retry i działa w emulatorze, który nie obsługuje tego warunku GCS.
- Film jest zapisany pod prywatną ścieżką właściciela. Nie powstaje publiczny
  URL ani token pobierania. Aplikacja pobiera go przez uwierzytelniony Storage
  do własnego pliku tymczasowego i usuwa plik po zamknięciu odtwarzacza.
- Błędy 403/404 kończą zadanie, a błędy przejściowe są ponawiane. Wyłączenie
  nagrywania lub usunięcie kamery blokuje późniejszy upload.

## Granice tego etapu

- Maksymalnie 6 MiB na gotowy film, obraz do 1280 × 720, 10 klatek/s,
  bez audio. Backend przyjmuje skończone MP4 H.264 trwające 1–30 sekund.
- Pierścień ma 16 segmentów po około 2 sekundy. Każda kamera z włączonym
  nagrywaniem uruchamia dodatkowy proces FFmpeg. Kodowanie gotowych filmów
  jest wykonywane pojedynczo dla całego Bridge.
- Maksymalnie 16 równoczesnych/przygotowywanych nagrań i 16 gotowych filmów
  czekających na upload. Pełna kolejka nie blokuje wykryć AI; pominięcie filmu
  jest widoczne w logu.
- Gotowe filmy oczekują lokalnie do 24 godzin. Nieudane zadania, osierocone
  pliki i stare pliki tymczasowe są sprzątane. To retencja **lokalna**, nie
  automatyczne usuwanie filmów z chmury po 24 godzinach.
- Niedokończone nagranie i prebufor nie przetrwają restartu. Zatrzymanie kamery
  anuluje przechwytywanie; zerwanie strumienia może skrócić film.
- Odtwarzacz prywatnych plików jest przeznaczony dla aplikacji mobilnej.
  Przeglądarka pokazuje informację o otwarciu filmu na telefonie.

Przed publikacją aplikacji pozostaje uzgodniona część dotycząca retencji
chmurowej i usuwania mediów przy usunięciu konta lub danych kamery. Obecna
funkcja usuwania konta sprząta Firestore i Auth, ale nie usuwa jeszcze plików
Storage. Ten etap nie zmienia tej funkcji i nie wdraża nic na produkcję.

## Kolejność dalszych etapów AI

Po sprawdzeniu nagrań na telefonie kontynuujemy ustalony plan: metadane AI,
strefy detekcji i obszary ignorowane, dopracowanie agregacji, reguły alertów,
testy wielu kamer i zużycia zasobów, diagnostyka oraz testy prawdziwych kamer
ONVIF/RTSP. Całość służy wydaniu aplikacji mobilnej.
