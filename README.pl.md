# arq-gfn-guard

[English](README.md) | Polski

Lekki LaunchAgent dla macOS, który wstrzymuje [Arq 7](https://www.arqbackup.com/) wyłącznie podczas prawdziwej sesji streamingu w [GeForce NOW](https://www.nvidia.com/geforce-now/).

## Po co

Cloud gaming jest wrażliwy na zapchany upload i wzrost opóźnień. Backup działający w tle może powodować przycięcia lub utratę pakietów. Samo sprawdzanie, czy aplikacja GeForce NOW jest otwarta, byłoby zbyt szerokie — launcher często zostaje uruchomiony przez cały dzień.

## Jak to działa

- Obserwuje lokalny log niezawodności NVIDIA i reaguje na faktyczny cykl sesji streamingu.
- Wstrzymuje wszystkie plany Arq już podczas przygotowania sesji, przed uruchomieniem streamu.
- Ustawia dziesięciominutową pauzę Arq i odnawia ją co cztery minuty podczas gry.
- Wznawia Arq kilka sekund po wyjściu z trybu streamingu, nawet jeśli aplikacja GeForce NOW nadal jest otwarta.
- Co 60 sekund wykonuje kontrolne uzgodnienie stanu na wypadek pominięcia zdarzenia w logu.
- Działa jako bieżący użytkownik, bez `sudo` i bez połączeń sieciowych. Na referencyjnym Macu Intel zajmuje około 2 MB RAM i praktycznie 0% CPU w spoczynku.
- Domyślnie działa **bez powiadomień**. Opcjonalne komunikaty są dostępne po polsku i angielsku.

Guard wznawia wyłącznie pauzę, którą sam utworzył. Jeśli zostanie zamknięty lub wyładowany, dziesięciominutowa pauza Arq wygaśnie automatycznie.

## Instalacja

Wymagania:

- macOS z Arq 7 w `/Applications/Arq.app`
- GeForce NOW w `/Applications/GeForceNOW.app`
- wyłączone hasło aplikacji Arq, aby LaunchAgent użytkownika mógł bezobsługowo wywoływać `arqc`; nie wyłącza to szyfrowania backupu

```bash
git clone https://github.com/adriank1410/arq-gfn-guard.git
cd arq-gfn-guard
./install.sh
```

Domyślna instalacja działa po cichu. Aby włączyć powiadomienia:

```bash
ARQ_GFN_NOTIFICATIONS=1 ./install.sh
```

Język powiadomień jest automatycznie zgodny z macOS. Można go wymusić:

```bash
ARQ_GFN_NOTIFICATIONS=1 ARQ_GFN_LANG=pl ./install.sh
ARQ_GFN_NOTIFICATIONS=1 ARQ_GFN_LANG=en ./install.sh
```

Ponowne uruchomienie instalatora bez nadpisania zachowuje aktualne ustawienia powiadomień.

## Powiadomienia

| Zdarzenie | Polski | English |
|---|---|---|
| Początek streamu | Backup wstrzymany na czas aktywnej sesji GeForce NOW. | Backup paused for the active GeForce NOW session. |
| Koniec streamu | Sesja GeForce NOW zakończona; backup wznowiony. | GeForce NOW session ended; backup resumed. |

Aby wrócić do trybu cichego, uruchom `ARQ_GFN_NOTIFICATIONS=0 ./install.sh`.

## Konfiguracja

Instalator zapisuje poniższe zmienne w wygenerowanym pliku LaunchAgenta:

| Zmienna | Domyślnie | Znaczenie |
|---|---:|---|
| `ARQ_GFN_NOTIFICATIONS` | `0` | `1` włącza komunikaty początku i końca sesji; `0` oznacza tryb cichy |
| `ARQ_GFN_LANG` | puste | `en`, `pl` albo puste dla autodetekcji języka macOS |
| `ARQ_GFN_LOOP_SECONDS` | `2` | Interwał lekkiego sprawdzania sygnatury logu |
| `ARQ_GFN_SAFETY_SECONDS` | `60` | Interwał pełnego kontrolnego uzgodnienia stanu |

Pauza celowo trwa 10 minut i jest odnawiana co cztery minuty. Zapewnia to zapas przy chwilowym opóźnieniu procesu, a jednocześnie automatyczne wznowienie, jeśli agent zniknie.

## Dlaczego sprawdzanie co dwie sekundy

Guard nie analizuje logu NVIDIA ani nie wywołuje `pgrep` co dwie sekundy. Szybka ścieżka spoczynkowa składa się wyłącznie z działającego wewnątrz procesu sprawdzenia sygnatury pliku przez `zsh/stat` i uśpienia `zselect`. `tail`, `awk`, sprawdzenie procesu i odczyt zegara uruchamiają się dopiero po zmianie logu albo podczas kontrolnego uzgodnienia co 60 sekund.

Wcześniejszy wariant oparty na `launchd` `WatchPaths` wyglądał lepiej na papierze, ale macOS scalał lub opóźniał zdarzenia na tyle, że zarówno pauza, jak i wznowienie potrafiły następować zbyt późno. `fswatch` dodałby zależność od Homebrew, a natywny helper Swift/kqueue wymagałby dystrybucji i utrzymywania pliku binarnego o większym zużyciu pamięci. Obecne rozwiązanie zajmowało na referencyjnym Macu Intel około 2 MB RAM i praktycznie 0% CPU w spoczynku. Interwał pozostaje konfigurowalny dla osób, które wolą wolniejszą reakcję.

## Obsługa

```bash
# Decyzje guarda i komunikaty arqc
tail -f ~/Library/Logs/ArqGFNGuard/guard.log

# Stan LaunchAgenta
launchctl print gui/$UID/com.local.arq-gfn-guard

# Zastosowanie zmian kodu lub konfiguracji
./install.sh
```

## Odinstalowanie

```bash
./uninstall.sh
```

Logi celowo pozostają na dysku. Jeśli guard utworzył aktywną pauzę, wygaśnie ona w ciągu 10 minut.

## Testy

Testy korzystają z odizolowanych logów i stanu oraz atrap `arqc` i powiadomień. Nigdy nie wstrzymują prawdziwej instalacji Arq.

```bash
zsh -n arq-gfn-guard.sh install.sh uninstall.sh tests/test_guard.zsh
zsh tests/test_guard.zsh
plutil -lint com.local.arq-gfn-guard.plist
```

## Bezpieczeństwo i prywatność

- Bez uprawnień roota i bez połączeń sieciowych.
- Stały systemowy `PATH` i absolutne ścieżki poleceń istotnych dla bezpieczeństwa.
- Prywatny stan i logi: katalogi `700`, pliki `600`.
- Atomowy zapis stanu oraz ograniczony odczyt logu.
- Tekst powiadomienia trafia do AppleScript jako argument, a nie fragment kodu.
- Analizowany jest wyłącznie końcowy 1 MB lokalnego logu NVIDIA; tytuły gier i dane konta nie są nigdzie wysyłane.

## Licencja

[MIT](LICENSE)
