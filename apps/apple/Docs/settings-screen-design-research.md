# OcPlayer Settings Hub — UI Design Reference Research

Research report for restyling `App/Shared/Features/Settings/SettingsView.swift` to match the
"Rex"-style card section look (dark purple ambient background, section labels above cards,
rounded-square icon tiles, inset hairlines, floating tab bar).

**Deployment target:** iOS 26 / macOS 26 (per `README.md`), so every Liquid Glass API below is
available unconditionally — no `#available` gating needed.

### Method note — first-party measurements

Apple publishes **no numeric metrics** for inset-grouped list corner radii, row heights, separator
insets or icon tiles. Where the report says **"measured"**, I booted the iPhone 17 Pro simulator
(iOS 26.3, 402 × 874 pt, @3x = 1206 × 2622 px), launched `com.apple.Preferences` and the Health app,
took `simctl io … screenshot`, and measured pixel geometry directly with NumPy. Those numbers are
labelled **[measured]** and can be reproduced. Everything else is labelled with its source.

---

## ⚠️ Correction after implementation (2026-10-13) — read before using §4/§6

The research was written **before** the restyle was implemented. Three of its recommendations were
disproved by rendering the real `Form` on an iPhone 17 Pro simulator and measuring the bitmap.
The corrections below are what actually shipped; the original text is kept for the reasoning
and citations, but **do not implement §4's `.frame(minHeight: 54)` or §6's constants verbatim.**

| Research says | What actually happens | What shipped |
|---|---|---|
| §4/§6: row height `54` via `.frame(minHeight: 54)` | `.insetGrouped` row pitch = **content height + 30 pt** of system padding. `minHeight: 54` renders an **84 pt** pitch, not 54. Measured: no frame → 52.3 pt; `minHeight: 58` → 88.0 pt; `minHeight: 28` → 58.0 pt. | `SettingsMetrics.rowContentMinHeight = 28` (content), `systemRowInsets = 30`, `rowPitch = 58` — matching Rex's measured 57.8 pt |
| §3: separator inset needs `.alignmentGuide(.listRowSeparatorLeading)` | iOS 16+ already aligns the separator to the leading text edge; with and without the guide the separator started at **exactly 69 pt**. The guide is intent-as-code, not a working fix. | Guide kept, comment corrected, and a test pins the **result** (69 pt), not the modifier |
| §6: card corner radius `22` via `RoundedRectangle` | Not needed — `insetGrouped` supplies the continuous card shape and corner radius natively; painting our own fights the system's iOS 26 radii. | Card = per-section `listRowBackground(SettingsCardFill())` only |
| §6: row height `52.3` labelled "Row pitch (= row height, no gaps)" | That equals Apple's *pitch*; the "no gaps" gloss is what invites the +30 pt mistake above. | — |

Two further findings worth carrying forward:

* **Apple's own measured pitch is 52.3 pt, and Rex's is 57.8 pt.** Rex is not exotic — it is Apple's
  `.insetGrouped` metrics with a slightly taller row and a bigger icon glyph.
* **The icon tile question resolved against tiles.** Rex has *no* tile: its glyph sits directly on
  the card in white (measured: a column with no glyph reads 77.3 luma vs 79.0 for bare card fill).
  Apple's own Settings app *does* use 29 pt tiles. We took Rex's tile-less treatment and only
  fixed the tint (system accent → `.primary` monochrome).

---

## 1. Apple HIG / iOS 26 Liquid Glass specifics for Settings-style screens

### 1.1 What Apple actually documents about inset-grouped lists

Apple's `ListStyle.insetGrouped` reference says only:

> "On iOS, the inset grouped list style displays a continuous background color that extends from the
> section header, around both sides of list items in the section, and down to the section footer.
> This visually groups the items to a greater degree than either the `.inset` or `.grouped` styles do."

