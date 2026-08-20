# Déploiement backend (serveur LAN)

Stack Docker Compose pour héberger `monokek-spring` + `pms-modulith` sur un
même serveur, avec MySQL, MinIO, un reverse proxy Caddy et des sauvegardes
automatiques. Les apps Tauri (postes caisse/réception) tournent sur d'autres
machines du même réseau local et pointent vers ce serveur.

## Côté développeur : publier une nouvelle version

```bash
cp .env.example .env   # une fois, puis renseigner DOCKERHUB_NAMESPACE + vraies valeurs
docker login
./deploy/build-and-push.sh          # tag "latest"
./deploy/build-and-push.sh v1.2.0   # ou un tag précis
```

## Côté client : déployer

Le client n'a besoin ni du code source ni de Maven — seulement Docker et ces
quelques fichiers : `docker-compose.yml`, `.env`, et le dossier `deploy/`
(uniquement `deploy/caddy/` et `deploy/mysql/` — ce sont des fichiers de
config, pas du code).

```bash
docker login   # identifiants fournis avec la licence — images privées
cp .env.example .env
# éditer .env : mots de passe DB/MinIO, LICENSE_SIGNING_KEY,
# MINIO_PUBLIC_ENDPOINT (IP ou nom LAN du serveur), DOCKERHUB_NAMESPACE,
# et le bloc monokek-identity : IDENTITY_ISSUER (adresse LAN de CE serveur,
# via Caddy — ex. http://192.168.1.50:8090), le couple de clés RSA
# IDENTITY_RSA_PRIVATE_KEY_PEM/IDENTITY_RSA_PUBLIC_KEY_PEM (commande openssl
# fournie en commentaire dans .env.example — à générer une seule fois, sinon
# chaque redémarrage invalide tous les tokens en cours), et les trois secrets
# clients IDENTITY_*_CLIENT_SECRET

docker compose pull
docker compose up -d
docker compose ps       # tout doit passer "healthy"
```

Les postes Tauri du LAN doivent être compilés avec
`NEXT_PUBLIC_*_API_URL=http://<IP-ou-nom-du-serveur>` (au lieu de
`localhost`) — c'est un réglage de build côté frontend, pas de cette stack.

## Sauvegardes

Le service `backup` tourne en continu, dump les deux bases MySQL et miroire
le bucket MinIO toutes les `BACKUP_INTERVAL_SECONDS` (24h par défaut), dans
`./deploy/backups/`, avec purge après `BACKUP_RETENTION_DAYS` jours (7 par
défaut). Penser à copier ce dossier hors du serveur périodiquement — un
volume Docker local n'est pas une vraie sauvegarde en cas de panne matérielle.

## TLS

Le Caddyfile sert en HTTP simple pour l'instant (serveur en LAN, sans domaine
public — Let's Encrypt ne peut pas valider un serveur non joignable depuis
Internet). Si ce serveur devient un jour accessible publiquement avec un vrai
domaine, il suffit de remplacer `:80 {` par le domaine dans
`deploy/caddy/Caddyfile` — Caddy gère alors le certificat automatiquement.
