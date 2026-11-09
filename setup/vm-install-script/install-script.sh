  KUBE_MINOR="$(kubeadm version -o short | cut -d. -f1,2)"
else
  KUBE_MINOR="$(curl -fsSL https://dl.k8s.io/release/stable.txt | cut -d. -f1,2)"
fi
if [[ ! -s /etc/apt/keyrings/kubernetes-apt-keyring.gpg ]]; then
  curl -fsSL "https://pkgs.k8s.io/core:/stable:/${KUBE_MINOR}/deb/Release.key" | gpg --dearmor > /etc/apt/keyrings/kubernetes-apt-keyring.gpg
fi
printf 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/%s/deb/ /\n' "$KUBE_MINOR" > /etc/apt/sources.list.d/kubernetes.list

# Fix Jenkins repository *before* apt update: old entry causes NO_PUBKEY 7198F4B714ABFC68.
# Back up and disable OTHER Jenkins source-list files to avoid duplicate/conflicting signed-by entries.
BACKUP_DIR="/root/jenkins-apt-backup-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$BACKUP_DIR"
shopt -s nullglob
for f in /etc/apt/sources.list.d/*.list /etc/apt/sources.list.d/*.sources; do
  [[ "$f" == /etc/apt/sources.list.d/jenkins.list ]] && continue
  if grep -q 'pkg.jenkins.io' "$f"; then
    cp -a "$f" "$BACKUP_DIR/"
    # Do not modify a mixed-purpose file: fail and ask for manual inspection.
    if grep -Ev '^\s*(#|$)' "$f" | grep -v 'pkg.jenkins.io' | grep -q .; then
      echo "Other APT sources share $f; inspect and disable old Jenkins entry manually" >&2
      exit 1
    fi
    mv "$f" "$f.disabled"
  fi
done
# Handle an old Jenkins entry in main sources.list, without blindly editing unrelated repos.
if [[ -f /etc/apt/sources.list ]] && grep -Eq '^[[:space:]]*deb .*pkg\.jenkins\.io' /etc/apt/sources.list; then
  cp -a /etc/apt/sources.list "$BACKUP_DIR/sources.list"
  sed -i '/^[[:space:]]*deb .*pkg\.jenkins\.io/s/^/# disabled old Jenkins source: /' /etc/apt/sources.list
fi
curl -fsSL https://pkg.jenkins.io/debian-stable/jenkins.io-2026.key -o /etc/apt/keyrings/jenkins-keyring.asc
EXPECTED_FP='5E386EADB55F01504CAE8BCF7198F4B714ABFC68'
ACTUAL_FP="$(gpg --batch --show-keys --with-colons /etc/apt/keyrings/jenkins-keyring.asc | awk -F: '$1=="fpr" {print $10; exit}')"
[[ "$ACTUAL_FP" == "$EXPECTED_FP" ]] || { echo "Unexpected Jenkins signing key fingerprint: $ACTUAL_FP" >&2; exit 1; }
printf 'deb [signed-by=/etc/apt/keyrings/jenkins-keyring.asc] https://pkg.jenkins.io/debian-stable binary/\n' > /etc/apt/sources.list.d/jenkins.list

apt-get update
apt-get install -y ca-certificates curl gnupg wget lsb-release
apt-get install -y docker.io vim build-essential jq python3-pip kubelet kubectl kubernetes-cni kubeadm containerd
# Preserve the original jc utility without system-wide pip mutation if possible.
if ! command -v jc >/dev/null 2>&1; then
  if apt-cache show jc >/dev/null 2>&1; then apt-get install -y jc; else python3 -m pip install jc; fi
fi
if command -v dmidecode >/dev/null 2>&1; then dmidecode -s system-uuid 2>/dev/null || true; fi
systemctl enable kubelet

banner KUBERNETES
mkdir -p /etc/containerd
# Keep existing containerd config if present; avoid disruptive overwrites.
if [[ ! -s /etc/containerd/config.toml ]]; then
  containerd config default | sed 's/SystemdCgroup = false/SystemdCgroup = true/' > /etc/containerd/config.toml
  systemctl restart containerd
fi
systemctl enable --now containerd

CLUSTER_EXISTING=false
if [[ -s /etc/kubernetes/admin.conf ]]; then
  CLUSTER_EXISTING=true
  echo 'Existing kubeadm cluster found: preserving etcd, certificates and manifests.'
else
  echo 'No existing kubeadm admin.conf; initializing the Kubernetes control-plane.'
  kubeadm init --pod-network-cidr '10.244.0.0/16' --service-cidr '10.96.0.0/16' --skip-token-print
fi

# Keep kubectl functional for both root and the normal Azure user.
install -d -m 0700 /root/.kube
install -m 0600 /etc/kubernetes/admin.conf /root/.kube/config
install -d -o "$TARGET_USER" -g "$(id -gn "$TARGET_USER")" -m 0700 "$TARGET_HOME/.kube"
install -o "$TARGET_USER" -g "$(id -gn "$TARGET_USER")" -m 0600 /etc/kubernetes/admin.conf "$TARGET_HOME/.kube/config"
export KUBECONFIG=/etc/kubernetes/admin.conf

if ! kubectl -n kube-system get daemonset weave-net >/dev/null 2>&1; then
  # Retain the same Weave Net plugin used by the original script.
  kubectl apply -f 'https://github.com/weaveworks/weave/releases/download/v2.8.1/weave-daemonset-k8s-1.11.yaml'
fi
kubectl rollout status daemonset weave-net -n kube-system --timeout=180s
NODE_NAME="$(kubectl get nodes -o jsonpath='{.items[0].metadata.name}')"
# Original single-node control plane untaint setting, idempotent.
kubectl taint nodes "$NODE_NAME" node-role.kubernetes.io/control-plane:NoSchedule- 2>/dev/null || true
kubectl get nodes -o wide

banner Docker
mkdir -p /etc/docker /etc/systemd/system/docker.service.d
cat > /etc/docker/daemon.json <<'DOCKER_CONFIG'
{
  "exec-opts": ["native.cgroupdriver=systemd"],
  "log-driver": "json-file",
  "storage-driver": "overlay2"
}
DOCKER_CONFIG
systemctl daemon-reload
systemctl enable --now docker
systemctl restart docker

banner 'Java and MAVEN'
apt-get install -y openjdk-11-jdk maven
# Jenkins requires a newer runtime; keep Java 11 as the system default for builds.
if apt-cache show openjdk-21-jre-headless >/dev/null 2>&1; then
  apt-get install -y fontconfig openjdk-21-jre-headless
  JENKINS_JAVA="$(find /usr/lib/jvm -path '*/bin/java' -type f -o -path '*/bin/java' -type l | grep -E '(java-21|jdk-21)' | head -n 1 || true)"
