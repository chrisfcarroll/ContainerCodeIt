#!/usr/bin/env bash
#
# Builds the code-it container image from the Dockerfile, selecting the tool chains
# and package caches to include. code-it.sh delegates its --build-image and
# --rebuild-image flags here.
#
# Usage:
#   ./code-it-build.sh [OPTIONS]
#
# Options:
#   --tool-chains, -t LIST   Comma-separated tool chains to build. Default: dotnet,node.
#                            Known: dotnet, node (aliases js-node, ts-node), bun
#                            (aliases js-bun, ts-bun), python (alias uv).
#                            --stack is an alias for --tool-chains.
#   --package-caches LIST    Comma-separated package repos to support, independent of
#                            --tool-chains. Known: nuget, npm, bun.
#                            Default: the repos implied by --tool-chains
#                            (dotnet->nuget, node->npm).
#   --rebuild                Bump the Dockerfile's "# last changed" dates to today first,
#                            so the agent install layers rerun and the agents update.
#   --image, -i NAME         Image name to build. Default: "code-it-alpine-<chains>",
#                            a slug of the resolved --tool-chains list.
#   --dockerfile-dir DIR     Directory containing the Dockerfile.
#                            Defaults to this script's own directory.
#   --runtime, -r NAME       Container runtime to use: "docker" or "container".
#                            Default: auto-detected (Apple container on macOS, else docker).
#   --dry-run, -d            Print the build command without executing it.
#   --help, -h               Show this help message.
#
# The image is labelled with its tool chains and package caches
# (code-it.tool-chains=..., code-it.package-caches=...), so code-it.sh can detect a
# mismatch between the image and the --tool-chains it was asked to run.

set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/code-it-common.sh
. "$script_dir/lib/code-it-common.sh"

# Absolute path of an existing directory, without realpath (absent on older macOS)
abs_dir() { (CDPATH= cd -- "$1" && pwd); }

tool_chains=""
package_caches=""
package_caches_set=false
rebuild=false
image=""
dockerfile_dir="$script_dir"
runtime=""
dry_run=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --tool-chains|--tech|--stack|-t)
            tool_chains="$2"
            shift 2
            ;;
        --package-caches)
            package_caches="$2"
            package_caches_set=true
            shift 2
            ;;
        --rebuild)
            rebuild=true
            shift
            ;;
        --image|-i)
            image="$2"
            shift 2
            ;;
        --dockerfile-dir)
            dockerfile_dir="$2"
            shift 2
            ;;
        --runtime|-r)
            runtime="$2"
            shift 2
            ;;
        --dry-run|-d)
            dry_run=true
            shift
            ;;
        --help|-h)
            sed -n '2,/^$/{ s/^# \{0,1\}//; p; }' "$0"
            exit 0
            ;;
        -*)
            echo "Unknown option: $1" >&2
            echo "Run $0 --help for usage." >&2
            exit 1
            ;;
        *)
            echo "Unexpected argument: $1" >&2
            echo "Run $0 --help for usage." >&2
            exit 1
            ;;
    esac
done

# Resolve the requested tool chains and package caches. An explicit, empty
# --package-caches means "no package caches", not "use the implied ones".
enabled_tool_chains=$(ci_resolve_tool_chains "$tool_chains") || exit 1
if [[ "$package_caches_set" == true ]]; then
    enabled_package_caches=$(ci_resolve_package_caches "$package_caches" "$enabled_tool_chains") || exit 1
else
    enabled_package_caches=$(ci_resolve_package_caches "" "$enabled_tool_chains") || exit 1
fi

if [[ -z "$image" ]]; then
    image=$(ci_default_image_name "$enabled_tool_chains")
fi

# Detect / validate the container runtime
runtime=$(ci_detect_runtime "$runtime") || exit 1

if [[ ! -f "$dockerfile_dir/Dockerfile" ]]; then
    echo "Warning: Dockerfile not found at: $dockerfile_dir/Dockerfile" >&2
    exit 1
fi
dockerfile_dir=$(abs_dir "$dockerfile_dir")

# --rebuild: bump the "# last changed" cache-bust dates to today, so the agent
# install layers rebuild and update the agents. (Write to a temp file and move:
# portable in-place edit for BSD and GNU sed.)
if [[ "$rebuild" == true ]]; then
    today=$(date +%Y-%m-%d)
    sed -E "s/# last changed [0-9]{4}-[0-9]{2}-[0-9]{2}/# last changed $today/" "$dockerfile_dir/Dockerfile" > "$dockerfile_dir/Dockerfile.tmp" \
        && mv "$dockerfile_dir/Dockerfile.tmp" "$dockerfile_dir/Dockerfile"
    echo "    Updated '# last changed' dates in $dockerfile_dir/Dockerfile to $today"
fi

# Build args for the tool chains and package caches, spelled the way the
# Dockerfile's ARGs match them (uppercase).
build_args=()
for tc in dotnet node bun python; do
    if ci_has "$enabled_tool_chains" "$tc"; then v=true; else v=false; fi
    build_args+=(--build-arg "$(printf '%s' "$tc" | tr '[:lower:]' '[:upper:]')=$v")
done
for pc in nuget npm; do
    if ci_has "$enabled_package_caches" "$pc"; then v=true; else v=false; fi
    build_args+=(--build-arg "$(printf '%s' "$pc" | tr '[:lower:]' '[:upper:]')=$v")
done

# Label the image with its resolution, so code-it.sh can check it rather than guess
# from the image name.
build_args+=(--label "code-it.tool-chains=$(ci_join , "$enabled_tool_chains")")
build_args+=(--label "code-it.package-caches=$(ci_join , "$enabled_package_caches")")

echo "    Building with tech ${enabled_tool_chains// /,}; package repos ${enabled_package_caches// /,}"

# Print the command
echo "    $runtime build ${build_args[*]} -t ${image}:latest $dockerfile_dir"

if [[ "$dry_run" == true ]]; then
    exit 0
fi

"$runtime" build "${build_args[@]}" -t "${image}:latest" "$dockerfile_dir"