— [Apple: `ListStyle.insetGrouped`](https://developer.apple.com/documentation/swiftui/liststyle/insetgrouped)

Note the phrase **"extends from the section header"**: the header is *outside* the rounded container
and the card starts below it. That is exactly the Rex layout, and it is the native iOS behaviour —
you do not have to fight the framework to get headers above cards.

The HIG "Lists and tables" page is qualitative only; it specifies no metrics:

> "In iOS and iPadOS, for example, the grouped style uses headers, footers, and additional space to
> separate groups of data" … "Choose a row style that fits the information you need to display. For
> example, you might need to display a small image in the leading end of a row, followed by a brief
> explanatory label."

— [HIG: Lists and tables](https://developer.apple.com/design/human-interface-guidelines/lists-and-tables)

It also warns against mixing disclosure affordances — relevant because your rows navigate:

> "Avoid adding an index to a table that displays controls — like disclosure indicators — in the
> trailing ends of its rows."

— [HIG: Lists and tables](https://developer.apple.com/design/human-interface-guidelines/lists-and-tables)

### 1.2 What changed in iOS 26 (Liquid Glass) for lists, cards, headers, tab bars

Apple's migration guide is the authoritative source. Three changes matter directly here:

> "To give content room to breathe, organizational components like lists, tables, and forms have a
> **larger row height and padding**. Sections have an **increased corner radius** to match the
> curvature of controls across the system."

> "**Check capitalization in section headers.** Lists, tables, and forms optimize for legibility by
> adopting **title-style capitalization** for `Section(content:header:)`. This means section headers
> **no longer render entirely in capital letters** regardless of the capitalization you provide."

> "**Adopt forms to take advantage of layout metrics across platform.** Use SwiftUI forms with the
> `.grouped` [style] to automatically update your form layouts."

— [Apple: Adopting Liquid Glass](https://developer.apple.com/documentation/technologyoverviews/adopting-liquid-glass)

The same page also tells you to stop painting your own bar backgrounds, which is directly relevant to
your bottom tab bar:

> "**Reduce your use of custom backgrounds in controls and navigation elements.** Any custom
> backgrounds and appearances you use in these elements might overlay or interfere with Liquid Glass
> or other effects that the system provides, such as the scroll edge effect."

— [Apple: Adopting Liquid Glass](https://developer.apple.com/documentation/technologyoverviews/adopting-liquid-glass)

WWDC25 session 323 restates the geometry rule that governs nested radii:

> "Many of our controls have their corners aligned perfectly within their containers… This is called
> **corner concentricity**. For example, a button that is positioned at the bottom of a sheet should
> share the same corner center with the corners of the sheet."

> "To build views that automatically maintain concentricity with their container, use the concentric
> rectangle shape."

— [WWDC25 323: Build a SwiftUI app with the new design](https://developer.apple.com/videos/play/wwdc2025/323/)

WWDC25 session 356 gives the arithmetic explicitly:

> "We use three shape types to build concentric layouts: fixed shapes have a constant corner radius.
> Capsules use a radius that's half the height of the container. And **concentric shapes calculate
> their radius by subtracting padding from the parent's**."

— [WWDC25 356: Get to know the new design system](https://developer.apple.com/videos/play/wwdc2025/356/)

That is the rule to apply between your card (outer) and icon tile (inner): an inner radius is
visually correct when it equals `outerRadius − padding`, sharing a common corner centre.

### 1.3 Tab bars on iOS 26

The HIG now describes the floating bar directly:

> "A tab bar **floats above content** at the bottom of the screen. Its items rest on a
> [Liquid Glass] background that allows content to peek through."

> "For tab bars with an attached accessory, like the MiniPlayer in Music, you can choose to minimize
> the tab bar and move the accessory inline with it when a person scrolls down."

— [HIG: Tab bars](https://developer.apple.com/design/human-interface-guidelines/tab-bars)

Apple does **not** publish the iOS tab bar height or selection-pill shape (it publishes the tvOS
value, 68 pt, explicitly — which shows the omission for iOS is deliberate). **[measured]** on
iOS 26.3, iPhone 17 Pro:

| Tab bar metric | Measured value |
|---|---|
| Bar capsule vertical extent | y 791.0 → 853.0 pt = **62 pt tall** |
| Leading inset | ≈ **21 pt** |
| Trailing inset | 402 − 380 = ≈ **22 pt** |
| Bottom inset | 874 − 853 = **21 pt** |

These independently corroborate a third-party teardown which states:

> "The bar is **inset** from the screen edges (21pt on left, right, and bottom)" … "The **labels** are
> **11pt** text in SF" … "The **selected destination** is shown in the app's brand color"

— [Learn UI Design: The iOS 26 Design Guidelines, An Illustrated Guide](https://www.learnui.design/blog/ios-design-guidelines-templates.html)

**Do not hand-roll this.** The pill-shaped selection, the glass material, the scroll-linked
minimisation and the safe-area maths are all system-drawn. Apple's own guidance is to use `TabView`:

> "**Consider adapting your tab bar into a sidebar automatically** … **Choose whether to automatically
> minimize your tab bar in iOS.**"

— [Apple: Adopting Liquid Glass](https://developer.apple.com/documentation/technologyoverviews/adopting-liquid-glass)

Your app already uses the correct modern API — `TabView` with `Tab(_:systemImage:value:)` and a
`Tab(role: .search)` — in `App/Shared/AppShell.swift:158-212`. The only missing piece for the maximally
modern behaviour is `.tabBarMinimizeBehavior(.onScrollDown)`, documented as:

> "The following `TabView` minimizes its tab bar when scrolling in the 'Numbers' or 'Alerts' tabs on iPhone."

— [Apple: `tabBarMinimizeBehavior(_:)`](https://developer.apple.com/documentation/swiftui/view/tabbarminimizebehavior(_:))

If you want a now-playing strip above the tab bar (natural for a media player), that is
`tabViewBottomAccessory(content:)` — iOS 26 only, and it collapses *into* the bar when minimised:

> "On iPhone, the placement of the bottom accessory depends on the tab bar size: when the tab bar is
> normal size, the accessory appears above it; when the tab bar is collapsed, the accessory displays
> inline."

— [Apple: `tabViewBottomAccessory(content:)`](https://developer.apple.com/documentation/swiftui/view/tabviewbottomaccessory(content:))

### 1.4 [measured] Apple's real inset-grouped geometry on iOS 26

Measured from the Settings root screen of iOS 26.3 on iPhone 17 Pro (402 × 874 pt). Card "B" is the
8-row *通用 / 辅助功能 / …* group.

| Metric | Measured value | Notes |
|---|---|---|
| Screen | 402 × 874 pt | @3x |
| Card horizontal inset | **16 pt** each side | card width **370 pt** |
| Card corner radius | **≈ 21.3 pt** | vertical corner extent; ASCII plot of the corner confirmed a continuous curve |
| Row pitch (= row height, no gaps) | **52.3 pt** | separator-to-separator; identical across all 8 rows |
| Card height, 8 rows | 418.3 pt | 418.3 / 8 = 52.3 ✓ |
| Section gap, headerless (card→card) | **35 pt** | measured card A bottom 258.0 pt → card B top 293.3 pt |
| Separator colour | `#E8E8E8` on white | i.e. ≈ `Color.black.opacity(0.09)` |
| Separator band | 3 device px = **1.0 pt** | antialiasing may widen a true hairline; treat 1 pt as the upper bound |
| Separator leading inset | **56 pt from card edge** | = 16 (card inset) + 40; **exactly** the label leading edge |
| Separator trailing inset | **0 pt** | runs flush to the card's trailing edge |
| Icon tile | **29 × 29 pt** | square |
| Icon tile leading inset | **13.67 pt** from card edge | ≈ 14 pt |
| Icon tile corner radius | **≈ 7 pt** continuous | best circular fit ≈ 8 pt; ratio ≈ 0.24 × tile size |
| Tile → label gap | **14 pt** | label leading = 56.67 pt from card edge |
| Label ink height | 15 pt (CJK glyphs) | consistent with the 17 pt system body style |
| Card background | pure white `#FFFFFF` | on grouped background `#F2F2F7` |

Two of these are the load-bearing ones for you:

1. **The separator inset is not arbitrary — it equals the label's leading edge.** That is precisely
   the Rex behaviour you described, and it is the native iOS behaviour since iOS 16 (see §3.2).
2. **Apple's own tile is 29 pt, not 34–40 pt.** Rex's 34–40 pt tiles are a deliberate deviation.
   If you want to stay Apple-idiomatic, 29–30 pt; if you want the Rex look, 34 pt is the safe
   maximum before rows start to feel top-heavy at a 52 pt row height.

### 1.5 Standard Apple metrics you must not violate

> "**Offer sufficiently sized controls.** … Strive to meet the recommended minimum control size for
> each platform" — Default control size **44x44 pt**, Minimum control size **44x44 pt** (iOS).

> "**Consider spacing between controls as important as size.** … it works well to add about **12
> points** of padding around elements that include a bezel. For elements without a bezel, about
> **24 points** of padding works well around the element's visible edges."

— [HIG: Accessibility](https://developer.apple.com/design/human-interface-guidelines/accessibility)

> "Follow the recommended default and minimum text sizes for each platform" — Default **17 pt**,
> minimum **11 pt** (iOS).

— [HIG: Typography](https://developer.apple.com/design/human-interface-guidelines/typography)

> "**Support larger text sizes.** … Ideally, give people the option to enlarge text by at least
> **200 percent**."

— [HIG: Accessibility](https://developer.apple.com/design/human-interface-guidelines/accessibility)

> "**Be prepared for text-size changes.** … table rows or other containers **may need to grow in
> height** so that text isn't cropped or doesn't overlap other content; and table rows with a single
> line of text by default might need to grow vertically to accommodate multiple lines of text."

— [HIG: Layout](https://developer.apple.com/design/human-interface-guidelines/layout)

The last one is the direct constraint on your "row height ~52–56 pt" target: **it must be a minimum,
never a fixed height.**

---

## 2. Real-world "beautiful settings screen" analyses

### 2.1 Typography scale that well-regarded iOS apps converge on

The most complete public tabulation of the iOS type ramp, matched against Apple's own text styles:

| Element | Style | Light colour | Dark colour |
|---|---|---|---|
| Paragraph text, **list item titles**, input text | **17 pt regular** | `#000` | `#FFF` |
| Secondary text | **15 pt regular** | `#3C3C43` @ 60 % | `#EBEBF5` @ 70 % |
| Tertiary text, **captions** | **13 pt regular** | `#3C3C43` @ 30 % or 60 % | `#EBEBF5` @ 30 % or 70 % |
| Tab bar labels | **11 pt regular** | `#1A1A1A` | `#F5F5F5` |
| Toolbar labels | **17 pt medium** | `#1A1A1A` | `#F5F5F5` |

> "iOS has a mildly opinionated typographical language — it tends to style text with **weight or
> color**, rather than size or case."

— [Learn UI Design: The iOS 26 Design Guidelines](https://www.learnui.design/blog/ios-design-guidelines-templates.html)

**Implication for your section headers.** Rex uses "small gray text" above the card. The
system-consistent choice is **13 pt** (`.footnote`) — *not* 11 pt uppercase-with-tracking, which is
the pre-iOS-26 idiom Apple explicitly moved away from ("section headers no longer render entirely in
capital letters", [Adopting Liquid Glass](https://developer.apple.com/documentation/technologyoverviews/adopting-liquid-glass)).
Use sentence case or title-style capitalisation, `.footnote`, `.secondary`. If you want more presence,
`headerProminence(.increased)` is the sanctioned lever:

> "For iOS 15.0+ you can also increase the header prominence, which makes the section header larger
> and bold. This works also with dynamic types."

— [SwiftyPlace: How to Customise the SwiftUI List Style](https://www.swiftyplace.com/blog/customise-list-view-appearance-in-swiftui-examples-beyond-the-default-stylings)
(API: [`headerProminence(_:)`](https://developer.apple.com/documentation/swiftui/view/headerprominence(_:)))

### 2.2 The icon tile: the community-standard number and Apple's real number

The accepted StackOverflow answer for reproducing Apple Settings' tiles — score 7, accepted — gives
these literal values in code:

```swift
configuration.icon
    .font(.system(size: 17))
    .foregroundColor(.white)
    .background(
        RoundedRectangle(cornerRadius: 7)
            .frame(width: 28, height: 28)
            .foregroundColor(color)
    )
```

— [Stack Overflow: How would you make Icons like in the Settings App (SwiftUI)](https://stackoverflow.com/questions/69836958/how-would-you-make-icons-like-in-the-settings-app-swiftui)

That is a **28 × 28 pt tile at radius 7 pt** — a ratio of **0.25**. My independent **[measured]**
value from Apple's shipping iOS 26 Settings is **29 × 29 pt at ≈ 7 pt continuous** — a ratio of
**0.24**. The two agree, which is a good sign that ~0.24–0.25 × tileSize is the correct radius ratio.

A commenter on the same thread flags the trap you must avoid:

> "your answer does not allow the SFFont to scale with user preferences … They look weird [when you
> change the Text setting]."

— [Stack Overflow](https://stackoverflow.com/questions/69836958/how-would-you-make-icons-like-in-the-settings-app-swiftui)

### 2.3 Tint strategy: per-row accent vs monochrome vs single brand tint

**[measured]** Apple's own strategy in iOS 26 Settings is **per-row colour**, and it is semantic,
not decorative:

| Row | Tile colour [measured] |
|---|---|
| 通用 (General) | mid grey |
| 辅助功能 (Accessibility) | system blue `#0089FE` |
| 操作按钮 (Action Button) | system blue |
| 待机显示 (StandBy) | near-black |
| 搜索 (Search) | mid grey |
| 相机 (Camera) | mid grey |
| 主屏幕与 App 资源库 | system blue |
| Apple 智能与 Siri | **multicolour / iridescent** |
| 屏幕时间 (Screen Time) | purple |

Note that in iOS 26 these tiles render as full-colour, app-icon-like artwork, not flat glyph tiles.
For a third-party app the two defensible strategies are:

- **Per-row accent (Rex-like, Apple-like).** Assign a colour per destination and keep it stable.
  This is the strongest scannability play in a settings hub where each row is a *destination*.
- **Single brand tint (monochrome tiles).** Lower noise, stronger brand signal. Apple's Liquid Glass
  guidance leans this way for chrome:

> "In the new design, toolbar icons use **monochrome rendering** by default. The monochrome palette
> reduces visual noise and maintains legibility. Use `tint(_:)` only to convey meaning."

— [WWDC25 323: Build a SwiftUI app with the new design](https://developer.apple.com/videos/play/wwdc2025/323/) (as summarised in the bundled `swiftui-expert-skill` Liquid Glass reference)

Since your app already has a purple ambient background (see §3.6), a **single purple-family tint with
per-row hue rotation for the three "service" rows** (Jellyfin / Bangumi / MoviePilot) gives you the
Rex feel without a rainbow. Apple's general colour rule:

> "**Review your use of color in controls.** Be judicious with your use of color in controls and
> navigation so they stay legible. If you do apply color to these elements, leverage system colors,
> or define a custom color with light and dark variants, and an increased contrast option for each
> variant."

— [Apple: Adopting Liquid Glass](https://developer.apple.com/documentation/technologyoverviews/adopting-liquid-glass)

### 2.4 Card + divider recipe from a published SwiftUI design system

The most directly reusable published code is Swift with Majid's "List replacement" primitives, which
solve exactly your problem (a card of rows with inset dividers):

```swift
public struct DividedCard<Content: View>: View {
    public var body: some View {
        subview
        if subviews.last?.id != subview.id {
            Divider()
                .padding(.vertical, 8)
                .padding()
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 32))
    }
}
```

— [Swift with Majid: Building List replacement in SwiftUI](https://swiftwithmajid.com/2026/04/06/building-list-replacement-in-swiftui)

Three takeaways with numbers: card radius **32 pt** (material-backed, not a solid fill), `Divider()`
with **8 pt vertical padding**, and the divider inset with a plain `.padding()`. His accompanying
`NavigationButtonStyle` exists specifically because:

> "One thing you can miss from using List view in SwiftUI is the styling of a NavigationLink. List
> automatically adds the chevron on the trailing edge… Fortunately, we can achieve that using a custom
> button style."

— [Swift with Majid](https://swiftwithmajid.com/2026/04/06/building-list-replacement-in-swiftui)

### 2.5 When to abandon `List` (and when not to)

The clearest decision rule found:

> "Stay with `ScrollView` plus `LazyVStack` when you need a **custom feed: mixed card shapes,
> full-bleed sections, nested horizontal scrollers, custom pinned headers, bespoke transitions, or
> layout that does not want to look like a platform list**."

> "The mistake is treating `List` as a performance panic button."

— [The Swift Dev: Fix SwiftUI Lazy Stack Jank Before You Switch To List](https://www.theswift.dev/posts/fix-swiftui-lazy-stack-jank-before-you-switch-to-list)

And on the raw capability split:

> "Since iOS 17, the combination of `ScrollView` and `LazyVStack` has far surpassed `List` in terms of
> scroll control capabilities and convenience … when precise subview scrolling or varying visual
> effects based on subview positions are needed, `LazyVStack` is undoubtedly the superior choice."

— [Fatbobman: List or LazyVStack](https://fatbobman.com/en/posts/list-or-lazyvstack)

For a settings hub the data set is tiny (10–20 rows, no recycling need), so **performance is not the
deciding factor**. The deciding factor is whether you need per-row corner control (→ `LazyVStack`) or
free platform behaviours like swipe actions, edit mode, keyboard navigation and free macOS support
(→ `List`).

---

## 3. SwiftUI implementation recipes for exactly this look

### 3.1 The two architectures

| | **A. `List` / `Form` + `.insetGrouped`** | **B. `ScrollView` + `LazyVStack` + hand-rolled cards** |
|---|---|---|
| Card radius control | none directly (system-chosen; **≈21 pt on iOS 26 [measured]**) | full control (`cornerRadius: 22`) |
| First/last row corner radius | free and correct | free and correct **if you round the whole stack once** (§3.3) |
| Separator inset | free and correct (iOS 16+) | manual, trivial |
| Row height | free, Dynamic-Type-correct | manual, easy to get wrong |
| macOS behaviour | `Form` + `.formStyle(.grouped)` just works | you rebuild everything |
| Keyboard nav / Focus | free | manual |
| Swipe actions / `.refreshable` | free | manual |
| Ambient gradient background | `.scrollContentBackground(.hidden)` + background layer | trivial |
| Effort to reach Rex's look | **low** — mostly tile + background work | medium–high |

**Recommendation: start with A.** Your measured target values are within ~2 pt of Apple's shipping
iOS 26 values (card radius 22 vs 21.3 measured; row height 54 vs 52.3 measured; separator inset =
label leading, identical). That means the Rex look is *approximately what `.insetGrouped` already
renders on iOS 26*, and the only genuinely custom parts are:

1. the dark purple ambient background behind the list,
2. the leading icon tile (34–40 pt vs Apple's 29 pt),
3. the card fill colour (translucent over the gradient, not opaque white).

Only move to architecture B if (3) proves impossible to express with `.listRowBackground`.

### 3.2 Separator inset — how to control it (and the iOS 16 behaviour change)

Since iOS 16, `List` row separators inset **automatically to the leading text**, which is exactly
what Rex does and what Apple does:

> "In iOS 16, `List` row separator insets automatically and aligns to the text. Here is a comparison
> of the same code of the `.insetGrouped` list style on iOS 15 vs. iOS 16."

> "Hmm, `List` line separators of system apps, e.g., Settings App, will have an inset or padding that
> makes separators align with text, not to icon."

— [Sarunw: How to adjust List row separator insets in SwiftUI](https://sarunw.com/posts/swiftui-list-row-separator-insets)

To control it precisely, SwiftUI exposes dedicated alignment guides:

> "`listRowSeparatorLeading` — A guide marking the leading edge of a `List` row separator. … Use this
> guide to align the leading end of the bottom `List` row separator with any other horizontal guide of
> a view that is part of the cell content."

— [Apple: `HorizontalAlignment.listRowSeparatorLeading`](https://developer.apple.com/documentation/swiftui/horizontalalignment/listrowseparatorleading)

```swift
HStack(spacing: 12) {
    IconTile(...)
    Text(title)
        .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] }   // hairline starts at the label
    Spacer()
    Text(value).foregroundStyle(.secondary)
}
```

The trailing guide is `.listRowSeparatorTrailing` ([Nil Coalescing: Adjust List row separator insets](https://nilcoalescing.com/blog/AdjustListRowSeparatorInsets)).

If you need hairlines that do **not** follow the label — e.g. Rex-style separators that stop short of
the card edge — the standard trick is to hide the system ones and draw your own:

```swift
Text(title)
    .listRowSeparator(.hidden)
```

Apple's semantics for that modifier are important:

> "This modifier expresses a preference to the containing `List`. **The list style is the final
> arbiter** of the separator visibility."

— [Apple: `listRowSeparator(_:edges:)`](https://developer.apple.com/documentation/swiftui/view/listrowseparator(_:edges:))

So never rely on it alone; verify on device. Note also that every section gets an extra separator
after it, hidden separately:

> "Each section also gets separators added after the section. You can hide section separators with the
> `listSectionSeparator` modifier."

— [SwiftyPlace: Customise the SwiftUI List Style](https://www.swiftyplace.com/blog/customise-list-view-appearance-in-swiftui-examples-beyond-the-default-stylings)
(API: [`listSectionSeparator(_:edges:)`](https://developer.apple.com/documentation/swiftui/view/listsectionseparator(_:edges:)))

Do **not** use `Divider()` as a list row — Apple's own docs and community testing both warn:

> "A `List` separator is not the same as a `Divider`. If you try to use a `Divider` view, it will be
> treated as a list row and additional spacing and styling are added."

— [SwiftyPlace](https://www.swiftyplace.com/blog/customise-list-view-appearance-in-swiftui-examples-beyond-the-default-stylings)

### 3.3 First and last row corner radius — the robust trick

The failure mode with hand-rolled cards is per-row corner logic (`.topLeading` on row 0,
`.bottomLeading` on row n, all four in the middle) which breaks the moment a section has one row or
rows become conditional. **Round the container once, not the rows:**

```swift
VStack(spacing: 0) {
    ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
        SettingsRow(row)
        if index < rows.count - 1 { Hairline() }
    }
}
.background(cardFill, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
.contentShape(.rect)          // whole card is one hit region… but see §5 for why not on rows
```

With this, first/last row corners are correct by construction, and `UnevenRoundedRectangle` is only
needed if the card is visually clipped by an outer container.

**If you want the concentric behaviour**, iOS 26 gives you the correct primitive:

> "Sets the container shape to use for any container relative shape or **concentric rectangle** within
> this view."

— [Apple: `containerShape(_:)`](https://developer.apple.com/documentation/swiftui/view/containershape(_:))

> "`ConcentricRectangle` automatically calculates each corner's radius relative to the container shape,
> so your view adapts correctly across devices and sizes **without hard-coded values**."

> "It's also possible that your app is running on a device whose corners are square. To ensure that
> your view always has rounded corners that are concentric relative to the container shape when they
> can be, use `concentric(minimum:)` to specify a rounded corner with a minimum radius."

— [Apple: `ConcentricRectangle`](https://developer.apple.com/documentation/swiftui/concentricrectangle)

A worked, cited example — including the exact caveat that trips people up:

> "Applying `.containerShape(.rect(cornerRadius: 24))` to the `ZStack` in `Card` ensures that the
> background `ConcentricRectangle` matches the 24-point corner radius exactly, while the foreground
> `ConcentricRectangle` becomes a concentric version of the container shape where the corner radius is
> computed as **24 minus the padding**. The top corners of the foreground `ConcentricRectangle` will
> be rounded by default, but **the bottom corners would get a radius of 0** because of their greater
> distance to the parent container corners unless we set `isUniform` to true."

— [Nil Coalescing: Corner concentricity in SwiftUI on iOS 26](https://nilcoalescing.com/blog/ConcentricRectangleInSwiftUI)

So: if your 29–34 pt icon tile sits 14 pt inside a 22 pt card with 14 pt vertical padding, a plain
`ConcentricRectangle` will give the tile a *very small* radius (22 − 14 = 8 on the near corners,
0 on the far ones). Use the uniform form to avoid lopsided tiles:

```swift
struct SettingsCard<Content: View>: View {
    @ContentBuilder var content: Content          // Group(subviews:) style decomposition
    private let radius: CGFloat = 22

    var body: some View {
        VStack(spacing: 0) { content }
            .containerShape(.rect(cornerRadius: radius))
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}

// inside a row:
Image(systemName: symbol)
    .font(.system(size: 17, weight: .semibold))
    .foregroundStyle(.white)
    .frame(width: 29, height: 29)
    .background(
        ConcentricRectangle(corners: .concentric(minimum: 7), isUniform: true).fill(tint),
        in: .rect(corners: .concentric(minimum: 7), isUniform: true)
    )
```

### 3.4 Section spacing

```swift
.listSectionSpacing(35)                        // iOS 17+, points
.listSectionSpacing(.compact)                  // .compact / .default / .custom(_:)
```

Apple documents the exact half-and-half semantics:

> "If adjacent sections have different spacing applied, **each section applies half its spacing above
> and below** … In the above example, the 'Colors' and 'Borders' section are separated by 10 pts of
> spacing, and the 'Borders' and 'Shapes' section are separated by 55 pts of spacing."

— [Apple: `listSectionSpacing(_:)`](https://developer.apple.com/documentation/swiftui/view/listsectionspacing(_:))

So `.listSectionSpacing(35)` reproduces the **[measured]** 35 pt iOS 26 gap. Note `.listSectionSpacing`
has **no macOS availability** in its declaration (iOS 17 / iPadOS 17 / Mac Catalyst 17 / visionOS 1 /
watchOS 10) — gate it or use `.listSectionMargins` on macOS.

iOS 26 adds per-edge section margins, which is how you dial the card's horizontal inset:

> "The default section margins are based on the list style, list section spacing and content margins of
> the list. **Using this modifier overrides these default values completely.**"

— [Apple: `listSectionMargins(_:_:)`](https://developer.apple.com/documentation/swiftui/view/listsectionmargins(_:_:)) (iOS 26 / iPadOS 26 / Mac Catalyst 26 / visionOS 26)

To match the **[measured]** 16 pt card inset: `.listSectionMargins(.horizontal, 16)`.

### 3.5 Row insets, row spacing, and the iOS 18 caveat

```swift
.listRowInsets(EdgeInsets(top: 0, leading: 14, bottom: 0, trailing: 16))   // iOS 13+
.listRowSpacing(0)                                                        // iOS 15+
```

Apple warns about a real layout gotcha with `listRowInsets`:

> "On iOS 18 and earlier, and on visionOS 2 and earlier, the content of list rows can **grow slightly
> into the row insets**. The effective vertical insets can then be smaller than expected."

— [Apple: `listRowInsets(_:)`](https://developer.apple.com/documentation/swiftui/view/listrowinsets(_:))

Since you target iOS 26 only, this does not bite you — but it *does* mean the same code on an iOS 18
device will look different, which matters if you ever lower the deployment target.

Row height: there is no "set the row height" API. Row height is emergent from the content plus
`.listRowInsets`. To hit **54 pt**, give the row content a `.frame(minHeight: 54)` (min, not fixed —
see §5) and let the insets be 0.

### 3.6 The ambient gradient background

The system's own grouped background is `#F2F2F7` light / black dark, and Apple's rule is to hide the
list's own background and supply yours:

```swift
List { … }
    .scrollContentBackground(.hidden)          // iOS 16+ / macOS 13+
    .background { AmbientBackdrop() }          // your purple gradient
```

> "With iOS 16+ and macOS 13+, you can now directly remove the list background with a new modifier
> `scrollContentBackground`. This also works for `ScrollView` and `TextEditor`."

— [SwiftyPlace](https://www.swiftyplace.com/blog/customise-list-view-appearance-in-swiftui-examples-beyond-the-default-stylings)

OcPlayer already does exactly this at `App/Shared/Features/Settings/SettingsView.swift:70-71`
(`.scrollContentBackground(.hidden)` + `.formStyle(.grouped)`), and already has an ambience component
at `App/Shared/DesignSystem/PageAmbience.swift` and `App/Shared/DesignSystem/BackdropAmbienceView.swift`.
The Rex look is therefore mostly a matter of **feeding the existing ambience into the Settings hub**
and **replacing the transparent row background with a translucent card fill**.

⚠️ One conflict to resolve: your existing helper at `SettingsView.swift:146-152` is

```swift
func settingsRowBackground() -> some View {
    #if os(iOS)
    listRowBackground(Color.clear)
    #else
    self
    #endif
}
```

`Color.clear` is correct for letting the ambient gradient through, but it means **the rows have no card
at all** — you are seeing the ambient wash, not a card. To get Rex's card you need a *translucent*
fill (e.g. `.ultraThinMaterial` or `Color.white.opacity(0.06)` in dark mode) applied **per section**,
plus `.listRowBackground` applied to the *first* section only if you want a single card per section.
The idiomatic way to get one card per section is to leave the row backgrounds clear and put the card
behind the section using a `Section` background — or, more reliably, to move to architecture B.

### 3.7 Scroll edge effects (iOS 26)

> "By default, a scroll view renders an automatic edge effect. Use this modifier to change the scroll
> edge effect style."

```swift
ScrollView { LazyVStack { … } }
    .scrollEdgeEffectStyle(.hard, for: .all)
```

— [Apple: `scrollEdgeEffectStyle(_:for:)`](https://developer.apple.com/documentation/swiftui/view/scrolledgeeffectstyle(_:for:))

Related: [`scrollEdgeEffectHidden(_:for:)`](https://developer.apple.com/documentation/swiftui/view/scrolledgeeffecthidden(_:for:))
and [`safeAreaBar(edge:alignment:spacing:content:)`](https://developer.apple.com/documentation/swiftui/view/safeareabar(edge:alignment:spacing:content:)).

**Do not add your own darkening gradient behind the nav bar / tab bar.** Apple is explicit:

> "An automatic scroll edge effect blurs and fades content under system toolbars to keep controls
> legible. **Remove any custom background-darkening effects behind bar items, as they will interfere.**"

— [WWDC25 323](https://developer.apple.com/videos/play/wwdc2025/323/) (as summarised in the bundled `swiftui-expert-skill` Liquid Glass reference)

And from the HIG:

> "Instead of applying a solid or semi-opaque background color beneath controls, use a scroll edge
> effect to visually elevate controls above content."

— [HIG: Layout](https://developer.apple.com/design/human-interface-guidelines/layout)

Your `AppShellChrome.swift` already uses `.glassEffect(.regular, in: Capsule())` at line 29 and
`.glassEffect(.regular, in: .rect(cornerRadius: 9, style: .continuous))` at line 124 — check these
against the "don't hand-paint chrome" rule.

### 3.8 Keeping macOS sane on the same codebase

Apple's own pattern for dual-platform settings:

> "When you use an `App` declaration for multiple platforms, compile the settings scene **only in macOS**."

```swift
@main
struct MyApp: App {
    var body: some Scene {
        WindowGroup { ContentView() }
        #if os(macOS)
        Settings { SettingsView() }
        #endif
    }
}
```

— [Apple: `Settings`](https://developer.apple.com/documentation/swiftui/settings)

> "**Adopt forms to take advantage of layout metrics across platform.** Use SwiftUI forms with the
> `grouped` [style] to automatically update your form layouts."

— [Apple: Adopting Liquid Glass](https://developer.apple.com/documentation/technologyoverviews/adopting-liquid-glass)

> "Rows in a grouped rows form have leading aligned labels and trailing aligned controls within
> visually grouped sections."

— [Apple: `FormStyle.grouped`](https://developer.apple.com/documentation/swiftui/formstyle/grouped)

Practical rules for your shared file:

1. Keep `Form` + `.formStyle(.grouped)` as the root on both platforms — it is the API Apple tells you
   to use, and it gives you the macOS Settings look for free.
2. Gate iOS-only modifiers. `.listSectionSpacing` has no macOS availability; `.listSectionMargins` is
   iOS 26 / iPadOS 26 / Mac Catalyst 26 / visionOS 26 only (no macOS). Use `#if os(iOS)` around them.
   `.scrollContentBackground(.hidden)` **is** available on macOS 13+, so the ambient background works
   on both.
3. Do **not** apply the floating-tab-bar treatment on macOS — macOS has no tab bar in this sense;
   use `NavigationSplitView` + a `Settings` scene.
4. `listRowSeparator` **is** available on macOS 13+ ([Apple](https://developer.apple.com/documentation/swiftui/view/listrowseparator(_:edges:))),
   but the macOS grouped form draws its own separators; verify visually.
5. Your existing `#if os(iOS)` branch in `settingsRowBackground()` is the right shape — keep that
   pattern for every new metric.

---

## 4. Icon tile components

### 4.1 Concrete geometry

| Parameter | Value | Source |
|---|---|---|
| Tile size (Apple-idiomatic) | **29 × 29 pt** | **[measured]** iOS 26.3 Settings |
| Tile size (Rex-like) | **34 pt** (34–40 acceptable) | user's description of Rex |
| Tile corner radius | **7 pt** at 29 pt; **8–9 pt** at 34 pt | **[measured]** ≈ 7 pt; ratio 0.24–0.25 corroborated by the SO recipe (7/28) |
| Corner curve style | `.continuous` | SwiftUI's `RoundedRectangle(cornerRadius:style:)`; default changed from `.circular` to `.continuous` in iOS 17 ([Hacking with Swift: SwiftUI's built-in shapes](https://www.hackingwithswift.com/quick-start/swiftui/swiftuis-built-in-shapes)) |
| Glyph point size | **15–17 pt** | SO recipe uses `.font(.system(size: 17))` on a 28 pt tile; **[measured]** Apple's custom artwork ink measures 22.0 × 22.3 pt inside a 29 pt tile (76 %) — an upper bound, not a target for SF Symbols |
| Glyph weight | `.semibold` (or `.medium`) | Apple HIG: "avoid Ultralight, Thin, and Light font weights, which can be difficult to see, especially when text is small" — [HIG: Typography](https://developer.apple.com/design/human-interface-guidelines/typography) |
| Glyph colour | `.white` | **[measured]** Apple's glyph ink on the blue tile is pure white |
| Tile → label gap | **12–14 pt** | **[measured]** 14.0 pt in Apple Settings |
| Tile leading inset in card | **14 pt** | **[measured]** 13.67 pt |
| Tile vertical centring | centred in the row | **[measured]** tile top offset 12.33 pt from the separator in a 52.33 pt row → (52.33 − 29) / 2 = 11.67 ✓ |

### 4.2 `.font(.system(size:weight:))` vs `.imageScale(_:)`

`Image.Scale` is defined as:

> "A scale to apply to **vector images relative to text**."

> "Use this type with the `imageScale(_:)` modifier, or the `imageScale` environment key, to set the
> image scale."

— [Apple: `Image.Scale`](https://developer.apple.com/documentation/swiftui/image/scale)

The distinction that matters:

| | `.imageScale(.small/.medium/.large)` | `.font(.system(size:weight:))` |
|---|---|---|
| Unit | relative to the **current text style** | absolute points |
| Scales with Dynamic Type | **yes**, automatically | **no** — needs `@ScaledMetric` |
| Weight control | inherits text weight | explicit |
| Predictable tile fit | less | more |

**Recommended: absolute size + `@ScaledMetric`,** so the tile and glyph grow together and the tile
stays square:

```swift
@ScaledMetric(relativeTo: .body) private var tileSize: CGFloat = 29
@ScaledMetric(relativeTo: .body) private var glyphSize: CGFloat = 15

Image(systemName: symbol)
    .font(.system(size: glyphSize, weight: .semibold))
    .foregroundStyle(.white)
    .frame(width: tileSize, height: tileSize)
    .background(
        RoundedRectangle(cornerRadius: tileSize * 0.25, style: .continuous)
            .fill(tint.gradient)
    )
```

The `tileSize * 0.25` expression encodes the measured ratio and keeps the tile concentric at every
Dynamic Type size — this is the single most important detail, because a hard-coded `cornerRadius: 7`
on a `@ScaledMetric` tile will look wrong at accessibility sizes.

`.imageScale(.small)` on a `.body`-styled image is the alternative if you want zero bookkeeping and
are happy for the glyph to track the text style, but then the **tile** must also be driven by a text
style, which is fragile.

### 4.3 `containerRelativeFrame` — the wrong tool here

`containerRelativeFrame(_:alignment:)` sizes a view relative to its **scroll container's** dimensions
(useful for paging carousels), not relative to a parent card. It will not give you concentric icon
tiles. If your goal is "the tile's corner radius should relate to the card's corner radius", the
correct APIs are `.containerShape(_:)` + `ConcentricRectangle` (§3.3) — not `containerRelativeFrame`.
(`ConcentricRectangle` itself is *not* a container-relative shape: Apple notes that when the container
shape does not conform to `RoundedRectangularShape`, `ConcentricRectangle` "provides an inset version
of the container shape like `ContainerRelativeShape`" —
[Apple](https://developer.apple.com/documentation/swiftui/concentricrectangle).)

### 4.4 Rendering mode and variant

Apple defines four rendering modes:

> "**Monochrome** — Applies one color to all layers in a symbol. **Hierarchical** — Applies one color
> to all layers in a symbol, **varying the color's opacity according to each layer's hierarchical
> level**. **Palette** — Applies two or more colors… **Multicolor** — Applies intrinsic colors to some
> symbols to enhance meaning."

> "**Confirm that a symbol's rendering mode works well in every context.** Depending on factors like
> the size of a symbol and its contrast with the current background color, different rendering modes
> can affect how well people can discern the symbol's details."

— [HIG: SF Symbols](https://developer.apple.com/design/human-interface-guidelines/sf-symbols)

API: [`symbolRenderingMode(_:)`](https://developer.apple.com/documentation/swiftui/view/symbolrenderingmode(_:)) (iOS 15+), [`symbolVariant(_:)`](https://developer.apple.com/documentation/swiftui/view/symbolvariant(_:)) (iOS 15+).

On a **tinted, small (29–34 pt) tile**:

- `.symbolRenderingMode(.hierarchical)` — **use it** when the symbol has multiple layers and you want
  depth without a second colour. It is the safest choice on a coloured fill because it stays inside
  one hue.
- `.symbolRenderingMode(.monochrome)` — what Apple Settings effectively uses (flat white). Best when
  contrast between the glyph and the tile is the priority, i.e. whenever your tile tint is light or
  saturated.
- `.symbolVariant(.fill)` — SwiftUI already applies `.fill` automatically in some containers:

> "SwiftUI sets a variant for you in some environments. For example, SwiftUI automatically applies the
> `.fill` symbol variant for items that appear in the `content` closure of the `swipeActions(edge:allowsFullSwipe:content:)`
> method, or as the tab bar items of a `TabView`."

— [Apple: `SymbolVariants`](https://developer.apple.com/documentation/swiftui/symbolvariants)

  A settings tile is **not** one of those containers, so if you want filled glyphs you must ask:
  `.symbolVariant(.fill)`. Filled reads better at 15–17 pt on a saturated tile; outline reads better
  on a subtle/neutral tile. Pick one and apply it uniformly — mixing outline and fill across rows in
  the same card is the most common "crude" tell.

### 4.5 Liquid Glass on tiles — don't

> "**Avoid overusing Liquid Glass effects.** If you apply Liquid Glass effects to a custom control, do
> so sparingly. … Limit these effects to the most important functional elements in your app."

— [Apple: Adopting Liquid Glass](https://developer.apple.com/documentation/technologyoverviews/adopting-liquid-glass)

Tiles are content, not chrome. Use a solid or gradient fill. Reserve `glassEffect` + `GlassEffectContainer`
for the floating chrome (your `AppShellChrome.swift`). If you do need several glass elements adjacent:

> "`GlassEffectContainer` gives grouped elements a shared sampling region, ensuring a consistent
> appearance" … "**Glass cannot sample other glass.**"

— [WWDC25 323](https://developer.apple.com/videos/play/wwdc2025/323/) (bundled skill reference)

And `glassEffectUnion(id:namespace:)` for merging:

> "All Liquid Glass effects with the same shape and Liquid Glass variant will be combined into a single shape."

— [Apple: `glassEffectUnion(id:namespace:)`](https://developer.apple.com/documentation/swiftui/view/glasseffectunion(id:namespace:))

---

## 5. Accessibility + correctness pitfalls of hand-rolled settings cards

### 5.1 Tap targets — the tile is never the target

> "Strive to meet the recommended minimum control size for each platform" — iOS default **44x44 pt**,
> minimum **44x44 pt**.

— [HIG: Accessibility](https://developer.apple.com/design/human-interface-guidelines/accessibility)

A 29–34 pt tile is below 44 pt on its own. This is fine **only because the whole row is the control**.
Make that true explicitly:

```swift
Button { … } label: {
    HStack(spacing: 12) { tile; label; Spacer(minLength: 8); value; chevron }
        .frame(minHeight: 54)
        .contentShape(.rect)          // Spacer() area is now hittable
}
.buttonStyle(.plain)
```

Without `.contentShape`, the `Spacer()` region and the padding are dead zones and the effective target
is only the glyph+text run. Doc: [Apple: `contentShape(_:eoFill:)`](https://developer.apple.com/documentation/swiftui/view/contentshape(_:eofill:)).

### 5.2 Never use `.onTapGesture` for a navigating row

`.onTapGesture` is invisible to VoiceOver activation, Full Keyboard Access, Switch Control and pointer
hover. Apple:

> "**Offer alternatives to gestures.** Make sure your UI's core functionality is accessible through more
> than one type of physical interaction."

> "**Let people use the keyboard alone to navigate and interact with your app.** … Avoid overriding
> system-defined keyboard shortcuts."

> "**Support Switch Control.**"

— [HIG: Accessibility](https://developer.apple.com/design/human-interface-guidelines/accessibility)

Use `NavigationLink` (which also gives you keyboard focus and the macOS selection behaviour) or
`Button`. In a hand-rolled card, `NavigationLink` will **not** add a chevron (only `List` does — see
the Swift with Majid note in §2.4), so you draw it yourself and must hide it from VoiceOver (§5.4).

### 5.3 VoiceOver row grouping — get this right or the screen is unusable

Apple's semantics for each behaviour:

| Behaviour | Meaning |
|---|---|
| `.combine` | "Any child accessibility element's **properties are merged** into the new accessibility element." … "The new accessibility element merges properties from **all non-hidden children**. Some properties may be transformed or ignored to achieve the ideal combined result. For example, **not all of `AccessibilityTraits` are merged and a `default` action may become a named action**." |
| `.ignore` | Replace children with a single element you label yourself |
| `.contain` | Semantic grouping — VoiceOver announces the container name when focus enters/exits |

— [Apple: `AccessibilityChildBehavior.combine`](https://developer.apple.com/documentation/swiftui/accessibilitychildbehavior/combine) and [Apple: `accessibilityElement(children:)`](https://developer.apple.com/documentation/swiftui/view/accessibilityelement(children:))

Practical rules for a settings row:

- **Do** mark the tile glyph decorative — it duplicates the label, and Apple's own rule is:

> "**Provide an accessibility label for every icon.** Regardless of what you show in the interface,
> always specify an accessibility label for each icon."

— [Apple: Adopting Liquid Glass](https://developer.apple.com/documentation/technologyoverviews/adopting-liquid-glass)

  In SwiftUI the way to satisfy this for a *decorative, redundant* icon is to hide it from the tree:
  `Image(systemName:).accessibilityHidden(true)` — the label carries the meaning. Doc reference:
  [Apple: `accessibilityHidden(_:)`](https://developer.apple.com/documentation/swiftui/view/accessibilityhidden(_:)).

- **Prefer `.accessibilityElement(children: .combine)`** on the row for the common case. VoiceOver then
  reads "Jellyfin, 已连接" as one stop instead of three, and the fact that the `NavigationLink`'s
  default action survives the merge (per the `combine` doc above) is what makes the row activatable.
- **Use `.ignore` + an explicit `.accessibilityLabel`** when `.combine` produces something clumsy,
  e.g. when the trailing value is a long server name you want to read as a separate "value":
  ```swift
  .accessibilityElement(children: .ignore)
  .accessibilityLabel(title)
  .accessibilityValue(value)
  .accessibilityAddTraits(.isButton)
  ```
- **Use `.contain`** on the *card*, so VoiceOver announces the group boundary:
  ```swift
  card.accessibilityElement(children: .contain).accessibilityLabel("服务")
  ```
  This is the accessible equivalent of your visual section header, and it is worth adding because
  iOS 26's `Section` headers already provide it — losing it is a regression when you hand-roll.

The bundled `swiftui-expert-skill` reference (`references/accessibility-patterns.md:115-155`)
summarises these three as: `.combine` = auto-join child labels; `.ignore` = manual label for
container; `.contain` = semantic grouping.

### 5.4 The chevron

If you draw `Image(systemName: "chevron.right")`, mark it `.accessibilityHidden(true)` — otherwise
VoiceOver announces "chevron right" or, worse, "right arrow" after every row. `.combine` does not
reliably strip it. Also colour it `.tertiary` and never tint it with the row accent; that is what makes
hand-rolled rows look noisy.

### 5.5 Dynamic Type — the three ways hand-rolled cards break

1. **Fixed row height.** `.frame(height: 54)` clips the label at AX sizes. HIG: rows "may need to grow
   in height so that text isn't cropped" — [HIG: Layout](https://developer.apple.com/design/human-interface-guidelines/layout).
   Use `.frame(minHeight: 54)`.
2. **Fixed tile size.** A hard-coded 29 pt tile next to a 40 pt label looks broken. Use
   `@ScaledMetric` (§4.2). Also note the tile's *corner radius* must scale with it.
3. **Horizontal stacking that cannot reflow.** HIG: "horizontally adjacent views may need to stack
   vertically to provide more space for text" — [HIG: Layout](https://developer.apple.com/design/human-interface-guidelines/layout).
   Your `HStack { tile; label; Spacer; value; chevron }` must tolerate the value text wrapping or
   truncating before the label does.

Test at least at `.accessibility5` and at the largest standard size. The rest of your app already
handles this concern elsewhere (see the note about scroll-when-content-exceeds-screen in the bundled
skill's blog citation for Nil Coalescing).

### 5.6 Value-text truncation

HIG, on preserving recognisability of clipped text:

> "Sometimes, an **ellipsis in the middle** of text can make an item easier to distinguish because it
> preserves both the beginning and the end of the content."

— [HIG: Lists and tables](https://developer.apple.com/design/human-interface-guidelines/lists-and-tables)

Your hub rows show server names and profile names (`SettingsView.swift:41-61`), which are exactly the
strings that need middle truncation:

```swift
Text(value)
    .foregroundStyle(.secondary)
    .lineLimit(1)
    .truncationMode(.middle)
```

Also apply a `.layoutPriority` so the *label* never truncates before the value does.

### 5.7 Contrast, appearance and accessibility settings

> "**Test your interface with a variety of display and accessibility settings.** Translucency and fluid
> morphing animations contribute to the look and feel of Liquid Glass, but can adapt to people's needs.
> For example, people can choose a preferred look for Liquid Glass in their device's settings, or turn
> on accessibility settings that **reduce transparency or reduce motion**. These settings can remove or
> modify certain effects."

— [Apple: Adopting Liquid Glass](https://developer.apple.com/documentation/technologyoverviews/adopting-liquid-glass)

Concretely, for a purple-tinted ambient background: Reduce Transparency will flatten your translucency
into an opaque colour, so your card fill must still contrast against the *opaque* background. Test with
Settings → Accessibility → Display & Text Size → Reduce Transparency, Increase Contrast, and
Differentiate Without Color. Never encode row meaning in the tile colour alone (Apple: "avoid relying
on color alone" is a general HIG colour rule; the same page notes "**Use color sparingly in non-game
apps**" — [HIG: Color](https://developer.apple.com/design/human-interface-guidelines/color)).

### 5.8 `List`-specific pitfalls

1. **`.listRowBackground` must be applied per row**, not to the `Section` — applying it to a `Section`
   is a no-op in some list styles. If you need one card per section, this is the strongest argument
   for architecture B.
2. **Section separators.** Hiding row separators does not hide the separator *after* the section;
   use `listSectionSeparator(.hidden)` — [SwiftyPlace](https://www.swiftyplace.com/blog/customise-list-view-appearance-in-swiftui-examples-beyond-the-default-stylings).
3. **Separator is a preference, not a command.** "The list style is the final arbiter of the separator
   visibility" — [Apple](https://developer.apple.com/documentation/swiftui/view/listrowseparator(_:edges:)).
4. **`Divider()` inside a `List` becomes a row** — do not use it for hairlines.
5. **macOS grouped `Form` ignores many iOS list modifiers.** Always verify on the macOS target; your
   project builds both (`OcPlayer-macOS` and `OcPlayer-iOS` schemes).

---

## 6. Concrete recommended values

All values in **points**. "Apple" = **[measured]** from iOS 26.3 Settings.app on iPhone 17 Pro
(402 × 874 pt @3x). "Rex-target" = the look described in the brief, reconciled with Apple's metrics.

### 6.1 Layout

| Element | Apple [measured] | Rex-target (recommended) | SwiftUI |
|---|---|---|---|
| Screen card horizontal inset | 16 | **16** | `.listSectionMargins(.horizontal, 16)` or `.padding(.horizontal, 16)` |
| Card corner radius | 21.3 | **22** | `RoundedRectangle(cornerRadius: 22, style: .continuous)` |
| Card fill | white `#FFFFFF` on `#F2F2F7` | translucent: `.ultraThinMaterial` or `Color.white.opacity(0.06)` over your gradient | `.background(.ultraThinMaterial, in: …)` |
| Row height (pitch) | 52.3 | **54** | `.frame(minHeight: 54)` — **min**, never fixed |
| Section gap (card → card) | 35 | **32–35** | `.listSectionSpacing(35)` (iOS 17+; no macOS) |
| Header → card gap | n/a | **6** | `.padding(.top, 6)` on the section content |
| Card → next header gap | n/a | **28** | folded into `listSectionSpacing` |
| Separator inset (leading) | 56 from card edge = **label leading edge** | **= label leading edge** | `.alignmentGuide(.listRowSeparatorLeading) { $0[.leading] }` |
| Separator inset (trailing) | 0 (flush to card edge) | **16** (Rex stops short) | custom hairline, or `.listRowSeparator(.hidden)` + overlay |
| Separator thickness | 1.0 (3 px @3x) | **1 device pixel** | `Divider()` (1 px) or `.frame(height: 1 / displayScale)` |
| Separator colour | `#E8E8E8` ≈ `Color.black.opacity(0.09)` | `Color.primary.opacity(0.10)` | — |
| Row leading inset in card | 13.67 | **14** | `.listRowInsets(EdgeInsets(top: 0, leading: 14, bottom: 0, trailing: 16))` |
| Tile → label gap | 14.0 | **12–14** | `HStack(spacing: 12)` |
| Label → chevron trailing inset | 16 | **16** | row trailing inset |

### 6.2 Icon tile

| Parameter | Apple [measured] | Rex-target (recommended) | SwiftUI |
|---|---|---|---|
| Tile size | 29 × 29 | **30** (Apple-idiomatic) or **34** (Rex look) | `@ScaledMetric(relativeTo: .body) var tile: CGFloat = 30` |
| Tile corner radius | ≈ 7 | **tile × 0.25** (7.5 at 30, 8.5 at 34) | `RoundedRectangle(cornerRadius: tile * 0.25, style: .continuous)` |
| Tile corner curve | continuous | **`.continuous`** | — |
| Tile fill | flat per-row accent | solid or `tint.gradient` | `.fill(tint.gradient)` |
| Glyph size | 17 (SO recipe) / 22 ink [measured] | **15–16** | `.font(.system(size: 15, weight: .semibold))` |
| Glyph weight | — | **`.semibold`** | — |
| Glyph colour | white | **`.white`** | `.foregroundStyle(.white)` |
| Rendering mode | flat white (monochrome-ish) | **`.hierarchical`** on tinted tiles, `.monochrome` if tint is light | `.symbolRenderingMode(.hierarchical)` |
| Variant | mixed | **pick one: `.fill`** for a saturated tile | `.symbolVariant(.fill)` |
| Tile leading inset | 13.67 | **14** | row leading inset |
| Tile vertical alignment | centred | **centred** | default `HStack` alignment |

### 6.3 Typography

| Element | Size | Weight | Colour | SwiftUI |
|---|---|---|---|---|
| Section header (above card) | **13** | `.regular` | `.secondary` | `.font(.footnote)` — *not* uppercase (Apple dropped all-caps headers in iOS 26) |
| Row label | **17** | `.regular` | `.primary` | `.font(.body)` |
| Row value (trailing) | **15** | `.regular` | `.secondary` | `.font(.subheadline)` |
| Card footer / help text | **13** | `.regular` | `.tertiary` | `.font(.footnote)` |
| Tab bar label | 11 | `.regular` | system | system-drawn — do not override |
| Page title (large) | 34 | `.bold` | `.primary` | `.navigationTitle` |
| Page title (inline, scrolled) | 17 | `.semibold` | `.primary` | `.navigationBarTitleDisplayMode(.inline)` |

Sources for the type ramp: [HIG: Typography](https://developer.apple.com/design/human-interface-guidelines/typography)
(17 pt default / 11 pt minimum) and [Learn UI Design](https://www.learnui.design/blog/ios-design-guidelines-templates.html)
(17 / 15 / 13 / 11 with the exact light & dark opacities).

### 6.4 Chrome

| Element | Value | Source |
|---|---|---|
| Tab bar height | **62** (system-drawn) | **[measured]** |
| Tab bar inset (L/R/bottom) | **21** (system-drawn) | **[measured]**, corroborated by [Learn UI Design](https://www.learnui.design/blog/ios-design-guidelines-templates.html) |
| Tab bar implementation | `TabView` + `Tab(...)`; add `.tabBarMinimizeBehavior(.onScrollDown)` | [Apple](https://developer.apple.com/documentation/swiftui/view/tabbarminimizebehavior(_:)) |
| Now-playing strip | `.tabViewBottomAccessory { … }` | [Apple](https://developer.apple.com/documentation/swiftui/view/tabviewbottomaccessory(content:)) |
| Scroll edge effect | leave on `automatic`; optionally `.scrollEdgeEffectStyle(.hard, for: .all)` | [Apple](https://developer.apple.com/documentation/swiftui/view/scrolledgeeffectstyle(_:for:)) |
| Custom bar darkening | **remove it** | [Apple](https://developer.apple.com/documentation/technologyoverviews/adopting-liquid-glass) |
| Minimum hit target | **44 × 44** | [HIG: Accessibility](https://developer.apple.com/design/human-interface-guidelines/accessibility) |
| Control spacing (bezelled) | **12** | [HIG: Accessibility](https://developer.apple.com/design/human-interface-guidelines/accessibility) |
| Control spacing (unbezelled) | **24** | [HIG: Accessibility](https://developer.apple.com/design/human-interface-guidelines/accessibility) |
| Dynamic Type support | ≥ **200 %** enlargement | [HIG: Accessibility](https://developer.apple.com/design/human-interface-guidelines/accessibility) |

### 6.5 Drop-in constants block

```swift
// App/Shared/DesignSystem/SettingsMetrics.swift
enum SettingsMetrics {
    // Card
    static let cardRadius: CGFloat      = 22
    static let cardInset: CGFloat       = 16      // measured: 16
    static let sectionSpacing: CGFloat  = 35      // measured: 35 (headerless card→card)
    static let cardToHeaderGap: CGFloat = 6

    // Row
    static let rowMinHeight: CGFloat    = 54      // measured pitch: 52.3
    static let rowLeadingInset: CGFloat = 14      // measured: 13.67
    static let rowTrailingInset: CGFloat = 16

    // Separator
    static let separatorOpacity: Double = 0.10    // measured #E8E8E8 ≈ black 0.09
    static let separatorTrailingInset: CGFloat = 16  // Rex stops short; Apple is flush (0)

    // Icon tile
    static let tileSize: CGFloat        = 30      // Apple measured 29; Rex uses 34
    static let tileRadiusRatio: CGFloat = 0.25    // measured 7/29 = 0.241
    static let tileGlyphSize: CGFloat   = 15
    static let tileLabelGap: CGFloat    = 12      // measured gap: 14

    static var tileRadius: CGFloat { tileSize * tileRadiusRatio }
}
```

---

## 7. Headline recommendations for OcPlayer

1. **You are closer than you think.** Apple's shipping iOS 26 `.insetGrouped` metrics (card radius
   21.3, row 52.3, separator aligned to label leading) are within 2 pt of Rex's target. Do not
   rewrite the screen as a `LazyVStack` first — restyle `Form` and only escalate if the per-section
   card fill proves impossible.
2. **Fix the icon tiles first.** This is the single biggest visual delta. `SettingsView.swift:146-152`
   currently paints rows `Color.clear`, so there are no tiles at all today. Add the 30 pt tile with a
   `tileSize * 0.25` continuous radius and a 15 pt semibold white glyph.
3. **Feed the existing ambience in.** `PageAmbience.swift` / `BackdropAmbienceView.swift` already
   exist; the Settings hub is not using them. That alone closes most of the "crude" gap.
4. **Header font is 13 pt `.footnote` `.secondary`, sentence case.** Apple removed all-caps section
   headers in iOS 26; using uppercase here would read as dated.
5. **Row height must be `.frame(minHeight: 54)`,** and the tile size must be `@ScaledMetric`. These
   two choices are what separate a polished implementation from one that breaks at accessibility sizes.
6. **`.contentShape(.rect)` + `NavigationLink`/`Button`** for rows; `.accessibilityElement(children: .combine)`
   or `.ignore` + explicit label/value; `.accessibilityHidden(true)` on the tile glyph and the chevron.
7. **Do not hand-roll the floating tab bar.** `TabView` already gives it to you; add
   `.tabBarMinimizeBehavior(.onScrollDown)` and, if you want the media-player touch,
   `.tabViewBottomAccessory { … }`.
