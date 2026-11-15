# Demo artwork

`fanren.jpg`, `kurumi.jpg`, `after-the-rain.jpg`, `ice-castle.jpg`, `ranma.jpg`,
`student-council.jpg` and `avatar.jpg` are artwork-only crops of the macOS
reference screenshot supplied by the user on 2026-11-15. `ambience.jpg` is a
strongly downsampled/reconstructed crop of its empty background area, used as a static fixture.
Do not ship these fixtures as a production media catalog or describe them as
live server data. The title bar, cards, text and interactions are WinUI controls.

`avatar-nav.png` is a centered circular crop of `avatar.jpg` with transparent
edges, sized at 54×54 pixels for the 18 DIP navigation avatar. It lets the avatar
use the same native icon slot and selection indicator as the other navigation items.

The Interstellar, Dune, Spirited Away, Arrival and Blade Runner images were
downloaded from TMDB's public image CDN for the initial offline layout demo.
They remain temporary preview assets, not application branding.

`mac-*` assets and `catalog.json` are offline fixtures extracted from the local
macOS app image/metadata cache on 2026-11-15. The home stills and student-council
episode stills are artwork-only crops from the current native app screenshots.
`mac-*-detail.jpg` is the older progressively blurred detail fixture. The current
window background uses raw `mac-*-backdrop.jpg` assets and blurs them at runtime;
the detail's sharp and blurred layers share the same decoded image.
Original artwork and full screenshots remain local under the ignored reports
directory. No account credentials or server item identifiers are included in
this catalog. See `docs/DEMO-VALIDATION.md` for the remaining UI differences.
