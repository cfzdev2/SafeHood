# Agregacja zdarzeń kamery

## Cel

Agregacja łączy wiele bliskich wykryć w jeden czytelny wpis historii. Ogranicza
liczbę powiadomień, zdjęć i nagrań, ale nie może ukrywać innego rodzaju
aktywności ani utrzymywać jednego zdarzenia bez końca.

## Reguły

- Ruch, osoba i pojazd należą do wspólnej grupy wizualnej. Przykładowo autobus
  i osoby wykryte na tej samej scenie tworzą jeden wpis z podsumowaniem AI.
- Dźwięk ma własną oś agregacji i nie znika w zdarzeniu wizualnym.
- Sabotaż kamery ma własną oś agregacji i nie jest scalany z ruchem ani
  dźwiękiem.
- Kolejne wykrycie scala się z aktywnym zdarzeniem swojej grupy, gdy odstęp od
  poprzedniego wykrycia nie przekracza 15 sekund.
- Jedno zdarzenie może obejmować maksymalnie 2 minuty. Dalsza ciągła aktywność
  rozpoczyna nowy wpis, dzięki czemu powstaje świeży materiał i kolejny alert.
- Zdarzenie oznaczone jako inne niż `new` lub `viewed` nie jest ponownie
  otwierane.
- Powtórzona wysyłka tego samego `externalEventId` nadal zwraca wcześniejsze
  potwierdzenie i nie zwiększa liczników.

## Zgodność

Grupa wizualna zachowuje istniejące pola `activeEventId` i `lastReceivedAt` w
`cameraEventStates`. Dźwięk i sabotaż używają osobnych pól w tym samym
dokumencie, więc nie jest wymagana migracja ani dodatkowe sprzątanie przy
usuwaniu kamery lub konta.

## Weryfikacja

Testy backendu sprawdzają:

- wspólny wpis dla ruchu, osoby i pojazdu,
- osobne wpisy i stany dla dźwięku oraz sabotażu,
- rozpoczęcie nowego zdarzenia po przekroczeniu dwóch minut,
- zachowanie okna ciszy, dawnych czasów, kolejki Bridge i idempotencji UUID,
- brak podwójnych powiadomień podczas ponowienia tej samej wysyłki.

Test ręczny ze strumieniem autobusu i osób powinien nadal zakończyć się jednym
zdarzeniem wizualnym, jednym zdjęciem i jednym nagraniem. Cztery potwierdzone
ślady mogą zwiększyć `occurrenceCount` oraz podsumowanie AI, ale nie tworzą
czterech osobnych alertów.

## Powiązane reguły alertów

Agregację uzupełniają reguły opisane w `camera_alert_rules.md`: pojedynczy
alert dla jednego wpisu, eskalacja z wyłączonego ruchu do włączonej osoby oraz
konfigurowalny odstęp pomiędzy kolejnymi alertami.
