# Lokalny build macOS — bez GitHub

Ta instrukcja opisuje, jak zbudować Fritzing 1.0.8 dla macOS w całości na własnym Macu: bez GitHub
Actions, bez wysyłania czegokolwiek do sieci poza pobraniem oficjalnych źródeł i Qt. Wszystko robi
jeden skrypt: `scripts/build-local-macos.sh`.

Build jest **natywny dla architektury tego Maca** — `arm64` (Apple silicon) albo `x86_64` (Intel).
Nie powstaje binarka universal; skrypt odmawia pracy, gdy `--arch` nie zgadza się z `uname -m`, i
gdy terminal działa pod Rosettą.

Workflow GitHub (`.github/workflows/build.yml`) zostaje w zestawie jako opcja alternatywna, ale nie
jest do niczego potrzebny.

## Co powstaje

    <katalog wyjściowy>/fritzing-macos-<arch>-unsigned.zip           gotowa aplikacja
    <katalog wyjściowy>/fritzing-macos-<arch>-unsigned.zip.sha256    suma kontrolna SHA-256
    <katalog wyjściowy>/logs/build-local-macos-<data>.log            pełny log przebiegu

W archiwum, w jego korzeniu, są obok siebie:

    Fritzing.app/                     aplikacja
    custom-parts/                     cztery paczki .fzpz + IMPORT-CUSTOM-PARTS.txt + LICENSE.txt

Wewnątrz aplikacji, oprócz tego co robi `macdeployqt`:

    Fritzing.app/Contents/MacOS/fritzing-parts/parts.db   baza części
    Fritzing.app/Contents/PlugIns/libngspice.0.dylib      biblioteka symulatora SPICE
    Fritzing.app/Contents/PlugIns/ngspice/analog.cm       modele XSPICE (i pozostałe *.cm)
    Fritzing.app/Contents/MacOS/libngspice.0.dylib        dowiązanie do ../PlugIns/…
    Fritzing.app/Contents/MacOS/ngspice                   dowiązanie do ../PlugIns/ngspice

Dlaczego akurat tam: Fritzing szuka `libngspice.0.dylib` po kolei w katalogach z
`QCoreApplication::libraryPaths()`, a potem czyta modele z katalogu `ngspice/` **obok znalezionej
biblioteki**. W spakowanej aplikacji `libraryPaths()` zawiera `Contents/PlugIns` (standardowy
katalog wtyczek pakietu oraz wpis `Plugins = PlugIns`, który `macdeployqt` zapisuje w
`Contents/Resources/qt.conf`) i `Contents/MacOS` (`applicationDirPath()`). Runtime leży fizycznie w
`Contents/PlugIns`, a dowiązania w `Contents/MacOS` sprawiają, że działa niezależnie od tego, który
z tych dwóch katalogów zostanie przeszukany pierwszy.

Aplikacja jest **niepodpisana** (albo podpisana ad hoc — patrz niżej): nie ma Apple Developer ID i
nie ma notaryzacji. Rozdział „Gatekeeper” opisuje, co z tym zrobić.

## Wymagania

Sprzęt i system:

- macOS 12 lub nowszy (`MACOSX_DEPLOYMENT_TARGET=12.0`, tak jak wymaga Qt 6.8);
- ok. **30 GB** wolnego miejsca na dysku, na którym będzie katalog roboczy (skrypt przerywa pracę
  poniżej 15 GB i ostrzega poniżej 30 GB);
- realny czas budowania: zwykle **1–2,5 godziny**, z czego pobranie Qt to ok. 2,5 GB.

Oprogramowanie, które musi być zainstalowane **wcześniej** — skrypt niczego nie instaluje sam:

| Narzędzie | Po co | Instalacja |
|---|---|---|
| Xcode Command Line Tools | `clang`, `make`, `git`, `curl`, `ditto`, `lipo`, `otool`, `install_name_tool`, `codesign`, `unzip`, `shasum` | `xcode-select --install` |
| CMake | budowa libgit2 i QuaZip | `brew install cmake` albo https://cmake.org/download/ |
| Python 3.8+ | odczyt `versions.lock.json` i instalacja Qt przez `aqtinstall` | jest w Command Line Tools; albo `brew install python` |

Czego **nie** trzeba:

- 7-Zip — na macOS pakowanie robi `ditto`, a rozpakowywanie `tar`;
- `automake`/`autoconf`/`libtool` — przypięta paczka źródeł ngspice 42 zawiera gotowy `configure`.
  Skrypt wypisuje o tym notatkę informacyjną i sięga po `brew install automake autoconf libtool`
  tylko wtedy, gdyby `configure` kiedyś zniknął ze źródeł;
