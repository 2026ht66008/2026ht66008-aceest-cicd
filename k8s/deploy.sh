#!/usr/bin/env bash
# Deploys ACEest to Minikube using five strategies. Jenkins calls it; you can run it by hand too.
#
#   ./k8s/deploy.sh init                       namespace, secrets and the rolling-update objects
#   ./k8s/deploy.sh rolling   <tag>            rolling update; rolls back by itself if it fails
#   ./k8s/deploy.sh bluegreen <tag>            deploy to the idle colour, check it, switch traffic
#   ./k8s/deploy.sh canary    <stable> <new>   1 in 5 requests go to <new>
#   ./k8s/deploy.sh ab        <a> <b>          group A gets <a>, group B gets <b>
#   ./k8s/deploy.sh shadow    <live> <new>     users get <live>; a copy of each request goes to <new>
#   ./k8s/deploy.sh rollback  <strategy>       go back to the last stable version
#   ./k8s/deploy.sh status                     what is running, and where
#
# Tags are Docker Hub tags such as v3.1.2 or v3.2.4.
set -euo pipefail
export PATH="/usr/local/bin:$PATH"

NS=aceest
DIR="$(cd "$(dirname "$0")" && pwd)"
HOST="${NODE_HOST:-localhost}"                   # where the NodePorts answer (set NODE_HOST to override)
VM_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"

k() { kubectl -n "$NS" "$@"; }

# Repository part of the image name, e.g. myuser/aceest-fitness (taken from the manifests)
image() { grep -m1 -o '[^ ]*/aceest-fitness' "$DIR/rolling-update.yaml"; }

current_tag() { k get deployment "$1" -o jsonpath='{.spec.template.spec.containers[0].image}' | sed 's/.*://'; }

# Version that answers on a NodePort, e.g. v3.2.4
version_on() {
    curl -fsS --max-time 3 "http://$HOST:$1/health" "${@:2}" \
        | grep -o '"version":"[^"]*"' | cut -d'"' -f4 | sed 's/^/v/'
}

# Wait until a NodePort answers with the expected version
wait_for_version() {
    local port=$1 want=$2
    for _ in $(seq 1 20); do
        if [ "$(version_on "$port" 2>/dev/null || true)" = "$want" ]; then
            return 0
        fi
        sleep 3
    done
    echo "Port $port did not answer with $want"
    return 1
}

# Create a strategy's objects the first time; later runs only change images,
# so the rollout history and the blue-green switch are kept
ensure() {
    local file=$1 first=$2
    if ! k get deployment "$first" >/dev/null 2>&1; then
        echo "Creating objects from k8s/$file"
        kubectl apply -f "$DIR/$file"
    fi
}

# set image + wait; returns non-zero if the new pods never become ready
roll_to() {
    local deployment=$1 tag=$2
    k set image "deployment/$deployment" app="$(image):$tag"
    k annotate "deployment/$deployment" kubernetes.io/change-cause="deploy $tag" --overwrite >/dev/null
    k rollout status "deployment/$deployment" --timeout=120s
}

init() {
    kubectl apply -f "$DIR/00-namespace.yaml"

    # Docker Hub login for pulling images (Jenkins passes these in)
    if [ -n "${DOCKERHUB_USERNAME:-}" ] && [ -n "${DOCKERHUB_TOKEN:-}" ]; then
        k create secret docker-registry dockerhub \
            --docker-server=https://index.docker.io/v1/ \
            --docker-username="$DOCKERHUB_USERNAME" --docker-password="$DOCKERHUB_TOKEN" \
            --dry-run=client -o yaml | k apply -f -
    fi

    # A random Flask secret key, shared by all pods (made once)
    if ! k get secret aceest-app >/dev/null 2>&1; then
        k create secret generic aceest-app \
            --from-literal=ACEEST_SECRET_KEY="$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')"
    fi

    ensure rolling-update.yaml aceest-rolling
}

rolling() {
    local tag=$1 before
    ensure rolling-update.yaml aceest-rolling
    before="$(current_tag aceest-rolling)"
    echo "Rolling update: $before -> $tag  (http://$VM_IP:30081)"

    if roll_to aceest-rolling "$tag" && wait_for_version 30081 "$tag" \
        && k exec deployment/aceest-rolling -- python -m pytest -q -p no:cacheprovider; then
        echo "Rolling update to $tag done; tests passed inside the running pod"
    else
        echo "Rolling update to $tag FAILED - rolling back to $before"
        k rollout undo deployment/aceest-rolling
        k rollout status deployment/aceest-rolling --timeout=120s
        echo "Back on $(version_on 30081)"
        exit 1
    fi
}

bluegreen() {
    local tag=$1 live idle
    ensure blue-green.yaml aceest-blue
    live="$(k get service aceest-bg-live -o jsonpath='{.spec.selector.slot}')"
    if [ "$live" = blue ]; then idle=green; else idle=blue; fi
    if [ "$(current_tag "aceest-$live")" = "$tag" ]; then
        echo "Blue-green: $tag is already live on $live - nothing to switch"
        return 0
    fi
    echo "Blue-green: live is $live ($(current_tag "aceest-$live")); deploying $tag to $idle"

    if ! roll_to "aceest-$idle" "$tag" || ! wait_for_version 30086 "$tag"; then
        echo "$tag did not come up on $idle - live traffic was never switched"
        k rollout undo "deployment/aceest-$idle"
        exit 1
    fi

    switch_to "$idle"
    if ! wait_for_version 30082 "$tag"; then
        echo "Switch failed - going back to $live"
        switch_to "$live"
        exit 1
    fi
    echo "Blue-green: users now on $idle ($tag); $live is kept running for an instant rollback"
}

