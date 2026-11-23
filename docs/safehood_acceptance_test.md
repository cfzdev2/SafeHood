# SafeHood — dalsze prace i test generalny

Aktualizacja: **23.11.2026**. Użytkownik odłożył testy na sprzęcie, bo nie
ma teraz możliwości ich wykonać. Ten dokument jest punktem powrotu do pracy.
Baza planu: `f968cf9`, gałąź `codex/unify-camera-wizard`.

## Wymaganie produktu

Użytkownik dodaje kamerę przez SafeHood i wybiera jedno ustawienie ruchu:
**Wyłączone**, **Tylko historia** albo **Historia i alert**. SafeHood dobiera
obsługę automatycznie. Nie wymaga wyboru ONVIF/DVRIP, dodatkowego przełącznika
tła, otwierania podglądu ani używania aplikacji producenta w zwykłej obsłudze.

Docelowy monitoring działa niezależnie od telefonu. Kamera lub działający
odbiornik przekazuje zdarzenia do backendu, a telefon odbiera powiadomienia.
Android analizujący lokalny obraz jest rozwiązaniem przejściowym i nie stanowi
potwierdzenia monitoringu 24/7. Samo przejście na Firebase Blaze nie połączy
backendu z prywatnym adresem kamery.

## Co jest potwierdzone, a co czeka

| Obszar | Obecny stan | Co pozostaje sprawdzić |
| --- | --- | --- |
| Logika ostatniej zmiany | Analiza Darta bez problemów; 93 testy Fluttera przeszły przed sporządzeniem planu. | Działanie tej wersji na Xiaomi. |
| Chińska kamera `robot…` / NVT | Użytkownik wcześniej potwierdził lokalny LIVE oraz zdarzenie ruchu ze zdjęciem przy otwartym podglądzie. | Automatyczny start bez LIVE, minimalizacja, rzeczywiste media i monitoring niezależny od telefonu. |
| Połączenie komputera z chińską kamerą | W poprzednich logach TCP z Windows do kamery kończył się timeoutem, mimo działającego połączenia telefonu. | Osiągalność kamery przez niezależny odbiornik; znany problem P0. Dawne IP `192.168.1.9` wymaga aktualnego potwierdzenia. |
| Motorola FOCUS72-W | Wcześniej obraz działał przez Hubble i przekierowanie ADB. | Samodzielne parowanie, obraz i zdarzenia w SafeHood bez Hubble/ADB jako przekaźnika. |
| Klipy zdarzeń | Kod nagrywania i prywatnego zapisu ma testy. | Prawdziwe nagrania z odpowiedniej kamery przy każdym obsługiwanym sposobie wykrywania. |
| Obraz w zgłoszeniu | Jest osadzony w zgłoszeniu i ograniczony do uczestników. Obecna transmisja to odświeżane klatki bez dźwięku, zależne od otwartego zgłoszenia autora. | Odbiór na drugim koncie i źródło transmisji niezależne od otwartego telefonu autora. |

Nie oznaczamy kamery jako w pełni obsługiwanej po samym wykryciu sieci,
otwarciu portu, uzyskaniu RTSP lub zapisaniu jej na liście. Wynik dla jednego
modelu nie potwierdza obsługi drugiego modelu.

## Co przygotować teraz, bez kamer

To lista dalszych prac, a nie deklaracja ich wdrożenia w tej aktualizacji.
W tej aktualizacji zapisano plan; nie dodano kolejnych funkcji aplikacji.

