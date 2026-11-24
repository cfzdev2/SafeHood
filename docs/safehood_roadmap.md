# SafeHood: darmowa podstawa i dalsze prace

**Stan na 23.11.2026:** użytkownik nie ma teraz możliwości wykonania testu
kamery. Próby ostatnich zmian na sprzęcie są **odłożone i niezaliczone**.
Monitoring niezależny od telefonu ma przygotowaną ścieżkę Bridge; jego
działanie na obu fizycznych kamerach pozostaje otwartym wymaganiem P0.
96 testów Fluttera oraz zestawy Bridge/backendu potwierdziły logikę pakietu;
nie zastępują tej próby.
Nie dodajemy ponownie osobnego przełącznika „wykrywanie w tle”.

Kolejność pracy bez sprzętu, rejestr odłożonych prób i scenariusz testu
całego systemu są w [planie testu generalnego](safehood_acceptance_test.md).
Po powrocie do kamer zaczynamy od tego rejestru, bez ponownego parowania
działających urządzeń i bez traktowania dawnych prób jako testu nowej wersji.

SafeHood ma działać także dla osoby, która nie ma kamery: może zgłosić
zdarzenie, zobaczyć zgłoszenia w okolicy i odbierać alerty od sąsiadów.
Dodawanie obsługiwanej kamery zaczyna się od zasilania, telefonu i domowego
Wi-Fi. Kreator wybiera sposób połączenia i potwierdza go obrazem.

| Obszar | Darmowy plan | Opcjonalny Plus |
| --- | --- | --- |
| Kamery | Podgląd i status, wykrywanie ruchu, osób i pojazdów, alerty dla właściciela, krótka historia ze zdjęciami. | Dłuższa historia nagrań w chmurze. |
| Okolica | Tworzenie zgłoszeń, odbieranie alertów od sąsiadów i zgłoszenie problemu z poziomu zdarzenia kamery. | Funkcje społeczności pozostają darmowe. |
| Analiza | Klasyfikacja podstawowych zdarzeń, także gdy wymaga modelu AI. | Szukanie po opisie, podsumowania i bardziej szczegółowe reguły. |

Podstawową funkcję nazywamy **Wykrywanie**. Użytkownik wybiera raz:
**Wyłączone**, **Tylko historia** albo **Historia i alert**. Nie ma osobnego
ustawienia „wykrywanie w tle”. Otwieranie LIVE nie jest warunkiem włączenia
monitoringu. SafeHood sam uruchamia dostępny odbiornik i próbuje przypisać
kamerę do działającego, sparowanego Bridge’a.

Docelowo telefon jest klientem: kamera wykrywa zdarzenie, działająca integracja
dostarcza je do backendu, a backend zapisuje je i wysyła alert właścicielowi.
Ten przepływ musi działać przy zamkniętej aplikacji, także poza domowym Wi-Fi.
Pełną kompatybilność potwierdza dopiero taki test na rzeczywistym urządzeniu.

Odbiornik Androida analizujący obraz jest rozwiązaniem przejściowym dla
połączenia lokalnego. Włącza się automatycznie z jednym ustawieniem ruchu,
ale nadal zależy od telefonu, jego Wi-Fi i działającej usługi Androida.
Nie jest równoważny monitoringowi niezależnemu od telefonu. Obecny odbiornik
Androida obsługuje jedną kamerę; aplikacja nie powinna losowo wybierać jednej
z kilku ani oznaczać pozostałych jako chronionych.

Dla kamery udostępniającej wyłącznie zdarzenia i obraz w LAN potrzebny jest
osiągalny odbiornik, np. działający Bridge. Obsługiwana integracja producenta
lub wysyłka zdarzeń bezpośrednio do backendu może go zastąpić. Plan Blaze
sam nie daje backendowi dostępu do prywatnego adresu kamery. To warunek
techniczny, niezależny od płatnego planu. Status „Monitoring aktywny” przy
połączeniu Bridge wymaga świeżego potwierdzenia połączenia z tą kamerą
oraz świeżego heartbeat Bridge’a, nie samego przypisania lub udanego LIVE.

Wykrycie i zdjęcie są prywatne. Sąsiedzi mogą zobaczyć zgłoszenie, gdy
właściciel zdecyduje się je utworzyć. Powiadomienie dostają osoby,
które mają włączone alerty. Krótka historia, np. siedem dni, jest
punktem wyjścia do pilotażu. Limity ustalimy po pomiarze użycia.

## Kolejność

1. Sprawdzić przepływ: wykrycie osoby → prywatne zdjęcie i jeden alert
   właściciela → potwierdzone zgłoszenie → jeden alert dla uprawnionego
   sąsiada. Powtórzenie tej samej akcji nie może wysłać drugiego alertu.
