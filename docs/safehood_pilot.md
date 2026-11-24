# SafeHood: przygotowanie pilotażu

Pakiet 23.11.2026 przygotowuje lokalny przepływ. Nie uruchamia płatnego
planu ani wdrożenia. Kontynuujemy na istniejących kamerach, Xiaomi i emulatorze
Androida z osobnym kontem sąsiada.

## Najpierw próba lokalna

1. Pobrać gałąź `codex/unify-camera-wizard`, uruchomić
   `node tools/setup_vscode_tasks.cjs`, a w VS Code zadanie
   `SafeHood - Start Dev Stack`. Flutter uruchomić swoim zadaniem Android.
2. Firebase wczytuje ostatni pełny zapis. Starsze `emulator-data` jest
   pierwszym źródłem, gdy nie ma jeszcze nowych kopii. Nie wybieramy
   automatycznie losowego historycznego eksportu ani nie resetujemy kont.
   Kopie trafiają do ignorowanego `.safehood-dev`; pozostaje sześć ostatnich
   kompletnych zapisów. Zapis odbywa się co minutę i przy kończeniu pracy.
3. Przy już włączonym wykrywaniu nie otwierać LIVE, tylko wykonać G04–G10
   z `safehood_acceptance_test.md`. Osobno sprawdzić telefon zminimalizowany,
   wyłączony i poza Wi-Fi. Zanotować faktyczną godzinę ruchu i alertu.
4. Wykonać zgłoszenie na koncie A, odebrać na B. Autor włącza udostępnienie
   obrazu. Sprawdzić G11–G14, zatrzymanie i wygaśnięcie udostępnienia.
5. Zanik zasilania i sieci, dwie kamery oraz nocna próba kończą akceptację.
   Każdy model ma swój wynik; Motorola nie dziedziczy wyniku chińskiej kamery.

Wpis bez stabilnego UUID nie daje podstawy do automatycznej zmiany IP.
Na takim urządzeniu najpierw ustalamy tożsamość w kreatorze i potwierdzamy
obraz; nazwa „NVT”, marka czy kolejny adres nie wystarczają.

## Darmowa podstawa

Ruch, prywatna historia z rzeczywistymi materiałami, alert właściciela,
zgłoszenia i społeczność pozostają podstawą produktu. Osoby i pojazdy są
oznaczane tylko na podstawie rzeczywistego wykrycia z kamery lub działającego
modelu. Różnica klatek rozpoznaje ruch, nie klasę obiektu.

Opcjonalne płatne dodatki to późniejsze wyszukiwanie po opisie, podsumowania
i bardziej rozbudowane reguły. Techniczne użycie modelu do podstawowej
klasyfikacji samo w sobie nie oznacza płatnej funkcji. Pakiet nie dodaje
rozliczeń ani nie wiąże podstawowych zdarzeń z wykupieniem dodatku AI.

## Osobne wdrożenie po akceptacji

1. Oddzielić projekt pilotażu od emulatorów i produkcji. Sprawdzić konfigurację
   Auth, Firestore, Storage, region Functions i konfigurację aplikacji.
   Przed migracją zrobić eksport i sprawdzić jego odtworzenie.
2. Potwierdzić działającą drogę kamera → odbiornik → backend. Blaze nie tworzy
   dostępu do lokalnego IP. Bridge musi pozostać uruchomiony i osiągać kamerę,
   chyba że konkretny model ma potwierdzoną niezależną integrację producenta.
3. Skonfigurować osobne poświadczenia odbiornika, reguły dostępu i retencję.
   Materiały pozostają prywatne; uczestnicy widzą tylko udostępnione zgłoszenie.
   Uwzględnić wygasanie `incidentLiveGrants.expiresAt` i sprzątanie mediów.
4. Ustalić budżet pilotażu, alerty kosztowe, limity instancji i retencję na
   podstawie pomiarów. Alert budżetowy nie jest twardym limitem wydatków.
   Zmierzyć zapis materiałów, odczyty historii, transfer i zapisy transmisji.
5. Wdrożyć backend i reguły na projekt pilotażu, następnie sprawdzić cały
   przepływ na dwóch kontach z aplikacją korzystającą z tego projektu.
   Zachować możliwość powrotu do poprzedniej wersji; nie usuwać emulatorów.

Obecny podgląd zgłoszenia jest ograniczonym relayem JPEG: do 1 klatki/s,
do 320 px, bez dźwięku, najwyżej 10 minut po decyzji autora. Klipy i prywatne
zdjęcia mają osobne większe rozdzielczości. Płynna transmisja dla większej
liczby uczestników wymaga osobnej ścieżki wideo i pomiarów; nie należy jej
utożsamiać z obecnym relayem ani oznaczać jako przetestowanej.
