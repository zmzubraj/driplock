# Driplock site: design contract (v2, modern)

## Direction

Tokens that unlock drop by drop. The product is a stream, so the page is built around liquid filling a vessel, a level that rises in measured steps. It is a modern product page: the product's own interface is the imagery (stream cards, the unlock calendar, the recovery timeline), drawn crisply in code from real numbers. There are no stock photos and no crypto clichés.

## Tokens

| Name | Value | Role |
|---|---|---|
| paper | `#f3f6f7` | Page ground: cool, clean |
| ink | `#0f1d24` | Text |
| tide | `#0c4a55` | Dominant brand surface: the hero and the simulator band |
| tide-2 | `#0a3a43` | Deeper tide for contrast panels |
| drip | `#38c2d6` | The liquid: fills, the unlocked share, focus |
| amber | `#f0a43a` | Locked, cliff or window-closing states only |
| line | `#d7e0e3` | Hairlines |

## Type

- **Schibsted Grotesk (400 to 800):** everything. Headlines tight (-0.02em), numbers tabular.
- **JetBrains Mono:** code only.

## Layout idea

1. A dark tide hero with a large live stream card (the vessel filling drop by drop).
2. Three product rows that alternate sides, each a real interface fragment.
3. A tide band with the timeline simulator.
4. Builders, the inspection record, then the footer.

## Signature detail

The vessel: a liquid level that rises one step per month with a falling drop, and a live counter.

## Rules

- Product fragments are white cards with a 12px radius and one soft shadow. Nothing else gets a shadow.
- Amber appears only for locked, cliff or closing states.
- No gradients on text, no glass blur, no numbered cards, no all-caps mono labels, and no fake window chrome.
