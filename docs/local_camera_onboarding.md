# Lokalne dodawanie kamer na Androidzie

**Moje kamery → Dodaj kamerę** od razu wyszukuje kamery w domowej sieci.
Wyniki pojawiają się w trakcie skanowania. Użytkownik może od razu wskazać
urządzenie i sprawdzić obraz, gdy SafeHood szuka kolejnych kamer. Jeśli kamera
nie jest jeszcze w sieci, **Połącz nową kamerę z Wi‑Fi** wyszukuje jej sieć
i prowadzi przez konfigurację. Rodzaj połączenia wybiera SafeHood.

| Sytuacja | Co sprawdza aplikacja |
| --- | --- |
| Kamera jest w domowej sieci | SafeHood sprawdza ONVIF i jego profile Media/Media2. Gdy kamera nie poda działającego adresu obrazu, aplikacja kolejno próbuje ograniczonej liczby znanych ścieżek RTSP na tym samym urządzeniu. Prosi o dane kamery przy wymaganym logowaniu lub gdy nie można uruchomić obrazu. |
| Kamera ma własną sieć na czas konfiguracji | SafeHood sugeruje sieci przypominające kamery. Po wyborze urządzenia sprawdza jego możliwości. Dla znanego profilu `robot…` próbuje najpierw DVRIP i w razie niezgodności sprawdza ONVIF. Po wysłaniu ustawień sam wyszukuje kamerę w domowym Wi‑Fi, także gdy kamera rozłączyła się przed potwierdzeniem. |
| Kamera ma kod na etykiecie | **Mam kod z etykiety kamery** otwiera wyszukiwanie zgodnej kamery Reolink E1 Pro / E330 z BLE, Android 10+. Aplikacja sprawdza identyfikator przed wysłaniem Wi‑Fi i ponownie przed lokalnym uruchomieniem obrazu. |
| Użytkownik zna adres strumienia lub potrzebuje integracji producenta | **Opcje zaawansowane** zachowują możliwość użycia pełnego adresu strumienia albo istniejącego konfiguratora producenta. |

Zapis jest dostępny po wyrenderowaniu pierwszej klatki. Wpisz nazwę i
lokalizację, a potem otwórz kamerę z **Moje kamery**. Pełny adres strumienia
i dane logowania kamery pozostają w bezpiecznym magazynie telefonu.
Hasło domowego Wi-Fi jest używane wyłącznie podczas parowania.

Jeśli ten telefon ma wpisy ze starszej listy, w **Moje kamery** pojawi się
przycisk **Przenieś wcześniej zapisaną kamerę**. Po wybraniu wpisu kreator
sprawdza metodę połączenia pod tym adresem. Zachowuje zapisany strumień jako
podgląd również wtedy, gdy ONVIF nie daje się potwierdzić. Nie wymaga
ponownego parowania. Starszy wpis zostanie usunięty po zapisie na koncie.

Potwierdzony ONVIF jest rejestrowany z adresem usługi i przypisywany do
aktywnego Bridge konta. AI, zdarzenia, nagrania i powiadomienia wymagają, żeby
Bridge mógł sam połączyć się z kamerą w sieci. Ręczny RTSP umożliwia podgląd.

Lista **Moje kamery** odświeża dostępność lokalnych kamer z telefonu, gdy
jest widoczna. **Kamera offline** oznacza brak odpowiedzi pod zapisanym
adresem. Status monitoringu opisuje oddzielnie połączenie z Bridge.

Na Reolinku aplikacja sprawdza UID ponownie po lokalnym logowaniu. Przy
otwieraniu zapisanej kamery odszukuje ją po UID nawet po zmianie IP.
Operacja fabrycznej aktywacji wymaga podania oddzielnego hasła kamery.
Jeśli firmware potrzebuje HTTP do ustawienia hasła, SafeHood włącza je
czasowo i próbuje przywrócić stan wyjściowy. Ta operacja i zwykły RTSP nie
zapewniają szyfrowania TLS na LAN; do pierwszej próby użyj zaufanego domowego
Wi-Fi. Odpowiedź BLE albo otwarty port nie oznacza działającego obrazu.

## Próba na telefonie

1. Otwórz aplikację na Androidzie i zaloguj się. W **Moje kamery → Dodaj
   kamerę** wybierz znalezioną kamerę. Zaczekaj na obraz, zapisz i otwórz
   podgląd z głównej listy. Jeśli masz starszy wpis, sprawdź, że przeniesienie
   nie prosi o wybór protokołu i zachowuje działający obraz.
2. Na testowym Reolinku E1 Pro / E330 z BLE uruchom tryb pierwszej
   konfiguracji zgodnie z instrukcją modelu. Wybierz dodanie z kodu, wpisz go i zezwól na Bluetooth,
   wpisz dane Wi-Fi 2,4 GHz, ustaw hasło kamery i otwórz podgląd. Zanotuj
   model, rewizję i firmware. Potwierdź, że po restarcie routera lub zmianie
   IP podgląd nadal działa. Wyłącz dostęp kamery do internetu i sprawdź ponownie.
3. Sprawdź zły klucz Wi-Fi, odmowę uprawnienia i przerwanie konfiguracji.
   Przy utracie potwierdzenia Bluetooth bezpiecznym następnym krokiem jest
   ponowne wyszukanie po UID. Sprawdź też, czy inne kamery w pobliżu nie
   są wybierane automatycznie.

Wersja pilotażowa nie potwierdza obsługi na realnym urządzeniu. Motorola
FOCUS72-W / Hubble, iOS, parowanie kodem pokazywanym obiektywowi oraz inne
firmware wymagają osobnych prób. Samo wykrycie ONVIF nie potwierdza, że
ten model udostępnia ustawienia Wi-Fi.

W przypadku FOCUS72-W wybierz **Opcje zaawansowane → Sprawdź obraz
Motoroli**. Kamerę i telefon połącz z domowym Wi-Fi, zamknij Hubble, wpisz
adres IP kamery i porusz dłonią przed obiektywem. Test sprawdza dwa adresy
obrazu podane w [bazie Agent DVR](https://www.ispyconnect.com/camera/hubble)
i potwierdza obraz na żywo dopiero przy dwóch różnych zdekodowanych
klatkach. Jedno zdjęcie, żądanie logowania lub brak odpowiedzi to wyniki
próby, a nie potwierdzenie obsługi. Test nie zapisuje kamery i nie wymaga
zmiany konfiguracji. Instrukcja FOCUS72-W nadal opisuje konfigurację przez
[Hubble](https://asset.conrad.com/media10/add/160267/c1/-/pl/001668958ML01/manual-1668958-motorola-focus-72-lan-wi-fi-ip-cctv-camera.pdf).

## Weryfikacja i odniesienia

Uruchom `flutter analyze` i `flutter test`.
W `test/native/ReolinkWireTest.java` są opublikowane dane testowe BLE,
walidacja odpowiedzi UDP i symulowana sesja TCP z odczytem/włączeniem
RTSP. W `test/native/CameraPairingOnvifTest.java` są testy SOAP i HTTP.
Kod protokołu odwołuje się do
[reolink-provisioning](https://github.com/cmolson/reolink-provisioning/tree/d06309d0fc1dc51cb9916f48ab15b88496bd2979),
[reolink_aio](https://github.com/starkillerOG/reolink_aio)
oraz [reolink-init](https://github.com/TinKurbatoff/reolink-init/tree/fbf86e147682d3e1cad5c0a705add9ad409fd64e).
Informacje licencyjne są w `docs/third_party/`.
