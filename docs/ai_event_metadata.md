# SafeHood: bogatsze metadane zdarzeń AI

Ten etap rozszerza nowe wykrycia lokalnego AI o informacje używane przez
docelową aplikację mobilną. Łatka jest przygotowana na commit `423111b`
z gałęzi `main` i zawiera wcześniejsze założenia dotyczące prywatnych zdjęć,
trwałego outboxa oraz nagrań zdarzeń.

## Co dostaje użytkownik

- Historia pokazuje osobno liczbę osób i pojazdów rozpoznanych w zdarzeniu.
- Szczegóły zdarzenia pokazują dokładne klasy: osoby, rowery, samochody,
  motocykle, autobusy i ciężarówki.
- Widoczne są najwyższa pewność wykrycia, czas aktywności, godzina pierwszego
  i ostatniego wykrycia oraz łączna liczba klatek potwierdzających obiekty.
- Starsze zdarzenia i starszy Bridge nadal działają. Dla danych bez nowego pola
  aplikacja zachowuje dotychczasowy wygląd i licznik wykryć.

Liczby oznaczają unikalne ślady potwierdzone przez tracker w ramach zdarzenia.
Nie są gwarantowaną liczbą różnych osób: obiekt, który zniknie i wróci, może
otrzymać nowy ślad. Nie zapisujemy prostokątów detekcji, ponieważ zdjęcie jest
pobierane później i pozycja prostokąta nie musi już pasować do obrazu.

## Przepływ i bezpieczeństwo

Bridge zapisuje razem z tym samym UUID zdarzenia klasę, liczbę klatek, zakres
czasu oraz identyfikator zweryfikowanego modelu
`yolox-nano-coco-c789161e`. Dane przechodzą przez trwały outbox, więc restart
nie zmienia ich i nie tworzy drugiego obiektu.

Backend akceptuje metadane wyłącznie od uwierzytelnionego Bridge dla źródła
`local-ai`. Sprawdza typ, klasę, model, czas i liczniki, a potem agreguje je
w transakcji Firestore. Retry tego samego UUID nie zwiększa liczników.
Zachowana jest również zgodność z potwierdzeniami utworzonymi przed tą łatką.
Reguły Firestore pozwalają właścicielowi odczytać podsumowanie, ale nie
pozwalają aplikacji samodzielnie go dopisać ani zmienić.

Zapisane pole `aiMetadata` ma wersję schematu 1 i zawiera liczbę obiektów,
osób i pojazdów, liczniki klas, maksymalną pewność, pierwszy i ostatni czas,
sumę klatek potwierdzających oraz listę modeli. Identyfikator modelu jest
dostępny diagnostycznie, ale nie jest pokazywany użytkownikowi w interfejsie.

## Zastosowanie łatki

Zapisz `safehood_ai_event_metadata.patch` w `~/safehood`. Punktem startowym
powinien być commit `423111b Add private AI event recordings`.

```bash
cd ~/safehood
git --no-pager log -1 --oneline
git status --short
git apply --check safehood_ai_event_metadata.patch && git apply safehood_ai_event_metadata.patch
```

Nie dodawaj do commita lokalnych zdjęć RTSP ani starszych plików `.patch`.

## Automatyczne sprawdzenie

```bash
cd ~/safehood
npm --prefix functions test
npm --prefix functions run lint
npm --prefix bridge run test:ai
npm --prefix bridge run check
npm --prefix functions run test:rules
flutter analyze
flutter test test/features/camera_events/domain/camera_event_ai_metadata_test.dart test/features/camera_events/presentation/camera_event_ai_summary_test.dart
git diff --check
```

Testy backendu sprawdzają agregację klas, zakres czasu, brak podwajania przy
retry, migrację hashy potwierdzeń i zgodność ze starszym Bridge. Testy Bridge
sprawdzają trwały zapis oraz odtworzenie metadanych z outboxa. Test reguł
Firestore potwierdza, że klient mobilny nie może sfałszować podsumowania.

## Test na telefonie

1. Uruchom emulatory i znany strumień RTSP z obrazem autobusu oraz ludzi.
2. Uruchom aplikację po `flutter analyze`, a następnie zrestartuj Bridge:

```bash
cd ~/safehood
SAFEHOOD_AI_DEBUG=true SAFEHOOD_FUNCTIONS_BASE_URL=http://127.0.0.1:5001/safehood-security-app/europe-central2 npm --prefix bridge start
```

3. Poczekaj na cztery wpisy `BRIDGE INGEST` dla nowego obrazu testowego.
4. Otwórz nowe zdarzenie w historii. Karta powinna pokazać liczbę osób
   i pojazdów, a szczegóły między nagłówkiem a zdjęciem panel **Analiza AI**.
5. Dla dotychczasowego obrazu wynik powinien zwykle obejmować autobus i osoby,
   ale dokładna liczba zależy od wyniku detektora. Film i zdjęcie mają nadal
   działać bez zmian.

Istniejące zdarzenia nie są wstecznie uzupełniane. Jeżeli nowe wykrycie scali
się ze starym zdarzeniem bez metadanych, podsumowanie obejmie tylko ślady
odebrane już po aktualizacji.

## Następny etap planu

Po zatwierdzeniu metadanych przechodzimy do stref detekcji i obszarów
ignorowanych. Później pozostają: dopracowanie agregacji, reguły alertów,
testy wielu kamer i zasobów, diagnostyka oraz testy prawdziwych kamer
ONVIF/RTSP przed wydaniem aplikacji mobilnej.
