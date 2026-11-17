# Lokalne dodawanie kamer na Androidzie

**Moje kamery → Dodaj kamerę → Skonfiguruj kamerę i sprawdź obraz** otwiera kreator.
Po sprawdzeniu obrazu zapis tworzy zwykły wpis kamery na koncie.

| Ścieżka | Co sprawdza aplikacja |
| --- | --- |
| Reolink przez Bluetooth | Pilotaż E1 Pro / E330 w rewizji z BLE, Android 10+. Wpisz UID z etykiety. Aplikacja wysyła ustawienia Wi-Fi po dopasowaniu reklamy BLE, szuka tego UID w LAN, konfiguruje konto lokalne i RTSP. |
| Hotspot kamery (ONVIF lub DVRIP) | Po zmianie sieci telefon wraca do domowego Wi-Fi i wyszukuje kamerę, żeby sprawdzić ONVIF i obraz. |
| Kamera ONVIF w sieci | Aplikacja wyszukuje kamerę oraz pyta o lokalne dane ONVIF, jeśli są potrzebne. Próbuje usługi Media i Media2, preferuje profil H.264 i prosi o adres RTSP. |
| Ręczny RTSP | Wpisz pełny adres strumienia H.264, np. `rtsp://192.168.1.50:554/live`. Domyślnie odbiór przez TCP; po niepowodzeniu można spróbować UDP, gdy Wi-Fi kamery jest główną siecią telefonu. |

Zapis jest dostępny po wyrenderowaniu pierwszej klatki. Wpisz nazwę i
lokalizację, a potem otwórz kamerę z **Moje kamery**. Pełny adres strumienia
i dane logowania kamery pozostają w bezpiecznym magazynie telefonu.
Hasło domowego Wi-Fi jest używane wyłącznie podczas parowania.

Jeśli ten telefon ma wpisy ze starszej listy, w **Moje kamery** pojawi się
przycisk **Przenieś wcześniej zapisaną kamerę**. Wybierz wpis i wykryj jego
ONVIF albo zachowaj sam RTSP. Kreator wykorzysta zapisany adres obrazu bez
ponownego parowania. Starszy wpis zostanie usunięty po zapisie na koncie.

Potwierdzony ONVIF jest rejestrowany z adresem usługi i przypisywany do
aktywnego Bridge konta. AI, zdarzenia, nagrania i powiadomienia wymagają, żeby
Bridge mógł sam połączyć się z kamerą w sieci. Ręczny RTSP umożliwia podgląd.

Na Reolinku aplikacja sprawdza UID ponownie po lokalnym logowaniu. Przy
otwieraniu zapisanej kamery odszukuje ją po UID nawet po zmianie IP.
Operacja fabrycznej aktywacji wymaga podania oddzielnego hasła kamery.
Jeśli firmware potrzebuje HTTP do ustawienia hasła, SafeHood włącza je
czasowo i próbuje przywrócić stan wyjściowy. Ta operacja i zwykły RTSP nie
zapewniają szyfrowania TLS na LAN; do pierwszej próby użyj zaufanego domowego
Wi-Fi. Odpowiedź BLE albo otwarty port nie oznacza działającego obrazu.

## Próba na telefonie

1. Otwórz aplikację na Androidzie i zaloguj się. W **Moje kamery → Dodaj
   kamerę** wybierz RTSP lub ONVIF. Zaczekaj na obraz, zapisz i otwórz
   podgląd z głównej listy. Jeśli masz starszy wpis, sprawdź też jego
   przeniesienie i przypisanie do aktywnego Bridge.
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
