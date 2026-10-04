# Hollowmere – Launch-Plan (v1.0)

Stand: 4. Oktober 2026 · Basis: Commit `7ea8072` · Engine: Godot 4.7.2 (GL Compatibility) · Backend: Nakama + Postgres

Dieser Plan bringt Hollowmere vom aktuellen Stand („quasi fertig“) zu einem launch- und produktionsreifen Release. Alles hier Gelistete ist Launch-Umfang. Die Phasen geben die **Reihenfolge** vor, weil spätere Features auf früheren Fundamenten aufbauen. Sie sind keine Release-Etappen.

Legende: `[ ]` offen · Größe **S** (≤ ½ Tag) · **M** (1–2 Tage) · **L** (3–5 Tage) · **XL** (> 1 Woche) · `→` Abhängigkeit

---

## 0. Leitentscheidungen

| Thema | Entscheidung |
|---|---|
| Zeitmodell | **Hybrid.** Der beschleunigte Tag/Nacht-Zyklus bleibt für Atmosphäre, NPC-Tagesabläufe und Energie. Schlafen ist optional (überspringt die Nacht, füllt Energie auf), Ohnmacht um 2:00 entfällt. Alles Wirtschaftliche (Pflanzen, Maschinen, Eier, Zucht, Farm-Jobs, Krabbenkörbe) läuft in **Echtzeit**, auch offline. |
| Saisons | Folgen dem **echten Kalender** (meteorologisch: 1. März, 1. Juni, 1. Sept., 1. Dez.), Hemisphäre automatisch aus der Locale mit manuellem Override. |
| Pflanzen außerhalb der Saison | Überall pflanzbar. Jede Pflanze hat **pro Saison einen eigenen Wachstums- und Ertragsfaktor**. Im Gewächshaus gibt es nie einen Malus, sondern immer einen Bonus. |
| Nachwachsen | **Saat-Stufen** I–IV mit 3, 6 und 12 Ernten bzw. unbegrenzt (Stufe IV „Ewig“). |
| Offline-Fortschritt | Läuft bis zu **14 Tage** weiter. |
| Casino-Währung | **Chips**, in beide Richtungen gegen Gold tauschbar. Zusätzlich gibt es einen exklusiven Casino-Shop, in dem man mit Chips bezahlt. Echtgeld ist ausgeschlossen. |
| Agent-MCP | **Gehosteter Remote-MCP-Server** (Streamable HTTP) neben Nakama. Der Spieler erzeugt im Spiel einen Token oder verbindet sich per OAuth. Funktioniert auch im Browser. Die Simulation läuft **im Spielclient**, nicht auf dem Server. |
| Mining | **Beides:** ein neues Bergbau-Gebiet mit dauerhaftem, abbaubarem Tunnelsystem **und** Umbau der bestehenden Regions-Minen auf abbaubare Wände. |
| Release | **Alles** zum Launch. |

### Bestandsaufnahme (relevant für den Plan)

- Speicherstand: `SaveManager` schreibt versionierte JSON-Saves (`SAVE_VERSION = 1`) lokal und per Nakama-Storage (`saves/slot_N`). `before_write` in `server/nakama/modules/hollowmere.lua` erlaubt nur die Collection `saves`.
- Einstellungen liegen nur lokal in `user://settings.cfg` (`autoload/settings.gd`, Liste `SAVED`).
- Wachstum, Jobs, Maschinen und Eier werden in `GameState.end_day()` über Nacht aufgelöst (`FarmGrid.new_day`, `FarmJobs.run`, `Machines.automate`). Pflanzen-Daten haben `days`/`regrow` in `data/crops.json` (40 Sorten).
- Kalender: `core/calendar/calendar.gd` mit 28 Tagen pro Saison. Festivals, Board-Requests und Wochenaufgaben hängen daran.
- Koop ist host-authoritativ. Alle Spieleraktionen laufen über `Coop.act()` mit einer Whitelist `Coop.ACTIONS`.
- UI: `UIRoot` verwaltet einen Panel-Stack mit Einzelpanels (Inventar, Team, Crafting, Journal, Map …). Container öffnen sich im Inventar in einer eigenen rechten Spalte (`_container_box`).
- Rucksäcke gibt es bereits als Stufen (`progression.json → backpacks`, 7×4 bis 12×7, Kauf im General Store).
- Minen: pro Region prozedurale Etagen (`MapBuilder.build_mine`, Aufzug alle 5 Etagen).
- Story: 13 Kapitel in `progression.json → story`, dazu Board-Requests und Wochenaufgaben, aber kein allgemeines Quest-System.
- Werkzeuge sind Stufen pro Spieler (`PlayerData.tool_level`), keine einzelnen Items.
- Chat existiert (`Coop.send_chat`, `Net.chat_received(from_name, text)`) ohne Spieler-ID und ohne Sprechblasen.
- Fonts: Tiny5 (Pixel), Nunito (lesbar), `SymbolsFallback.ttf`.

---

## Phase A – Fundamente (vor allen Features)

Diese Bausteine werden von fast allen Features gebraucht. Ohne sie entstehen Doppelarbeit und Migrationschaos.

### A1 Save-Format v2 und Migrationsgerüst · L
- [ ] `SAVE_VERSION = 2`, die Migrationskette in `SaveManager.migrate()` auf Einzelschritte umbauen (`_migrate_1_to_2`, …).
- [ ] Neue Top-Level-Blöcke reservieren: `time` (letzter Echtzeit-Tick), `quests`, `skills`, `fishing`, `mining`, `casino`, `enchants`, `tutorial`.
- [ ] Größenbudget prüfen: Nakama-Limit `max_save_bytes` = 3 MB. Mining-Diffs und Quest-Historie müssen kompakt sein. Saves vor dem Upload mit gzip und Base64 komprimieren, das Lua-Modul akzeptiert beide Formate.
- [ ] Fixtures `tests/fixtures/save_v2_*.json` und ein Migrationstest v0 → v1 → v2.

### A2 TimeService: Echtzeit, Serverzeit, Manipulationsschutz · M
- [ ] Neues Autoload `TimeService`: `now()` liefert Unix-Sekunden. Wenn eingeloggt, wird die Serverzeit verwendet (Offset aus dem `health`-RPC, regelmäßig nachjustiert).
- [ ] Offline gilt: Die Zeit darf nie rückwärts laufen (`last_seen` im Save). Vorwärtssprünge über das Offline-Cap hinaus werden gekappt.
- [ ] **Offline-Cap: 14 Tage.** Längere Abwesenheiten zählen wie 14 Tage. Lange Abwesenheiten werden in groben Schritten aggregiert nachgerechnet (statt 2.016 Einzel-Ticks), damit das Laden auf Mobilgeräten unter 200 ms bleibt.
- [ ] Das Signal `TimeService.tick(dt_real)` läuft alle 5 s während des Spiels, `catch_up(elapsed)` einmal beim Laden.

### A3 SeasonService: echte Jahreszeiten · S
- [ ] `season_for(date, hemisphere)` mit meteorologischen Grenzen. Hemisphäre aus `OS.get_locale()` (Ländercode → Süd für AU, NZ, ZA, AR, BR, CL …), Override in den Einstellungen.
- [ ] Im Koop gilt die Saison des Hosts.
- [ ] Debug-Override (`--season=winter` und eine Dev-Einstellung) für Tests und Screenshots.

### A4 Modifier-System · M
- [ ] Zentrale `Modifiers`-Klasse: `Modifiers.get(p, "crop_growth_mult")` sammelt Boni aus Skilltree, Verzauberungen, Rucksack, Essen-Buffs, Gebäuden und Saison.
- [ ] Alle bisherigen hart kodierten Boni (Glück, Spa, Traits) schrittweise darauf umstellen. Das ist die Voraussetzung für Skilltree, Enchanting und Rucksack-Boni.

### A5 Datenregister für neue Inhalte · S
- [ ] Neue Dateien in `game/data/`: `fish.json`, `ores.json`, `mine_layers.json`, `enchantments.json`, `skills.json`, `quests.json`, `emotes.json`, `casino.json`, `seasonal_events.json`.
- [ ] `Data` lädt sie, `test_data_integrity.gd` validiert Referenzen (Items, Villager, Maps, Icons, Übersetzungen).

### A6 Koop-Erweiterung als Muster · S
- [ ] Jede neue Spieleraktion kommt in `Coop.ACTIONS` und wird host-seitig validiert. Für jede Aktion gibt es einen Eintrag im 4-Peer-Desync-Test (`tests/net/desync_test.gd`).
- [ ] Neues Muster für **zeitbasierte Systeme**: Nur der Host rechnet Echtzeit-Fortschritt, Clients bekommen Tile- und Objekt-Syncs wie bisher.