| Kolejność | Zakres pracy | Warunek zakończenia |
| --- | --- | --- |
| 1 — P0 | Dokończyć wybór i diagnostykę niezależnego odbiornika zdarzeń. Oddzielnie opisać obsługę zdarzeń kamery, integrację producenta i analizę dostępnego obrazu. | Każda kamera ma potwierdzoną ścieżkę albo widoczny brak stałego monitoringu. Samo przypisanie Bridge nie daje zielonego statusu. Osiągalność rzeczywistej kamery pozostaje testem sprzętowym. |
| 2 — P0 | Ujednolicić zapis rzeczywistego zdjęcia i krótkiego filmu dla zdarzeń ruchu, niezależnie od tego, który odbiornik wykrył ruch. | Testy obejmują poprawny materiał, brak klatki, błąd wysyłki i ponowienie bez duplikatów. Zwykły ruch nie może korzystać ze starych materiałów demonstracyjnych. |
| 3 — P1 | Domknąć zgłoszenie: prywatne zdarzenie → decyzja właściciela → zgłoszenie → właściwi sąsiedzi → media i podgląd wewnątrz zgłoszenia. | Sąsiad nie otwiera prywatnej kamery; otrzymuje tylko materiały udostępnione do zgłoszenia. Docelowa transmisja nie zależy od otwartego ekranu autora. |
| 4 — P1 | Sprawdzić trwałość kont, kamer i parowania Bridge po restarcie środowiska. Ujednolicić zadania startowe i dane emulatorów. | Restart nie tworzy pustego konta ani nie gubi kamer; błędne parowanie daje jedno czytelne wskazanie przyczyny. |
| 5 — P1 | Dopracować ponawianie połączeń, aktualność statusów, powrót po zmianie IP i czytelne błędy kreatora. | Symulowane awarie nie zapętlają odtwarzacza, nie tworzą kilku odbiorników i nie pozostawiają fałszywego statusu online. Jakość obrazu nadal wymaga próby na kamerze. |
| 6 — P2 | Sprawdzić darmową podstawę i oddzielenie opcjonalnej analizy AI. Przygotować osobny plan uruchomienia Firebase Blaze po testach lokalnych. | Ruch, historia, alerty i zgłoszenia nie wymagają włączania płatnych dodatków. Osoby i pojazdy mają rzeczywistą, potwierdzoną metodę wykrywania; nie są tylko przełącznikami w UI. |

Pierwszym zadaniem wdrożeniowym po zatwierdzeniu tej listy jest punkt 1,
następnie punkt 2. Nie rozbudowujemy płatnych dodatków przed działającą podstawą.

## Przygotowanie testu generalnego

Potrzebne są obecny komputer, Xiaomi, dostępna kamera i istniejący emulator
Androida na PC z drugim kontem SafeHood. Nie zakładamy drugiego fizycznego
telefonu ani zakupu kolejnego sprzętu. Test drugiej kamery wykonujemy później
na tym samym zestawie. Równoczesna obsługa obu kamer ma osobny wynik.

Przed próbą zapisujemy wersję aplikacji, model kamery, aktualny adres,
wybrany odbiornik i dwa konta testowe: **A — właściciel**, **B — sąsiad**.
Potwierdzamy, że oba korzystają z tego samego backendu i właściwego projektu.
Nie usuwamy kont ani danych w celu obejścia błędu logowania.

Testy automatyczne uruchamiamy na osobnych projektach emulatorów, kolejno.
Przechwycona wysyłka FCM potwierdza wybór odbiorcy, nie odbiór na urządzeniu.

```bash
flutter analyze
flutter test
npm --prefix functions test
npm --prefix bridge run check
npm --prefix bridge run test:ai
npm --prefix bridge run test:background-motion
npm --prefix bridge run test:recording
npm --prefix functions run test:rules
npm --prefix functions run test:storage-rules
npm --prefix functions run test:phone-motion
npm --prefix functions run test:incident-live
npm --prefix functions run test:free-flow
npm --prefix functions run test:clips:backend
```

Nie uruchamiamy równocześnie zestawów korzystających z tych samych portów.
Testy reguł i przepływów używają konfiguracji `firebase.rules-test.json`,
oddzielnej od danych kont użytkownika. Do FFmpeg potrzebny jest zainstalowany
FFmpeg. Dostarczenie FCM sąsiadowi sprawdzamy na emulatorze z działającą
obsługą Google; w razie jej braku test odbioru wykonujemy kolejno na Xiaomi
po zmianie konta i wywołaniu osobnego zdarzenia testowego.

## Rejestr prób na sprzęcie — wszystkie odłożone

