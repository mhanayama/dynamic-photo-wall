#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/../.."
output="$PWD/artifacts/macos/network-interop"
mode="--interop"
if [[ "${1:-}" == "--with-discovery" ]]; then
    mode="--interop-discovery"
elif [[ -n "${1:-}" ]]; then
    echo "Usage: $0 [--with-discovery]" >&2
    exit 2
fi
mkdir -p "$output"
run="$(mktemp -d "$output/run.XXXXXX")"
peer_pid=""
finish() {
    local result=$?
    if [[ -n "$peer_pid" ]]; then
        kill "$peer_pid" 2>/dev/null || true
        wait "$peer_pid" 2>/dev/null || true
    fi
    if [[ "$result" -ne 0 ]]; then
        echo "Interop verification failed. Logs: $run" >&2
        for log in "$run"/*.log; do
            [[ -f "$log" ]] || continue
            echo "$log" >&2
            tail -30 "$log" >&2
        done
    fi
}
trap finish EXIT
dotnet build tests/NetworkCore.Tests -c Release > "$run/dotnet-build.log" 2>&1
xcrun swiftc -parse-as-library -O -module-cache-path "$output/ModuleCache" \
    macos/DynamicPhotoWall/Networking/PeerContracts.swift \
    macos/DynamicPhotoWall/Networking/PeerStorage.swift \
    macos/DynamicPhotoWall/Networking/PeerTransport.swift \
    tests/NetworkInterop/NativeProbe.swift -o "$output/NativeProbe" \
    > "$run/swift-build.log" 2>&1
dotnet tests/NetworkCore.Tests/bin/Release/net10.0/NetworkCore.Tests.dll "$mode" "$run" > "$run/dotnet.log" 2>&1 &
peer_pid=$!
"$output/NativeProbe" "$run" > "$run/swift.log" 2>&1
wait "$peer_pid"
peer_pid=""
trap - EXIT
cat "$run/swift.log" "$run/dotnet.log"
echo "TLS uses loopback; optional multicast uses an isolated port. No user Keychain, photos, settings or desktop windows used. Results: $run"