### A7 Gemeinsame UI-Bausteine · M
- [ ] `CoinLabel` (Goldmünzen-Icon plus formatierte Zahl), `ChipLabel`, `PriceTag` (rot, wenn nicht bezahlbar), `StatBar`, `Badge` („Empfohlen“, „Neu“).
- [ ] `FloatingWindow` (verschiebbar, schließbar, Z-Reihenfolge, am Bildschirmrand eingerastet, Position wird im Profil gespeichert).
- [ ] `IconTabBar` für die Menü-Shell.
- [ ] Zahlenformat nach Locale (`1.234` in DE, `1,234` in EN; kurz `12,3k` und `1,2 Mio.` für das HUD).

### A8 Asset-Pipeline-Batches · M (laufend)
- [ ] Sammeldatei `tools/art_pipeline/launch_sheets.txt` mit allen neuen Sprites (siehe Asset-Liste in Phase H). Generierung über Replicate: `nano-banana-2` für Gebäude, Porträts und Tilesets, `nano-banana-2-lite` für Item-Icons, `fishaudio/ace-step-1.5` für Musik.
- [ ] Gleicher Weg wie bisher: generieren, quantisieren, Atlas (`process.py`, `derive_icons.py`), Stilregeln aus `style.md`.

### A9 i18n-Workflow und Glossar · S
- [ ] `game/i18n/GLOSSARY.md` mit festen Gaming-Begriffen (siehe F2).
- [ ] Test `test_i18n_glossary.gd`: Verbotene Übersetzungen (z. B. „Zusammen spielen“, „Handwerk“, „Talkarte“) dürfen in `de.po` nicht vorkommen. Alle neuen Strings stehen in `hollowmere.pot` (die CI prüft das bereits).

---

## Phase B – Fixes und Optimierungen

### F1 Einstellungen und Profil im Nutzerkonto speichern · M
- [ ] Neue Nakama-Collection `profile`, Key `settings` (pro User, `permission_read = 1`, `permission_write = 1`). `before_write` im Lua-Modul um `profile/settings` und `profile/meta` erweitern, mit Größenlimit 64 KB und Schema-Prüfung.
- [ ] Synchronisiert werden: Lautstärken, Textgröße, Font, Farbenblind-Modus, Bildschirmwackeln, 12/24 h, Auto-Pause, Sprache, Tastenbelegung, Uhrgeschwindigkeit, Analytics-Opt-in, Hemisphäre, Emote-Rad-Belegung, Fensterpositionen, gesehene Tutorials, Chat-Einstellungen, Menü-Präferenzen.
- [ ] **Nicht** synchronisiert werden gerätespezifische Werte: `fullscreen`, `server_*`, `touch_controls`, Fenstergröße.
- [ ] Konfliktregel: Jede Einstellung trägt `updated_at`, beim Login wird pro Schlüssel zusammengeführt (neuerer Wert gewinnt). Uploads werden 3 s gebündelt. Offline greift `settings.cfg` als Cache.
- [ ] Ablauf: Nach dem Login Profil laden und anwenden (`Settings.apply()`). Nach dem Logout bleiben die lokalen Werte erhalten.
- [ ] Tests: Unit-Test für Merge-Logik, Nakama-Integrationstest (Login auf Gerät A, ändern, Login auf Gerät B, Wert übernommen).

### F2 Gaming-Begriffe in der deutschen Übersetzung · S
- [ ] Glossar festlegen und in `de.po` durchziehen. Vorschlag:

| Englisch | Deutsch (neu) | statt bisher |
|---|---|---|
| Co-op | Koop | „Zusammen spielen“ |
| Crafting / Craft | Crafting / craften | „Handwerk“, „Herstellen“ |
| Map / Valley map | Map / Tal-Map | „Karte“, „Talkarte“ |
| Journal | Journal | „Tagebuch“ |
| Party | Party | „Team“ |
| Quest / Questlog | Quest / Questlog | – |
| Shop | Shop | „Laden“ (im UI-Kontext) |
| Skill tree | Skilltree | – |
| Loot | Loot | „Beute“ |
| Hotbar | Hotbar | – |
| Emote | Emote | – |
| Daily Quest | Daily Quest | „Tagesaufgabe“ |
| Item | Item | „Gegenstand“ (nur im UI) |
| Chat | Chat | – |

- [ ] Fließtext in Dialogen darf natürlich bleiben (z. B. „Sable reicht dir eine abgenutzte Karte“ als physischer Gegenstand). Nur UI-Labels, Menüs und Tipps folgen dem Glossar.
- [ ] Glossar-Test aus A9 aktivieren.

### F3 Kampfmenü nutzerfreundlicher · M
- [ ] `BattleEngine.preview(attacker, move, defender)` liefert erwarteten Schaden als Min/Max in Prozent der aktuellen Gegner-KP, KO-Chance, Effektivität, STAB, Trefferchance und Statuseffekt. Rein und deterministisch, ohne Zufall zu verbrauchen.
- [ ] Neue Attacken-Karten in `battle_screen.gd → _show_moves()`:
  - Typ-Icon und Typfarbe, Name, Stärke, Genauigkeit, AP (falls vorhanden)
  - **Schadensbalken** auf der Gegner-KP-Leiste als Vorschau beim Hover oder Fokus („32–38 %“, „KO möglich“)
  - Effektivitäts-Badge: „Sehr effektiv ×2“, „Wenig effektiv ×½“, „Wirkungslos“
  - **„Empfohlen“-Badge** für die Attacke mit dem besten Erwartungswert, bei Status-Attacken nach einfacher Heuristik (z. B. kein Gift auf bereits vergiftete Gegner)
  - Langer Druck (Touch) oder Hover zeigt die Beschreibung
- [ ] Im Kampf schwebende Schadenszahlen und Effektivitäts-Text.
- [ ] Wechsel-Menü: Typ-Matchup des eigenen Wildlings gegen den aktuellen Gegner („Vorteil“, „Nachteil“).
- [ ] Buttongrößen bleiben touch-tauglich (die Regel aus Commit `178d5c1` beibehalten). `test_battle_ui.gd` erweitern.

### F4 Fehlende Zeichen im Browser („25CF“-Kästchen) · S
- [ ] Ursache: **Nunito** (lesbarer Font) enthält `●` (U+25CF) und `→` nicht, und `SymbolsFallback.ttf` deckt sie auch nicht ab. Betroffen sind Titelbildschirm, Account, Map, Koop und Kampf. Desktop-Systeme fallen auf Systemfonts zurück, Browser nicht.
- [ ] Fix: `SymbolsFallback.ttf` neu subsetten (Noto Sans Symbols 2 und Noto Sans, OFL) mit allen genutzten Sonderzeichen: `● → ← ↑ ↓ … · × ★ ☆ ♥ ✓ ✕ ⚔ ▶ ◀ •` plus Zeichen aus Übersetzungen.
- [ ] Wo es sich anbietet, Glyphen durch Textur-Icons ersetzen (Online-Punkt, Herzen, Sterne), damit es im Pixel-Stil konsistent ist.
- [ ] **Test** `test_glyph_coverage.gd`: Sammelt alle Zeichen aus `.gd`-Strings, `de.po` und `data/*.json` und prüft sie gegen Tiny5+Fallback **und** Nunito+Fallback. Die CI schlägt fehl, wenn ein Zeichen fehlt.

### F5 Wildlinge auf dem Hof starten ihre Standard-Aktivität · S
- [ ] `GameState.move_creature(uid, "den")` setzt `c.job = c.job_type()`, sofern `can_do_job`. Dasselbe beim Schlüpfen und Befreunden direkt in den Hof.
- [ ] Neues Feld `job_manual: bool`: Ein bewusst gewähltes „Ausruhen“ wird nicht überschrieben.
- [ ] Migration v2: Hof-Wildlinge ohne Job und ohne `job_manual` bekommen ihren Standardjob.
- [ ] Toast: „Puddlop gießt jetzt deine Felder.“

### F6 Farm-Aktivitäten verständlich und bequem auswählbar · M
- [ ] Das `OptionButton` im Team-Panel durch **Job-Karten** ersetzen: Icon, Name, konkrete Wirkung mit Zahlen („gießt bis zu 14 Felder pro Stunde“, „+20 % Wachstum im Umkreis von 3 Feldern“), Leistung als Sterne, Energieverbrauch pro Stunde, Badge „Passt zum Typ“ bzw. „Empfohlen“.
- [ ] Mit dem Idle-Modell (Phase C) werden Jobs zu **Raten pro Stunde**. Die Karte zeigt die Live-Leistung („Letzte Stunde: 12 Felder gegossen, 3 Erze geschmolzen“).
- [ ] **Hof-Übersicht** im Team-Tab: alle Hof-Wildlinge mit Job, Energie und Leistung, Job-Wechsel per Drag & Drop auf Job-Spalten.
- [ ] Optional: Wirkungsbereich auf der Farm einblenden, wenn ein Job gewählt wird.
- [ ] Job-Texte in `types.json` (`job_desc`) überarbeiten und übersetzen.