2. Na chińskiej kamerze `robot…` ustabilizować obraz po Wi-Fi, sprawdzić
   jakość i automatyczny powrót po przerwie. Na Motoroli FOCUS72-W najpierw
   potwierdzić dostęp do obrazu bez telefonu jako przekaźnika. Do obu
   ścieżek obrazu podpiąć to samo podstawowe wykrywanie.
3. Zweryfikować alerty i nagrania na dwóch kontach i działanie zgłoszeń
   na koncie bez kamery. Po teście sprzętu przygotować osobne wdrożenie
   backendu na Firebase Blaze i pilotaż darmowej wersji.
4. Zacząć Plus od jednej funkcji, np. wyszukiwania po opisie. Pozostałe
   dodatki dobierać na podstawie użycia i kosztu przechowywania danych.

## Test przepływu

```bash
npm --prefix functions run test:free-flow
```

Test korzysta z osobnego projektu emulatorów. Wysyła zdarzenie przez
handler Bridge, zapisuje zdjęcie i ponawia to samo zgłoszenie.
Sprawdza reguły dostępu i odbiorców, przechwytując wiadomości FCM.
Dostarczenie push na telefon i wykrycie z rzeczywistego obrazu są
osobnym testem. Do próby na urządzeniach używamy kont testowych.

## Próba podglądu po przerwie

Otwórz obraz z kamery `robot…` na pełnym ekranie. Odłącz na chwilę jej
zasilanie. Gdy kamera wróci do domowego Wi-Fi, obraz powinien wrócić bez
klikania „Połącz ponownie”. Powtórz próbę, ale przejdź do historii zdarzeń,
gdy kamera jest odłączona: ponawianie ma się zatrzymać do powrotu do LIVE.

Jeśli kamera udostępnia drugi profil ONVIF, wypróbuj podgląd przy słabszym
Wi-Fi. Jedna przerwa nie powinna zmienić jakości. Przy powtarzających się
zacięciach SafeHood może wybrać mniejszy obraz. Po ustabilizowaniu obrazu
otwórz LIVE ponownie i sprawdź, czy aplikacja zaczyna od tej jakości.

## Próba automatycznego uruchomienia wykrywania

W **Moje kamery → robot… → Ustawienia → Wykrywanie ruchu** wybierz
**Historia i alert**. Nie włączaj niczego dodatkowego i nie otwieraj LIVE.
SafeHood uruchamia odbiornik automatycznie. Przy odbiorniku telefonu
wymagane są Wi-Fi kamery i połączenie z backendem. Zminimalizuj aplikację,
przejdź w kadrze i sprawdź prawdziwe zdarzenie oraz alert właściciela.
Wyłączenie wykrywania ma zatrzymać odbiornik.

Po przypisaniu Bridge’a telefon nadal może być odbiornikiem, dopóki Bridge
nie potwierdzi połączenia z kamerą. Sam status „Bridge online” nie dowodzi,
że kamera jest osiągalna. Odłącz kamerę i sprawdź zmianę stanu, następnie
przywróć zasilanie. Dane o monitoringu starsze niż 90 sekund nie mogą
podtrzymywać zielonego statusu.

## Próba monitoringu niezależnego od telefonu

Po potwierdzeniu odbioru zdarzeń przez Bridge lub integrację producenta
zamknij SafeHood i odłącz telefon od domowego Wi-Fi. Inne urządzenie ma
wywołać rzeczywisty ruch przed kamerą. Zdarzenie musi zapisać się w backendzie,
a właściciel ma odebrać alert przez internet. Utrata odbiornika ma być widoczna
jako brak stałego monitoringu, bez utraty zapisanego ustawienia ruchu.

Dla chińskiej kamery robot potwierdziliśmy dotąd lokalny obraz i detekcję
z klatek. Z logów użytkownika wynika, że Bridge na komputerze nie nawiązywał
połączenia z jej adresami ONVIF/RTSP. Pełny test niezależny od telefonu
pozostaje niepotwierdzony. Dla Motoroli dotychczasowy strumień przez Hubble
i ADB również nie stanowi samodzielnej integracji SafeHood.

Testy automatyzacji:
- Flutter: `flutter test test/features/cameras/data/camera_monitoring_coordinator_test.dart`.
- Backend telefonu: `npm --prefix functions run test:phone-motion`.
- Backend odbiornika: `npm --prefix functions run test:incident-live`.

Testy backendu przechwytują wysyłkę FCM; dostarczenie powiadomienia na
rzeczywisty telefon jest osobnym testem sprzętowym.
