#!/usr/bin/env bash
# Rotation de la clé RSA qui signe les jetons (monokek-identity).
#
# À lancer après toute fuite de la clé (ex. private.pem commité dans git) ou périodiquement.
#
#   ./deploy/rotate-jwt-key.sh                 # génère, met à jour .env, retire private/public.pem de git
#   ./deploy/rotate-jwt-key.sh --restart       # idem, puis recrée identity + spring + pms
#   ./deploy/rotate-jwt-key.sh --yes --restart # sans confirmation interactive
#
# Options :
#   --restart         recrée monokek-identity, monokek-spring et pms-modulith pour que la nouvelle
#                     clé soit signée ET que les caches JWKS des deux autres services soient vidés
#                     (sinon l'ancienne clé reste acceptée jusqu'à ~5 min après le changement).
#   --yes             ne demande pas confirmation.
#   --env-file FILE   fichier à modifier (défaut : .env à la racine du dépôt de déploiement).
#   --no-git          ne touche pas à git (private.pem / public.pem / .gitignore).
#
# Conséquence : TOUS les jetons en circulation deviennent invalides, donc tous les utilisateurs
# (caisses, tablettes, PMS) doivent se reconnecter une fois.
#
# Ce script n'affiche jamais la clé, ne la met dans aucun fichier autre que .env, et ne commite rien.
set -euo pipefail
cd "$(dirname "$0")/.."

ENV_FILE=.env
RESTART=0
ASSUME_YES=0
TOUCH_GIT=1

while [ $# -gt 0 ]; do
    case "$1" in
        --restart) RESTART=1 ;;
        --yes) ASSUME_YES=1 ;;
        --no-git) TOUCH_GIT=0 ;;
        --env-file) shift; ENV_FILE="${1:?--env-file demande un chemin}" ;;
        -h|--help) sed -n '2,22p' "$0"; exit 0 ;;
        *) echo "Option inconnue : $1 (voir --help)" >&2; exit 1 ;;
    esac
    shift
done

command -v openssl >/dev/null || { echo "openssl est requis." >&2; exit 1; }
[ -f "$ENV_FILE" ] || { echo "Fichier introuvable : $ENV_FILE" >&2; exit 1; }
[ -w "$ENV_FILE" ] || { echo "$ENV_FILE n'est pas modifiable par cet utilisateur." >&2; exit 1; }
if [ "$RESTART" -eq 1 ]; then
    command -v docker >/dev/null || { echo "--restart demande docker." >&2; exit 1; }
fi

echo "Rotation de la clé de signature JWT"
echo "  fichier modifié : $ENV_FILE"
echo "  effet           : tous les utilisateurs devront se reconnecter"
[ "$RESTART" -eq 1 ] && echo "  redémarrage     : monokek-identity, monokek-spring, pms-modulith"
if [ "$ASSUME_YES" -ne 1 ]; then
    read -r -p "Continuer ? [o/N] " answer
    case "$answer" in o|O|oui|OUI|y|Y) ;; *) echo "Annulé."; exit 1 ;; esac
fi

umask 077
WORK=$(mktemp -d)
cleanup() {
    find "$WORK" -type f -exec shred -u {} + 2>/dev/null || true
    rm -rf "$WORK"
    unset NEWVAL
}
trap cleanup EXIT

# --- 1. Nouvelle paire (PKCS#8 / X.509, corps base64 sur une ligne, comme .env.example) -----------
openssl genrsa 2048 2>/dev/null | openssl pkcs8 -topk8 -nocrypt -out "$WORK/private.pem"
openssl rsa -in "$WORK/private.pem" -pubout -out "$WORK/public.pem" 2>/dev/null
PRIVATE_BODY=$(grep -v -- '-----' "$WORK/private.pem" | tr -d '\n')
PUBLIC_BODY=$(grep -v -- '-----' "$WORK/public.pem" | tr -d '\n')
[ -n "$PRIVATE_BODY" ] && [ -n "$PUBLIC_BODY" ] || { echo "Génération de la clé échouée." >&2; exit 1; }

# --- 2. Sauvegarde puis réécriture atomique de .env ---------------------------------------------
BACKUP="${ENV_FILE}.bak-$(date +%Y%m%d-%H%M%S)"
cp -p "$ENV_FILE" "$BACKUP"
chmod 600 "$BACKUP"

