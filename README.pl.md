# arq-gfn-guard

[English](README.md) | Polski

Wstrzymuje backupy [Arq 7](https://www.arqbackup.com/) podczas prawdziwej sesji streamingu w [GeForce NOW](https://www.nvidia.com/geforce-now/), a po jej zakończeniu automatycznie je wznawia.

## Problem

Cloud gaming jest wrażliwy na zapchany upload i wzrost opóźnień. Backup działający w tle może zamienić stabilną sesję GeForce NOW w przycięcia albo utratę pakietów.

Wstrzymywanie Arq zawsze, gdy aplikacja GeForce NOW jest otwarta, byłoby zbyt szerokie — launcher może działać przez cały dzień. Istotne jest to, czy rzeczywiście trwa streaming.

## Co robi

1. **Wykrywa prawdziwe sesje streamingu** — czyta zdarzenia IPC z mniejszego `debug.log` GFN, z `console.log` jako alternatywą. Nowsze zdarzenia sesji mają pierwszeństwo przed starymi wpisami w drugim pliku.
2. **Wstrzymuje backup przed startem streamu** — wywołuje oficjalne polecenie Arq `arqc pauseBackups` już po wykryciu przygotowania sesji.
3. **Bezpiecznie podtrzymuje pauzę** — ustawia dziesięciominutową pauzę i odnawia ją co cztery minuty podczas streamingu.
4. **Wznawia backup po wyjściu z gry** — wywołuje `arqc resumeBackups` w ciągu kilku sekund, nawet jeśli launcher GeForce NOW nadal jest otwarty.
5. **Działa bezpiecznie przy błędach** — problem z odczytem procesu nie może fałszywie wznowić Arq; pominięte zdarzenie jest uzgadniane w ciągu 60 sekund; po wyłączeniu guarda pozostaje tylko automatycznie wygasająca pauza.
6. **Śledzi własne udane pauzy** — wznawia backup tylko wtedy, gdy prywatny stan potwierdza, że guard skutecznie wywołał pauzę. Arq udostępnia jedną globalną pauzę, dlatego łączenie sesji GFN z niezależną ręczną pauzą Arq nie jest obsługiwane i może zakończyć się jej zastąpieniem albo wznowieniem.
7. **Działa cicho i lokalnie** — bez roota, bez połączeń sieciowych, z użyciem około 2 MB RAM i praktycznie 0% CPU w spoczynku na referencyjnym Macu Intel.
8. **Zgłasza problemy powiadomieniami macOS** — alerty o błędach są domyślnie włączone; zwykłe powiadomienia początku i końca sesji pozostają wyłączone. Oba rodzaje obsługują język polski i angielski.

### Powiadomienia

| Zdarzenie | Polski | English |
|---|---|---|
| Początek streamu | Backup wstrzymany na czas aktywnej sesji GeForce NOW. | Backup paused for the active GeForce NOW session. |
| Koniec streamu | Sesja GeForce NOW zakończona; backup wznowiony. | GeForce NOW session ended; backup resumed. |
| Odnowienie pauzy | *(bez powiadomienia)* | *(silent)* |

Powiadomienia można włączyć przy instalacji przez `ARQ_GFN_NOTIFICATIONS=1`. Ich język jest zgodny z macOS; `ARQ_GFN_LANG=pl` albo `ARQ_GFN_LANG=en` wymusza konkretny wariant.

Alerty błędów są niezależne od zwykłych powiadomień. Brak źródeł lub nierozpoznany stan zgłaszany jest po co najmniej 60 sekundach, przy najbliższym uzgodnieniu (domyślnie zwykle do około 120 sekund od wykrycia problemu). Błędy poleceń Arq i zapisu stanu zgłaszane są od razu po nieudanej operacji. Jeden trwający błąd nie powtarza powiadomienia po każdym sprawdzeniu ani restarcie; powrót do poprawnej pracy pozwala zgłosić jego ponowne wystąpienie. Dostarczenie powiadomień zależy od ustawień macOS i trybu skupienia. Brak użytecznych logów przy działającym GFN oznacza „nie można ustalić stanu sesji”, a nie dowód, że trwa gra. Błąd polecenia Arq oznacza, że guard nie uzyskał potwierdzenia jego wykonania. Sam otwarty launcher ze znanym stanem zakończenia nie wymaga pauzy. Żaden parser nie odtworzy pewnie zdarzeń usuniętych ze wszystkich źródeł; alert ma ujawnić taką utratę detekcji. Nie usuwaj katalogu stanu guarda w `~/Library/Application Support/ArqGFNGuard/` podczas jego działania.

## Decyzje projektowe

**Dlaczego log GFN zamiast sprawdzania, czy aplikacja jest otwarta?**

Zdarzenia sesji pochodzą z `debug.log` oraz `console.log` w `~/Library/Application Support/NVIDIA/GeForceNOW/`, zweryfikowanych lokalnie w GFN 2.0.87 i 2.0.88. Mniejszy `debug.log` zawiera `IPC_STREAMING_PREPARE/STARTING/SESSION_SETUP/STARTED_EVENT` oraz `IPC_STREAMING_TERMINATED/MODE_EXIT_EVENT`. Alternatywny `console.log` zawiera stany `Loading` / `Streaming` oraz `PostSessionConnection` / `PostStreaming` / `Done`. Wybór uwzględnia czas zdarzenia, aby stary wpis w jednym pliku nie przesłonił nowej sesji w drugim. W lokalnej wersji 2.0.88 stare `logs/gfn_reliability_monitor.log` i `logs/gameStreamClientAgent.log` nie zawierały nowej sesji, dlatego nie są automatycznymi alternatywami. `ARQ_GFN_LOG_FILE` przy bezpośrednim uruchomieniu ogranicza odczyt do jawnie wskazanego pliku; starszy format pozostaje obsługiwany.

Po zaobserwowaniu cofnięcia czasu w dopisanych zdarzeniach guard korzysta z tego źródła do zamknięcia procesu GFN, zamiast porównywać je ze starym zegarem drugiego pliku. Zachowuje ten wybór przy restarcie z aktywną pauzą. Brak tego źródła wywoła alert i podtrzymanie własnej pauzy. Cofnięcia czasu sprzed uruchomienia guarda nie da się jednoznacznie rozpoznać z logów bez strefy czasowej. Po zaobserwowanym zamknięciu GFN stare wpisy startu nie uruchamiają ponownej pauzy przy samym otwarciu launchera.

**Dlaczego stałe sprawdzanie co dwie sekundy zamiast `launchd` `WatchPaths`?**

Wcześniejszy wariant `WatchPaths` wyglądał lepiej na papierze, ale macOS scalał lub opóźniał zdarzenia na tyle, że zarówno pauza, jak i wznowienie następowały zbyt późno. Obecna szybka ścieżka spoczynkowa nie analizuje logu ani nie wywołuje `pgrep`: sprawdza sygnatury obu plików przez `zsh/stat` oraz małe fragmenty kontrolne przez `zsh/system`, a następnie zasypia przez `zselect`. `tail`, `awk`, sprawdzenie procesu i odczyt zegara uruchamiają się dopiero po zmianie logu albo podczas kontrolnego uzgodnienia co 60 sekund.

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

Domyślnie działa **bez powiadomień o początku i końcu sesji**, ale z alertami o błędach. Zwykłe powiadomienia można włączyć przez:

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
| `ARQ_GFN_NOTIFICATIONS` | `0` | `1` włącza jeden komunikat początku i końca sesji; `0` wyłącza zwykłe komunikaty sesji |
| `ARQ_GFN_ERROR_NOTIFICATIONS` | `1` | Ostrzega o błędach detekcji i poleceń Arq; `0` wyłącza te alerty |
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
| *(tworzony podczas działania)* | `~/Library/Application Support/ArqGFNGuard/guard-paused` oraz `guard-alert-detection`, `guard-alert-action` |
| *(tworzony podczas działania)* | `~/Library/Logs/ArqGFNGuard/guard.log` |
| *(wyjście launchd)* | `~/Library/Logs/ArqGFNGuard/launchd.out.log` oraz `launchd.err.log` |

## Testy

Testy używają odizolowanych logów i stanu oraz atrap `arqc`, zegara, odczytu procesu i powiadomień. Nigdy nie wstrzymują prawdziwej instalacji Arq.

```bash
for script_file in arq-gfn-guard.sh install.sh uninstall.sh tests/*.zsh; do zsh -n "$script_file" || break; done
zsh tests/test_guard.zsh
zsh tests/test_sources.zsh
zsh tests/test_source_edges.zsh
zsh tests/test_alert_edges.zsh
plutil -lint com.local.arq-gfn-guard.plist
```

## Lokalna próba bez Arq

Uruchom w `zsh` z katalogu repo. Przykład symuluje start sesji na plikach tymczasowych, wyświetla decyzję i usuwa pliki próby. Nie instaluje LaunchAgenta ani nie wywołuje Arq. Oczekiwany wpis: `DRY-RUN arqc pauseBackups 10`. Pełny cykl pause/renew/resume sprawdza zestaw testów powyżej.

```zsh
(
  test_root=$(mktemp -d /tmp/arq-gfn-preview.XXXXXX) || exit 1
  trap 'rm -rf "$test_root"' EXIT
  printf '%s\n' '2026-09-09 23:00:08.062 INFO  gfn/StreamerManagerService  Advancing to state: Streaming' > "$test_root/gfn.log"
  ARQ_GFN_GUARD_DRY_RUN=1 ARQ_GFN_GUARD_ONCE=1 \
    ARQ_GFN_FORCE_PROCESS=1 ARQ_GFN_NOTIFICATIONS=0 \
    ARQ_GFN_LOG_FILE="$test_root/gfn.log" \
    ARQ_GFN_STATE_DIR="$test_root/state" \
    ARQ_GFN_GUARD_LOG="$test_root/guard.log" \
    ./arq-gfn-guard.sh
  cat "$test_root/guard.log"
)
```

## Wymagania

- macOS z Arq 7 w `/Applications/Arq.app`
- GeForce NOW w `/Applications/GeForceNOW.app`
- wyłączone hasło aplikacji Arq, aby LaunchAgent użytkownika mógł bezobsługowo wywoływać `arqc`; **nie** wyłącza to szyfrowania backupu

## Bezpieczeństwo i prywatność

- Stały systemowy `PATH` i absolutne ścieżki poleceń istotnych dla bezpieczeństwa.
- Prywatny stan i logi: katalogi `700`, pliki `600`.
- Atomowy zapis stanu i automatyczna rotacja logu guarda. Po zwykłym dopisaniu danych detekcja czyta najwyżej ostatni 1 MiB i pamięta ostatni rozpoznany stan. Jeśli w tym oknie nie ma zdarzenia, pełny odczyt strumieniowy następuje tylko przy starcie, wymianie/skróceniu pliku albo po przyroście co najmniej 1 MiB od ostatniej analizy. Jeśli nowy plik po rotacji nie ma jeszcze zdarzenia, guard sprawdza też jego `.bak`, ale tylko gdy inode albo zapisane fragmenty kontrolne pasują do poprzednio obserwowanego źródła. Pozwala to odzyskać koniec sesji przeniesiony przy rotacji bez ufania niepowiązanemu staremu backupowi logu. Niezmieniony plik korzysta z pamięci podręcznej po sprawdzeniu fragmentów kontrolnych podczas okresowego uzgodnienia stanu. Tożsamość źródła i fragmenty kontrolne są zapisywane atomowo razem z czasem odnowienia pauzy, aby po restarcie rozpoznać ten sam plik przeniesiony przy rotacji. Pamięć źródła w procesie jest czyszczona po wykryciu zamknięcia GFN. Przed ponownym użyciem stanu po dopisaniu danych `zsh/system` sprawdza pierwsze 128 bajtów oraz 128 bajtów przy poprzednim końcu, aby wykryć zmienioną zawartość po wyzerowaniu i odrośnięciu logu. Jeśli moduł lub odczyt kontrolny jest niedostępny, zmienione pliki wracają do pełnego odtwarzania stanu. Odtworzenie stanu trwa proporcjonalnie do rozmiaru pliku, bez buforowania go w całości.
- Tekst powiadomienia trafia do AppleScript jako argument, a nie fragment kodu.
- Tytuły gier, dane konta, treść logu ani telemetria nie są nigdzie wysyłane.

## Licencja

[MIT](LICENSE)
