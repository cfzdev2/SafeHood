# Java dla zadań Firebase

Zadanie `SafeHood - Firebase` automatycznie wybiera działającą Javę 21 lub
nowszą. Sprawdza `JAVA_HOME`, `JDK_HOME`, `STUDIO_JDK`, PATH, środowisko
dołączone do Android Studio oraz typowe instalacje JDK w Windows.
Obsługuje także inną lokalizację Android Studio zapisaną w rejestrze.

Wybrany katalog `bin` trafia do PATH procesu Firebase i jego procesów
potomnych. Skrypt nie modyfikuje globalnych zmiennych ani wpisów rejestru
i nie pobiera oprogramowania. Błąd Javy jest zgłaszany przed utworzeniem
blokady uruchomienia lub rozpoczęciem pracy emulatorów.

Samą diagnostykę uruchomisz z katalogu projektu:

```bash
node tools/dev_java.cjs
```

Poprawny wynik zawiera wersję oraz lokalizację Javy. Jeśli skrypt nie znajdzie
odpowiedniego środowiska, sprawdź `flutter doctor -v` i instalację Android
Studio/JDK. Skrypt podaje osobny komunikat również wtedy, gdy znajduje
wyłącznie starszą wersję. Pełny zestaw kontroli oraz test zachowania danych
Firebase korzystają z tego samego wyboru Javy.