Wyniki do wpisania po wykonaniu: **ZALICZONE**, **BŁĄD** albo **BLOKADA**.
**ODŁOŻONE** oznacza brak aktualnego testu. Nie przepisujemy automatycznie
wcześniejszego sukcesu podglądu na wyniki monitoringu, nagrań czy powiadomień.

| ID | Próba | Oczekiwany wynik | Status na 23.11.2026 |
| --- | --- | --- | --- |
| G01 | Start środowiska i logowanie A/B, następnie restart z zapisanymi danymi. | Konta, kamera i ustawienia pozostają; brak nieskończonego „łączenia z profilem”. | ODŁOŻONE |
| G02 | Dodanie kamery z trybu konfiguracji przez SafeHood, gdy przeznaczymy ją do ponownej konfiguracji. | Kreator sam wybiera obsługę; kamera dołącza do Wi-Fi, pokazuje prawdziwy obraz i trafia na główną listę. | ODŁOŻONE |
| G03 | Otwieranie istniejącej kamery bez ponownego parowania. | Zapisane dane działają; brak dublowania kamery. | ODŁOŻONE |
| G04 | LIVE przy świetle i większym ruchu, pełny ekran, wyjście i powrót. | Bez utrwalonych pasów i czarnego ekranu; zacięcie uruchamia powrót obrazu; zapisujemy faktyczną płynność. | ODŁOŻONE |
| G05 | Jedno ustawienie „Historia i alert”, bez otwierania LIVE; następnie Home i wygaszenie ekranu. | Odbiornik uruchamia się automatycznie, prawdziwy ruch tworzy zdarzenie i alert. Brak drugiego przełącznika. | ODŁOŻONE |
| G06 | „Tylko historia”, następnie „Wyłączone”. Pomiędzy próbami czekamy na upływ ustawionego odstępu alertów. | Najpierw jest zapis bez alertu, potem brak nowych wykryć z tej kamery. Inne kamery nadal działają zgodnie ze swoimi ustawieniami. | ODŁOŻONE |
| G07 — P0 | Przy działającym niezależnym odbiorniku zamykamy SafeHood i przełączamy telefon z domowego Wi-Fi na dane komórkowe. Wywołujemy ruch. | Zdarzenie i alert docierają mimo zamkniętej aplikacji i braku lokalnego połączenia telefonu z kamerą. Sam test G05 nie zalicza tej próby. | ODŁOŻONE; niezależny odbiornik niepotwierdzony |
| G08 — P0 | Wyłączamy telefon, wywołujemy ruch i notujemy godzinę; potem włączamy telefon i sprawdzamy historię. | Backend zapisał zdarzenie w czasie, gdy telefon był wyłączony. Nie wymagamy otrzymania push na wyłączonym telefonie. | ODŁOŻONE; niezależny odbiornik niepotwierdzony |
| G09 | Zdjęcie i film z prawdziwego zdarzenia, następnie zdarzenie bez dostępnego materiału. | Właściwa kamera, moment i pomieszczenie; film daje się odtworzyć. Przy braku pliku jest informacja o braku materiału, a nie demonstracyjne zdjęcie/film. | ODŁOŻONE |
| G10 | Kilka ruchów w jednym epizodzie i ponowienie wysyłki. | Agregacja i odstęp alertów działają zgodnie z ustawieniami; brak zdublowanych zgłoszeń i powiadomień od ponowienia. | ODŁOŻONE |
| G11 | Właściciel tworzy zgłoszenie ze zdarzenia; konto B jest uprawnionym sąsiadem. | Prywatne wykrycie nie alarmuje sąsiadów automatycznie. Dopiero zgłoszenie trafia do właściwych osób. | ODŁOŻONE |
| G12 | Konto B otwiera zgłoszenie, zdjęcie, film i udostępniony obraz. | Obraz jest w zgłoszeniu; B nie otrzymuje dostępu do prywatnej kamery, jej adresu ani danych logowania. | ODŁOŻONE |
| G13 | Autor zatrzymuje udostępnianie lub zgłoszenie wygasa; osoba spoza uczestników próbuje odczytu. | Obraz wygasa i dostęp zostaje odebrany. Brak stale odtwarzanych starych klatek udających LIVE. | ODŁOŻONE |
| G14 | Zamknięcie zgłoszenia i aplikacji autora przy próbie docelowej transmisji. | Jeżeli wdrożono niezależne źródło, B nadal otrzymuje aktualny obraz do końca udostępniania. Obecny relay klatek telefonu tego nie potwierdza. | ODŁOŻONE; źródło niezależne do przygotowania |
| G15 | Odłączenie zasilania kamery, przerwa Wi-Fi, powrót zasilania i ewentualna zmiana IP. | Status traci potwierdzenie, odbiornik ponawia i wraca do pracy; nie trzeba usuwać i dodawać kamery. | ODŁOŻONE |
| G16 | Bridge działa, ale nie może połączyć się z kamerą; później przestaje wysyłać heartbeat. | Nie pojawia się fałszywy aktywny monitoring. Wygasłe potwierdzenie kamery po 90 sekundach nie utrzymuje zielonego statusu. | ODŁOŻONE |
| G17 | Dwie kamery mają włączony ruch, potem wyłączamy lub usuwamy jedną. | Każda ma własny prawdziwy stan; nie ma mylenia zdjęć ani globalnego wyłączenia drugiej. Limit odbiornika telefonu nie jest ukrywany jako pełne działanie obu. | ODŁOŻONE |
| G18 | Ruch, historia, alert i zgłoszenie przy wyłączonych opcjonalnych dodatkach AI. Osobno osoba i pojazd, jeśli sprzęt/odbiornik ma ich obsługę. | Darmowa podstawa działa. Nazwa wykrytej klasy odpowiada rzeczywistości; sam ruch nie jest automatycznie oznaczany jako osoba. | ODŁOŻONE |
| G19 | Motorola: powtórzenie G02–G18 dla faktycznie dostępnych funkcji, z zamkniętym Hubble i bez tunelu ADB. | Własny wynik zgodności Motoroli, bez uznania jej za działającą tylko dlatego, że działa chińska kamera. | ODŁOŻONE |
| G20 | Po zaliczeniu prób podstawowych: kilka godzin działania bez interakcji i następnie próba przez noc. | Zdarzenia nadal zapisują się we właściwym czasie; brak narastających opóźnień, ciągłych restartów i fałszywego statusu ochrony. | ODŁOŻONE |

