# Dock Extend checklist

## Prototype acceptance

- [x] Keep the existing macOS app launcher centered in the dock.
- [x] Use the unused left and right dock margins for configurable widgets.
- [x] Provide a compact widget state that uses roughly one-third less vertical space.
- [x] Expand widget details on mouseover/focus so the full state is available without opening a window.
- [x] Make the two-state behavior configurable: `Compact until hover` or `Always full`.
- [x] Include an add/customize affordance and a visible settings drawer.
- [x] Include a first useful widget pair: Focus timer and Weather.
- [x] Keep a responsive fallback where side widgets stack below the launcher on narrow screens.
- [x] Provide keyboard focus styles and Escape-to-close for the settings drawer.

## Next product decisions

- [ ] Decide whether compact mode should show one value, an icon-only rail, or a user-selected summary.
- [ ] Define the widget plugin/API model for live macOS data.
- [ ] Test the expanded dock against real menu-bar and Dock translucency settings.
- [ ] Add persistence for widget order, visibility, and display mode.
- [ ] Validate hover expansion with trackpad, keyboard, and reduced-motion preferences.

## Native macOS vertical slice

- [x] Start a real Swift Package using SwiftUI and AppKit.
- [x] Show a borderless floating dock window above normal app windows.
- [x] Keep the window visible across Spaces and full-screen apps.
- [x] Center the dock at the bottom of the main display's visible frame.
- [x] Implement compact-by-default widgets that expand on mouseover.
- [x] Add an in-app menu to switch between compact and always-expanded modes.
- [x] Persist the display mode between launches.
- [x] Make launcher tiles open their corresponding macOS applications.
- [x] Use the installed macOS app icons instead of placeholder artwork.
- [x] Reposition after macOS display configuration changes.
- [x] Add native settings for widget visibility, side assignment, and display mode.
- [x] Add and remove launcher applications from native settings.
- [x] Persist the launcher application list between launches.
- [x] Reorder launcher applications by dragging tiles onto one another.
- [x] Package the executable as a normal `DockExtend.app` bundle.
- [x] Anchor the floating dock to the physical bottom edge instead of the area above the system Dock.
- [ ] Reposition intelligently when the system Dock is set to auto-hide.
- [ ] Replace sample tiles with launchable apps and real widget data.
- [x] Add a live Music widget with track state and play/pause/next controls.
- [x] Add a live Herdr agents widget with status-driven icons.
- [x] Click a Herdr agent to focus its Herdr space, tab, and pane.
- [ ] Add preferences, persistence, launch-at-login, and accessibility behavior.
- [ ] Add an explicit launch-at-login preference.
