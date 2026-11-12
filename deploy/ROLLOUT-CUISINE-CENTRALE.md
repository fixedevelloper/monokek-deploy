# Déploiement progressif : cuisine centrale (hub) + correctifs de session

Ce qui est livré : `monokek-identity` (grace period du refresh token, journal des `invalid_grant`),
`monokek-spring` (migrations V27 et V28, cuisine centrale, retour de la cuisine, rattrapage, alerte d'attente),
et les clients Flutter / Tauri.

**Principe : rien ne change pour une succursale tant qu'on ne lui a pas créé de lien avec un hub.**
Le déploiement du code et l'activation de la cuisine centrale sont deux étapes séparées.

## 0. Avant de commencer

- [ ] **Sauvegarde de la base** (le service `monokek-backup` en fait une chaque jour ; en lancer une à la main
      juste avant, et vérifier que le fichier existe et n'est pas vide). C'est la seule vraie marche arrière, voir §5.
- [ ] Choisir un **tag explicite** (par exemple `cuisine-centrale-1`) et ne pas déployer en `latest` : il faut pouvoir
      revenir au tag précédent. Noter le tag actuellement en production (`IMAGE_TAG` dans le `.env` du serveur).
- [ ] Vérifier dans le `.env` du serveur que `IDENTITY_RSA_PRIVATE_KEY_PEM` / `IDENTITY_RSA_PUBLIC_KEY_PEM`
      sont renseignées (sinon chaque redémarrage de `monokek-identity` invalide toutes les sessions)
      et que `POS_CLIENT_SECRET` est dans les builds Flutter / Tauri.
- [ ] Choisir **une succursale pilote** et une **heure creuse**.

## 1. Publier les images (poste du développeur)

```bash
docker login
./deploy/build-and-push.sh cuisine-centrale-1     # construit et pousse identity, spring, pms, backup
```

`monokek-identity` fait maintenant partie du script (il n'y était pas).

## 2. Mettre à jour le serveur

```bash
# dans le .env du serveur : IMAGE_TAG=cuisine-centrale-1
docker compose pull
docker compose up -d monokek-spring            # applique V27 et V28 au démarrage (Flyway)
docker compose logs -f monokek-spring | grep -E "Successfully applied|Started MonokekApplication|ERROR"
docker compose up -d monokek-identity          # après spring : identity dépend de ses tables
docker compose ps                              # tout doit passer "healthy"
```

Attendu dans les logs de spring : `now at version v28`. Si Flyway ou la validation Hibernate échoue, **ne pas insister** :
restaurer le tag précédent (voir §5).

Les sessions existantes ne sont pas coupées : le redémarrage de `monokek-identity` garde les clés RSA fixes,
et les refresh tokens sont en base.

## 3. Vérifications immédiates (cuisine centrale encore INACTIVE)

Le comportement doit être **identique à avant** pour toutes les succursales :

- [ ] Un serveur envoie une commande : le ticket arrive à l'écran cuisine de **sa** succursale, le ticket s'imprime.
- [ ] La cuisine passe le ticket « prêt » : le serveur de la commande reçoit « prête à servir », la caisse aussi.
- [ ] La caisse encaisse : le paiement est enregistré dans la session de caisse de la succursale.
- [ ] Un envoi répété (couper le Wi-Fi au moment d'envoyer, puis réessayer) ne crée pas de seconde manche.
- [ ] Journal d'activité : les changements de statut de ticket apparaissent.
- [ ] Logs de `monokek-identity` : chercher `invalid_grant:` (voir §6).

## 4. Activer la cuisine centrale pour la succursale pilote

Préalables côté données. Tout se fait dans l'app d'administration (Tauri) avec un compte **ADMIN sans succursale**
(les appels d'API équivalents restent possibles, voir plus bas) :

1. Le hub existe comme **succursale** avec ses **stations de cuisine**, ses **comptes cuisine** (rôle `kitchen`,
   rattachés à la succursale du hub) et son **imprimante** (emplacement `kitchen`, ou `bar`... selon la station).
2. Créer le lien succursale pilote -> hub : **Réglages -> onglet Stations -> carte « Cuisine centrale »**
   (« Copie du ticket à l'origine » désactivée par défaut). Équivalent API :

```bash
curl -X POST "$API/api/admin/kitchen-hub-links" \
     -H "Authorization: Bearer $ADMIN_TOKEN" -H "Content-Type: application/json" \
     -d '{"branchId": <ID_PILOTE>, "hubBranchId": <ID_HUB>, "printOriginCopy": false}'
# lister : GET /api/admin/kitchen-hub-links    activer la copie : PATCH /api/admin/kitchen-hub-links/<id> {"printOriginCopy": true}
```

3. Pointer les catégories concernées de la succursale pilote vers une station du hub : **Menu -> catégorie -> Station
   cuisine**. Le sélecteur propose les stations de la succursale et celles de son hub (suffixées du nom du hub) ;
   le serveur refuse de toute façon une station qui n'est ni de la succursale ni d'un hub lié.

Vérifications du pilote :

- [ ] La commande envoyée par la succursale pilote apparaît à l'écran du hub avec le **nom de la succursale d'origine**.
- [ ] Le ticket s'imprime **au hub** (et à l'origine si la copie est activée).
- [ ] Quand le hub passe le ticket « prêt », le **serveur qui a envoyé** et la **caisse de la succursale pilote** sont notifiés ;
      un autre serveur de la même succursale ne reçoit rien.
- [ ] L'encaissement se fait **à la caisse de la succursale pilote** ; le hub n'a aucun accès aux montants.
- [ ] Hub éteint 10+ minutes : l'alerte « en attente de la cuisine » arrive chez le serveur et à la caisse.
- [ ] Couper puis rétablir le Wi-Fi d'une tablette : elle récupère les « prêt » manqués à la reconnexion.

Laisser tourner **au moins un service complet** avant d'ajouter d'autres succursales (un lien par succursale).

## 5. Marche arrière

**Désactiver la cuisine centrale (sans toucher au code) :** supprimer le lien (`DELETE /api/admin/kitchen-hub-links/<id>`)
et remettre les catégories sur les stations de la succursale. Les tickets déjà créés au hub restent visibles au hub.

**Revenir à l'ancienne version du code :** les migrations V27 et V28 sont additives, MAIS `kitchen_tickets.origin_branch_id`
est `NOT NULL` : l'ancienne version de `monokek-spring` ne la renseigne pas, donc **la création de tickets échouerait**.
Avant de relancer l'ancien tag, exécuter :

```sql
ALTER TABLE kitchen_tickets MODIFY COLUMN origin_branch_id BIGINT UNSIGNED NULL;
```

Les autres colonnes ajoutées (`order_rounds.created_by`, `client_request_id`, `kitchen_hub_links`, `print_origin_copy`,
`delay_alerted_at`) sont nullables ou avec valeur par défaut et ne gênent pas l'ancien code. Flyway ignore par défaut
les migrations « futures » déjà appliquées, donc l'ancienne image devrait démarrer ; **à vérifier sur un environnement
de test avant la production** (c'est la seule hypothèse de ce plan que je n'ai pas pu confirmer).
En cas de doute ou de données corrompues : restaurer la sauvegarde du §0 avec l'ancien tag.

`monokek-identity` peut revenir en arrière seul, sans migration : la grace period est en mémoire.

## 6. Suivi après mise en service

- **Logs de `monokek-identity`** : `invalid_grant:` (une ligne par refus de refresh, avec type de grant, empreinte du
  token, IP, User-Agent) et `fenetre de grace` (un refresh rattrapé grâce à la grace period = une réponse perdue
  qui aurait déconnecté l'utilisateur). Des `invalid_grant` sans `fenetre de grace` correspondante indiquent une autre
  cause (session expirée ou révoquée).
- **Logs de `monokek-spring`** : `Ticket refuse: station ... ne sert pas la branche ...` = une catégorie pointe vers une
  station qu'elle ne peut pas utiliser (données à corriger) ; `ticket(s) de cuisine en attente ... alerte envoyee`.
- Réglages : `app.identity.refresh-grace-seconds` (60), `app.kitchen.delay-alert-minutes` (10, 0 = désactivé).

## 7. Limites connues au moment du déploiement

- Les écrans d'administration sont dans l'app Tauri uniquement (pas dans Flutter). La carte « Cuisine centrale » n'est
  utilisable que par un ADMIN sans succursale assignée (les autres reçoivent un message explicatif).
- Registre SSE, alerte d'attente et grace period sont **en mémoire, mono-instance**. Ne pas lancer deux
  instances du même service sans bus partagé.
- Le rattrapage des événements manqués n'existe que dans l'app Flutter, pas dans Tauri.
- Le remplissage de `origin_branch_id` sur les tickets existants (V27) a été testé sur une base vide uniquement.