## Jak wykonamy próbę

Najpierw wykonujemy G01 oraz G03–G10 na już dodanej chińskiej kamerze.
G02 robimy jako osobny test kreatora; nie wymaga resetowania kamery przed
każdą próbą. Dopiero po potwierdzeniu podstaw przechodzimy do zgłoszeń,
awarii i dwóch kamer. Motorola ma osobny wynik. Próba przez noc jest
ostatnia, po krótszych scenariuszach.

G07 i G08 są warunkiem potwierdzenia monitoringu niezależnego od telefonu.
Jeśli nie ma osiągalnego odbiornika, wpisujemy **BLOKADA** i wracamy do
połączenia kamery; nie zastępujemy tego otwarciem LIVE na Xiaomi.
Udane testy emulatorów również nie zaliczają tych scenariuszy.

Dla błędu zapisujemy: ID testu, wersję aplikacji, model kamery, godzinę,
widoczny komunikat, ID zdarzenia/zgłoszenia i krótki fragment odpowiednich
logów. Zapisujemy czas od ruchu do zdarzenia i do powiadomienia, zamiast
zakładać, że dotarły natychmiast. Nie kopiujemy haseł, tokenów ani pełnych
adresów strumieni z danymi logowania.

## Warunek przejścia do pilotażu i Blaze

Najpierw muszą przejść krytyczne scenariusze dla modelu, który ma być
ogłoszony jako obsługiwany: prawdziwy ruch bez otwartego telefonu, właściwy
alert, rzeczywiste materiały, prywatność i powrót po utracie połączenia.
Ograniczenia transmisji i obsługi danego modelu pozostają jawne.
Po tym przygotowujemy osobne wdrożenie backendu na Blaze i ponawiamy
przepływ na środowisku pilotażowym. Ten dokument nie uruchamia płatnego
planu, wdrożenia ani resetu kamer.
