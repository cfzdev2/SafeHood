# Kamery lokalne: ONVIF, RTSP i Wi-Fi

1. Połącz telefon i kamerę z tą samą siecią lokalną. Kamera może być wpięta
   do routera kablem, a telefon połączony przez Wi-Fi.
2. W **Dodaj kamerę → Kamery ONVIF i RTSP** uruchom wykrywanie. Bez multicastu
   SafeHood może wykryć usługę ONVIF także zapytaniem do znanych portów.
   Gdy nie wykryje kamery, użyj **Wpisz adres ONVIF** (IP, IP:port albo pełny
   adres usługi) lub **Wpisz adres RTSP** (pełny adres strumienia).
3. Jeśli kamera wymaga osobnego konta ONVIF, wpisz je w **Dane logowania
   i adres RTSP**. To konto kamery, nie konto SafeHood ani hasło Wi-Fi.
   Po dodaniu pola są dostępne w ustawieniach kamery. Adres RTSP można
   podać także jako obejście dla kamery ONVIF, która nie zwraca poprawnego URI.
4. Otwórz LIVE. Przy kilku profilach SafeHood preferuje H.264 w rozdzielczości
   odpowiedniej na telefon. Na Androidzie najpierw próbuje RTP przez TCP,
   a przy awarii przechodzi do kolejnych dostępnych prób (w tym trybu
   domyślnego odtwarzacza). Jeśli kamera oferuje H.264, wybierz go przed H.265
   lub trybem Smart Codec, gdy odtwarzacz nie potrafi pokazać obrazu.

Ustawienia połączenia wpisane ręcznie, w tym login i pełny adres RTSP,
pozostają w bezpiecznym magazynie urządzenia i są oddzielone według konta
SafeHood. Nie trafiają do Firestore. Bridge nie dostaje z tego telefonu
haseł ani ręcznych adresów. Samodzielny adres RTSP służy tu do podglądu.
Bridge dla skonfigurowanych kamer ONVIF potrafi teraz spróbować kolejnego
profilu, trybu transportu i usługi Media2; nadal potrzebuje dostępu do
kamery w LAN. Dla Bridge z kamerą wymagającą logowania potrzebna jest
odrębna konfiguracja.

## Przeniesienie kamery z kabla na Wi-Fi

- Po wykryciu lub podaniu IP wybierz **Połącz kamerę z Wi-Fi**. Najpierw
  trzeba nawiązać połączenie z kamerą: przez kabel do routera albo własną
  sieć kamery, jeśli ją udostępnia.
- Formularz jest dostępny dopiero, gdy kamera pokaże bezprzewodowy interfejs
  ONVIF. Jeśli kamera obsługuje skanowanie, można wybrać sieć z listy; w
  przeciwnym wypadku wpisz dokładny SSID. Obsługiwane jest WPA2-Personal
  (PSK/CCMP). Hasło Wi-Fi jest wysyłane do kamery tylko przy zatwierdzeniu,
  nie jest zapisywane. Przy HTTP zostanie przesłane bez szyfrowania po LAN,
  co aplikacja pokazuje przed wysłaniem.
- Przyjęcie ustawień przez kamerę nie potwierdza jeszcze, że dołączyła do
  sieci. Po zmianie uruchom wykrywanie ponownie. Po zmianie IP można też
  wpisać nowy adres w ustawieniach **podglądu na tym telefonie**. Adres
  Bridge trzeba wówczas zaktualizować osobno.
- Jeżeli kamera nie udostępnia konfiguracji Wi-Fi przez ONVIF, ustaw sieć
  w jej panelu lub aplikacji producenta. Parowanie przez własny protokół
  producenta, jego QR, Bluetooth lub chmurę wymaga oddzielnej integracji.
  Samo wykrycie przez ONVIF nie oznacza obsługi konfiguracji Wi-Fi.

Podstawa protokołu:
[ONVIF Device Management](https://www.onvif.org/ver10/device/wsdl/devicemgmt.wsdl),
[Media1](https://www.onvif.org/ver10/media/wsdl/media.wsdl) i
[Media2](https://www.onvif.org/ver20/media/wsdl/media.wsdl).
Zmiana odtwarzania RTSP przez TCP dotyczy Androida. Podgląd i konfigurację
sieci należy sprawdzić na rzeczywistych kamerach. Nie zakładamy, że
obecny odtwarzacz iOS odtworzy każdy adres RTSP.

## Sprawdzenie po instalacji

- `flutter pub get`, `flutter analyze`, `flutter test`.
- `npm --prefix bridge run check` i `npm --prefix bridge run test:ai`.
- Uruchom ponownie pełne `flutter run` na Androidzie, żeby przebudować
  wtyczkę natywną. Ręczna zmiana pliku w katalogu Pub Cache nie jest
  potrzebna: projekt ma własną kopię wtyczki.
- Dla NVT z tej rozmowy: użyj już dodanej kamery albo wpisz jej aktualny
  adres ONVIF (w próbie był to `192.168.1.6:8899`). Sprawdź, czy LIVE
  pokazuje obraz przez co najmniej 30 sekund. Potem sprawdź, czy kamera
  rzeczywiście udostępnia w SafeHood bezprzewodowy interfejs.
