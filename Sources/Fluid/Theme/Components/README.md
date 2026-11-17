# Dropdown controls

All dropdown selectors share `FluidDropdown.swift`. Keep their selection bindings,
search, menu entries, and enabled states in their existing owners.

- Use `FluidDropdown(title:width:content:)` for a text-labelled menu.
- Apply `.fluidDropdownStyle()` after `.pickerStyle(.menu)` for native pickers,
  or outside the label closure of a native `Menu`.
- Searchable buttons use `searchablePickerControlChrome(width:height:)`, which
  delegates its surface to `FluidDropdownSurface`, plus `FluidDropdownChevron`.
- Custom/compact overlay triggers use `.fluidDropdownSurface()` with their existing
  compact layout. Do not change overlay hover-open behavior to adopt the style.

Do not duplicate outlines, hover fills, chevrons, or animation timings in screens.
Update the shared component to change the design everywhere. macOS can flatten
native menu labels, so putting the surface inside a `Menu` label is insufficient.
Segmented controls, disclosure rows, and icon-only action/context menus are not
selection dropdowns and retain their own controls.

Hover changes are local, disabled controls do not highlight, and Reduce Motion
suppresses the short hover transition. No timers, polling, or rendering-time I/O.

## Standard action buttons

The app theme installs `FluidOutlinedButtonStyle` as the default, so unstyled
buttons inherit it automatically, including sheets. Use `.fluidOutlinedButton()`
for an explicit neutral action override. Existing `.fluidButton(.secondary)`
and `.fluidCompactButton()` delegate to `FluidOutlinedButtonStyle` as well.
Use `.controlSize(.small)` for compact contexts. Preserve accent-filled primary
and destructive actions, link controls, and icon-only toolbar controls when those
semantics are intentional. Do not copy a local outline or hover implementation.
The shared style has hover/press feedback, disabled appearance, and reduced-motion
support without scaling or changing layout on hover.

Native `ToolbarItemGroup` buttons must explicitly use `.buttonStyle(.automatic)`
to preserve macOS grouping instead of inheriting the outlined form-action style.

## Lists, chips, status, metrics and notices

`FluidListControls.swift` owns the look of list-style content. Screens pass content
only; colors, fills, radii and spacing come from it and `AppTheme`, so a redesign
(for example replacing the glass look) changes one file, not every screen.

- Interaction fills: `FluidInteractionVisuals.fill(_:isSelected:isHovered:isPressed:)`.
  Never write `primaryText.opacity(...)` for hover, press or selection in a screen.
- Positive marks ("supported", "in use"): `theme.look.highlight`, `highlightText`
  and `highlightFill`.
- Selectable list rows: wrap the row in a `Button` with `.fluidSelectableRow(isSelected:)`.
  It covers the full row with hover, press and selected fills; its keyboard-focus ring
  is rounded and inset.
- Sorting and filtering live in a pop-up's or page's top-right header as menus ("Sort by",
  "Your language"), in `.fluidDropdownStyle(appearance: .text)`. Column headers are labels,
  never controls.
- Chips and tags: `FluidChip(text:systemImage:style:)` with `.highlight`, `.neutral`,
  `.outlined` or `.dashed`. Wrap many chips in `FluidChipFlow`.
- Status: `FluidStatusLabel(text:)` for a short status that tells one row apart, e.g. "In use"
  on one row of a list. Never for the normal state of the only item shown.
- Detail facts: `FluidFactRow(label:value:)`.
- Information bands under a header: `FluidNoticeBanner(title:message:accessory:)`.
- Expandable rows use `FluidDisclosureGroupStyle`; actions use `.fluidAction()` on
  pages that moved to the refined look (below), `.fluidGlassAction()` elsewhere;
  selectors use `FluidDropdown.swift`.

## The refined look

`AppTheme.Look` (in `AppThemeLook.swift`) holds the colors of the refined look:
canvas, sheet, surface, edge, divider, text roles, highlight, quiet fill and the two
action colors. `FluidTextRole` holds its text sizes, weights and letter spacing.
`FluidLookControls.swift` builds the pieces from them. Restyle the app by changing
those values; never put a color, size or tracking number in a screen.

The look follows fluidvoice.com: black, white and grey only. No colored glows, tints,
hue washes or gradient buttons. The only color on a page is a maker's own logo
(`FluidModelLogo`). Buttons are flat: a white main action, quiet grey ones, no outline
or shadow.

Pages move onto the look one at a time (Models first). A page on the look uses:

- `.fluidCanvas()` on its scroll view for the page background.
- `FluidPageHeader(title:subtitle:)` for its headline. The toolbar already shows the page
  name, so the headline is a sentence about the page (like the Dashboard greeting), never
  the page name again.
- `FluidSurfaceCard { }` for cards: solid fill, hairline edge, no material.
- A card that opens something is one button: `Button { … }.fluidCardButton()`, with a
  `FluidActionLabel(title: "Change")` inside to name the action. The whole card takes the click,
  hover and keyboard focus; never put a second button inside it.
- `FluidGlyphTile(systemImage:)` for a symbol on a neutral tile.
- `FluidHairline()` between rows and sections, never `Divider()`.
- `.fluidText(.role)` plus a `theme.look` color for every text.
- `.fluidAction(.primary)` for the one main action in a view and `.fluidAction()`
  for the rest; `size: .large` in footers. Hover, press, disabled, keyboard focus and
  Reduce Motion are built in.
- `.fluidDropdownStyle(appearance: .text)` for a selector inside a line of small text.

Once every page has moved, the window paints `look.canvas`, `.fluidCanvas()` and the
older palette roles are removed.

## Pop-ups

Every pop-up has one size: `FluidPopupLayout` (smallest 880 x 540, grows with the window up
to 960 x 820). Present a pop-up with `.fluidPopup(item:)` or `.fluidPopup(isPresented:)`,
never a bare `.sheet`. That sizes it with `FluidPopupFrame` and reports it to
`FluidPopupPresence`, so the main window grows and stays big enough while it is open.
Inside, fill the frame (`.frame(maxWidth: .infinity, maxHeight: .infinity)`); never set
a fixed pop-up size in a screen.

## Model logos

`FluidModelLogo(mark:size:)` draws a model's maker mark: `.speech(model)` for speech
models, `.cleanup` for Fluid Intelligence cleanup models. Use it wherever a model is
listed so a model looks the same on every page.