- `bison`/`flex` — z tego samego powodu (parsery są wygenerowane w paczce źródeł);
- Homebrewowego `ngspice` — celowo **nie jest używany**. Runtime symulatora jest budowany ze
  źródła przypiętego w `versions.lock.json`, dla tej architektury, i ląduje w aplikacji.

Uwagi:

- Wersje Qt (6.8.3), `aqtinstall` (3.3.0), commity `fritzing-app` i `fritzing-parts`, wersja
  ngspice (42) i opcje jego `configure` biorą się z `versions.lock.json` — skrypt nie ma ich
  wpisanych na sztywno.
- Jeżeli czegoś brakuje, skrypt wypisuje **listę wszystkich braków razem z poleceniem naprawy** i
  kończy pracę kodem 3, zanim cokolwiek pobierze.

## Jedno polecenie

Najpierw, jednorazowo, nadaj prawa wykonywania (pliki skopiowane z sieci albo z ZIP-a często je
tracą):

    chmod +x build-local-macos.command scripts/*.sh

Potem, z katalogu zestawu w Terminalu:

    ./build-local-macos.command

lub równoważnie:

    bash scripts/build-local-macos.sh

`build-local-macos.command` można też uruchomić dwuklikiem w Finderze (otworzy się okno Terminala).

Domyślnie:

- katalog roboczy: `$HOME/fritzing-build` (Qt, źródła, zależności, pliki pośrednie),
- katalog wyjściowy: `out/` w katalogu zestawu.

Inne katalogi (ścieżki ze spacjami są obsługiwane, choć `qmake`/`make` ich nie lubią — skrypt
ostrzega):

    ./build-local-macos.command --work-dir "$HOME/fritzing build" --out-dir "$HOME/fritzing wynik"

Gotowe Qt można wskazać zamiast pobierać nowe — przez parametr albo zmienną `QT_ROOT`:

    ./build-local-macos.command --qt-root "$HOME/Qt/6.8.3/macos"

Skrypt sprawdza, czy takie Qt jest kompletne (`qmake`, `lrelease`, `macdeployqt`, QtSvg,
QtCore5Compat, QtSerialPort, `qmake -query QT_VERSION` = 6.8.3). Jeżeli nie jest, pobiera własne Qt
do katalogu roboczego i o tym informuje.

## Gdzie jest wynik

Na końcu skrypt wypisuje podsumowanie, na przykład:

    =============================== BUILD FINISHED ===============================
    Artifact   : /Users/<login>/.../out/fritzing-macos-arm64-unsigned.zip (486 MB)
    SHA-256    : 9f2c...
                 /Users/<login>/.../out/fritzing-macos-arm64-unsigned.zip.sha256
    Contents   : Fritzing.app (arm64) and custom-parts/ (4 packages, IMPORT-CUSTOM-PARTS.txt)
    Simulator  : Fritzing.app/Contents/PlugIns/libngspice.0.dylib with ngspice/ code models
    Signature  : none (unsigned)
    Log        : /Users/<login>/.../out/logs/build-local-macos-20260909-101500.log
    Work dir   : /Users/<login>/fritzing-build

Sumę kontrolną można sprawdzić:

    shasum -a 256 -c out/fritzing-macos-arm64-unsigned.zip.sha256

Rozpakuj archiwum (dwuklik w Finderze albo `ditto -x -k <zip> <katalog>`), przenieś `Fritzing.app`
gdzie chcesz — i przeczytaj następny rozdział, zanim uruchomisz.

Części z katalogu `custom-parts/` importuje się w Fritzingu przez `Plik ▸ Otwórz…` i wskazanie
pliku `.fzpz` (szczegóły: `IMPORT-CUSTOM-PARTS.txt` w tym katalogu).

## Gatekeeper, podpis ad hoc, brak notaryzacji

Aplikacja jest budowana lokalnie i **nie ma podpisu Apple Developer ID ani notaryzacji**. Nie da
się ich zrobić bez płatnego konta w Apple Developer Program, a zadanie tego nie obejmuje.

Co to znaczy w praktyce:

1. **Kwarantanna.** Jeżeli archiwum trafi na inny komputer przez przeglądarkę, AirDrop, e-mail albo
   komunikator, system dopisze do plików atrybut `com.apple.quarantine` i przy uruchomieniu pokaże
   „Nie można otworzyć, ponieważ pochodzi od niezidentyfikowanego dewelopera”. Dla **tej, własnoręcznie
   zbudowanej** aplikacji atrybut zdejmuje się jednym poleceniem, wskazującym dokładnie ten pakiet:

       xattr -dr com.apple.quarantine "/Applications/Fritzing.app"

   (podaj rzeczywistą ścieżkę do rozpakowanego `Fritzing.app`). Rób to **wyłącznie** dla plików,
   które sam zbudowałeś i których pochodzenie znasz — polecenie wyłącza kontrolę pochodzenia dla
   wskazanego katalogu. Nie uruchamiaj go na całym `/Applications` ani na katalogu `Pobrane`.

   Archiwum zbudowane i rozpakowane na tym samym Macu zwykle w ogóle nie dostaje kwarantanny.

2. **Podpis ad hoc** (opcjonalny). Przełącznik `--sign-adhoc` podpisuje pakiet przed spakowaniem:

       ./build-local-macos.command --sign-adhoc

   Robi to dokładnie `codesign --force --deep --sign -`, po czym skrypt weryfikuje wynik przez
   `codesign --verify --deep --strict`. Podpis ad hoc **nie jest** podpisem Apple: nie usuwa
   ostrzeżenia Gatekeepera przy pliku pobranym z sieci. Jest za to przydatny lokalnie —
   stabilizuje tożsamość aplikacji dla systemowej zapory i dla pęku kluczy, więc macOS nie pyta o
   uprawnienia po każdej przebudowie. Na Apple silicon poszczególne pliki wykonywalne i tak muszą
   być podpisane co najmniej ad hoc; skrypt budujący robi to sam dla `libngspice.0.dylib` i modeli
   `*.cm` po każdej zmianie ścieżek przez `install_name_tool`.

3. **Notaryzacja: nie jest wykonywana.** Nie ma `notarytool`, nie ma `stapler`, nie ma żadnych
   sekretów ani wysyłania czegokolwiek do Apple. Archiwum jest oznaczone jako `unsigned` świadomie.

4. Pierwsze uruchomienie można też odblokować bez terminala: prawy przycisk myszy na `Fritzing.app`
   ▸ „Otwórz” ▸ „Otwórz” w oknie ostrzeżenia (albo Ustawienia systemowe ▸ Prywatność i
   bezpieczeństwo ▸ „Otwórz mimo to”).

## Wznowienie po przerwaniu lub błędzie

Uruchom **to samo polecenie jeszcze raz**. Nic nie jest pobierane ani budowane od zera:

- kompletne Qt w katalogu roboczym (lub wskazane przez `--qt-root`) jest używane bez pobierania,
- `aqtinstall` w środowisku wirtualnym jest instalowany tylko, gdy brakuje przypiętej wersji,
- `bootstrap-macos.sh` pomija istniejące źródła i zbudowane zależności; gotowy runtime ngspice dla
  tej architektury jest wykrywany po `lipo -archs` i nie jest budowany drugi raz,
- `make` kompiluje tylko to, co się zmieniło.

Dodatkowe przełączniki:

| Przełącznik | Działanie |
|---|---|
| `--force-qt-install` | usuwa Qt z katalogu roboczego i instaluje je od nowa |
| `--skip-bootstrap` | pomija pobieranie źródeł i zależności (praca bez sieci; wymaga, aby były już w katalogu roboczym razem z runtime'em ngspice) |
| `--skip-build` | pomija kompilację i tylko przepakowuje `Fritzing.app` z poprzedniego przebiegu |
| `--sign-adhoc` | podpis ad hoc pakietu przed spakowaniem |
| `--arch <arch>` | jawne potwierdzenie architektury; musi być zgodne z `uname -m` |

Przykład szybkiego przepakowania bez kompilacji:

    ./build-local-macos.command --skip-bootstrap --skip-build

## Usunięcie katalogu roboczego

Katalog roboczy zajmuje kilkanaście GB i po skopiowaniu archiwum nie jest potrzebny:

    rm -rf "$HOME/fritzing-build"

Katalog wyjściowy (`out/`) z archiwum, sumą SHA-256 i logami zostaje nietknięty. Skrypt sam nigdy
nie kasuje katalogu roboczego ani wyjściowego — usuwa tylko własne katalogi pośrednie w środku
katalogu roboczego.

## Co robi skrypt, krok po kroku

1. **Platforma i architektura** — `uname -s` musi być `Darwin`, `uname -m` musi być `arm64` albo
   `x86_64`, a `sysctl sysctl.proc_translated` nie może wskazywać na Rosettę. Niezgodność kończy
   się kodem 2, zanim cokolwiek powstanie.
2. **Prerekwizyty** — Xcode CLT i pojedyncze narzędzia, CMake, Python, komplet plików zestawu,
   paczki `.fzpz`, wolne miejsce, ostrzeżenia o spacjach i długości ścieżki. Braki są raportowane
   razem, przed jakimkolwiek pobieraniem (kod 3).
3. **Qt** — jeżeli `--qt-root`/`QT_ROOT` nie wskazuje kompletnego Qt, powstaje środowisko wirtualne
   `<katalog roboczy>/aqt-venv`, instalowany jest w nim `aqtinstall==3.3.0` (wersja z locka) i
   wywoływane `python -m aqt install-qt mac desktop 6.8.3 clang_64 --outputdir <katalog roboczy>/Qt
   --modules qt5compat qtserialport`.
4. **Źródła, zależności i ngspice** — `scripts/bootstrap-macos.sh` (ten sam skrypt, którego używa
   workflow GitHub): płytkie klony przypięte do commitów z locka, boost, svgpp, nagłówki ngspice,
   libgit2, QuaZip, Clipper1 oraz **budowa ngspice 42 jako biblioteki współdzielonej** dla bieżącej
   architektury (`--with-ngshared --enable-xspice …`, bez OpenMP, FFTW, readline i X11), z modelami
   kodu w `lib/ngspice/`.
5. **Kompilacja** — `scripts/build-macos.sh`: `lrelease`, `qmake` z `QMAKE_APPLE_DEVICE_ARCHS`
   ustawionym na jedną architekturę, `make release`, `macdeployqt`, wstawienie runtime'u ngspice do
   `Contents/PlugIns` z naprawą `install_name`/zależności przez `install_name_tool` i ponownym
   podpisem ad hoc każdego zmienionego pliku, dowiązania w `Contents/MacOS`, generacja `parts.db`
   (na chwilę uruchamia się `Fritzing` — to normalne) i kontrole `file`, `lipo -archs`, `otool -L`
   przed spakowaniem.
6. **Części dodatkowe** — cztery `.fzpz` z `parts/dist`, `IMPORT-CUSTOM-PARTS.txt` i `LICENSE.txt`
   trafiają do katalogu `custom-parts/` obok `Fritzing.app`.
7. **Archiwum końcowe i SHA-256** — `ditto -c -k --sequesterRsrc`, potem `unzip -Z1` sprawdza, że w
   archiwum naprawdę są aplikacja, `parts.db`, `libngspice.0.dylib`, `analog.cm` i wszystkie części;
   na końcu plik `.sha256` w formacie zgodnym z `shasum -a 256 -c`.

Log całego przebiegu (razem z komunikatami narzędzi) trafia do `out/logs/`.

## Kody wyjścia

| Kod | Znaczenie |
|---|---|
| 0 | sukces |
| 1 | błąd w trakcie budowania (szczegóły w logu, blok `BUILD FAILED`) |
| 2 | uruchomiono nie na macOS, na nieobsługiwanej architekturze, pod Rosettą albo z niezgodnym `--arch` |
| 3 | brakuje prerekwizytu; nic nie zostało pobrane |

## Typowe problemy

- **`permission denied` przy `./build-local-macos.command`** — wykonaj raz
  `chmod +x build-local-macos.command scripts/*.sh`.
- **„This shell runs under Rosetta”** — otwórz Terminal natywnie (Finder ▸ Programy ▸ Narzędzia ▸
  Terminal ▸ Informacje ▸ odznacz „Otwórz z użyciem Rosetty”) albo uruchom
  `arch -arm64 ./build-local-macos.command`.
- **`xcrun: error: invalid active developer path`** — brakuje Xcode Command Line Tools:
  `xcode-select --install`.
- **Błąd `configure` ngspice** — pełny log jest w `out/logs/`; katalog `<work>/ngspice-42-build-<arch>`
  zawiera `config.log`. Skrypt kasuje niedokończony prefiks, więc kolejne uruchomienie zaczyna
  budowę ngspice od nowa, nie dotykając reszty.
- **`libngspice.0.dylib still references libraries outside the bundle`** — w systemie znalazła się
  biblioteka (najczęściej z Homebrew), którą `configure` dołączył. Log wypisuje `otool -L`; usuń
  konflikt albo zgłoś, żeby dopisać kolejną opcję `--without-…` do locka.
- **Build przerwany** — po prostu uruchom polecenie ponownie, patrz „Wznowienie”.
- **Symulacja SPICE nadal nie działa** — sprawdź, czy w pakiecie jest
  `Contents/PlugIns/ngspice/analog.cm`; jeżeli jest, załącz log z uruchomienia Fritzinga z konsoli
  (`/Applications/Fritzing.app/Contents/MacOS/Fritzing`).

## Czego ta ścieżka nie robi

- niczego nie publikuje, nie wysyła i nie wymaga konta GitHub (pobierane są tylko publiczne źródła
  i pakiety Qt),
- nie tworzy `.dmg` — wynikiem jest ZIP z `Fritzing.app`,
- nie tworzy binarki universal — wynik jest natywny dla jednej architektury,
- nie podpisuje przez Apple Developer ID i nie notaryzuje,
- nie instaluje Xcode, CMake ani Pythona i nie zmienia ustawień systemu,
- nie zmienia przypiętych wersji z `versions.lock.json` ani definicji części.
