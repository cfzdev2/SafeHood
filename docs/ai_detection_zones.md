# Strefy wykrywania lokalnego AI

## Zachowanie

- Każda kamera może mieć do 4 stref aktywnych i do 4 obszarów ignorowanych.
- Brak stref aktywnych oznacza analizę całego obrazu.
- Obszar ignorowany zawsze ma pierwszeństwo przed strefą aktywną.
- O przynależności obiektu decyduje dolny środek jego ramki. Ten punkt najlepiej
  odpowiada miejscu, w którym osoba albo pojazd znajduje się na podłożu.
- Odrzucona detekcja nie trafia do trackera, więc nie tworzy zdarzenia, zdjęcia,
  nagrania ani powiadomienia.

## Współrzędne

Strefy są prostokątami zapisanymi jako `left`, `top`, `width` i `height` w
zakresie od 0 do 1. Odnoszą się do kwadratowego wejścia modelu 416 × 416.
Edytor mobilny pokazuje zdjęcie z takim samym dopasowaniem do lewego górnego
rogu i takim samym szarym wypełnieniem jak proces FFmpeg w Bridge.

Minimalna szerokość i wysokość strefy wynosi 0,02 obrazu. Aplikacja, reguły
Firestore, backend i Bridge niezależnie walidują konfigurację. Uszkodzona
konfiguracja otrzymana przez backend wyłącza AI danej kamery, zamiast rozszerzyć
analizowany obszar.

## Przepływ konfiguracji

1. Aplikacja zapisuje `aiDetectionZones` i `aiIgnoreZones` w dokumencie kamery.
2. Reguły Firestore sprawdzają właściciela, liczbę stref i ich geometrię.
3. `getBridgeConfiguration` normalizuje dane i przekazuje je właściwemu Bridge.
4. Zmiana stref zmienia fingerprint sesji i bezpiecznie restartuje analizę.
5. `CameraAiSession` filtruje detekcje przed aktualizacją `ObjectTracker`.

## Test ręczny

1. Uruchom emulatory, testowy RTSP, Bridge i aplikację.
2. Wejdź w ustawienia kamery, następnie **Analiza AI → Strefy wykrywania**.
3. Dodaj czerwoną strefę na osobie lub autobusie i zapisz.
4. Zaczekaj na restart sesji Bridge. Licznik `detectionsZoneRejected` powinien
   rosnąć, a nowe zdarzenie dla obiektu w czerwonej strefie nie powinno powstać.
5. Przesuń obszar poza obiekt albo dodaj obejmującą go zieloną strefę. Po
   ponownym zapisie powinno pojawić się zwykłe zdarzenie ze zdjęciem i — jeśli
   nagrywanie jest włączone — filmem.
