#!/usr/bin/env bash
# Sets up a fresh Prayogshala VM (Rocky Linux) for the ACEest pipeline.
# The lab VM is reset between sessions, so run this at the start of every session:
#
#   sudo bash scripts/setup-prayogshala.sh
#
# It installs/starts: SonarQube (Docker), SonarScanner, kubectl, Minikube,
# and lets the jenkins user run Docker and deploy to Minikube. Safe to run twice.
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
    echo "Please run with sudo: sudo bash scripts/setup-prayogshala.sh"
    exit 1
fi

STUDENT="${SUDO_USER:-root}"
STUDENT_HOME="$(getent passwd "$STUDENT" | cut -d: -f6)"
SCANNER_VERSION="8.1.0.6389"
VM_IP="$(hostname -I | awk '{print $1}')"

step() { echo; echo "===== $* ====="; }

step "1/7 Memory and CPU check"
free -h
echo "CPUs: $(nproc)"
if [ "$(nproc)" -lt 2 ]; then
    echo "Minikube needs at least 2 CPUs - ask the lab support for a bigger VM."
    exit 1
fi

step "2/7 SonarQube"
# Elasticsearch inside SonarQube needs a higher memory-map limit
echo 'vm.max_map_count=524288' > /etc/sysctl.d/99-sonarqube.conf
sysctl -q -p /etc/sysctl.d/99-sonarqube.conf
if ! docker ps -a --format '{{.Names}}' | grep -qx sonarqube; then
    docker run -d --name sonarqube --restart unless-stopped \
        -e SONAR_ES_BOOTSTRAP_CHECKS_DISABLE=true -p 9000:9000 sonarqube:community
else
    docker start sonarqube >/dev/null
fi

step "3/7 SonarScanner in /opt/sonar-scanner"
if [ ! -x /opt/sonar-scanner/bin/sonar-scanner ]; then
    dnf install -y -q unzip
    curl -fsSLo /tmp/sonar-scanner.zip \
        "https://binaries.sonarsource.com/Distribution/sonar-scanner-cli/sonar-scanner-cli-${SCANNER_VERSION}-linux-x64.zip"
    rm -rf /opt/sonar-scanner /opt/sonar-scanner-*
    unzip -q /tmp/sonar-scanner.zip -d /opt
    mv /opt/sonar-scanner-* /opt/sonar-scanner
    chmod -R a+rX /opt/sonar-scanner
fi
/opt/sonar-scanner/bin/sonar-scanner --version | grep -i "SonarScanner CLI" || true

step "4/7 kubectl and Minikube"
if [ ! -x /usr/local/bin/kubectl ]; then
    KUBECTL_VERSION="$(curl -fsSL https://dl.k8s.io/release/stable.txt)"
    curl -fsSLo /usr/local/bin/kubectl "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl"
    chmod +x /usr/local/bin/kubectl
fi
if [ ! -x /usr/local/bin/minikube ]; then
    curl -fsSLo /usr/local/bin/minikube \
        https://storage.googleapis.com/minikube/releases/latest/minikube-linux-amd64
    chmod +x /usr/local/bin/minikube
fi
/usr/local/bin/kubectl version --client || true
/usr/local/bin/minikube version || true

step "5/7 Let the jenkins user run Docker"
usermod -aG docker jenkins
systemctl restart jenkins

step "6/7 Start Minikube (owned by jenkins, so the pipeline can deploy)"
# --listen-address/--ports publish the NodePorts on the VM's own IP,
# so the strategies are reachable at http://<vm-ip>:30081 ... 30086
sudo -u jenkins -H /usr/local/bin/minikube start \
    --driver=docker --cpus=2 --memory=2800mb --embed-certs \
    --listen-address=0.0.0.0 \
    --ports=30081:30081,30082:30082,30083:30083,30084:30084,30085:30085,30086:30086

# Give the student the same kubeconfig, so plain `kubectl` works in the terminal
mkdir -p "$STUDENT_HOME/.kube"
cp /var/lib/jenkins/.kube/config "$STUDENT_HOME/.kube/config"
chown -R "$STUDENT": "$STUDENT_HOME/.kube"
/usr/local/bin/kubectl --kubeconfig "$STUDENT_HOME/.kube/config" get nodes

# Open the ports if the firewall is on (it usually isn't on the lab VM)
if systemctl is-active -q firewalld; then
    firewall-cmd -q --add-port=8080/tcp --add-port=9000/tcp --add-port=30081-30086/tcp
fi

step "7/7 Waiting for SonarQube to finish starting"
for _ in $(seq 1 60); do
    if curl -fs http://localhost:9000/api/system/status | grep -q '"UP"'; then
        echo "SonarQube is up"
        break
    fi
    sleep 5
done

cat <<EOF

Setup done. Next (see the guide):
  1. SonarQube  http://localhost:9000  -> log in (admin/admin), make a token
  2. Jenkins    http://localhost:8080  -> credentials 'sonar-token' and 'dockerhub', then the job
  3. After the pipeline deploys, the strategies are at http://$VM_IP:30081 ... 30086
     (on the VM you can also use: http://\$(sudo -u jenkins minikube ip):30081)
EOF
