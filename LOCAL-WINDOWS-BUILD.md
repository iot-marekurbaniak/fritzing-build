# Lokalny build Windows x64 — bez GitHub

Ta instrukcja opisuje, jak zbudować Fritzing 1.0.8 (Windows x64, wersja niepodpisana) w całości na
własnym komputerze: bez GitHub Actions, bez wysyłania czegokolwiek do sieci poza pobraniem
oficjalnych źródeł i Qt. Wszystko robi jeden skrypt: `scripts/build-local-windows.ps1`.

Workflow GitHub (`.github/workflows/build.yml`) zostaje w zestawie jako opcja alternatywna, ale nie
jest do niczego potrzebny.

## Co powstaje

    <katalog wyjściowy>\fritzing-windows-x64-unsigned.zip           gotowa aplikacja
    <katalog wyjściowy>\fritzing-windows-x64-unsigned.zip.sha256    suma kontrolna SHA-256
    <katalog wyjściowy>\logs\build-local-windows-<data>.log         pełny log przebiegu

W archiwum, obok `Fritzing.exe`, `fritzing-parts\` i `parts.db`, jest katalog `custom-parts\` z
czterema paczkami części tego zestawu (`.fzpz`), plikiem `IMPORT-CUSTOM-PARTS.txt` (instrukcja
importu po polsku i angielsku) oraz `LICENSE.txt` (CC BY-SA 4.0).

Aplikacja jest **niepodpisana**: przy pierwszym uruchomieniu Windows SmartScreen pokaże ostrzeżenie
(„Więcej informacji” → „Uruchom mimo to”).

## Wymagania

Sprzęt i system:

- Windows 10 lub 11, 64-bitowy;
- ok. **30 GB** wolnego miejsca na dysku, na którym będzie katalog roboczy (skrypt przerywa pracę
  poniżej 15 GB i ostrzega poniżej 30 GB);
- realny czas budowania: zwykle **1,5–3 godziny** (`nmake` kompiluje jednowątkowo), z czego
  pobranie Qt to ok. 2,5 GB.

Oprogramowanie, które musi być zainstalowane **wcześniej** — skrypt niczego nie instaluje sam i nie
zmienia systemowego `PATH`:

| Narzędzie | Po co | Instalacja (przykład) |
|---|---|---|
| Visual Studio 2022 z „Desktop development with C++” | kompilator MSVC x64, `nmake`, `cl`, `lib` | `winget install --id Microsoft.VisualStudio.2022.Community --override "--add Microsoft.VisualStudio.Workload.NativeDesktop --includeRecommended"` |
| CMake | budowa zlib, libgit2, QuaZip | `winget install --id Kitware.CMake` (albo CMake z Visual Studio — skrypt go znajdzie) |
| Git | pobranie `fritzing-app` i `fritzing-parts` | `winget install --id Git.Git` |
| Python 3.8+ | instalacja Qt przez `aqtinstall` | `winget install --id Python.Python.3.12` |
| 7-Zip | spakowanie dystrybucji | `winget install --id 7zip.7zip` |
| `curl.exe`, `tar.exe` | pobranie i rozpakowanie zależności | wbudowane w Windows 10 1803+ |

Uwagi:

- Wersje Qt (6.8.3), `aqtinstall` (3.3.0), commity `fritzing-app` i `fritzing-parts` oraz adresy
  źródeł biorą się z `versions.lock.json` — skrypt nie ma ich wpisanych na sztywno.
- Skrypt sam znajdzie CMake dołączony do Visual Studio, Git i 7-Zip w domyślnych katalogach
  instalacyjnych; dopisuje je wtedy do `PATH` **tylko własnego procesu**.
- „Python” z Microsoft Store (zaślepka w `WindowsApps`) nie jest akceptowany — nie potrafi
  utworzyć środowiska wirtualnego.
- Jeżeli czegoś brakuje, skrypt wypisuje **listę wszystkich braków razem z poleceniem naprawy** i
  kończy pracę kodem 3, zanim cokolwiek pobierze.

## Jedno polecenie

W `cmd.exe` (albo dwuklikiem w Eksploratorze) z katalogu zestawu:

    build-local-windows.cmd

W PowerShell (Windows PowerShell 5.1 lub PowerShell 7):

    powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\build-local-windows.ps1

Domyślnie:

- katalog roboczy: `%USERPROFILE%\fritzing-build` (Qt, źródła, zależności, pliki pośrednie),
- katalog wyjściowy: `out\` w katalogu zestawu.

Inne katalogi (ścieżki ze spacjami są obsługiwane):

    build-local-windows.cmd -WorkDir "D:\fritzing build" -OutDir "D:\fritzing wynik"

Gotowe Qt można wskazać zamiast pobierać nowe — przez parametr albo zmienną `QT_ROOT`:

    build-local-windows.cmd -QtRoot "D:\Qt\6.8.3\msvc2022_64"

Skrypt sprawdza, czy takie Qt jest kompletne (qmake, lrelease, windeployqt, Qt6Svg, Qt6Core5Compat,
Qt6SerialPort). Jeżeli nie jest, pobiera własne Qt do katalogu roboczego i o tym informuje.

## Gdzie jest wynik

Na końcu skrypt wypisuje podsumowanie, na przykład:

    =============================== BUILD FINISHED ===============================
    Artifact   : C:\...\out\fritzing-windows-x64-unsigned.zip (312.4 MB)
    SHA-256    : 9f2c...
                 C:\...\out\fritzing-windows-x64-unsigned.zip.sha256
    Custom part: custom-parts\ in the archive (4 packages, IMPORT-CUSTOM-PARTS.txt)
    Log        : C:\...\out\logs\build-local-windows-20260908-131500.log
    Work dir   : C:\Users\...\fritzing-build

Rozpakuj archiwum w dowolnym miejscu i uruchom `Fritzing.exe`. Sumę kontrolną można sprawdzić:

    certutil -hashfile out\fritzing-windows-x64-unsigned.zip SHA256

Części z katalogu `custom-parts\` importuje się w Fritzingu przez `Plik ▸ Otwórz…` i wskazanie
pliku `.fzpz` (szczegóły i drugi sposób: `IMPORT-CUSTOM-PARTS.txt` w tym katalogu).

## Wznowienie po przerwaniu lub błędzie

Uruchom **to samo polecenie jeszcze raz**. Nic nie jest pobierane ani budowane od zera:

- kompletne Qt w katalogu roboczym (lub wskazane przez `-QtRoot`) jest używane bez pobierania,
- `aqtinstall` w środowisku wirtualnym jest instalowany tylko, gdy brakuje przypiętej wersji,
- `bootstrap-windows.ps1` pomija istniejące źródła i zbudowane zależności,
- `nmake` kompiluje tylko to, co się zmieniło.

Dodatkowe przełączniki:

| Przełącznik | Działanie |
|---|---|
| `-ForceQtInstall` | usuwa Qt z katalogu roboczego i instaluje je od nowa |
| `-SkipBootstrap` | pomija pobieranie źródeł i zależności (praca bez sieci; wymaga, aby były już w katalogu roboczym) |
| `-SkipBuild` | pomija kompilację i tylko przepakowuje wynik poprzedniego builda z `custom-parts\` |

Przykład szybkiego przepakowania bez kompilacji:

    build-local-windows.cmd -SkipBootstrap -SkipBuild

## Usunięcie katalogu roboczego

Katalog roboczy zajmuje kilkanaście GB i po skopiowaniu archiwum nie jest potrzebny. Usunięcie
(PowerShell):

    Remove-Item -LiteralPath "$env:USERPROFILE\fritzing-build" -Recurse -Force

albo w `cmd.exe`:

    rmdir /s /q "%USERPROFILE%\fritzing-build"

Katalog wyjściowy (`out\`) z archiwum, sumą SHA-256 i logami zostaje nietknięty. Następny build po
usunięciu katalogu roboczego pobierze i zbuduje wszystko od nowa.

## Co robi skrypt, krok po kroku

1. **Prerekwizyty** — system, wolne miejsce, komplet plików zestawu, 7-Zip, Git, CMake, `curl`,
   `tar`, Python (tylko gdy trzeba instalować Qt) i MSVC (przez `scripts/msvc-env.ps1`, w osobnym
   procesie). Braki są raportowane razem, przed jakimkolwiek pobieraniem.
2. **Qt** — jeżeli `-QtRoot`/`QT_ROOT` nie wskazuje kompletnego Qt, powstaje środowisko wirtualne
   `<katalog roboczy>\aqt-venv`, instalowany jest w nim `aqtinstall==3.3.0` (wersja z locka) i
   wywoływane `python -m aqt install-qt windows desktop 6.8.3 win64_msvc2022_64 --outputdir
   <katalog roboczy>\Qt --modules qt5compat qtserialport`.
3. **Źródła i zależności** — `scripts/bootstrap-windows.ps1` (te same, sprawdzone skrypty, których
   używa workflow GitHub): płytkie klony przypięte do commitów z locka oraz boost, svgpp, ngspice
   (nagłówki), zlib, libgit2, QuaZip i Clipper1.
4. **Kompilacja** — `scripts/build-windows.ps1`: `lrelease`, `qmake`, `nmake release`,
   `windeployqt`, kompletowanie katalogu dystrybucji, generacja `parts.db` i spakowanie do ZIP.
   W trakcie generowania bazy części na chwilę uruchamia się `Fritzing.exe` — to normalne.
5. **Części dodatkowe** — cztery `.fzpz` z `parts/dist`, `IMPORT-CUSTOM-PARTS.txt` i `LICENSE.txt`
   trafiają do katalogu `custom-parts\`.
6. **Archiwum końcowe** — kopia ZIP-a z builda plus `custom-parts\`, dopisane 7-Zipem; skrypt
   otwiera gotowe archiwum i sprawdza, że są w nim `Fritzing.exe`, `fritzing-parts/parts.db` i
   wszystkie części.
7. **SHA-256** — plik `.sha256` w formacie zgodnym z `sha256sum -c`.

Log całego przebiegu (razem z komunikatami narzędzi) trafia do `out\logs\`.

## Kody wyjścia

| Kod | Znaczenie |
|---|---|
| 0 | sukces |
| 1 | błąd w trakcie budowania (szczegóły w logu) |
| 2 | uruchomiono nie na Windows |
| 3 | brakuje prerekwizytu; nic nie zostało pobrane |

## Typowe problemy

- **„nie można załadować pliku ... ponieważ w tym systemie zablokowano wykonywanie skryptów”** —
  uruchom przez `build-local-windows.cmd` albo dodaj `-ExecutionPolicy Bypass` do polecenia
  `powershell`. Skrypt nie zmienia globalnej polityki wykonywania.
- **Visual Studio jest, a skrypt go nie widzi** — potrzebny jest komponent „Desktop development
  with C++” (`Microsoft.VisualStudio.Component.VC.Tools.x86.x64`); doinstaluj go w Visual Studio
  Installer. Skrypt cytuje w komunikacie dokładny błąd z `scripts/msvc-env.ps1`.
- **Błędy o zbyt długich ścieżkach** — użyj krótkiego katalogu roboczego, np.
  `-WorkDir C:\fritzing-build`. Skrypt ostrzega, gdy ścieżka jest dłuższa niż 60 znaków.
- **Program antywirusowy spowalnia build** — katalog roboczy można dodać do wykluczeń; to decyzja
  użytkownika, skrypt niczego w ustawieniach nie zmienia.
- **Build przerwany** — po prostu uruchom polecenie ponownie, patrz „Wznowienie”.
- **Symulacja SPICE nie działa** — biblioteka `ngspice.dll` nie jest budowana ani dołączana; to
  znane ograniczenie zestawu (patrz `README.md`).

## Czego ta ścieżka nie robi

- niczego nie publikuje, nie wysyła i nie wymaga konta GitHub (pobierane są tylko publiczne źródła
  i pakiety Qt),
- nie podpisuje binariów (brak certyfikatu — archiwum jest oznaczone jako `unsigned`),
- nie instaluje kompilatora, CMake, Gita, Pythona ani 7-Zipa i nie zmienia systemowego `PATH`,
- nie zmienia przypiętych wersji z `versions.lock.json` ani definicji części.