### F7 Gewässerränder und Ecken zu hell · M
- [ ] Ursache eingrenzen: Die Uferecken kommen aus `shore_cap_<season>.png` (`tools/art_pipeline/tiles.py`). Das sind vorgebackene Landfarben pro Saison und Terrain (6 Terrains × 64 Zeilen), die echten Bodentiles sind dagegen texturiert und haben Varianten. Zusätzlich verdächtig:
  - Die Aufhellung aus Commit `4d56fc8` („Lighten pond shores …“)
  - Ob `water_fx.gd` (Schimmer und Animation) additiv über den Cap-Pixeln liegt
  - Ob Regen-, Saison- und Tageszeit-Tönung alle Layer gleich trifft (`CanvasModulate`) oder einzelne Layer eigene Materialien bzw. `light_mask` haben
  - `world.gd:107` zwingt nicht-saisonale Maps auf `summer`, Caps und Boden könnten dort aus verschiedenen Saisons stammen
- [ ] Testmatrix: 4 Saisons × {klar, Regen, Sturm, Schnee} × {Tag, Dämmerung, Nacht} × {Farm, Stadt, Region} als automatisierte Screenshots (`store_shots.gd` erweitern) plus Pixelvergleich Cap gegen benachbartes Bodentile.
- [ ] Fix-Richtung: Caps nicht mehr als Flachfarbe backen, sondern **aus dem tatsächlichen Boden-Atlas** der jeweiligen Saison maskieren (Textur übernehmen, nur die Rundung ausstanzen). Wasser-Effekte per Maske auf die Wasserfläche begrenzen.
- [ ] Gleiche Logik später für Bewässerungsgräben (Phase C) und Stege wiederverwenden.

---

## Phase C – Idle-Mechaniken, Saisons, Pflanzen

Das ist der tiefste Eingriff in den Kern. Er muss vor Quests, Skilltree und Balancing stehen, weil alles auf Raten statt Tagen umgestellt wird.

### C1 Echtzeit-Wachstum (lazy, deterministisch) · XL
- [ ] Neues Crop-Schema im Soil-Dict: `{id, progress (0..1), last_tick, watered_until, fert, fert_until, quality_boost, pollinated, harvests}`.
- [ ] Pure Funktion `CropGrowth.advance(crop, soil_ctx, from_t, to_t)`. Sie integriert **stückweise** über Zeitabschnitte mit unterschiedlicher Rate (z. B. erst bewässert, dann trocken) und braucht keine Server-Simulation.
- [ ] Rate = `base_rate × saison_faktor[crop][season] × (bewässert ? 1,6 : 1,0) × dünger × gewächshaus (1,15) × job_boni × skill_boni`. **Unbewässert wächst es weiter, nur langsamer** (Idle-freundlich).
- [ ] Neue Spalten in `crops.json`: `grow_min` (Echtzeit-Minuten bis reif), `season_rate {spring, summer, fall, winter}`, `season_yield {…}`. Die Spalte `days` entfällt.
- [ ] Zeitskala als Startwert (wird im Balancing feinjustiert): kurze Pflanzen 10–30 min, mittlere 1–4 h, lange 8–24 h, Bäume 1–3 Tage.
- [ ] Auswertung: beim Betreten einer Map, alle 5 s für die sichtbare Map, beim Speichern und einmal als Offline-Catch-up beim Laden.
- [ ] Rendering zeigt Wachstumsstufen aus `progress`. Tooltip beim Zielen: „Reif in 1 h 12 min“ samt aktiver Boni.

### C2 Ernten ohne Neupflanzen, Saat-Stufen · M
- [ ] Nach der Ernte bleibt die Pflanze stehen und beginnt wieder bei `regrow_progress` (Mehrfachernte-Pflanzen) bzw. bei 0 (alle anderen).
- [ ] **Saat-Stufen** bestimmen, wie oft eine Pflanze geerntet werden kann, bevor sie verbraucht ist:

| Stufe | EN | DE | Ernten | Bezug |
|---|---|---|---|---|
| I | Common | Gewöhnlich | 3 | Saatguthandlung |
| II | Refined | Veredelt | 6 | Saatguthandlung ab Farmlevel bzw. Herzen, Saatmaschine |
| III | Noble | Edel | 12 | Veredelung (Crafting), Quests, Mining-/Angel-Loot, Casino-Shop |
| IV | Everlasting | Ewig | unbegrenzt | Veredelung aus III mit seltenen Materialien, Main-Story, saisonale Events |

- [ ] Saat-Stufe als Item-Qualität bzw. Meta (`tier`), Icon mit Stufen-Rahmen, Feld-Tooltip „Noch 4 Ernten“. Höhere Stufen wachsen nicht schneller, damit Stufe und Wachstum getrennt balanciert bleiben.
- [ ] Neue Maschine **Saatveredler** (Saat + Material → nächste Stufe) und Rezepte in `recipes.json`.
- [ ] Entfernen nur bewusst per Sense oder Hacke (mit Bestätigung, wenn reif). Ist die letzte Ernte erreicht, verwelkt die Pflanze sichtbar und das Feld wird wieder frei.
- [ ] Migration: Bestehende Pflanzen werden zu Stufe I mit voller Erntezahl.

### C3 Bewässerung: Wassernähe, Gräben, Eimer · L
- [ ] **Wassernähe**: Felder im Umkreis von 4 Feldern (Manhattan) um Wasser oder einen gefüllten Graben gelten dauerhaft als bewässert (Minecraft-Farmland-Regel). Ein Indikator zeigt es (Tropfen-Icon, feuchte Erde).
- [ ] Neue Werkzeuge: **Schaufel** (gräbt einen Graben `trench_dry`, schüttet ihn wieder zu) und **Eimer** (schöpft Wasser aus Teich, Fluss oder Meer und füllt Gräben).
- [ ] Wasserfluss: Ein Graben mit Verbindung zu einer Quelle wird über Flood-Fill bis maximal 8 Felder Abstand zu `trench_wet`. Bricht die Verbindung, trocknet er nach einer Weile aus.
- [ ] Gräben sind nicht begehbar, Holzplanken bzw. Brücken als baubares Objekt.
- [ ] Autotiling für schmale Kanäle (Ecken, T-Stücke, Kreuzungen) im selben Stil wie die neuen Uferkanten (F7).
- [ ] Koop-Aktionen `dig_trench`, `fill_trench`, `use_bucket` und Desync-Test.
- [ ] Sprinkler bleiben, setzen aber `watered_until` periodisch statt täglich.
- [ ] Gepflügte Felder im Sprinkler- oder Wasserbereich verwildern nicht mehr über Nacht. Bisher würfelt `FarmGrid.new_day` das Zurücksetzen von nacktem Boden aus, *bevor* die Sprinkler gießen.

### C4 Weitere Echtzeit-Systeme umstellen · L
- [ ] Maschinen (`machines.gd`): Fertigstellung als Unix-Zeitstempel statt Spielminute.
- [ ] Eier und Brutkasten, Zucht-Paare: Echtzeit-Dauer.
- [ ] Farm-Jobs (`jobs.gd`): statt einmal pro Nacht ein **Tick alle 10 Echtzeit-Minuten**. Energie regeneriert in Echtzeit, die Spa beschleunigt das. Offline wird in 10-Minuten-Schritten nachsimuliert (gedeckelt, Performance-Budget unter 200 ms auf Mobilgeräten, notfalls aggregiert).
- [ ] Bäume, Forage-Respawn, Debris-Wachstum: Echtzeit-Timer.
- [ ] Versandkiste: Auszahlung zu jedem Spieltagswechsel **und** sofort beim Laden nach Offline-Zeit.
- [ ] **„Während du weg warst“-Bericht** ersetzt bzw. erweitert den Morgenbericht (`day_report.gd`): gewachsen, geerntet, Jobs, Maschinen, Eier, Versand, verpasste Daily Quests.

### C5 Hybrider Spieltag · M
- [ ] Spieltag läuft weiter (Uhr, Licht, NPC-Routinen, Läden offen und geschlossen). Die Ohnmacht um 2:00 entfällt, die Nacht läuft einfach weiter bis 6:00.
- [ ] Schlafen überspringt die Nacht, füllt Energie auf und löst den Spieltagswechsel aus (Shop-Rotation, Board-Requests).
- [ ] Energie regeneriert langsam zusätzlich in Echtzeit, damit Wiedereinsteiger nicht leer starten.
- [ ] `Calendar.date_string()` zeigt künftig echtes Datum und Saison plus Spieluhrzeit. Den Spieltag-Zähler gibt es nur noch intern.
- [ ] Koop: Schlaf-Abstimmung (`Coop.request_sleep`) bleibt, ist aber optional.

