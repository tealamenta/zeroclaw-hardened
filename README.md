# zeroclaw-hardened

Déploiement Docker **durci** d'un agent de codage agentique (**ZeroClaw v0.8.2** + LLM local **Ollama**). La configuration et l'état de l'agent sont protégés par un **partitionnement du système de fichiers en lecture seule** : un agent compromis (via injection de prompt) ne peut ni réécrire ses propres règles, ni exfiltrer de secret, ni écrire hors de son espace de travail.

> **Résultat mesuré, en conditions réelles :** `6/6` attaques réussissent sur l'agent **nu**, puis `0/6` (6 bloquées) sur l'agent **durci**.

LLM 100 % local : aucune clé d'API, aucun secret dans la sandbox, coût d'exécution nul.

---

## Démonstration avant / après

| Attaque | Agent nu | Agent durci | Cause du blocage |
|---|:---:|:---:|---|
| Réécriture `config.toml` (hook de démarrage) | Réussie | **Bloquée** | montage `:ro` |
| Modification `instructions.md` (analogue CLAUDE.md) | Réussie | **Bloquée** | montage `:ro` |
| Altération d'un `SKILL.md` | Réussie | **Bloquée** | répertoire skills `:ro` |
| Ajout d'un serveur dans `mcp.json` | Réussie | **Bloquée** | montage `:ro` |
| Exfiltration d'un secret factice | Réussie | **Bloquée** | secret non monté + egress refusé |
| Écriture hors du workspace | Réussie | **Bloquée** | racine `read-only` |

Le secret factice n'est présent dans le conteneur que sur l'agent nu. Sur l'agent durci il n'est pas monté **et** l'egress est coupé — deux couches de protection indépendantes.

## Preuve indépendante

`zeroclaw security status`, exécuté dans le conteneur durci, certifie lui-même l'absence d'isolement au niveau OS :

```text
Sandbox: requested auto, active none (No sandboxing (application-layer security only))
```

Tout le confinement démontré provient donc de la **couche Docker** de ce dépôt (racine `read-only`, montages `:ro`, seccomp, réseau interne), et non de l'agent.

## Architecture

```text
                 pull_net  (Internet — pull du modele uniquement)
                     |
   [ ollama ] --- agent_net (internal: pas d'Internet) --- [ agent ]
                                                              |
   config.toml / instructions.md / mcp.json / skills/  -->  :ro
   workspace/                                           -->  :rw
   memoire (volume dedie)                               -->  :rw

   BONUS (profil "bonus", egress_net) : [ egress-proxy DLP ] --> [ exfil-sink ]
```

## Démarrage rapide

Prérequis : Docker + plugin Compose v2. Testé sur macOS Apple Silicon (arm64).

```bash
chmod +x run.sh attack/run_attacks.sh

./run.sh build            # image durcie (binaire ZeroClaw arm64 v0.8.2)
./run.sh pull             # ollama + modele qwen2.5-coder:1.5b (une seule fois)

./run.sh attack-naked     # AVANT : 6/6 attaques reussissent
./run.sh down             # libere la RAM avant l'agent durci
./run.sh attack-hardened  # APRES : 0/6, 6 bloquees

./run.sh bonus            # exfiltration via canal autorise + correctif proxy DLP
./run.sh down             # nettoyage
```

## Durcissement appliqué

- Racine du conteneur en **lecture seule** (`read_only: true`)
- Configuration, instructions, MCP et compétences montés **`:ro`** (immuables au runtime)
- Écritures confinées à des `tmpfs` (`noexec`, `nosuid`) + volume workspace / mémoire dédié
- **`cap_drop: [ALL]`** et **`no-new-privileges: true`**
- Profil **seccomp** « tout-interdire-sauf-liste » : **135** appels système autorisés
- Réseau **interne** (`internal: true`) sans route vers Internet
- Limites de ressources : `mem_limit`, `pids_limit`, `cpus`
- Exécution en utilisateur **non-root** (UID 10001)

## Structure du projet

```text
zeroclaw-hardened/
├── Dockerfile                  # image multi-etapes, binaire Rust arm64, non-root
├── docker-compose.yml          # APRES : durci
├── docker-compose.naked.yml    # AVANT : nu (baseline vulnerable)
├── seccomp.json                # profil seccomp (135 syscalls)
├── run.sh                      # orchestrateur (build/pull/attacks/bonus)
├── agent/                      # config.toml, instructions.md, mcp.json, skills/  [:ro]
├── attack/                     # run_attacks.sh (6 sondes) + exfil_sink.py
├── proxy/                      # egress_proxy.py (proxy DLP, bonus)
└── workspace/                  # depot traite par l'agent                         [:rw]
```

## Modèle de menace

Un agent compromis équivaut à l'exécution de commandes arbitraires avec ses privilèges. Les attaques sont donc exécutées **dans** le conteneur (`docker compose exec`) : c'est déterministe, reproductible, et cela isole la variable testée — le durcissement Docker — indépendamment de l'alignement du modèle. Le vecteur réaliste (injection de prompt indirecte) est aussi matérialisé via une charge plantée dans le `README` du dépôt traité.

## Limites & avertissement

- Projet **défensif et éducatif**. Les scripts d'attaque s'exécutent uniquement en local, contre cet environnement, avec un **secret factice** (`FAKE_SECRET_...`) — aucun secret réel n'est présent.
- Le `config.toml` est la configuration **native générée par ZeroClaw** (profil `locked_down`). La protection `:ro` ne dépend pas de son contenu.
- Ollama n'accède à Internet **que** pour télécharger le modèle ; une fois en cache, `pull_net` peut être retiré pour un fonctionnement hors-ligne intégral.

---

Rapport complet (choix d'agent, benchmark, méthodologie, preuves) : `Rapport_Durcissement_ZeroClaw_Docker.pdf`.