# Remplace la ligne NAME=... (ancrée : n'attrape pas NAME_AUTRE=) ou l'ajoute si absente.
# La valeur passe par l'environnement d'awk, jamais par la ligne de commande ni par un échappement.
set_var() {
    local name="$1" value="$2"
    NEWVAL="$value" awk -v name="$name" '
        BEGIN { v = ENVIRON["NEWVAL"]; prefix = name "=" }
        index($0, prefix) == 1 { print prefix v; found = 1; next }
        { print }
        END { if (!found) print prefix v }
    ' "$ENV_FILE" > "$WORK/env.new"
    cat "$WORK/env.new" > "$ENV_FILE"   # conserve droits et propriétaire de .env
}
set_var IDENTITY_RSA_PRIVATE_KEY_PEM "$PRIVATE_BODY"
set_var IDENTITY_RSA_PUBLIC_KEY_PEM "$PUBLIC_BODY"
unset PRIVATE_BODY PUBLIC_BODY

# Relecture : les deux valeurs écrites doivent redonner une paire cohérente.
read_var() { awk -v prefix="$1=" 'index($0, prefix) == 1 { print substr($0, length(prefix) + 1); exit }' "$ENV_FILE"; }
{
    echo "-----BEGIN PRIVATE KEY-----"; read_var IDENTITY_RSA_PRIVATE_KEY_PEM | fold -w 64; echo "-----END PRIVATE KEY-----"
} > "$WORK/check-private.pem"
{
    echo "-----BEGIN PUBLIC KEY-----"; read_var IDENTITY_RSA_PUBLIC_KEY_PEM | fold -w 64; echo "-----END PUBLIC KEY-----"
} > "$WORK/check-public.pem"
FROM_PRIV=$(openssl pkey -in "$WORK/check-private.pem" -pubout 2>/dev/null | openssl dgst -sha256 | awk '{print $NF}')
FROM_PUB=$(openssl pkey -pubin -in "$WORK/check-public.pem" -pubout 2>/dev/null | openssl dgst -sha256 | awk '{print $NF}')
if [ -z "$FROM_PRIV" ] || [ "$FROM_PRIV" != "$FROM_PUB" ]; then
    cat "$BACKUP" > "$ENV_FILE"
    echo "La relecture de $ENV_FILE ne donne pas une paire cohérente : ancien fichier restauré, rien n'a changé." >&2
    shred -u "$BACKUP" 2>/dev/null || rm -f "$BACKUP"
    exit 1
fi
echo "OK  $ENV_FILE mis à jour (empreinte de la nouvelle clé publique : ${FROM_PUB:0:16})"

# --- 3. git : la clé ne doit plus jamais être suivie ---------------------------------------------
if [ "$TOUCH_GIT" -eq 1 ] && git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    for f in private.pem public.pem; do
        if git ls-files --error-unmatch "$f" >/dev/null 2>&1; then
            git rm --cached -q "$f"
            echo "OK  $f retiré de l'index git (pas encore commité)"
        fi
        [ -f "$f" ] && { shred -u "$f" 2>/dev/null || rm -f "$f"; echo "OK  $f supprimé du disque"; }
    done
    for pattern in '*.pem' '.env.bak*'; do
        grep -qxF "$pattern" .gitignore 2>/dev/null || { printf '%s\n' "$pattern" >> .gitignore; echo "OK  '$pattern' ajouté à .gitignore"; }
    done
fi

# --- 4. Redémarrage ------------------------------------------------------------------------------
if [ "$RESTART" -eq 1 ]; then
    echo "Recréation des services…"
    docker compose up -d --force-recreate monokek-identity monokek-spring pms-modulith
    echo -n "Attente du healthcheck d'identity"
    for _ in $(seq 1 60); do
        status=$(docker compose ps monokek-identity --format '{{.Health}}' 2>/dev/null || true)
        [ "$status" = "healthy" ] && break
        echo -n "."; sleep 3
    done
    echo
    [ "${status:-}" = "healthy" ] && echo "OK  monokek-identity est healthy" \
        || echo "ATTENTION : monokek-identity n'est pas healthy — voir : docker compose logs monokek-identity" >&2
fi

cat <<EOF

Reste à faire à la main :
  1. Supprimer la sauvegarde qui contient l'ANCIENNE clé, une fois le service vérifié :
       shred -u "$BACKUP"
$( [ "$RESTART" -eq 1 ] || echo "  2. Appliquer : docker compose up -d --force-recreate monokek-identity monokek-spring pms-modulith" )
  - Commiter le retrait de private.pem / public.pem et .gitignore (rien n'a été commité).
  - L'ancienne clé reste dans l'HISTORIQUE git (et dans tout clone / fork du dépôt). La rotation
    la rend inutilisable ; pour l'effacer aussi de l'historique, avec git-filter-repo :
       git filter-repo --path private.pem --path public.pem --invert-paths
    puis force-push (réécriture d'historique : à décider et à coordonner avec les autres clones).
  - Vérifier ensuite une connexion depuis un poste, et qu'un ancien jeton reçoit bien un 401.
EOF