### C6 Saisons an den echten Kalender binden · L → A3
- [ ] Tileset-Wechsel nach echter Saison, Schnee-Bodentiles im Winter, verschneite Dächer und Bäume, Laub im Herbst, Blüten im Frühling (Tilesets pro Saison existieren schon, Winter-Overlay ergänzen).
- [ ] Wetter pro Saison: Schneefall-Partikel (`weather_fx.gd`), im Winter zugefrorene Teichränder mit Eisloch-Angeln (Phase F).
- [ ] **Saisonale Wildlinge**: Spawn-Bedingungen `{"s": [...]}` bleiben und bekommen 8–12 neue saisonexklusive Wildlinge (2–3 pro Saison) samt Sprites.
- [ ] **Saisonale Events** nach echtem Datum in `seasonal_events.json`: Frühlingsfest und Ostereier-Suche (gibt es schon, umhängen), Sommerfest am Strand, Erntefest, Halloween (Ende Okt.), Winterfest bzw. Weihnachten (Dez.), Silvester-Feuerwerk.
- [ ] **Saisonale NPCs**: Wanderhändler je Saison mit Spezialsortiment (der bestehende `traveler`-Shop wird saisonal).
- [ ] **Saisonale Quests** (Phase D, Quest-Typ `seasonal`).
- [ ] Bisherige Abhängigkeiten von `Calendar.season()` und dem Saisontag (Festivals, Board-Requests, Wochenaufgaben, Forage) auf SeasonService und echte Daten umstellen.

### C7 Mehr Pflanzen und Saatgut-Shop · M
- [ ] Rund 20 neue Pflanzen (40 auf ca. 60) mit unterschiedlichen Profilen: schnelle Idle-Pflanzen, lange Hochwert-Pflanzen, Winterpflanzen, Gewächshaus-Exoten, Blumen für Bienen und Bestäubung, Zutaten für Rezepte mit Fisch und Erz.
- [ ] Neues Gebäude **Saatguthandlung** im Dorf mit eigener NPC (Arbeitsname „Rosalind“, Porträt, Dialoge, Tagesablauf, Herzen). Saatgut wandert aus dem `general_store` dorthin.
- [ ] Sortiment nach Saison sortiert, mit Anzeige „wächst jetzt schnell“ bzw. „wächst jetzt langsam“, Wachstumszeit und Ertragsvorschau. Seltene Saaten nach Farmlevel oder Herzen freischaltbar.
- [ ] Item-Icons, Pflanzenstufen-Sprites, Gebäude-Sprite und Porträt generieren.

---

## Phase D – UI-Überarbeitung, Quests, Tutorials

### D1 Menü-Shell: fast Vollbild mit Icon-Tabs · L → A7
- [ ] Neue `MenuShell`: rund 94 % des Viewports innerhalb der Safe Area (Notch, Home-Indicator), oben `IconTabBar` mit Inventar, Team, Crafting, Quests/Journal, Map, Skilltree, Sammlung (Dex, Fische, Erze), Emotes und Einstellungen.
- [ ] Hotkeys öffnen die Shell direkt im passenden Tab (`I`/Tab, `P`, `C`, `J`, `M`, neu `K` für Skilltree). Nochmal drücken schließt sie. Tab-Wechsel mit `Q`/`E`, mit LB/RB am Gamepad und per Wischen am Touchscreen.
- [ ] Bestehende Panels (`inventory_panel.gd`, `party_panel.gd`, `craft_panel.gd`, `journal_panel.gd`, `map_panel.gd`, `settings_panel.gd`) in einbettbare Tab-Inhalte umbauen (`on_tab_shown()`, `on_tab_hidden()`). Shops, Dialoge, Handel und Kampf bleiben eigene Modale.
- [ ] Fokus- und Gamepad-Navigation, Touch-Smoke-Test und UI-Smoke-Test aktualisieren.

### D2 Container als verschiebbare Mini-Fenster (Tarkov-Stil) · M → A7
- [ ] Die rechte Container-Spalte (`_container_box`) entfällt. Das Inventar-Grid bekommt die volle Breite.
- [ ] Doppelklick bzw. Tippen auf einen Beutel, Koffer oder eine Truhe öffnet ein `FloatingWindow` direkt über dem Inventar. Mehrere Fenster können gleichzeitig offen sein, mit Drag & Drop zwischen allen Fenstern.
- [ ] Position pro Container-Typ wird im Profil gespeichert (F1).
- [ ] Verschachtelte Container öffnen ein weiteres Fenster. Wird ein Container bewegt oder abgelegt, schließt sein Fenster.
- [ ] Hof-Truhe, Versandkiste und andere Inventare nutzen dasselbe Fenster.

### D3 Rucksäcke · M
- [ ] **Standard größer**: von 7×4 auf 9×5. Die Stufen danach werden neu skaliert (z. B. 10×6, 12×7, 14×8).
- [ ] Rucksäcke werden **ausrüstbare Items** statt Stufen (Migration: `backpack_level` wird zum entsprechenden Item). Spieler können mehrere besitzen und wechseln, der Inhalt bleibt erhalten, sofern er passt, sonst gibt es eine Warnung.
- [ ] Spezial-Rucksäcke mit Boni über das Modifier-System:
  - Anglerrucksack (Köderfach, +Fangglück)
  - Bergmannsrucksack (+Lichtradius, Erz-Stapel)
  - Gärtnerrucksack (Saatfach, +Pflanztempo)
  - Abenteurerrucksack (+5 % Laufgeschwindigkeit)
  - Casino-exklusiver Rucksack (kosmetisch plus kleiner Glücksbonus)
- [ ] Rucksack am Charakter sichtbar (Paper-Doll-Layer).

### D4 Economy-Anzeige · M → A7
- [ ] Alle `%dg`-Strings (über 20 Stellen in Shop, Inventar, Journal, Tagesbericht, Abenteuer, Titel) durch `CoinLabel` ersetzen. Test: Kein UI-String darf mehr dem Muster `\d+g` bzw. `%dg` entsprechen.
- [ ] Shop-Kopfzeile mit aktuellem Guthaben. Preise rot bei zu wenig Geld. Verkaufswert-Vorschau inklusive Qualitätsstufe. Gewinnspanne bei Crafting und Maschinen („Saft verkauft sich für 3× den Rohwert“).
- [ ] Geld-Animation (Münzen fliegen zur HUD-Anzeige), HUD-Kurzformat für große Beträge.
- [ ] Optional: Kontoauszug mit den letzten 50 Einnahmen und Ausgaben im Journal.

### D5 Questsystem · XL → A1, A5
- [ ] Datengetriebene Quest-Engine (`core/quests/quests.gd`) mit `quests.json`:
  - Typen: `main`, `side`, `daily`, `tutorial`, `seasonal`, `event`
  - Voraussetzungen: Quests, Flags, Farmlevel, Herzen, Saison, Datum
  - Schritte mit Zielen: `stat` (Zähler), `talk_to`, `deliver`, `have_item`, `reach_map`, `reach_tile`, `win_battle`, `befriend`, `catch_fish`, `mine_ore`, `craft`, `flag`
  - Belohnungen: Gold, Items, Skillpunkte, Rezepte, Emotes, Freischaltungen
  - Dialog-Hooks pro Schritt
- [ ] **Main Story**: die 13 bestehenden Kapitel migrieren und um Kapitel für die neuen Gebiete erweitern (Küste und Fischer, Bergbaustadt und Tiefenmine, Casino-Stadt). Etwa 20 Kapitel insgesamt.
- [ ] **Sidequests**: 2–3 pro Villager (20 bestehende plus neue NPCs), inklusive Questketten mit kleinen Geschichten, Belohnungen und Herzen.
- [ ] **Daily Quests**: 3 pro echtem Tag (Reset um lokale Mitternacht über Serverzeit), einmal pro Tag neu würfelbar, Serienbonus („5 Tage in Folge“), skaliert mit dem Fortschritt. Board-Requests und Wochenaufgaben werden in dieses System überführt (`weekly`-Typ bleibt).
- [ ] UI: Questlog-Tab mit Filter (Main, Side, Daily, Saison) und **Quest-Tracker** im HUD (1–3 verfolgte Quests). Marker auf der Map und Richtungspfeil am Bildschirmrand. NPC-Symbole (`!` neue Quest, `?` abgeben).
- [ ] Koop: Main Story gilt für die Farm (Host), Side- und Daily-Quests sind pro Spieler.

