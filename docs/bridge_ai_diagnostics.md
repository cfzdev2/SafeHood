# SafeHood: diagnostyka wydajności Bridge i lokalnego AI

Ten etap dodaje właścicielowi czytelny podgląd kondycji lokalnego Bridge bez
wysyłania surowych logów ani danych dostępowych kamery. Raport jest dołączany
do istniejącego heartbeat co 30 sekund, więc nie powstaje osobna pętla zapisu
ani dodatkowe połączenie sieciowe.

## Co pokazuje aplikacja

W ekranie **Moje kamery → Zarządzaj Bridge** można rozwinąć panel diagnostyki.
Pokazuje on:

- czy wszystkie wymagane sesje AI działają i otrzymują klatki,
- liczbę przeanalizowanych oraz pominiętych klatek,
- liczbę oczekujących zdarzeń, zdjęć, filmów i inferencji,
- liczbę błędów analizy oraz obsługi zdarzeń,
- pamięć RAM procesu Bridge i czas od ostatniej przeanalizowanej klatki.

Stan ma cztery wartości:

- **AI działa prawidłowo** – sesje i kolejki mieszczą się w limitach,
- **AI pracuje z ograniczeniami** – ponad połowa klatek jest pomijana albo
  kolejka zaczyna się zapełniać,
- **AI wymaga uwagi** – brakuje wymaganej sesji, przez co najmniej 30 sekund
  nie ma klatek lub kolejka osiągnęła bezpieczny limit,
- **AI jest nieaktywne** – żadna kamera nie ma obecnie włączonego lokalnego AI.

Raport starszy niż 90 sekund jest pokazywany jako nieaktualny. Stan online
Bridge nadal zależy od dotychczasowego heartbeat i nie jest zastępowany przez
diagnostykę AI.

Okres rozruchowy bez pierwszej klatki jest liczony od włączenia danej
konfiguracji AI. Automatyczne ponowienia FFmpeg nie resetują tego czasu, więc
uszkodzony lub zatrzymany strumień nie może chwilowo wracać do stanu zdrowego.

## Bezpieczeństwo i zgodność

Raport nie zawiera identyfikatorów kamer, adresów ONVIF/RTSP, nazw hostów,
loginów, haseł, klatek obrazu ani treści błędów. Bridge przesyła wyłącznie
ograniczone liczniki, wartości pamięci i wiek ostatniej klatki.

Backend przyjmuje raport tylko od uwierzytelnionego Bridge, sprawdza pełny
schemat, typy, zakresy oraz zależności liczników. Dopiero backend wyznacza stan
`healthy`, `degraded`, `problem` albo `idle` i dodaje czas serwera. Dokument
Bridge może odczytać wyłącznie właściciel, a aplikacja nie może zmienić
diagnostyki. Starszy Bridge, który nie wysyła nowego pola, nadal działa.

## Automatyczne sprawdzenie

Na Windows przed testami reguł zawsze ustaw JDK z Android Studio:

```bash
cd ~/safehood

export JAVA_HOME="/c/Program Files/Android/Android Studio/jbr"
export PATH="$JAVA_HOME/bin:$PATH"

npm --prefix functions test
npm --prefix functions run lint
npm --prefix bridge run test:ai
npm --prefix bridge run check
npm --prefix functions run test:rules

dart format \
  lib/features/bridges/data/bridge_service.dart \
  lib/features/bridges/domain/bridge_diagnostics.dart \
  lib/features/bridges/domain/bridge_status.dart \
  lib/features/bridges/presentation/bridge_management_screen.dart \
  lib/features/bridges/presentation/widgets/bridge_diagnostics_panel.dart \
  test/features/bridges/domain/bridge_diagnostics_test.dart \
  test/features/bridges/presentation/bridge_diagnostics_panel_test.dart

flutter analyze
flutter test
git diff --check
```

## Test na telefonie

1. Uruchom poprawny stos deweloperski z pliku `.vscode/tasks.json` oraz
   aplikację Flutter.
2. Pozostaw włączony testowy strumień z autobusem i osobami oraz lokalne AI.
3. Poczekaj na co najmniej jeden heartbeat po uruchomieniu modelu.
4. Wejdź w **Moje kamery**, naciśnij ikonę Bridge i rozwiń panel
   **AI działa prawidłowo**.
5. Licznik klatek powinien rosnąć, liczba sesji powinna wynosić `1/1`, a
   ostatnia klatka powinna mieć kilka–kilkadziesiąt sekund.
6. Zatrzymaj wyłącznie zadanie strumienia RTSP. Po ponownych próbach Bridge i
   następnym heartbeat panel powinien pokazać **AI wymaga uwagi**.
7. Uruchom strumień ponownie. Bridge odtworzy sesję, a kolejny raport wróci do
   stanu **AI działa prawidłowo**.

## Następny etap

Po potwierdzeniu diagnostyki wykonujemy kontrolowany test kilku równoczesnych
kamer i zużycia CPU/RAM. Następnie pozostaje pełny test E2E z prawdziwą kamerą
ONVIF/RTSP oraz końcowe przygotowanie produkcyjne aplikacji mobilnej.
