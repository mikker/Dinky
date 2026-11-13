# Border development

The app applies a fixed 5% optical correction to rounded corner midpoints, tapering
to zero at the straight edges. The inner outline and square-corner behavior stay
unchanged. This is not a user configuration option.

Run `sh scripts/border-preview.sh` for a standalone native comparison. Choose 0% or
5–10% correction and adjust the width from 1 to 16 points in quarter-point steps.
Space toggles the selected correction against 0%. Its floating test window uses
the shared `Sources/DinkyPrivate/border_path.h` geometry without replacing Dinky
or changing its configuration. Keep it outside normal tiling and borders.

Run `python3 -m unittest discover -s scripts/tests` on macOS to compile and execute
the native geometry regression tests. These call the shared path directly and
check fractional, narrow, default and thick widths, all four corner midpoints,
the unchanged inner and straight edges, empty interior, and square corners.
Also run `swift build --jobs 4` and `swift test --jobs 4` for app changes.

The preview and geometry tests do not verify WindowServer compositing. For that,
compare actual app windows in a VM, recording the app commits, guest OS, display
scale, configuration, screenshots and live window state. Include both border
stacking orders, focus changes, movement and resizing during animations.
