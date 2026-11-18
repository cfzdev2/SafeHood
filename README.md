# safehood

A new Flutter project.

## Getting Started

This project is a starting point for a Flutter application.

A few resources to get you started if this is your first Flutter project:

- [Learn Flutter](https://docs.flutter.dev/get-started/learn-flutter)
- [Write your first Flutter app](https://docs.flutter.dev/get-started/codelab)
- [Flutter learning resources](https://docs.flutter.dev/reference/learning-resources)

For help getting started with Flutter development, view the
[online documentation](https://docs.flutter.dev/), which offers tutorials,
samples, guidance on mobile development, and a full API reference.

## Start w VS Code

Jeśli masz już lokalne zadanie `SafeHood - Firebase` w `.vscode/tasks.json`,
uruchom z katalogu repozytorium:

```bash
node tools/setup_vscode_tasks.cjs
```

Skrypt zachowa zadanie Firebase wraz z jego opcjami importu i zapisu danych,
zachowa konfigurację Fluttera i zrobi kopię starego pliku zadań.
`SafeHood - Start Dev Stack` uruchamia Firebase i Bridge z bieżącego
repozytorium przy otwarciu folderu. Bridge wystartuje po sprawdzeniu zapisanej
konfiguracji parowania w lokalnych emulatorach. Kamery testowe, MediaMTX,
strumień testowy i Flutter są dostępne osobno przez **Tasks: Run Task**.

Jeśli poprzednie zadania jeszcze działają, zatrzymaj je przed uruchomieniem
nowego zestawu. W terminalu Firebase użyj `Ctrl+C` i zaczekaj na eksport,
jeśli zadanie używa `--export-on-exit`. Potem wybierz **Tasks: Run Task →
SafeHood - Start Dev Stack**.
