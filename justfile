default: run

# use fvm if available, else use flutter directly
flutter := if `which fvm 2> /dev/null || true` != "" { "fvm flutter" }  else { "flutter" }

# target platform that is automatically chosen when using 'flutter run'
platform := `fvm flutter devices --machine | jq .[0].targetPlatform`

git_hash := `git rev-parse HEAD`

prepare:
    just gen
    {{flutter}} pub get

run flags="":
    #!/bin/sh
    flags={{flags}}
    flags="$flags --flavor local"
    flags="$flags --dart-define=GIT_HASH={{git_hash}}"
    {{flutter}} run $flags

run-release:
    just run --release

# Static gates, local == CI.
# 'check' mirrors the CI format job (.github/workflows/flutter.yml) verbatim:
# 'flutter pub get' then 'dart format --output=none --set-exit-if-changed lib'
# (read-only: --output=none + --set-exit-if-changed never rewrite files).
# 'analyze' is the additive clippy-equivalent diagnostic gate: errors are
# fatal by analyzer default; warnings and infos are forced fatal.
# Note: the tree carries pre-existing analyzer errors, so analyze (and
# therefore check) exits non-zero on a pristine base until those are fixed.
check: analyze
    fvm flutter pub get
    fvm dart format --output=none --set-exit-if-changed lib

analyze:
    fvm dart analyze --fatal-infos --fatal-warnings .

format:
    fvm dart format ./lib

gen:
    cd rust && just gen

inspect-db:
    #!/bin/sh
    case {{platform}} in
        "android-arm64")
          adb exec-out run-as dev.silentpayments.danawallet.local dd if=/data/user/0/dev.silentpayments.danawallet.local/databases/dana.db > /tmp/dana.db
          sqlite3 /tmp/dana.db
        ;;
        "linux-x64")
          sqlite3 ~/.dana/dana.db
        ;;
        *) echo "unknown platform: {{platform}}"
    esac
