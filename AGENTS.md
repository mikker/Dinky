# Development

- Run `swift test` and `swift build` for changes to the Swift app.
- Border optical correction grows only the outer corner outline by 5% of border width at the midpoint, tapering to zero at the straight edges. Preserve the inner outline and skip correction for square corners.
- Keep `scripts/border-preview.sh` using the shared `border_path.h` geometry. Its floating test window must stay outside normal Dinky tiling and borders; preview controls do not change the app configuration.
