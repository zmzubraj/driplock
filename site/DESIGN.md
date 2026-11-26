# Driplock site: design contract

## Direction

The bank-vault time lock. Since the 1870s, bank vaults have used clockwork time locks: once wound, the door cannot open early, not even for the manager. Driplock does the same for tokens. The page borrows that world: brushed steel, brass, white enamel dials, engraved plates and screws. It does not borrow digital-crypto clichés (neon, gradients, glass, coins).

## Tokens

| Name | Value | Role |
|---|---|---|
| nickel | `#dcdedd` | Page ground: cool, light, metallic |
| steel | `#4b5257` | Dominant surfaces: the hero plate and the guarantees plate |
| steel-deep | `#2f3438` | Text on light, dark plate edges |
| brass | `#9c7330` | Engraved accents, primary button, dial hand |
| brass-light | `#d6b676` | Engraving on steel |
| enamel | `#f6f5f0` | Dial faces, exhibit paper |
| hand-red | `#9a2b22` | Locked or cliff state only |

## Type

- **Big Shoulders Display (700, 800):** headlines and dial numerals, set like engraved plate lettering.
- **Public Sans (400, 600):** body text.
- **IBM Plex Mono (400):** code only.

## Layout idea

A sequence of plates bolted to a steel door: the hero plate over a photograph of a real time lock, a working dial, an engraved list of guarantees, then exhibits (a real page screenshot, a vault door photograph).

## Signature detail

The working dial. The visitor turns time forward and watches a real schedule unlock in monthly steps, the cancel window close at the cliff, and a backup take over after a lost key.

## Rules

- Screws (CSS dots) appear only on plates. There is no other decoration.
- Red appears only for the cliff or locked state.
- No numbered cards, no colored side stripes, no glass blur, and no single accented word in headlines.
