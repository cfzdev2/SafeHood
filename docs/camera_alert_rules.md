# Reguły alertów kamery

## Cel

Historia zdarzeń ma pozostać kompletna, ale telefon nie powinien wysyłać kilku
powiadomień o tej samej scenie. Użytkownik może dodatkowo ograniczyć częstość
alertów bez wyłączania analizy, zdjęć i nagrań.

## Reguły

- Jedno zagregowane zdarzenie może uruchomić najwyżej jeden alert.
- Wyłączenie alertów ruchu nie blokuje ważniejszego alertu osoby lub pojazdu.
  Jeśli zdarzenie zaczęło się jako ruch bez powiadomienia, późniejsze wykrycie
  włączonego typu może wysłać jego jedyny alert.
- Powtórzenie tego samego `externalEventId` nie wysyła kolejnego alertu.
- Odstęp między alertami jest ustawiany osobno dla każdej kamery. Dostępne
  wartości to: brak dodatkowego odstępu, 30 sekund, 1 minuta, 5 minut i
  15 minut.
- Limit działa niezależnie dla grup: obraz (ruch, osoba, pojazd), dźwięk oraz
  sabotaż. Alert dźwięku nie jest blokowany przez świeży alert osoby.
- Cooldown ogranicza wyłącznie powiadomienia. Nowe zdarzenia, zdjęcia, nagrania
  i metadane AI nadal są zapisywane.

## Zgodność

Starsze kamery i aplikacje bez pola `cooldownSeconds` zachowują poprzednie
działanie, czyli brak dodatkowego odstępu. Starsze aktywne zdarzenie bez stanu
powiadomienia nie otrzyma powtórnego alertu po wdrożeniu.

## Dane

Ustawienia kamery przechowują `notificationSettings.cooldownSeconds`.
Dozwolone wartości to `0`, `30`, `60`, `300` i `900`.

Zdarzenie ma wewnętrzne pole `notificationState`, które zapisuje wersję stanu,
czas decyzji o wysłaniu i typ alertu. Dokument `cameraEventStates` zachowuje
ostatni czas alertu osobno dla każdej grupy agregacji.

## Weryfikacja

Testy obejmują:

- przejście z wyłączonego ruchu do włączonej osoby,
- najwyżej jeden alert dla zdarzenia z pojazdem i osobami,
- brak utraty zdarzeń podczas aktywnego cooldownu,
- ponowny alert po upływie wybranego odstępu,
- niezależne limity obrazu, dźwięku i sabotażu,
- walidację ustawień przez model aplikacji oraz reguły Firestore.

Godziny ciszy wymagają jawnej strefy czasowej użytkownika i są osobnym etapem.