### D6 Überspringbare Tutorials im Questsystem · M → D5
- [ ] Tutorial-Questkette mit Typ `tutorial`: Bewegung, Werkzeuge, Pflanzen und Gießen, Ernten und Versand, Wildling befreunden, Kampf, Hof-Jobs, Crafting, Map und Reisen. Später kontextuell beim ersten Kontakt: Angeln, Mining, Verzaubern, Casino, Skilltree, Emotes, Gräben.
- [ ] Darstellung: kurze Hinweisbox mit Tasten bzw. Touch-Symbolen passend zum Eingabegerät, Hervorhebung des relevanten UI-Elements (Spotlight-Overlay).
- [ ] **Überspringen**: beim neuen Spiel fragen („Tutorial spielen?“), jederzeit „Tutorial überspringen“ im Questlog, einzelne Hinweise wegklickbar. Gesehene Tutorials stehen im **Profil** (F1), damit der zweite Spielstand nicht erneut fragt.
- [ ] Tutorials geben kleine Belohnungen, damit sie sich lohnen. Beim Überspringen werden die Belohnungen gutgeschrieben.

---

## Phase E – Skilltree

### E1 Spieler-XP und Skillpunkte · M → A4
- [x] Neue Spieler-Erfahrung (getrennt vom Farmlevel) aus allen Aktivitäten: Farmen, Kämpfen, Angeln, Mining, Crafting, Quests, Casino nur minimal.
- [x] Pro Level-up 1 Skillpunkt, Bonuspunkte aus Main-Story-Kapiteln, Schreinen und besonderen Quests. Rund 80 Punkte bis zum Max-Level, gut 110 Knoten im Baum, damit man Schwerpunkte setzen muss.

### E2 Baum und Effekte · L → E1
- [x] Sechs Zweige mit je etwa 15–20 Knoten (passive Boni, aktive Fähigkeiten, Freischaltungen, je ein Capstone):
  - **Farmen**: Wachstumstempo, Ertrag, Qualität, Gieß-Reichweite, längere Bewässerungsdauer, Saisonmalus reduzieren
  - **Wildling-Pflege**: Job-Leistung, Energie-Regeneration, Zucht und Schlüpfen schneller, mehr Hof-Plätze, Freundschaft
  - **Kampf**: Schaden, Heilung, Fangchance, EP, Typ-Spezialisierungen
  - **Erkundung**: Laufgeschwindigkeit, Energie, Map-Reisen, Forage, Truhenglück
  - **Handwerk** (Mining, Angeln, Crafting): Abbau-Tempo, Erz-Glück, Angel-Minispiel leichter, Crafting-Kosten, Verzauberungs-Rabatt
  - **Handel**: Verkaufspreise, Shop-Rabatte, Versand-Bonus, Offline-Effizienz (höherer Anteil der Job-Leistung während der Abwesenheit), Casino-Tagesbonus
- [x] Effekte rein datengetrieben über `skills.json` und das Modifier-System (A4).
- [x] Neuverteilung gegen Gold (steigend). Pro Spieler, im Koop also jeder seinen eigenen Baum.

### E3 Skilltree-UI · M
- [x] Eigener Tab in der Menü-Shell: verschiebbarer und zoombarer Knotengraph (Touch: Pinch und Pan), Knoten mit Icon, Zustand (gesperrt, verfügbar, investiert), Tooltip mit Werten „jetzt → nächste Stufe“, Bestätigung beim Investieren.
- [x] HUD-Hinweis „Skillpunkt verfügbar“.
- [ ] Rund 110 Knoten-Icons generieren (Lite-Modell, einheitlicher Rahmen pro Zweig).

---

## Phase F – Angeln, neue Küste, Teiche und Stege

### F-1 Angel-Mechanik · L
- [x] Werkzeug **Angelrute** in 4 Stufen (Bambus, Glasfaser, Gold, Meister) plus Köder und Zubehör (verzauberbar, siehe Phase H).
- [x] Ablauf, voll touch- und gamepadtauglich:
  1. Auswerfen: Halten lädt die Wurfweite auf.
  2. Warten auf den Biss mit sichtbarem Ausschlag, dann rechtzeitig tippen.
  3. Drill-Minispiel: Fisch-Zone mit gehaltener Taste in einer Leiste halten (Stardew-ähnlich, aber großzügiger). Schwierigkeit je Fisch.
- [x] Barrierefreiheit: Option „Einfaches Angeln“ (automatischer Drill mit leicht geringerer Qualität).
- [x] Gelegentlich hängt ein **Wasser-Wildling** am Haken und startet einen Kampf bzw. eine Befreundung.
- [x] Schatztruhen beim Angeln, Fischqualität nach Größe.
- [x] Koop: Angeln ist eine Host-validierte Aktion (`fish_cast` und `fish_result` mit Seed vom Host gegen Manipulation).

### F-2 Fisch-Inhalte · M
- [x] `fish.json` mit etwa 45 Fischen: Ort (Teich, Fluss, Meer, Mine-See, Eisloch), echte Saison, Tageszeit, Wetter, Seltenheit, Schwierigkeit, Größe, Preis. Dazu je ein **legendärer Fisch** pro Saison und Gebiet.
- [x] Fischsammlung (Fischdex) im Sammlungs-Tab (neues `CollectionPanel`, zusammen mit dem Wildling-Dex) mit Rekordgrößen. Neue Kochrezepte mit Fisch, Fisch in der Räuchermaschine (Maschinen-Rezept).
- [x] **Krabbenkörbe** als Idle-Objekt: werden ins Wasser gesetzt und sammeln in Echtzeit, mit Köder schneller.
- [x] Icons für alle Fische und Angelzubehör.

### F-3 Größere Teiche und Stege in bestehenden Gebieten · M
- [x] Neue Map-Op `pier` in `map_builder.gd`: begehbare Holzstege über Wasser (Tiles: Planken, Pfähle, Geländer, Enden).
- [x] Farm: Teich im Lakeside-Ausbaugebiet vergrößern und mit kleinem Steg versehen. Dorf: Parkteich mit Steg. Whisperwood: Waldsee. Ein Fluss in mindestens einer Region.
- [ ] Uferkanten mit der neuen Logik aus F7.

### F-4 Neue Küstenregion „Möwenbucht“ (Arbeitsname) · XL
- [x] Handgebaute Map (`data/maps/gull_bay.json`): Sandstrand mit Wellen-Animation, **großer Steg** ins Meer, Bootshafen, Felsenküste mit Gezeitentümpeln.
- [x] **Fischerhaus mit Angelshop**: NPC-Fischer (Shop: Ruten, Köder, Zubehör, Krabbenkörbe; Fischankauf mit Bonus), Fischerin-Tochter mit Sidequests, Bootsverleih als Übergang zur Casino-Stadt.
- [x] Erreichbar über Tidecove oder das Dorf, eingebunden in Map-Panel und Map-Reisen, mit Wildling-Spawns für den Strand.
- [ ] Musik „Strand“ und „Hafen am Abend“ (ace-step), Möwen- und Wellen-Ambience. (Bis dahin spielt der synthetisierte „beach“-Track; echte Tracks in Phase L.)
- [x] Questkette „Der alte Fischer“ als Main-Story-Kapitel („Salz und Schnur“, Kapitel 5, Save-Migration v4 verschiebt spätere Kapitel).

---

## Phase G – Mining

### G1 Abbausystem (Kern) · XL
- [ ] Chunk-basiertes, persistentes Höhlengitter (32×32-Chunks), generiert aus Welt-Seed plus Chunk-Koordinate über Noise. Gespeichert werden nur **Diffs** (abgebaute und platzierte Blöcke) als komprimierte Bitmasken, mit Blick auf das Save-Budget.
- [ ] Blöcke mit Härte, die eine passende Spitzhacken-Stufe verlangen: Erde, Stein, Tiefenstein, Basalt, Obsidian. Erzadern: Kupfer, Eisen, Silber, Gold, Mithril, Mystik. Kristalle: Quarz, Amethyst, Aquamarin, Rubin, Glimmerkristall. Fossilien und Artefakte für das Museum.
- [ ] **Tiefenschichten** (`mine_layers.json`): Lehmgänge, Steinhallen, Kristallgrotten, Unterwassersee (Angeln!), Magmatiefen. Je tiefer, desto wertvoller und gefährlicher.
- [ ] Licht: Fackeln platzierbar, Dunkelheit mit Lichtradius (performant für WebGL2: ein Lichtmasken-Pass statt vieler `Light2D`).
- [ ] Platzierbar: Fackeln, Leitern (zur nächsten Schicht), Stützbalken, Steinblöcke, Schienen und Lore (Schnellreise zurück zum Eingang).
- [ ] Abbau: Halten statt Spammen (touch-freundlich), sichtbarer Riss-Fortschritt, Partikel, Sound je Material, Energieverbrauch.
- [ ] **Besondere Wildlinge**: Gesteins- und Kristall-Wildlinge, die nur in bestimmten Schichten oder Grotten erscheinen, dazu 4–6 neue Spezies.
- [ ] Koop: `mine_block` und `place_block` als Host-Aktionen, Chunk-Diffs über den bestehenden `tile_sync`.

