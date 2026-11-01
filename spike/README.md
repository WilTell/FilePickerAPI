# Пробная сборка MSI

Черновая проверка для изменения `openspec/changes/user-logon-autostart` (задачи 1.5 и 1.6) до реализации. Приложение не собирается: проверяется только то, на чём держится план.

- `probe_pkg/__main__.py` — пробный exe: режим консоли `attach`, скрытое окно, консольный обработчик, `RegisterApplicationRestart`, событие остановки; каждый шаг пишет в `C:\ProgramData\FilePickerProbe\probe.jsonl`.
- `probe.wxs` — пакет по таблице «Содержимое MSI» из `design.md` плюс пробный отказ `PROBEFAIL`.
- `patch_resources.py` — правка ресурсов копии до подписи через `UpdateResource`.
- `tool.py` — ввод в чужую консоль, Ctrl+C, закрытие окна консоли, чтение экрана.
- `msi-probe.ps1` — сценарии: `basic`, `rm-admin`, `rm-system`, `rm-other-user`, `crash`.
- `.github/workflows/spike-msi-probe.yml` — сборка и запуск, результаты в артефактах `results-<сценарий>`.

После проверки выводы переносятся в `design.md`, а эта папка и воркфлоу удаляются.
