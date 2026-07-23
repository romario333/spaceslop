# Moons, dwarf planets & comets — art and simulator todo

Snapshot: **2026-07-23**. This is a **curated** list, not an exhaustive catalog: it covers
every moon, dwarf planet, comet, and interstellar visitor a typical player might recognize, and deliberately
stops there (the solar system has 400+ catalogued moonlets we will never ship). Items
are ordered roughly by how well-known they are — work top-down within each section.

Status definitions:

- A checked box means the body is fully done: finished art **and** simulator integration.
- **Art: yes** requires a finished PNG in `art/scifi-60s/` (the game's only art
  theme); generated/WIP sources in `art/_wip/` do not count.
- **Sim: yes** requires an entry in `src/config.zig` (`names` + `PlanetConfig`) and an
  orbit in the `orbits` table in `src/main.zig`.
- Leave a box unchecked until both are complete.

## Moons

### Earth (1)

- [x] **Moon** — Art: yes (`art/scifi-60s/moon.png`); Sim: yes (`moon`)

### Mars (2)

- [x] **Phobos** — Art: yes; Sim: yes (`phobos`)
- [x] **Deimos** — Art: yes; Sim: yes (`deimos`)

### Jupiter (9)

The four Galilean moons, the four inner moons, and the largest irregular.

- [x] **Io** — Art: yes; Sim: yes (`io`)
- [x] **Europa** — Art: yes; Sim: yes (`europa`)
- [x] **Ganymede** — Art: yes; Sim: yes (`ganymede`)
- [x] **Callisto** — Art: yes; Sim: yes (`callisto`)
- [ ] **Amalthea** — Art: no; Sim: no
- [ ] **Himalia** — Art: no; Sim: no
- [ ] **Thebe** — Art: no; Sim: no
- [ ] **Metis** — Art: no; Sim: no
- [ ] **Adrastea** — Art: no; Sim: no

### Saturn (9)

- [ ] **Titan** — Art: no; Sim: no
- [ ] **Enceladus** — Art: no; Sim: no
- [ ] **Mimas** — Art: no; Sim: no
- [ ] **Rhea** — Art: no; Sim: no
- [ ] **Iapetus** — Art: no; Sim: no
- [ ] **Dione** — Art: no; Sim: no
- [ ] **Tethys** — Art: no; Sim: no
- [ ] **Hyperion** — Art: no; Sim: no
- [ ] **Phoebe** — Art: no; Sim: no

### Uranus (5 — the classical five)

- [ ] **Titania** — Art: no; Sim: no
- [ ] **Oberon** — Art: no; Sim: no
- [ ] **Miranda** — Art: no; Sim: no
- [ ] **Ariel** — Art: no; Sim: no
- [ ] **Umbriel** — Art: no; Sim: no

### Neptune (3)

- [ ] **Triton** — Art: no; Sim: no
- [ ] **Proteus** — Art: no; Sim: no
- [ ] **Nereid** — Art: no; Sim: no

### Pluto (1)

- [ ] **Charon** — Art: no; Sim: no

## Dwarf planets

The five IAU-recognized dwarf planets, plus the four best-known candidates as
optional stretch goals.

- [ ] **Ceres** — Art: no; Sim: no
- [x] **Pluto** — Art: yes (`art/scifi-60s/pluto.png`); Sim: yes (`pluto`)
- [x] **Eris** — Art: yes; Sim: yes (`eris`)
- [x] **Haumea** — Art: yes; Sim: yes (`haumea`)
- [x] **Makemake** — Art: yes; Sim: yes (`makemake`)

Optional candidates (do after everything above):

- [ ] **Sedna** — Art: no; Sim: no
- [ ] **Quaoar** — Art: no; Sim: no
- [ ] **Gonggong** — Art: no; Sim: no
- [ ] **Orcus** — Art: no; Sim: no

## Comets

The household names. Comets are new territory for the simulator: highly eccentric
orbits already work (the `orbits` table supports `ecc`; Eris uses 0.35), but a comet
likely wants a tail treatment in art and possibly rendering — decide that once, then
apply it to all of them.

- [ ] **1P/Halley** — Art: no; Sim: no
- [ ] **Hale–Bopp (C/1995 O1)** — Art: no; Sim: no
- [ ] **67P/Churyumov–Gerasimenko** (Rosetta's comet) — Art: no; Sim: no
- [ ] **Hyakutake (C/1996 B2)** — Art: no; Sim: no
- [ ] **NEOWISE (C/2020 F3)** — Art: no; Sim: no
- [ ] **2P/Encke** — Art: no; Sim: no
- [ ] **109P/Swift–Tuttle** (parent of the Perseids) — Art: no; Sim: no

## Interstellar visitors

All three confirmed interstellar objects. Caveat for the implementing agent: these
are on hyperbolic escape trajectories in reality, which the `orbits` table (closed
Kepler ellipses) can't represent. Either approximate each as a very eccentric
long-period ellipse, or add one-shot hyperbolic flyby support — decide once and
note the choice here.

- [ ] **1I/ʻOumuamua** — Art: no; Sim: no
- [ ] **2I/Borisov** — Art: no; Sim: no
- [ ] **3I/ATLAS** — Art: no; Sim: no

## Deliberately excluded

Named here so future agents don't re-add them:

- **All remaining catalogued moons** — Jupiter's 90+ small irregulars beyond Himalia,
  Saturn's 280+ moonlets (Janus, Pan, Daphnis, ...), Uranus's minor moons (Puck,
  Cordelia, ...), Neptune's minor moons (Naiad, Hippocamp, ...), and Pluto's four
  small moons (Nix, Hydra, Kerberos, Styx). Too small/obscure for the target audience.
- **Asteroid and TNO satellites** (Dimorphos, Dysnomia, and the hundreds of
  binary-asteroid companions in the JPL small-body catalog).
- **Shoemaker–Levy 9** — famous, but it no longer exists (impacted Jupiter in 1994).

## Notes for the implementing agent

- Per body, the work is: (1) scifi-60s PNG in `art/scifi-60s/` (see the
  `art/themes/scifi-60s.md` style guide and `art/_wip/generated/` for how existing
  sources were made), (2) `PlanetConfig` + `names` entry in `src/config.zig`,
  (3) orbit entry in `src/main.zig` (`orbits` is index-aligned with `cfg.names`;
  there is a compile-time length assert).
- Moons orbit their parent's index with a small SOI; see the phobos/deimos and
  Galilean entries for tuned examples. Dwarf planets and comets orbit the sun
  (parent 0).
- Update this file's checkboxes and Art/Sim fields as you go.