### G2 Neue Bergbaustadt „Eisenkamm“ (Arbeitsname) · L
- [ ] Map mit Minenschacht-Eingang, **Bergmannsgilde** mit NPC-Vorarbeiter (Questgeber), **Mining-Shop** (Spitzhacken, Fackeln, Bomben, Helmlampe, Leitern, Schienen), **Schmelze/Schmiede** mit Schmiedin, Geologe (bestimmt Geoden und Kristalle, kauft Funde an).
- [ ] Musik „Bergbaustadt“ und „Tiefe Mine“ (ace-step), Ambience (Tropfen, Hall).
- [ ] Main-Story-Kapitel „Das Herz des Berges“ mit Boss-Wildling in den Magmatiefen.

### G3 Umbau der bestehenden Regions-Minen · M → G1
- [ ] Die Etagen-Generierung (`MapBuilder.build_mine`) bleibt, aber Wände werden abbaubar und Erzadern stecken in den Wänden. Etagen bleiben kurze Dungeons mit Aufzug. Diffs werden täglich zurückgesetzt (temporär), nur in Eisenkamm sind sie dauerhaft.
- [ ] Regionsspezifische Erze und Kristalle.

### G4 Neue Crafting-Rezepte und bessere Werkzeuge · M
- [ ] Neue Werkzeugstufe(n) über Mystic hinaus (z. B. „Kristall“) aus Mining-Ressourcen. Neue Rezepte: Bohrer (3×1-Abbau), Bomben, Helmlampe, verstärkte Angelrute, verbesserte Sprinkler, Eimer- und Schaufel-Stufen, **Verzauberungstisch**, **Amboss**, Schleifstein, Krabbenkörbe.
- [ ] Rezepte in `recipes.json`, Crafting-Tab mit Kategorien und Suchfeld.

---

## Phase H – Verzaubern

### H1 Verzauberungs-System (Minecraft-Stil) · L → A4, G1
- [ ] **Verzauberungstisch** (craftbar). Bücherregale in der Nähe erhöhen die maximale Stufe.
- [ ] Ressourcen: **Arkane Essenz** (aus Kristallen, seltenen Fischen und Wildling-Kämpfen) und **Glimmerstaub** (Kosten pro Versuch).
- [ ] Pro Werkzeug 3 Angebote mit Seed pro Spieler und Werkzeug (wie in Minecraft, neu gewürfelt nach jeder Verzauberung). Die Vorschau zeigt nur die erste Verzauberung, weitere sind Überraschung.
- [ ] Speicherung `PlayerData.tool_enchants = {tool: {enchant_id: level}}`, da Werkzeuge Stufen pro Spieler sind.
- [ ] Verzauberungen (`enchantments.json`), Beispiele:
  - Hacke: Weite Furche (3×1), Fruchtbarkeit (+Qualität)
  - Gießkanne: Ergiebigkeit (+Kapazität), Sprühnebel (3×3), Langer Regen (+Bewässerungsdauer)
  - Spitzhacke: Effizienz, Glück (mehr Erz), Behutsamkeit (Kristalle intakt)
  - Axt: Effizienz, Holzfäller (ganzer Baum)
  - Sense: Schwung (Fläche)
  - Angelrute: Köder (schneller Biss), Glück des Meeres (Schätze), Ruhige Hand (größere Zone)
  - Universal: Sparsamkeit (weniger Energie)
- [ ] **Amboss**: Verzauberungsbücher anwenden und kombinieren. **Schleifstein**: Verzauberung entfernen und Teil der Essenz zurück.
- [ ] Verzauberte Werkzeuge schimmern im Paper-Doll und in der Hotbar.
- [ ] Bücher als Loot in Truhen, beim Angeln und im Casino-Shop.

---

## Phase I – Casino

### I1 Casino-Stadt „Lumière“ (Arbeitsname, Monte-Carlo-Stil) · XL
- [ ] Neue Region an der Küste: Promenade mit Palmen, Yachthafen (Bootsfahrt von der Möwenbucht), Belle-Époque-Fassaden, Brunnen, Café und Hotel als Kulisse.
- [ ] **Großes Casino-Gebäude** als Außen-Sprite (großformatig) und eigene Innen-Map: Marmorboden, roter Teppich, Kronleuchter, Spieltische, Automatenreihen, Bar, Kassenschalter, VIP-Salon (freigeschaltet über Chip-Umsatz oder Quest).
- [ ] **Neue NPCs** mit Porträts, Dialogen und Tagesabläufen: Croupier(s), Kassiererin, Barkeeper, Concierge bzw. Host, ein exzentrischer High-Roller als Rivale (Sidequest-Kette), Sicherheitsmann. Dazu Gäste als Ambience-NPCs.
- [ ] Musik: Lounge-Jazz (Casino-Halle), Swing (Promenade), ruhiger Piano-Track (VIP). Sounds: Chips, Karten mischen und austeilen, Roulettekessel und Kugel, Walzen, Jackpot-Fanfare, Gemurmel-Ambience.
- [ ] Erreichbar nach einem Main-Story-Kapitel, damit Neueinsteiger nicht direkt im Casino landen.

### I2 Chips und Casino-Shop · M
- [ ] Kassenschalter: Gold ↔ Chips in beide Richtungen (fester Kurs, ohne Gebühr). Chip-Stand im HUD, solange man im Casino ist.
- [ ] **Casino-Shop** (nur Chips): exklusive Kosmetik (Outfits, Hüte), Möbel und Deko, Emotes, Verzauberungsbücher, seltene Eier, Casino-Rucksack, Musik-Platten für die Farm.
- [ ] Täglicher Gratis-Chip-Bonus (Skilltree-Knoten erhöht ihn).
- [ ] Selbstschutz-Optionen in den Einstellungen: Tageslimit für Einsätze (standardmäßig **aus**), Casino ausblenden.

### I3 Spielbare Spiele (alle mit echten Regeln) · XL
- [ ] **Roulette** (europäisch, einfache Null): komplettes Tableau mit Plein, Cheval, Transversale, Carré, Sixain, Rot/Schwarz, Gerade/Ungerade, Manque/Passe, Dutzende, Kolonnen. Animierter Kessel, Verlauf der letzten Zahlen.
- [ ] **Blackjack**: 6-Deck-Schuh mit Mischkarte, Dealer steht auf Soft 17, Double, Split, Versicherung, Blackjack zahlt 3:2. Optionale Strategie-Hilfe.
- [ ] **Spielautomaten**: 3 Themen (Klassik-Früchte, Wildlinge, Saisonal), 5 Walzen, Gewinnlinien, Paytable einsehbar, Ziel-RTP etwa 95 % per Simulation verifiziert, lokaler progressiver Jackpot.
- [ ] **Video Poker** (Jacks or Better) mit vollständiger Paytable.
- [ ] **Wildling-Rennen**: Wetten auf 6 Läufer mit sichtbaren Quoten aus Werten und Form, animiertes Rennen. Passt thematisch.
- [ ] **Glücksrad** am Eingang (einmal täglich gratis).
- [ ] Gemeinsamer Tisch-Code: `CasinoGame`-Basisklasse, deterministischer RNG mit Seed. Speichern nach jedem Einsatz, damit es kein Save-Scumming gibt.
- [ ] Koop: Spieler am selben Tisch sehen sich gegenseitig (Roulette und Blackjack als gemeinsame Tische, Host rechnet).
- [ ] Tests: Auszahlungs-Unit-Tests für jede Wettart, RTP-Simulation in der CI (1 Mio. Runden headless), Blackjack-Regel-Tests.
- [ ] Tutorials (D6) für jedes Spiel.

### I4 Rechtliches und Einstufung · S
- [ ] Simuliertes Glücksspiel beeinflusst die Altersfreigabe (IARC-Fragebogen für Web, itch und Microsoft, PEGI und USK über IARC, Steam-Fragebogen). Fragebogen vorab ausfüllen und das Ergebnis bewerten.
- [ ] Klarstellung in Store-Texten, AGB und Spiel: keine Echtgeld-Käufe, keine Auszahlung, Chips haben keinen realen Wert.

---

## Phase J – Soziales: Emotes und Chat-Blasen

