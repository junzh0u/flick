set fallback := true

# Build build/Flick.app
build:
    ./build.sh

# Build, then run build/Flick.app in place of the running Flick
run: build stop-flick
    open build/Flick.app

# Quit the build and go back to the installed Flick
stop: stop-flick
    open /Applications/Flick.app
    @# Any copy that asks about Launch at Login takes over the login item, as
    @# the build does when its menu opens; asking from here takes it back.
    @/Applications/Flick.app/Contents/MacOS/Flick launch-at-login >/dev/null

[private]
stop-flick:
    #!/bin/zsh
    pkill -x Flick || true
    while pgrep -xq Flick; do sleep 0.1; done

# Build with warnings as errors and run every test
check: test
    swift build -Xswiftc -warnings-as-errors

# Run the unit tests and the command-line tests
test:
    swift test
    Tests/test-cli.zsh

# Sign, notarize and publish VERSION as a GitHub Release (see release.sh)
release version:
    ./release.sh {{version}}
