<p align="center"><img src="screenshots/logo.png" alt="ShadeGunner" width="100%"></p>

# ShadeGunner — Android (Godot 4)

[English](README.md) · **Deutsch**

16-Farben-Cyberpunk-Sidescroller im Blade-Runner-Universum. Als Blade Runner
arbeitest du dich von den Außenbezirken bis ins Tyrell-HQ und musst
**Replikanten unter Passanten erkennen, scannen und deaktivieren** – und mit den
Folgen deiner Entscheidungen leben.

Das ist die **Android-/Handheld-Version** von [ShadeGunner](https://github.com/3p1cball-code/ShadeGunner):
ein originalgetreuer Neubau in **Godot 4 / GDScript**, kein Emulator-Wrapper.
Gleiche Simulation, gleiche Stadt, gleicher Look – die prozedurale Szene in 640×360,
Bayer-gedithert gegen eine 16-Farben-Palette und durch die CRT-Kette geschickt
(Wölbung, Scanlines, Schattenmaske, Bloom, Nachleuchten). Spielbar mit **Touch,
Gamepad (z. B. Retroid Pocket) oder Tastatur**, auf jedem Bildformat von 10:9 (Retroid Pocket Classic) bis
~22:9. Oberfläche und Texte auf **Deutsch und Englisch**.

**Download:** die signierte APK (arm64, ab Android 7) liegt auf der
[Release-Seite](https://github.com/3p1cball-code/ShadeGunner-Android/releases/latest).

## Screenshots

| | |
|---|---|
| ![Hauptmenü](screenshots/menu.png) | ![Einstellungen](screenshots/settings.png) |
| ![Außenbezirk](screenshots/level0.png) | ![Vorstadt](screenshots/level1.png) |
| ![Innenstadt](screenshots/level2.png) | ![Hafen](screenshots/level3.png) |
| ![Tyrell](screenshots/level4.png) | ![ROY vor Sebastians Haus](screenshots/roy.png) |

| Handy (20:9, Touch) | Handheld (4:3, Touch) |
|---|---|
| ![Handy](screenshots/phone.png) | ![Handheld 4:3](screenshots/handheld.png) |

## Atmosphäre zuerst

Das Spiel will ruhig gespielt werden: durch die Stadt gehen, sie aufnehmen, ein paar
Momente erleben, die sich wie im Film anfühlen. Die Mechanik dient der Stimmung – und
je weiter man kommt, desto dichter und unübersichtlicher werden die Straßen, bis die
Frage nicht mehr ist, *wer* ein Replikant ist, sondern ob das überhaupt zählt.

- **Eigene Palette je Viertel:** jede Zone hat ihre eigenen 16 Farben rund um ein
  Komplementärpaar plus ein paar nahe Abstufungen für Spitzlichter auf den Figuren
  (Außenbezirk Amber ↔ Blau/Violett, Vorstadt Grün/Cyan ↔ Pink, Innenstadt Teal ↔
  Signalrot, Hafen Asch-Blau ↔ Natrium, Tyrell Gold ↔ tiefes Blau).
- **Dichte Straßen:** alte, verschnörkelte Fassaden mit nachgerüsteten Kabeln neben
  Hypermodernem, Kreide-Graffiti-Monolithen und Ornament-Säulen, Wracks und Müll im
  Außenbezirk (weiter innen sauberer), **Brücken und überhängende Gebäude** zum
  Durchgehen, **Ampeltürme** als freistehende Objekte (manche direkt vor der Kamera,
  leicht unscharf), **Kabel quer über die Straße** (einzeln oder als Bündel), dünne
  unscharfe Kabel und Lampen im Vordergrund, Papiermüll in Böen, Radfahrer in kleinen
  Pulks als reine Kulisse, eine 60er-Limousine im modernen Verkehr, Papierschirme mit
  leuchtendem Schaft.
- **CRT-Phosphor:** fast weiße Spitzlichter ziehen etwas länger nach, und ausfadende
  Spuren werden beim Abklingen weicher.

## Kern-Loop

Beobachten → Ziel wählen → **scannen** (begrenzte Ladungen) → **Tell-Konfidenz**
(Naive Bayes, über den echten Replikantenanteil der Zone kalibriert) →
zielen/schießen (Passanten in der Schusslinie fangen die Kugel) → Quote erfüllen,
Ausgang öffnet sich → 1 aus 3 Upgrades. **Zivilisten töten ⇒ Verdacht** (ab 100 %
ist der Einsatz verloren).

Wer einen **Augenreflex** erwischt – beim Beobachten, per Scan, im Polizei-
Suchlicht oder beim Stromausfall –, sieht über der Person kurz das Emblem des
Spiels aufblitzen (Auge im Scanner-Fadenkreuz). Es markiert den Tell, nicht die
Wahrheit: Auch Menschen zeigen gelegentlich einen falschen Reflex.

- **Zonen:** Außenbezirk → Vorstadt → Innenstadt → Hafen → Tyrell.
- **Abwechslung:** Springen (über Baken, Tonnen und Kisten – nicht über Wracks oder
  parkende Autos – und Schlägen ausweichen), Verkehr auf zwei
  Fahrspuren, Polizei-Suchlicht (macht Augenreflexe sichtbar), Stromausfall,
  Kopfgeld-Replikanten, **landende Polizei-Spinner** (Abwind schiebt alle weg, danach
  Kontrolle mit Suchlicht vom Boden aus; der Spinner sperrt den Mittelstreifen),
  **Gaffs Origami** (eine Figur pro Zone: Huhn, Streichholzmann, Schaf, Kranich, Einhorn;
  Fund = Punkte + Scanner voll) und **Nudelbars** im Stil des White Dragon (Theke,
  Gäste, Koch, Neon-Drache; kurz an der Theke stehen füllt ein Herz auf).
- **Volle Straßen – und jeder ist Teil der Simulation:** Passanten auf der Fahrbahn,
  Flaneure auf dem hinteren Gehweg vor den Läden und **Gruppen, die herumstehen und
  reden**. Alle sind beobachtbar und scanbar, Replikanten verstecken sich in jeder Sorte.
  Schwierigkeit LEICHT/NORMAL/SCHWER skaliert die Menge.
- **Ansprechen und Rufen (`V`):** Kurz tippen spricht das Ziel an („Sie da! Stehen
  bleiben!“): Menschen heben die Hände und antworten, wer den REIZ-Tell hat, starrt nur.
  Halten lädt einen Ruf an die Menge, beim Loslassen läuft „LAPD! Alle runter!“ als
  sichtbare Welle über die Straße; jeder reagiert, wenn sie ihn erreicht, mit eigener
  Schrecksekunde. Wer den REIZ-Tell hat, bleibt **reglos stehen**, die anderen gehen **in
  Deckung** (die Kugel geht über Geduckte hinweg) oder rennen. Jeder Ruf erhöht die
  **Unruhe** der Straße: mehr Leute rennen, Replikanten werden nervös und hauen ab.
- **Kein Fahrzeug gleicht dem anderen:** Korosseriefarben, Akzentfarben (Zierlinien,
  Zweifarbdach, Schweller, Rallyestreifen), Unterboden-Neon, Helligkeit und Schriftzüge
  (Tyrell, Shimata, Pan Am, Off-World, Nexus 6, Eye Works …) werden je Fahrzeug
  kombiniert – auch Taxi-Dachschilder, Bus-Werbeband, Buslinie (z. B. „12 HADES“) und
  Laster-Aufschrift sind zufällig. 32 Varianten je Art.
- **Verkehr wird zur Kolonne:** Mit jedem Viertel fahren mehr Fahrzeuge – und je dichter
  der Verkehr, desto langsamer fließt er: Stop-and-go, haltende Taxis, Stau-Hupen, in der
  Innenstadt meist 5–7 Fahrzeuge im Bild. Und je langsamer und voller, desto **leiser**
  die Motoren. Stehst du in der Spur, hupt der Fahrer und **bremst** ab – angefahren wirst
  du nur noch, wenn du in letzter Sekunde vors Auto läufst (ganz vorn ist es wirklich
  gefährlich, im dichten Innenstadtverkehr kaum noch). Läufst du seitlich gegen ein Auto,
  gibt es nur einen kurzen **Rempler** (Stun), kein Herz. Am Fahrbahnrand **parken** Autos, Taxis, Laster
  (manche mit Warnblinker); sie sind zu hoch zum Drüberspringen und verdecken, wer
  dahinter steht.
- **Dampfende Gullis:** wie in New York – Gullideckel mit Glut im Spalt und gestreifte
  Dampfschlote, die in Schüben qualmen. Im Dampf sieht man fast nichts: Wer dort steht,
  lässt sich kaum beobachten.
- **Eigene Musik je Viertel:** Außenbezirk mit dem Titelthema, danach mit jeder Zone
  dichter (Arpeggien, Chor, Nebelhorn und Hafenmetall, Tyrell groß und hell). Dazu eine
  taktgleiche **Rhythmus-Spur** – vom Herzschlag in der Vorstadt bis zum treibenden
  Sequenzer in Tyrell –, die mit der Spannung lauter wird (Zielen, Unruhe, Flucht,
  Verdacht, ROY) und langsam wieder abklingt.
- **Holografische Ballerinas** (Blade Runner 2049): riesige Tänzerinnen über den Dächern
  und kleine auf Projektorsockeln am Gehweg – Pirouette, Seconde, Arabeske mit Promenade,
  Scanlines, Aussetzer, Glitches; im Stromausfall gehen sie aus.
- **Verkehr nach Syd Mead:** Polizei-Spinner mit Kapsel-Kanzel und Radgondeln,
  Deckard-Sedan, Metrokab mit Glas-Dom, Sebastians Armadillo-Laster, Aerial-Limousine,
  Stadtbus voller Fahrgäste, Motorrad mit Radscheiben.
- **Finale:** Tyrell ist ein langer letzter Sektor. Gegen Ende leert sich die Stadt –
  verfallene Viertel, Rollläden, Ornament-Säulen – bis zu **J. F. Sebastians Haus**
  (dem Bradbury). Davor steht **ROY** und wartet, bis man herankommt. Im Kampf stichelt
  er nur mit Sätzen aus dem Film. Hat er dich bis auf **ein Herz** geschlagen, lässt er
  ab und steht wehrlos da: Ein Schuss genügt. Schießt du nicht, spricht er – *Tränen im
  Regen* –, stirbt von selbst, und eine Taube steigt auf. Das Ende spiegelt, welchen Weg
  du gewählt hast. Der Ausgang öffnet erst, wenn die Quote erfüllt ist und ROY nicht
  mehr steht.

## Steuerung

| Touch | Gamepad | Tastatur | Aktion |
|---|---|---|---|
| Stick (links) | Steuerkreuz / linker Stick | `A/D`, `W/S`, Pfeile | gehen, Tiefe (nah/fern) |
| Person antippen | `L1`/`R1` | `Q` / `Tab` | Ziel wählen / wechseln |
| SCAN | `X` | `R` | gewähltes Ziel scannen |
| ZIELEN (halten, loslassen) | `R2` (halten, loslassen) | `E` (halten, loslassen) | zielen, schießen |
| ABBRECHEN | `B` | `C` | Waffe senken |
| RUF (tippen / halten) | `Y` | `V` | Ziel ansprechen / „LAPD! Alle runter!“ rufen |
| SPRUNG | `A` | `Leertaste` | springen |
| – | `L2` | `Shift` | sprinten |
| PAUSE | `Start` | `P` / `Esc` | Pause (Menüs: Einstellungen, Hilfe) |

Menüs gehen per Touch (Zeilen und Karten antippen), Steuerkreuz + `A` oder Pfeiltasten +
`Enter`. Die Android-Zurück-Geste pausiert. Touch-Steuerung: AUTO (auf Touchscreens
eingeblendet), AN oder AUS.

## Einstellungen und Leistung

Die Szene wird wie im Original auf der CPU komponiert, die Bildrate hängt also vom
Gerät ab. In den Einstellungen tauscht man Effekte gegen Bilder pro Sekunde:

- **Qualität** HOCH / MITTEL (Vorgabe auf Android: ohne Reflexionen) / NIEDRIG setzt
  **Reflexionen**, **Regen** (viel/wenig/aus), **Nebel** und **FX** auf einen Schlag;
  danach ist jede Option einzeln umschaltbar. Auf einem Handheld am besten mit
  **NIEDRIG** anfangen.
- **Bildformat** AUTO: die interne Breite passt sich dem Bildschirm an (Höhe 360,
  Breite 400–960) – keine Balken, kein Beschnitt, gleicher Maßstab auf jedem Gerät.
- **Darstellung** CRT oder **TEXT** (die Szene als ASCII-Zeichen in den Palettenfarben,
  weiterhin durch die CRT-Kette), Scanlines, Musik-/Effektlautstärke, Schwierigkeit,
  Sprache.

## Zum Port

- **1:1 zum Python-Original:** Konstanten und Tabellen werden aus den Python-Modulen
  exportiert (`tools/export_data.py`); die Simulation läuft schrittgleich
  (`tests/test_sim_parity.gd` spielt 25 517 Schritte gegen eine Spur des Originals nach:
  0 Abweichungen), Pythons `random` ist bitgenau nachgebaut (`src/core/pyrandom.gd`),
  QPainter auf Godots RenderingServer (`src/core/qp.gd`). HUD, Tonaufrufe, Figuren,
  Fahrzeuge, Stadtebenen und die ganze Szene werden gegen das Original pixelverglichen
  (`tools/*_reference.py`).
- **Eigene Palette je Zone** geht als Uniform an den Dither-Shader; das HUD behält
  `noir16`.
- **Port-eigene Beschleunigungen:** die Spiegelungen auf der nassen Straße zeichnet ein
  Shader, statt je Sprite-Frame ein weichgezeichnetes Bild zu backen; radiale Verläufe
  nutzen eine gecachte 2D-Textur; Perspektivboden und Spiegelungsstreifen sind je ein
  Zeichenaufruf.
- Test-Cheat (Tastatur): irgendwo `giveall` tippen (unsterblich, Ausgang immer offen);
  `giveall1`–`giveall5` springt direkt in Sektor 1–5.

## Bauen

```sh
godot --path . --rendering-driver opengl3            # am Desktop starten
godot --headless --path . --export-release "Android" build/shadegunner.apk
```

Braucht die Godot-4-Exportvorlagen, JDK 17 und das Android-SDK. `export_presets.cfg`
liegt nicht im Repo (enthält die Signatur-Einstellungen) – Vorlage ist
`export_presets.cfg.example`. Tests: `godot --headless --path . --script res://tests/test_sim.gd`
(und die übrigen Skripte in `tests/`).

## Lizenz

MIT. Ein unabhängiges Fanprojekt; Blade Runner ist eine Marke der jeweiligen Inhaber.