### J1 Emotes · L
- [ ] **Emote-Rad** (Hotkey `G`, Gamepad Steuerkreuz gedrückt halten, Touch-Button im HUD) mit 8 Slots, Belegung im Profil (F1).
- [ ] Start-Set: Winken, Verbeugen, Jubeln, Lachen, Daumen hoch, Herz, Sitzen, Schlafen, Tanz 1–3, Facepalm. Weitere über Quests, saisonale Events und den Casino-Shop.
- [ ] Umsetzung: Ein Emote ist eine **Animationssequenz** aus generierten Frames pro Paper-Doll-Layer (Körper, Kleidung, Haare) **plus** prozedurale Bewegung und Symbol-Sprechblase und Partikel. Tänze bekommen eigene Frames und einen kurzen Musik-Sting.
- [ ] Risiko: Konsistenz der Layer-Frames aus der Bild-KI. Deshalb zuerst ein **Prototyp mit 2 Tänzen** (bestätigt). Erst wenn der überzeugt, werden alle Frames generiert, sonst wird auf mehr prozedurale Animation ausgewichen.
- [ ] Party-Wildling reagiert (hüpft und tanzt mit). Im Koop werden Emotes per RPC synchronisiert.

### J2 Chat-Blasen über Charakteren · S
- [ ] Chat-RPC um Spieler-ID erweitern (`Coop.chat(pid, from_name, text)`). Sprechblase über dem Avatar (eigener und fremder) für etwa 5 s plus Lesedauer, mit Umbruch, maximaler Breite und Warteschlange bei mehreren Nachrichten.
- [ ] Chat-Log bleibt. Einfacher Wortfilter (abschaltbar), Spieler stummschalten, Längenlimit, Rate-Limit.
- [ ] Glyph-Abdeckung (F4) auch für Chat: nicht darstellbare Zeichen ersetzen.

---

## Phase K – Agent-MCP

Ziel: Spieler können ihren eigenen Charakter (dann im Zuschauermodus) **oder** virtuelle Koop-Partner von einer beliebigen KI (Claude, Cursor, ChatGPT mit MCP usw.) steuern lassen, als wäre es ein echter Mitspieler.

### K1 Architektur · L
```
KI-Client (Claude / Cursor / …)
   │  MCP (Streamable HTTP, OAuth 2.1 oder Personal Access Token)
   ▼
hollowmere-mcp  (Node/TypeScript, @modelcontextprotocol/sdk, Docker neben Nakama)
   │  Nakama Server-API (Token-Prüfung) + Realtime-Stream pro User
   ▼
Spielclient des Spielers (Browser oder Desktop, Host der Welt)
   └─ Autoload AgentBridge: führt Befehle über Coop.act() aus → dieselbe Validierung wie bei echten Spielern
```
- [ ] Die Welt wird **nur im Spielclient** simuliert, das Spiel muss also offen sein. Der MCP-Server ist ein reiner Relay mit Auth, Rate-Limits und Request/Response-Korrelation (Timeouts, Fehlercodes).
- [ ] Transport Spiel ↔ Server über Nakama-Realtime (Stream oder Notifications). Neue RPCs `agent_register_client`, `agent_command_result`.
- [ ] Auth: (a) **OAuth 2.1 mit Dynamic Client Registration** für Claude.ai bzw. Desktop-Connectors (Login-Seite unter der Spiel-Domain, Nakama-Login), (b) **Personal Access Token** aus dem Spiel für Claude Code, Cursor und andere. Token mit Scopes (`observe`, `act`, `chat`, `economy`), widerrufbar, Ablaufdatum.
- [ ] Deployment: neuer Service in `server/docker-compose.yml`, nginx-Route `mcp.hollowmere.tretu.de`, Healthcheck, Logs, Rate-Limit pro Token.

### K2 Modi im Spiel · L
- [ ] Neues Panel **„KI-Agenten“** (im Koop-Tab der Menü-Shell): Token erzeugen bzw. widerrufen, Verbindungsstatus, Modus wählen.
- [ ] **Modus „Eigenen Charakter steuern“**: Der Spieler wechselt in den **Zuschauermodus** (Kamera folgt, optional freie Kamera). Ein Overlay zeigt die letzten Aktionen und die „Gedanken“ des Agenten (über das Tool `narrate`). Die Taste „Steuerung zurücknehmen“ funktioniert jederzeit.
- [ ] **Modus „Virtueller Koop-Partner“**: Ein KI-Mitspieler wird als zusätzlicher Spieler (`agent:<id>`) im Koop-Roster angelegt, mit eigenem `PlayerData`, Avatar (Look wählbar), Inventar, Team und Skilltree. Er funktioniert auch solo (der Spieler hostet dafür lokal). Bis zu **3 Agenten** pro Welt. Der Agenten-Zugang ist zum Launch für alle kostenlos.
- [ ] Pfadfindung für Agenten-Bewegung: `AStarGrid2D` auf dem Map-Grid, Warps zwischen Maps.
- [ ] **Browser-Hinweis**: Hintergrund-Tabs drosseln `requestAnimationFrame`, die Simulation stoppt dann. Im Agenten-Modus erscheint ein Hinweis („Tab sichtbar lassen“), und die Engine-Hauptschleife wird soweit möglich weitergetaktet. Testen und dokumentieren.

### K3 MCP-Tools, Ressourcen und Prompts · XL
- [ ] **Beobachten**: `get_status` (Ort, Zeit, Saison, Wetter, Energie, Geld), `look_around` (Tiles, Objekte, NPCs, Wildlinge, Spieler im Umkreis als strukturiertes JSON und optional als ASCII-Karte), `get_inventory`, `get_party`, `get_farm_overview` (Felder, Reifezeiten, Jobs, Maschinen), `get_quests`, `get_map`, `get_shop`, `get_battle_state`, `get_dialogue`, `read_chat`, `wait_for_events` (Long-Poll auf Ereignisse wie Kampfbeginn, Dialog, Fisch beißt, Quest erledigt).
- [ ] **Handeln**: `walk_to` (Koordinate, Objekt, NPC oder Map), `interact`, `use_tool` (Tile oder Fläche), `plant`, `water_area`, `harvest_area`, `ship`, `buy`, `sell`, `craft`, `cook`, `equip`, `set_job`, `move_creature`, `dialogue_choose`, `battle_move`, `battle_switch`, `battle_item`, `battle_flee`, `fish` (Minispiel als Entscheidungen: wann einholen), `mine_block`, `place_block`, `enchant`, `casino_*` (Bet, Hit, Stand, Spin …), `chat_say`, `emote`, `sleep`, `narrate`.
- [ ] **Makros** für weniger Tool-Aufrufe: `farm_routine` (alles Reife ernten, gießen, nachpflanzen), `go_shopping(liste)`, `deposit_all`.
- [ ] **Ressourcen**: Spielhandbuch (Mechaniken, Typentabelle, Items, Rezepte, Fische, Erze, Karten) als MCP-Resources, generiert aus `data/*.json`, damit Agenten das Spiel verstehen.
- [ ] **Prompts**: „Spiele als Farmer“, „Hilf mir als Koop-Partner“, „Grinde Kämpfe“, „Optimiere meine Farm“.
- [ ] Schutz: Aktionsbudget pro Minute, keine zerstörerischen Aktionen ohne Scope (Spielstand löschen ist nie erlaubt, Verkauf wertvoller Items braucht den `economy`-Scope), Audit-Log im Spiel.

### K4 Tests und Doku · M
- [ ] E2E-Test in der CI: Nakama, `hollowmere-mcp` und ein headless Spielclient, dazu ein Skript-MCP-Client, der ein kurzes Szenario spielt (laufen, pflanzen, ernten, verkaufen, Kampf gewinnen).
- [ ] Anleitung `docs/agents.md` (bzw. im Spiel verlinkt): Einrichtung für Claude Desktop und Claude.ai (Custom Connector), Claude Code, Cursor sowie generische MCP-Clients.
- [ ] Datenschutzerklärung ergänzen (Agent-Verbindungen, Logs, Aufbewahrung).

---

## Phase L – Inhalte, Assets, Balancing

