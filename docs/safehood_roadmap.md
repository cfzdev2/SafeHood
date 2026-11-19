# SafeHood: darmowa podstawa i dalsze prace

SafeHood ma działać także dla osoby, która nie ma kamery: może zgłosić
zdarzenie, zobaczyć zgłoszenia w okolicy i odbierać alerty od sąsiadów.
Dodawanie obsługiwanej kamery zaczyna się od zasilania, telefonu i domowego
Wi-Fi. Kreator wybiera sposób połączenia i potwierdza go obrazem.

| Obszar | Darmowy plan | Opcjonalny Plus |
| --- | --- | --- |
| Kamery | Podgląd i status, wykrywanie ruchu, osób i pojazdów, alerty dla właściciela, krótka historia ze zdjęciami. | Dłuższa historia nagrań w chmurze. |
| Okolica | Tworzenie zgłoszeń, odbieranie alertów od sąsiadów i zgłoszenie problemu z poziomu zdarzenia kamery. | Funkcje społeczności pozostają darmowe. |
| Analiza | Klasyfikacja podstawowych zdarzeń, także gdy wymaga modelu AI. | Szukanie po opisie, podsumowania i bardziej szczegółowe reguły. |

Podstawową funkcję nazywamy **Wykrywanie**. Sprzęt i dostęp do obrazu
decydują, czy działa tylko podgląd, wykrywanie podczas oglądania czy
monitoring 24/7. Dla modeli, które nie dostarczają odpowiednich zdarzeń,
całodobowe wykrywanie wymaga działającego źródła obrazu i Bridge albo
innej potwierdzonej integracji. To warunek techniczny, niezależny od planu.

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
