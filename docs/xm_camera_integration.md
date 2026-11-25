# Integracja kamer DVRIP i FunSDK

Dodane ścieżki dotyczą rodziny DVRIP/Xiongmai. Nie potwierdzają kompatybilności
innych rodzin, w tym Motoroli. Użytkownik nadal dodaje kamerę i wybiera jedną
preferencję wykrywania ruchu. Aplikacja dobiera dostępny odbiornik.

## Co wykonuje aplikacja

1. Na wybranym urządzeniu odczytuje `SystemInfo` i konfigurację ruchu. Profil
   oraz dane logowania pozostają w prywatnym magazynie telefonu.
2. Android próbuje odebrać alarmy kamery przez DVRIP. Dopiero pierwszy rzeczywisty
   alarm zastępuje porównywanie klatek na telefonie. Awaria odbiornika przywraca
   dotychczasową metodę. Odbiornik lokalny nadal wymaga działającego telefonu.
3. W wersji z zatwierdzonym FunSDK aplikacja automatycznie zakłada techniczne
   konto usługi kamery powiązane z kontem SafeHood. Hasło jest szyfrowane w bazie
   kluczem serwera; użytkownik nie zakłada drugiego konta w osobnej aplikacji.
4. SDK przypisuje kamerę bez wymuszania odpięcia jej od innego konta i zgłasza
   adres backendu SafeHood do odbioru alarmów. Backend sprawdza prywatny token,
   właściciela, urządzenie, aktualne ustawienia oraz ponowienia zdarzeń.
5. Samo potwierdzenie SDK pozostawia stan `subscribed`. Dopiero odebrany callback
   ustawia potwierdzenie ścieżki chmurowej i pozwala zatrzymać odbiornik telefonu.
   To potwierdzenie konfiguracji, nie bieżący pomiar dostępności obrazu.

Zdjęcie w odbiorniku lokalnym pochodzi z żądania `OPSNAP` przy alarmie.
Callback tekstowy producenta nie dostarcza automatycznie zdjęcia ani klipu.
Ta paczka nie dodaje odtwarzania nagrań SD, zdalnego podglądu P2P ani analizy AI
przez FunSDK. Nie podstawia przykładowych materiałów. Te funkcje wymagają kolejnej
integracji mediów i testu z aktywnym SDK.

## Wymagany dostęp producenta

Oficjalny SDK wymaga rejestracji projektu Android i zatwierdzenia aplikacji:

- <https://aops.jftech.com/>
- <https://developer.jftech.com/>
- [Instrukcja integracji SDK](https://github.com/jlinklab/jlink-funsdk-android-demo)

Przygotowana wersja korzysta z API artefaktu **FunSDK 5.1.4**,
w tym `SMCInitInfoV2`. API sprawdzono wobec rzeczywistego pliku AAR tej wersji.
Biblioteka udostępnia natywne pliki ARM; emulator x86 zachowuje dotychczasową
obsługę lokalną. W zwykłym buildzie SDK jest wyłączony.

Przygotowanie prywatnej konfiguracji:

```bash
node tools/setup_xm_integration.cjs
```

W `android/xm-sdk.properties` wpisz własne zatwierdzone `uuid`, `appKey`,
`appSecret`, liczbowe `moveCard` i ustaw `enabled=true`. Plik jest ignorowany
przez Git. Następnie aplikacja wymaga pełnego ponownego zbudowania.
Nie używaj kluczy demonstracyjnych innych aplikacji.

## Backend odbierający alarmy

Skrypt przygotowuje klucz `SAFEHOOD_XM_ACCOUNT_KEY` w
`.safehood-dev/xm/account-key.txt` oraz `.secret.local` dla emulatorów.
Włącza też integrację backendu zmienną `SAFEHOOD_XM_ENABLED=true` w prywatnym
pliku środowiska. Domyślna wersja SafeHood nie wymaga sekretu tej integracji.
Nie zmieniaj tego klucza po utworzeniu kont usługi: służy do ich odszyfrowania.
W produkcji jest przekazywany przez Firebase Secret Manager.

Adres `SAFEHOOD_XM_CALLBACK_BASE_URL` wskazuje funkcję
`receiveXmCameraAlarm` dostępną przez publiczny HTTPS. Dostawca nie połączy się
z lokalnym emulatorem na komputerze. Samo włączenie SDK i uruchomienie emulatorów
nie zapewnia pracy przy wyłączonym telefonie.

Przed wdrożeniem produkcyjnym trzeba skonfigurować sekret w docelowym projekcie:

```bash
firebase functions:secrets:set SAFEHOOD_XM_ACCOUNT_KEY --data-file .safehood-dev/xm/account-key.txt
```

Ten dokument ani skrypt nie uruchamiają wdrożenia i nie zmieniają planu Firebase.
Plan, dostęp producenta oraz koszty usług wymagają sprawdzenia przed ich aktywacją.

## Testy automatyczne

```bash
flutter analyze
flutter test
npm --prefix functions run lint
npm --prefix functions test
npm --prefix functions run test:xm
node --test tools/test/setup_xm_integration.test.cjs
```

Test protokołu Android znajduje się w `DvripClientTest` i uruchamia lokalny
serwer TCP. Nie zastępuje próby z kamerą. Kompilacja adaptera względem bibliotek
Android i FunSDK potwierdza zgodność użytych metod; pełny build APK z własnymi
kluczami i test na urządzeniu pozostają warunkiem uruchomienia integracji.

## Warunki odbioru

- Test protokołu: fragmentacja TCP, dodatkowy bajt terminatora, poprawna sesja
  i kolejność odpowiedzi, alarm podczas odpowiedzi, limit wielkości zdjęcia.
- Test backendu: prywatna historia i alert właściciela, brak duplikatów,
  blokada fałszywych źródeł, nieprawidłowego urządzenia i odwołanego tokenu.
- Test telefonu: alarm i rzeczywiste zdjęcie po zminimalizowaniu; awaria native
  przywraca odczyt obrazu; wyłączenie wykrywania zatrzymuje odbiornik.
- Test chmury na fizycznej kamerze: telefon wyłączony, komputer wyłączony,
  rzeczywisty alarm w historii po ponownym zalogowaniu oraz powiadomienie
  na dostępnym urządzeniu konta. Test sprzętowy pozostaje do wykonania.
- Osobno: nagrania SD, zdalny obraz, klasy wykrywania obsługiwane przez konkretny
  model, restart zasilania i zachowanie po utracie dostępu do usługi producenta.

Źródła protokołu:
[python-dvr](https://github.com/OpenIPC/python-dvr),
[alarmy lokalne](https://github.com/equake/hass-xmeye),
[FunSDK Alarm Push](https://github.com/jlinklab/jlink-funsdk-android-demo/blob/main/wikis/EN/Device%20Management/Alarm%20Push.md),
[callback serwera](https://github.com/jlinklab/jlink-funsdk-android-demo/blob/main/wikis/EN/Device%20Management/Server-Side%20Alarm%20Message%20Integration.md).
