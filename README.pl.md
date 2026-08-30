# arq-gfn-guard

[English](README.md) | Polski

Wstrzymuje backupy [Arq 7](https://www.arqbackup.com/) podczas prawdziwej sesji streamingu w [GeForce NOW](https://www.nvidia.com/geforce-now/), a po jej zakończeniu automatycznie je wznawia.

## Problem

Cloud gaming jest wrażliwy na zapchany upload i wzrost opóźnień. Backup działający w tle może zamienić stabilną sesję GeForce NOW w przycięcia albo utratę pakietów.

Wstrzymywanie Arq zawsze, gdy aplikacja GeForce NOW jest otwarta, byłoby zbyt szerokie — launcher może działać przez cały dzień. Istotne jest to, czy rzeczywiście trwa streaming.

## Co robi

1. **Wykrywa prawdziwe sesje streamingu** — obserwuje lokalny log niezawodności NVIDIA pod kątem przygotowania, startu, zakończenia i wyjścia z trybu streamingu.
2. **Wstrzymuje backup przed startem streamu** — wywołuje oficjalne polecenie Arq `arqc pauseBackups` już po wykryciu przygotowania sesji.
3. **Bezpiecznie podtrzymuje pauzę** — ustawia dziesięciominutową pauzę i odnawia ją co cztery minuty podczas streamingu.
4. **Wznawia backup po wyjściu z gry** — wywołuje `arqc resumeBackups` w ciągu kilku sekund, nawet jeśli launcher GeForce NOW nadal jest otwarty.
5. **Działa bezpiecznie przy błędach** — problem z odczytem procesu nie może fałszywie wznowić Arq; pominięte zdarzenie jest uzgadniane w ciągu 60 sekund; po wyłączeniu guarda pozostaje tylko automatycznie wygasająca pauza.
6. **Śledzi własne udane pauzy** — wznawia backup tylko wtedy, gdy prywatny stan potwierdza, że guard skutecznie wywołał pauzę. Arq udostępnia jedną globalną pauzę, dlatego łączenie sesji GFN z niezależną ręczną pauzą Arq nie jest obsługiwane i może zakończyć się jej zastąpieniem albo wznowieniem.
7. **Działa cicho i lokalnie** — bez roota, bez połączeń sieciowych, z użyciem około 2 MB RAM i praktycznie 0% CPU w spoczynku na referencyjnym Macu Intel.
8. **Udostępnia opcjonalne powiadomienia macOS** — domyślnie wyłączone, automatycznie po polsku lub angielsku i bez powtarzania komunikatu przy odnawianiu pauzy.

### Powiadomienia

| Zdarzenie | Polski | English |
|---|---|---|
| Początek streamu | Backup wstrzymany na czas aktywnej sesji GeForce NOW. | Backup paused for the active GeForce NOW session. |
| Koniec streamu | Sesja GeForce NOW zakończona; backup wznowiony. | GeForce NOW session ended; backup resumed. |
| Odnowienie pauzy | *(bez powiadomienia)* | *(silent)* |

Powiadomienia można włączyć przy instalacji przez `ARQ_GFN_NOTIFICATIONS=1`. Ich język jest zgodny z macOS; `ARQ_GFN_LANG=pl` albo `ARQ_GFN_LANG=en` wymusza konkretny wariant.

## Decyzje projektowe

**Dlaczego log GFN zamiast sprawdzania, czy aplikacja jest otwarta?**

Log pokazuje faktyczny cykl streamingu. Launcher może dzięki temu pozostać otwarty bez ciągłego blokowania Arq.

**Dlaczego stałe sprawdzanie co dwie sekundy zamiast `launchd` `WatchPaths`?**

Wcześniejszy wariant `WatchPaths` wyglądał lepiej na papierze, ale macOS scalał lub opóźniał zdarzenia na tyle, że zarówno pauza, jak i wznowienie następowały zbyt późno. Obecna szybka ścieżka spoczynkowa nie analizuje logu ani nie wywołuje `pgrep`: wykonuje wyłącznie działające wewnątrz procesu sprawdzenie sygnatury przez `zsh/stat`, a następnie zasypia przez `zselect`. `tail`, `awk`, sprawdzenie procesu i odczyt zegara uruchamiają się dopiero po zmianie logu albo podczas kontrolnego uzgodnienia co 60 sekund.

`fswatch` wymagałby Homebrew. Natywny helper Swift/kqueue usunąłby timer, ale oznaczałby dystrybucję i utrzymywanie pliku binarnego o większym zużyciu pamięci. Interwał dwóch sekund pozostaje konfigurowalny.

**Dlaczego pauza trwa 10 minut i jest odnawiana co 4 minuty?**

Zapas chroni przed chwilowymi opóźnieniami procesu. Jeśli guard się zamknie albo zostanie wyładowany, Arq automatycznie ruszy po wygaśnięciu ostatniej pauzy.

**Co z osobną ręczną pauzą Arq?**

CLI Arq udostępnia jedną globalną pauzę i nie pozwala odczytać poprzedniego stanu. Nie łącz niezależnej ręcznej pauzy Arq z sesją GeForce NOW: pauza guarda może ją zastąpić, a automatyczne wznowienie — zakończyć. Ograniczenie nie wpływa na zwykłe sesje kontrolowane przez guard.

## Instalacja

Nie używaj `sudo` — to LaunchAgent bieżącego użytkownika.

```bash
git clone https://github.com/adriank1410/arq-gfn-guard.git
cd arq-gfn-guard
./install.sh
```

Domyślnie działa **bez powiadomień**. Można je włączyć przez:

```bash
ARQ_GFN_NOTIFICATIONS=1 ./install.sh
```

W razie potrzeby można wymusić język:

```bash
ARQ_GFN_NOTIFICATIONS=1 ARQ_GFN_LANG=pl ./install.sh
ARQ_GFN_NOTIFICATIONS=1 ARQ_GFN_LANG=en ./install.sh
```

Ponowne uruchomienie `./install.sh` bez nadpisania zachowuje zainstalowane ustawienia.

## Odinstalowanie

```bash
./uninstall.sh
```

Logi pozostają w `~/Library/Logs/ArqGFNGuard/`. Jeśli guard utworzył aktywną pauzę, wygaśnie ona automatycznie w ciągu 10 minut.

## Obsługa

```bash
# Decyzje guarda i komunikaty arqc
tail -f ~/Library/Logs/ArqGFNGuard/guard.log

# Stan LaunchAgenta
launchctl print gui/$UID/com.local.arq-gfn-guard

# Zastosowanie zmian kodu lub konfiguracji
./install.sh
```

## Konfiguracja

Przekaż nadpisanie do `./install.sh`; instalator je sprawdzi i zapisze w wygenerowanym pliku LaunchAgenta. Ponowna instalacja bez nadpisania zachowuje istniejące wartości.

| Zmienna | Domyślnie | Znaczenie |
|---|---:|---|
| `ARQ_GFN_NOTIFICATIONS` | `0` | `1` włącza jeden komunikat początku i końca sesji; `0` oznacza tryb cichy |
| `ARQ_GFN_LANG` | puste | `en`, `pl` albo puste dla autodetekcji języka macOS |
| `ARQ_GFN_LOOP_SECONDS` | `2` | Interwał lekkiego sprawdzania sygnatury logu |
| `ARQ_GFN_SAFETY_SECONDS` | `60` | Interwał pełnego kontrolnego uzgodnienia stanu |

Przykład z wolniejszą, pięciosekundową reakcją:

```bash
ARQ_GFN_LOOP_SECONDS=5 ./install.sh
```

## Pliki

| Plik w repo | Miejsce instalacji |
|---|---|
| `arq-gfn-guard.sh` | `~/Library/Application Support/ArqGFNGuard/arq-gfn-guard.sh` |
| `com.local.arq-gfn-guard.plist` | `~/Library/LaunchAgents/com.local.arq-gfn-guard.plist` *(generowany przez instalator)* |
| *(tworzony podczas działania)* | `~/Library/Application Support/ArqGFNGuard/guard-paused` |
| *(tworzony podczas działania)* | `~/Library/Logs/ArqGFNGuard/guard.log` |
| *(wyjście launchd)* | `~/Library/Logs/ArqGFNGuard/launchd.out.log` oraz `launchd.err.log` |

## Testy

Testy używają odizolowanych logów i stanu oraz atrap `arqc`, zegara, odczytu procesu i powiadomień. Nigdy nie wstrzymują prawdziwej instalacji Arq.

```bash
zsh -n arq-gfn-guard.sh install.sh uninstall.sh tests/test_guard.zsh
zsh tests/test_guard.zsh
plutil -lint com.local.arq-gfn-guard.plist
```

## Wymagania

- macOS z Arq 7 w `/Applications/Arq.app`
- GeForce NOW w `/Applications/GeForceNOW.app`
- wyłączone hasło aplikacji Arq, aby LaunchAgent użytkownika mógł bezobsługowo wywoływać `arqc`; **nie** wyłącza to szyfrowania backupu

## Bezpieczeństwo i prywatność

- Stały systemowy `PATH` i absolutne ścieżki poleceń istotnych dla bezpieczeństwa.
- Prywatny stan i logi: katalogi `700`, pliki `600`.
- Atomowy zapis stanu, ograniczony odczyt jednego megabajta logu i automatyczna rotacja.
- Tekst powiadomienia trafia do AppleScript jako argument, a nie fragment kodu.
- Tytuły gier, dane konta, treść logu ani telemetria nie są nigdzie wysyłane.

## Licencja

[MIT](LICENSE)
