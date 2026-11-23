#!/usr/bin/env bash
# Build, test and push a Docker image for every version tag (v1.0 ... v3.2.4),
# and save the source of each version as a build artifact in dist/.
#
# Usage: scripts/build-all-versions.sh <dockerhub-user>/aceest-fitness
# Jenkins runs this when BUILD_ALL_VERSIONS is ticked (docker login is already done).
set -euo pipefail

IMAGE="${1:?usage: $0 <dockerhub-user>/aceest-fitness}"

git fetch --tags --force --quiet || echo "(could not fetch tags, using the ones already here)"
mkdir -p build dist

for tag in $(git tag --list 'v*' --sort=version:refname); do
    echo "===== $tag ====="

    # The code exactly as it was tagged
    rm -rf "build/$tag" && mkdir -p "build/$tag"
    git archive "$tag" | tar -x -C "build/$tag"

    # Source archive for this version (kept by Jenkins as an artifact)
    git archive --format=tar.gz --prefix="aceest-fitness-$tag/" -o "dist/aceest-fitness-$tag.tar.gz" "$tag"

    # Every version is packaged with the same, current Dockerfile
    cp Dockerfile .dockerignore "build/$tag/"

    docker build -q -t "$IMAGE:$tag" "build/$tag"
    docker run --rm "$IMAGE:$tag" python -m pytest -q -p no:cacheprovider
    docker push -q "$IMAGE:$tag"
done

echo "Images now on Docker Hub:"
docker image ls "$IMAGE"
