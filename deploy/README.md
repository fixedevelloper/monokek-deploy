# Déploiement backend (serveur LAN)

Stack Docker Compose pour héberger `monokek-spring` + `pms-modulith` sur un
même serveur, avec MySQL, SeaweedFS (stockage S3), un reverse proxy Caddy et des sauvegardes
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
# éditer .env : mots de passe DB/stockage (MINIO_*), LICENSE_PUBLIC_KEY (clé publique du vendeur),
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
le bucket de stockage toutes les `BACKUP_INTERVAL_SECONDS` (24h par défaut), dans
`./deploy/backups/`, avec purge après `BACKUP_RETENTION_DAYS` jours (7 par
défaut). Penser à copier ce dossier hors du serveur périodiquement — un
volume Docker local n'est pas une vraie sauvegarde en cas de panne matérielle.

## Rotation de la clé de signature des jetons

La paire RSA d'`IDENTITY_RSA_*` signe tous les jetons (caisses, PMS). Quiconque détient la clé
privée peut se fabriquer un jeton administrateur : à renouveler après toute fuite, et ne jamais
la commiter (`*.pem` est ignoré par git).

```bash
./deploy/rotate-jwt-key.sh --restart
```

Le script génère une nouvelle paire, la écrit dans `.env` (sauvegarde `.env.bak-*` conservée : à
supprimer avec `shred -u` une fois le service vérifié), retire `private.pem`/`public.pem` de git,
puis recrée identity, spring et pms (cela vide aussi leurs caches de clés publiques, sinon
l'ancienne clé resterait acceptée quelques minutes). Tous les utilisateurs doivent se reconnecter.
`--help` détaille les options.

## TLS

Le serveur est en HTTPS (port **8443**) avec l'autorité interne de Caddy (`tls internal`) : un
serveur LAN joignable par IP ne peut pas obtenir de certificat d'une autorité publique. Le port
**8090** (HTTP) ne sert plus que `/ca.crt` (le certificat racine, public) et `/api/ping`, et
redirige tout le reste vers HTTPS.

Réglages dans `.env` : `CADDY_HOST` (IP ou nom LAN, il entre dans le certificat — une valeur
erronée fait rejeter le certificat par tous les postes), `CADDY_HTTPS_URL`
(`https://<CADDY_HOST>:8443`), et `IDENTITY_ISSUER` à la **même** URL HTTPS : l'émetteur des jetons
change, donc tous les utilisateurs sont déconnectés une fois.

### Faire approuver le certificat par chaque poste (une fois)

Le certificat racine est créé au premier démarrage de Caddy. Sur chaque machine :

```bash
curl -o monokek-ca.crt http://<CADDY_HOST>:8090/ca.crt
```

puis l'installer comme autorité de confiance :
- **Windows** : double-clic > Installer le certificat > Ordinateur local > « Autorités de
  certification racines de confiance ».
- **Linux (Debian/Ubuntu)** : copier dans `/usr/local/share/ca-certificates/` puis
  `sudo update-ca-certificates`.
- **Android** : Paramètres > Sécurité > Installer un certificat > Certificat CA. Attention : l'app
  Flutter n'approuve pas les certificats installés par l'utilisateur tant qu'un
  `networkSecurityConfig` ne le demande pas (voir `monokek-flutter/android`).

Vérifiez l'empreinte affichée (`openssl x509 -in monokek-ca.crt -noout -fingerprint -sha256`) avec
celle du serveur avant d'accepter : le téléchargement initial se fait en HTTP.

Les apps doivent être reconstruites avec `NEXT_PUBLIC_API_URL=https://<CADDY_HOST>:8443` (Tauri) et
`API_URL` en https (Flutter). Le volume `caddy-data` contient la clé de l'autorité : ne le supprimez
pas (cela obligerait à réinstaller le certificat racine sur tous les postes) et incluez-le dans
vos sauvegardes.

Si le serveur devient accessible publiquement avec un vrai domaine, remplacez simplement
`CADDY_HOST` par ce domaine et retirez `tls internal` : Caddy obtiendra un certificat public.
