# Lokalne dodawanie kamer na Androidzie

**Moje kamery → Dodaj kamerę → Skonfiguruj kamerę lub sprawdź obraz** otwiera kreator.
Ten sam kreator jest dostępny z **Kamery lokalne** przy ładowaniu profilu albo
z **Kamery lokalne bez konta** na ekranie logowania.

| Ścieżka | Co sprawdza aplikacja |
| --- | --- |
| Reolink przez Bluetooth | Pilotaż E1 Pro / E330 w rewizji z BLE, Android 10+. Wpisz UID z etykiety. Aplikacja wysyła ustawienia Wi-Fi po dopasowaniu reklamy BLE, szuka tego UID w LAN, konfiguruje konto lokalne i RTSP. |
| Hotspot kamery ONVIF | Dla kamer, które udostępniają konfigurację sieci przez ONVIF już w trybie parowania. Po zmianie sieci telefon wraca do domowego Wi-Fi i wyszukuje kamerę. |
| Kamera ONVIF w sieci | Aplikacja wyszukuje kamerę oraz pyta o lokalne dane ONVIF, jeśli są potrzebne. Próbuje usługi Media i Media2, preferuje profil H.264 i prosi o adres RTSP. |
| Ręczny RTSP | Wpisz pełny adres strumienia H.264, np. `rtsp://192.168.1.50:554/live`. Domyślnie odbiór przez TCP; po niepowodzeniu można spróbować UDP, gdy Wi-Fi kamery jest główną siecią telefonu. |

Można zapisać kamerę po wyrenderowaniu pierwszej klatki. Sprawdź na ekranie,
czy obraz się porusza. Kamery lokalne są osobną listą. Dane strumienia są
zaszyfrowane kluczem Android Keystore i zapisane poza kopią aplikacji.
Hasło domowego Wi-Fi nie trafia do tej listy ani do Firebase. Gość i każdy
zalogowany użytkownik mają osobną listę na telefonie. Monitoring, nagrania,
AI i powiadomienia nadal należą do dotychczasowych ścieżek.

Na Reolinku aplikacja sprawdza UID ponownie po lokalnym logowaniu. Przy
otwieraniu zapisanej kamery odszukuje ją po UID nawet po zmianie IP.
Operacja fabrycznej aktywacji wymaga podania oddzielnego hasła kamery.
Jeśli firmware potrzebuje HTTP do ustawienia hasła, SafeHood włącza je
czasowo i próbuje przywrócić stan wyjściowy. Ta operacja i zwykły RTSP nie
zapewniają szyfrowania TLS na LAN; do pierwszej próby użyj zaufanego domowego
Wi-Fi. Odpowiedź BLE albo otwarty port nie oznacza działającego obrazu.

## Próba na telefonie

1. Otwórz aplikację na Androidzie. Zamknij Bridge, a w trybie bez konta
   sprawdź **Kamery lokalne → Dodaj kamerę**. Dla RTSP lub ONVIF w tej
   samej sieci zaczekaj na obraz, zapisz i otwórz podgląd ponownie.
2. Na testowym Reolinku E1 Pro / E330 z BLE uruchom tryb pierwszej
   konfiguracji zgodnie z instrukcją modelu. Wpisz UID, zezwól na Bluetooth,
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
