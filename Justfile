build:
    swift build

test: test-space-switch
    swift test

test-space-switch:
    scripts/test-space-switch.sh

bundle *flags:
    scripts/bundle.sh {{flags}}

# Debug bundle, replace any running dinky, and run attached so logs stream here (fut's run extension uses this).
run: kill
    scripts/bundle.sh --debug
    ./build/dinky.app/Contents/MacOS/dinky

kill:
    pkill -f "dinky.app/Contents/MacOS/dinky" || true

vm-install: bundle
    scripts/vm-install.sh

# Symlink the bundled CLI into ~/.local/bin so `dinky <command>` works from any shell.
install: bundle
    mkdir -p ~/.local/bin
    ln -sf "$PWD/build/dinky.app/Contents/MacOS/dinky" ~/.local/bin/dinky
    ls -l ~/.local/bin/dinky

# Fuzz the debug build in the Tart VM: random actions, layout invariants checked after each. See scripts/fuzz.py.
fuzz seed="1" steps="150": build
    scripts/vm-fuzz.sh {{seed}} {{steps}}

# Build, sign with Developer ID, notarize and staple into dist/, without publishing.
package version:
    scripts/package-release.sh {{quote(version)}}

# Prepare, test, package, tag and publish a GitHub release from a clean, pushed main. The version defaults
# to the latest tag plus 0.1.
release version="":
    scripts/release.sh {{quote(version)}}
