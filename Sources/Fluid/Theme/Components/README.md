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