else
  # Ubuntu 22.04 may not offer OpenJDK 21 in enabled repositories. Install Temurin 21.
  curl -fsSL https://packages.adoptium.net/artifactory/api/gpg/key/public | gpg --dearmor > /etc/apt/keyrings/adoptium.gpg
  CODENAME="$(. /etc/os-release; echo "$VERSION_CODENAME")"
  printf 'deb [signed-by=/etc/apt/keyrings/adoptium.gpg] https://packages.adoptium.net/artifactory/deb %s main\n' "$CODENAME" > /etc/apt/sources.list.d/adoptium.list
  apt-get update
  apt-get install -y temurin-21-jre
  JENKINS_JAVA="$(find /usr/lib/jvm -path '*/bin/java' | grep -E '(temurin-21|jdk-21)' | head -n 1 || true)"
fi
[[ -n "$JENKINS_JAVA" && -x "$JENKINS_JAVA" ]] || { echo 'Java 21 executable not found' >&2; exit 1; }
"$JENKINS_JAVA" -version
java -version
mvn -version

banner JENKINS
apt-get install -y jenkins
# Java 21 only for Jenkins, without altering the default Java 11 for builds.
mkdir -p /etc/systemd/system/jenkins.service.d
cat > /etc/systemd/system/jenkins.service.d/java21.conf <<EOF_JAVA
[Service]
Environment="JENKINS_JAVA_CMD=$JENKINS_JAVA"
EOF_JAVA
systemctl daemon-reload
systemctl enable --now jenkins
systemctl restart jenkins
usermod -aG docker jenkins
# Retain the original Jenkins sudo access request. WARNING: this grants Jenkins full root.
cat > /etc/sudoers.d/jenkins-lab <<'JENKINS_SUDO'
jenkins ALL=(ALL) NOPASSWD: ALL
JENKINS_SUDO
chmod 0440 /etc/sudoers.d/jenkins-lab
visudo -cf /etc/sudoers.d/jenkins-lab

banner COMPLETED
systemctl --no-pager --full status jenkins | head -n 12 || true
kubectl get nodes
printf '\nJenkins initial password (keep private): sudo cat /var/lib/jenkins/secrets/initialAdminPassword\n'

