# fritzing-build

Skrypty budowania programu **Fritzing 1.0.8** (Windows x64, macOS arm64 i x86_64) używanego w kursie
*Budowa systemów Internetu Rzeczy* do dokumentowania układów. Wynik: program **niepodpisany**
(macOS: bez notaryzacji Apple), z symulatorem ngspice 42.

Źródła i ich wersje są przypięte w [`versions.lock.json`](versions.lock.json):
Fritzing app `5aa56a5` (1.0.8), fritzing-parts `27535f2`, Qt 6.8.3, boost 1.85.0, libgit2 1.7.1,
quazip 1.4, svgpp 1.3.1, clipper 6.4.2, zlib 1.3.1, ngspice 42.

## Budowanie w GitHub Actions

Workflow [`build.yml`](.github/workflows/build.yml) (*Actions → Build unsigned Fritzing → Run workflow*)
buduje trzy warianty i udostępnia je jako artefakty przebiegu:

| Artefakt | System |
|:--|:--|
| `fritzing-windows-x64` | Windows 10/11, 64-bit |
| `macos-arm64` | macOS na procesorach Apple (M1 i nowsze) |
| `macos-x86_64` | macOS na procesorach Intel |

## Budowanie lokalnie

- macOS: [`LOCAL-MACOS-BUILD.md`](LOCAL-MACOS-BUILD.md) — `./build-local-macos.command`
- Windows: [`LOCAL-WINDOWS-BUILD.md`](LOCAL-WINDOWS-BUILD.md) — `build-local-windows.cmd`

Części płytek kursu ([`parts/dist`](parts/dist): Arduino Nano ESP32 ABX00083, M5Stamp C3U Mate K122 —
bez widoku PCB) są wbudowane w program: [`scripts/add-course-parts.py`](scripts/add-course-parts.py) dodaje je
do `fritzing-parts/contrib` z zakładką „Kurs IoT” (`bins/more/kurs-iot.fzb`) przed wygenerowaniem `parts.db`.
Dodawane są tylko nowe pliki, więc „Sprawdź aktualizacje części” ich nie usuwa. Lokalne skrypty dokładają
ponadto katalog `custom-parts/` z paczkami `.fzpz` do ręcznego importu w innych wersjach Fritzinga.

## Pierwsze uruchomienie na macOS

Aplikacja nie jest notaryzowana, więc macOS ją zablokuje. Po rozpakowaniu: kliknij `Fritzing.app`
prawym przyciskiem → *Otwórz* → *Otwórz*, albo w Terminalu:

```
xattr -dr com.apple.quarantine /ścieżka/do/Fritzing.app
```

## Licencje

Fritzing — GNU GPL v3 (https://github.com/fritzing/fritzing-app); biblioteka części Fritzing — CC BY-SA;
części kursu w `parts/` — CC BY-SA 4.0 ([`parts/LICENSE.txt`](parts/LICENSE.txt)); ngspice — licencja
projektu ngspice; Qt 6 — LGPL v3. To repozytorium zawiera wyłącznie skrypty budowania i części kursu,
nie kod Fritzinga. Gotowe paczki dla studentów kursu: repozytorium `iot-marekurbaniak/materialy`
(dla członków organizacji).