### L1 Asset-Liste (Generierung über Replicate)
- [ ] **Tilesets**: Strand, Sand, Wellen; Stege und Pfähle; Gräben und Kanäle (Autotile); Schnee-Overlay; Casino-Innenraum (Marmor, Teppich, Tische, Automaten, Bar); Promenade; Bergbaustadt; Mine-Blöcke (5 Gesteine × Risse) und Erzadern; Kristallgrotten; Magma.
- [ ] **Gebäude**: Saatguthandlung, Fischerhaus mit Angelshop, Bootshaus, Grand Casino (groß), Hotel, Café, Bergmannsgilde, Mining-Shop, Schmelze, Geologen-Hütte.
- [ ] **Porträts und Charakter-Sprites**: Saatguthändlerin, Fischer, Fischerin, Vorarbeiter, Mining-Händler, Schmiedin, Geologe, 2 Croupiers, Kassiererin, Barkeeper, Concierge, High-Roller, Sicherheitsmann, 4 saisonale Händler, Gäste-NPCs.
- [ ] **Wildlinge**: 8–12 saisonale, 4–6 Mining- bzw. Kristall-Wildlinge, 2–4 Wasser- bzw. Strand-Wildlinge (Sprites, Kampf-Sprites, Dex-Einträge, Moves).
- [ ] **Item-Icons**: etwa 20 Saaten und Pflanzen, 45 Fische, 20 Erze, Kristalle und Barren, Angelzubehör, Werkzeugstufen, Rucksäcke, Bücher, Casino-Items, rund 110 Skill-Icons, Emote-Icons, Coin- und Chip-Icons.
- [ ] **Animationen**: Emote-Frames pro Paper-Doll-Layer, Angel-Animation, Spitzhacke im Dauerabbau, Schaufel, Eimer.
- [ ] **Kampf-Hintergründe**: Strand bei Nacht, Kristallgrotte, Magmatiefe.
- [ ] **Musik** (ace-step-1.5, ruhig, loopbar, passend zu den bestehenden Piano-Loops): Strand, Hafen am Abend, Angel-Minispiel, Bergbaustadt, Tiefe Mine, Casino-Lounge-Jazz, Promenade-Swing, VIP-Piano, Winter-Thema, Herbst-Thema, Festival-Thema, Halloween, Winterfest. Etwa 13 Tracks.
- [ ] **SFX**: Auswerfen, Biss, Spule, Platscher, Spitzhacke je Material, Block bricht, Fackel, Schaufel, Wasser fließt, Chips, Karten, Roulette, Walzen, Jackpot, Emote-Stings. Synth-Fallbacks in `audio.gd` ergänzen.
- [ ] **Web-Downloadgröße**: Budget für die `.pck` festlegen. Musik als OGG mit niedriger Bitrate. Neue Gebiets-Musik gegebenenfalls nachladbar (HTTP-Download beim ersten Betreten statt im initialen Paket).

### L2 Balancing · L → C, E, F, G, I
- [ ] `balance_sim` und `economy_sim` auf das Echtzeit-Modell umstellen: simulierte Spielerprofile (10 min pro Tag, 1 h pro Tag, Hardcore) über 30 echte Tage, mit Kennzahlen Gold pro Stunde, Fortschrittstempo und Offline-Anteil.
- [ ] Gold-Quellen und -Senken neu kalibrieren: Pflanzen, Fische, Erze, Casino (Erwartungswert negativ, RTP etwa 95 %, damit es keine Gold-Farm wird), Daily Quests. Senken: Saat, Werkzeuge, Rucksäcke, Verzauberungen, Skill-Neuverteilung, Gebäude.
- [ ] Offline-Fortschritt fühlt sich lohnend an, schlägt aber aktives Spielen nicht (Zielwert: Offline etwa 40–60 % der aktiven Rate).
- [ ] CI-Grenzen im 112-Tage-Sim auf das neue Modell übertragen.

---

## Phase M – Produktionsreife

### M1 Tests und CI · L
- [ ] Neue GUT-Unit-Tests: CropGrowth (Stückweise-Integration, Offline-Cap, Zeit rückwärts), Bewässerung und Flood-Fill, SeasonService (Hemisphären, Grenzen), Quest-Engine, Skills und Modifier, Angeln (Fischauswahl), Mining (Generierung deterministisch, Diffs), Verzaubern (Angebote, Kosten), Casino (Auszahlungen, RTP), Profil-Merge, Glyph-Abdeckung, Glossar, Formatierung.
- [ ] Smoke-Tests für jede neue Map, jeden neuen Tab und jedes neue Panel, mit Screenshots für Store und Regression.
- [ ] Desync-Test um alle neuen Koop-Aktionen erweitern.
- [ ] Nakama-Integrationstests: Profil-Sync, komprimierte Saves, Agent-RPCs.
- [ ] MCP-E2E-Test (K4).
- [ ] Perf-Bench (`perf_bench.gd`) für Mine mit Licht, Casino-Innenraum, Strand mit Wellen, Farm mit vielen Gräben. Ziel: 60 FPS auf Mittelklasse-Handy im Browser, Laden unter 200 ms für Offline-Catch-up.

### M2 Save-Migration und Datensicherheit · M
- [ ] Migration v1 → v2 mit echten Spielständen testen (Fixtures `save_v1_m3.json`). Pflanzen-Alter in Tagen wird zu `progress`, `backpack_level` wird zum Rucksack-Item, Jobs, Kalender-Felder.
- [ ] Vor der Migration automatisch ein Backup (`slot_N.v1.bak`). Ist die Cloud-Version neuer, wird sie bevorzugt.

### M3 Server und Betrieb · M
- [ ] `hollowmere.lua`: neue Collections (`profile`), Agent-RPCs, komprimierte Saves, Rate-Limits.
- [ ] `docker-compose.yml`: Service `hollowmere-mcp`, Secrets in `.env`. nginx: Subdomain `mcp.`, TLS, Rate-Limit, WebSocket bzw. SSE-Timeouts.
- [ ] Monitoring: Health-Endpoints, Fehlerberichte (gibt es schon) um MCP erweitern, Backups (Postgres) prüfen. `HOSTING.md` aktualisieren.

### M4 Lokalisierung · M
- [ ] Alle neuen Strings in EN und DE (geschätzt 3.000–4.000 neue Einträge). Glossar-Test, Platzhalter-Test (`%d`, `%s` gleiche Anzahl), Längen-Check für Buttons in DE.
- [ ] `msgfmt --check-format` sauber bekommen: Datentexte wie „25% schneller“ sind fälschlich als `c-format` markiert (3 Fehler, Godot selbst stört das nicht). Danach den Check in die CI aufnehmen.

### M5 Barrierefreiheit und Plattformen · M
- [ ] Alle neuen Minispiele mit Gamepad, Tastatur und Touch spielbar, Einfach-Modi (Angeln, Abbau halten statt tippen), Farbenblind-Palette für Roulette, Typen und Erze, Textgrößen in der neuen Menü-Shell.
- [ ] Testmatrix: Windows, macOS, Chrome, Safari (iOS und macOS), Firefox, Android Chrome, installierte PWA, Querformat auf dem Handy, Tablet.

### M6 Recht, Store, Launch · M
- [ ] Datenschutzerklärung und AGB aktualisieren: Profil-Sync, Chat, KI-Agenten, Casino-Hinweis.
- [ ] Altersfreigabe (I4) einholen.
- [ ] `store/STORE_PAGE.md`, Screenshots, Capsules und README um die neuen Features ergänzen, optional einen Trailer.
- [ ] `RELEASE.md`-Checkliste durchlaufen, Version `1.0.0`, Tag, CI-Exporte, Deployment auf `hollowmere.tretu.de`.
- [ ] Soft-Launch mit Testern (1–2 Wochen): Telemetrie (Opt-in), Fehlerberichte, Balancing-Hotfixes.

---

## Reihenfolge und kritischer Pfad

```
A (Fundamente) ──► B (Fixes) ──► C (Idle + Saisons + Pflanzen) ──┬─► D (Menü-Shell, Container, Rucksäcke, Economy, Quests, Tutorials)
                                                                  ├─► E (Skilltree)
                                                                  │
                     D + E ──► F (Angeln + Küste) ──► G (Mining) ──► H (Verzaubern) ──► I (Casino)
                                                                  │
                     D ──► J (Emotes, Chat-Blasen)                │
                     D + A6 ──► K (Agent-MCP; kann ab D parallel laufen)
                                                                  ▼
                                          L (Assets laufend, Balancing am Ende) ──► M (Produktionsreife, Launch)
```

Grobe Aufwandsschätzung (eine Person mit Agent-Unterstützung): A ≈ 1,5 Wochen · B ≈ 1 Woche · C ≈ 3 Wochen · D ≈ 3 Wochen · E ≈ 1,5 Wochen · F ≈ 2,5 Wochen · G ≈ 3 Wochen · H ≈ 1 Woche · I ≈ 3 Wochen · J ≈ 1,5 Wochen · K ≈ 3 Wochen · L/M ≈ 3 Wochen. **Gesamt etwa 25–30 Wochen**, mit Parallelisierung (K neben F–I, Assets laufend) etwa 18–22 Wochen.

---

## Entschiedene Punkte (4. Oktober 2026)

1. **Namen**: Möwenbucht (Küste), Eisenkamm (Bergbau), Lumière (Casino-Stadt), Rosalind (Saatguthändlerin).
2. **Glossar** (F2): wie oben, inklusive „Journal“ und „Party“.
3. **Nachwachsen** (C2): Saat-Stufen mit 3, 6 und 12 Ernten bzw. unbegrenzt.
4. **Offline-Fortschritt**: bis zu 14 Tage.
5. **Casino-Tageslimit**: standardmäßig aus.
6. **Agenten**: maximal 3 pro Welt, zum Launch kostenlos.
7. **Emotes**: zuerst ein Prototyp mit 2 Tänzen.
