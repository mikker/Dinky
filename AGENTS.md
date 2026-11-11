# Development

- Run `swift test` and `swift build` for changes to the Swift app.
- InDesign presentation mode reuses its document window. Preserve placement while suspending frame writes and borders, and resume without rerunning window rules.
- Keep presentation detection specific to InDesign, full display bounds and absent window buttons. Failed Accessibility reads must preserve the previous state.
