#!/usr/bin/env bash
# Reinitialisation ciblee OWASP Dependency-Check 12.2.2 sur VM Ubuntu.
# Ne supprime ni Jenkins, ni Docker, ni Kubernetes, ni SonarQube.
set -Eeuo pipefail

VERSION='12.2.2'
MIRROR='https://dependency-check.github.io/DependencyCheck_Builder/nvd_cache/nvdcve-{0}.json.gz'
PROJECT_DIR="${1:-$HOME/devsecops}"
LOCAL_CACHE="$HOME/.m2/repository/org/owasp/dependency-check-data"

say() { printf '\n>>> %s\n' "$*"; }
fail() { printf 'ERREUR: %s\n' "$*" >&2; exit 1; }

[[ "$(id -un)" != 'root' ]] || fail 'Executer ce script comme devsecops, sans sudo devant bash.'
[[ -f "$PROJECT_DIR/pom.xml" ]] || fail "pom.xml introuvable : $PROJECT_DIR"
command -v mvn >/dev/null || fail 'Maven non installe ou absent du PATH.'
command -v java >/dev/null || fail 'Java non installe ou absent du PATH.'
command -v sudo >/dev/null || fail 'sudo est requis pour le cache Jenkins.'
id jenkins >/dev/null 2>&1 || fail 'Utilisateur jenkins introuvable sur cette VM.'
JENKINS_HOME="$(getent passwd jenkins | cut -d: -f6)"
[[ "$JENKINS_HOME" == /* && "$JENKINS_HOME" != / && "$JENKINS_HOME" != "$HOME" ]] || fail 'HOME Jenkins inhabituel, arret par securite.'
JENKINS_CACHE="$JENKINS_HOME/.m2/repository/org/owasp/dependency-check-data"
JENKINS_SETTINGS="$JENKINS_HOME/.m2/settings.xml"

say 'Environnement actuel'
mvn -version
java -version
printf 'Projet : %s\nCache devsecops : %s\nCache jenkins : %s\n' "$PROJECT_DIR" "$LOCAL_CACHE" "$JENKINS_CACHE"

cat <<'NOTICE'

ATTENTION : arreter temporairement les builds Jenkins utilisant Dependency-Check.
Le script supprime uniquement les deux caches OWASP indiques ci-dessus et les
rapports OWASP dans target/ du projet local. Il n'efface aucun autre logiciel.
NOTICE
read -r -p 'Tape RESET-OWASP pour continuer : ' CONFIRM
[[ "$CONFIRM" == 'RESET-OWASP' ]] || fail 'Operation annulee.'
sudo -v

say '1/5 Nettoyage cible des anciens caches et rapports'
rm -rf -- "$LOCAL_CACHE"
sudo rm -rf -- "$JENKINS_CACHE"
if [[ -d "$PROJECT_DIR/target" ]]; then
  rm -f -- "$PROJECT_DIR"/target/dependency-check-report.*
fi

say '2/5 Reconstruction NVD via miroir officiel OWASP'
(
  cd "$PROJECT_DIR"
  mvn -B "org.owasp:dependency-check-maven:${VERSION}:update-only" \
    "-DnvdDatafeedUrl=$MIRROR"
)
[[ -d "$LOCAL_CACHE" ]] || fail 'Aucun cache cree apres update-only.'

say '3/5 Copie du cache pour le compte jenkins'
sudo install -d -o jenkins -g jenkins -m 0700 "$JENKINS_HOME/.m2"
sudo install -d -o jenkins -g jenkins -m 0755 "$JENKINS_HOME/.m2/repository"
sudo -u jenkins -H mkdir -p "$JENKINS_CACHE"
sudo cp -a -- "$LOCAL_CACHE/." "$JENKINS_CACHE/"
sudo chown -R jenkins:jenkins "$JENKINS_CACHE"
sudo -u jenkins test -r "$JENKINS_CACHE/11.0" || fail 'Le compte jenkins ne peut pas lire son cache.'

say '4/5 Configuration permanente du miroir Maven pour Jenkins'
if sudo test -e "$JENKINS_SETTINGS"; then
  echo "Un settings.xml Jenkins existe deja : $JENKINS_SETTINGS"
  echo 'Non modifie pour eviter de casser une configuration Maven existante.'
  echo 'Verifier manuellement la presence de nvdDatafeedUrl dans son profil Maven actif.'
else
  TMP_SETTINGS="$(mktemp)"
  trap 'rm -f -- "${TMP_SETTINGS:-}"' EXIT
  cat > "$TMP_SETTINGS" <<SETTINGS
<settings xmlns="http://maven.apache.org/SETTINGS/1.0.0">
  <profiles>
    <profile>
      <id>owasp-nvd-mirror</id>
      <properties>
        <nvdDatafeedUrl>${MIRROR}</nvdDatafeedUrl>
      </properties>
    </profile>
  </profiles>
  <activeProfiles>
    <activeProfile>owasp-nvd-mirror</activeProfile>
  </activeProfiles>
</settings>
SETTINGS
  sudo install -d -o jenkins -g jenkins -m 0700 "$JENKINS_HOME/.m2"
  sudo install -o jenkins -g jenkins -m 0600 "$TMP_SETTINGS" "$JENKINS_SETTINGS"
  echo "Cree : $JENKINS_SETTINGS"
fi

say '5/5 Verification technique du scan (le seuil CVSS est neutralise POUR CE TEST UNIQUEMENT)'
(
  cd "$PROJECT_DIR"
  mvn -B "org.owasp:dependency-check-maven:${VERSION}:check" \
    "-DnvdDatafeedUrl=$MIRROR" \
    -DautoUpdate=false \
    -DfailBuildOnCVSS=11 \
    -Dformat=ALL
)
REPORT_XML="$PROJECT_DIR/target/dependency-check-report.xml"
REPORT_HTML="$PROJECT_DIR/target/dependency-check-report.html"
[[ -s "$REPORT_XML" ]] || fail 'Le rapport XML est absent ou vide.'

say 'Reinitialisation terminee : scanner fonctionnel'
ls -lh -- "$REPORT_XML"
[[ -s "$REPORT_HTML" ]] && ls -lh -- "$REPORT_HTML" || true
cat <<'RESULT'

ATTENTION : ce test ne signifie PAS que l'application est securisee.
Il permet seulement de verifier que le moteur de scan et les rapports fonctionnent.
Le Jenkinsfile garde son seuil CVSS=5 et peut echouer normalement sur les CVE.

Pour refaire un CONTROLE DE SECURITE strict :
  cd ~/devsecops
  mvn org.owasp:dependency-check-maven:12.2.2:check \
    -DautoUpdate=false -DfailBuildOnCVSS=5 -Dformat=ALL

Puis relancer un NOUVEAU build Jenkins depuis GitHub (Build Now).
RESULT