# Point the live Service at one colour and the preview Service at the other
switch_to() {
    local new=$1 old
    if [ "$new" = blue ]; then old=green; else old=blue; fi
    k patch service aceest-bg-live -p "{\"spec\":{\"selector\":{\"slot\":\"$new\"}}}"
    k patch service aceest-bg-preview -p "{\"spec\":{\"selector\":{\"slot\":\"$old\"}}}"
}

canary() {
    local stable=$1 new=$2
    ensure canary.yaml aceest-canary-stable
    roll_to aceest-canary-stable "$stable"
    k scale deployment/aceest-canary-new --replicas=1
    if ! roll_to aceest-canary-new "$new"; then
        echo "Canary $new did not start - switching it off, all traffic stays on $stable"
        k scale deployment/aceest-canary-new --replicas=0
        exit 1
    fi
    k rollout status deployment/aceest-canary-router --timeout=120s
    echo "Canary: 4 of 5 requests -> $stable, 1 of 5 -> $new  (http://$VM_IP:30083)"
    echo "10 requests:"
    for _ in $(seq 1 10); do version_on 30083 || echo "error"; done | sort | uniq -c
}

ab() {
    local a=$1 b=$2
    ensure ab-testing.yaml aceest-ab-a
    roll_to aceest-ab-a "$a"
    k scale deployment/aceest-ab-b --replicas=1
    roll_to aceest-ab-b "$b"
    k rollout status deployment/aceest-ab-router --timeout=120s
    echo "A/B: group A -> $a, group B -> $b  (http://$VM_IP:30084)"
    echo "  X-AB-Group: A  -> $(version_on 30084 -H 'X-AB-Group: A')"
    echo "  X-AB-Group: B  -> $(version_on 30084 -H 'X-AB-Group: B')"
    echo "  no header      -> $(version_on 30084) (50/50 split by client address + browser)"
}

shadow() {
    local live=$1 new=$2
    ensure shadow.yaml aceest-shadow-live
    roll_to aceest-shadow-live "$live"
    k scale deployment/aceest-shadow-new --replicas=1
    roll_to aceest-shadow-new "$new"
    k rollout status deployment/aceest-shadow-router --timeout=120s
    echo "Shadow: users get $live, a copy of every request goes to $new  (http://$VM_IP:30085)"
    for _ in 1 2 3; do echo "  user got: $(version_on 30085)"; done
    sleep 2
    echo "  copies received by the shadow ($new):"
    k logs deployment/aceest-shadow-new --tail=3 | sed 's/^/    /'
}

rollback() {
    case "${1:-}" in
        rolling)
            k rollout undo deployment/aceest-rolling
            k rollout status deployment/aceest-rolling --timeout=120s
            echo "Rolling: back on $(version_on 30081)"
            ;;
        bluegreen)
            local live
            live="$(k get service aceest-bg-live -o jsonpath='{.spec.selector.slot}')"
            if [ "$live" = blue ]; then switch_to green; else switch_to blue; fi
            sleep 2
            echo "Blue-green: users back on $(version_on 30082)"
            ;;
        canary)
            k scale deployment/aceest-canary-new --replicas=0
            echo "Canary switched off - all traffic on $(current_tag aceest-canary-stable)"
            ;;
        ab)
            k scale deployment/aceest-ab-b --replicas=0
            echo "A/B test ended - everyone gets $(current_tag aceest-ab-a)"
            ;;
        shadow)
            k scale deployment/aceest-shadow-new --replicas=0
            echo "Shadow switched off - users were never affected"
            ;;
        *)
            echo "usage: $0 rollback rolling|bluegreen|canary|ab|shadow"
            exit 1
            ;;
    esac
}

status() {
    k get deployments -o wide
    echo
    printf '%-22s %-28s %s\n' "Strategy" "URL" "Answers with"
    printf '%-22s %-28s %s\n' "Rolling update" "http://$VM_IP:30081" "$(version_on 30081 || echo -)"
    printf '%-22s %-28s %s\n' "Blue-green (live)" "http://$VM_IP:30082" "$(version_on 30082 || echo -)"
    printf '%-22s %-28s %s\n' "Blue-green (preview)" "http://$VM_IP:30086" "$(version_on 30086 || echo -)"
    printf '%-22s %-28s %s\n' "Canary" "http://$VM_IP:30083" "mix of $(current_tag aceest-canary-stable 2>/dev/null || echo -) and $(current_tag aceest-canary-new 2>/dev/null || echo -)"
    printf '%-22s %-28s %s\n' "A/B testing" "http://$VM_IP:30084" "A=$(version_on 30084 -H 'X-AB-Group: A' || echo -)  B=$(version_on 30084 -H 'X-AB-Group: B' || echo -)"
    printf '%-22s %-28s %s\n' "Shadow" "http://$VM_IP:30085" "$(version_on 30085 || echo -) (copies to $(current_tag aceest-shadow-new 2>/dev/null || echo -))"
}

command="${1:-}"
shift || true
case "$command" in
    init)      init ;;
    rolling)   rolling "${1:?tag}" ;;
    bluegreen) bluegreen "${1:?tag}" ;;
    canary)    canary "${1:?stable tag}" "${2:?new tag}" ;;
    ab)        ab "${1:?tag for group A}" "${2:?tag for group B}" ;;
    shadow)    shadow "${1:?live tag}" "${2:?new tag}" ;;
    rollback)  rollback "${1:-}" ;;
    status)    status ;;
    *)         sed -n '2,13p' "$0"; exit 1 ;;
esac
