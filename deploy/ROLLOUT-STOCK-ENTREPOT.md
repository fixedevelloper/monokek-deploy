# Stock général (entrepôt) : phase 1

Migration **V29**. À livrer APRÈS la cuisine centrale (V27, V28), dans une version séparée.

## Ce qui change au déploiement
- Le stock d'ingrédients actuel (global) devient le stock de l'**entrepôt général**. Les succursales démarrent à 0 :
  rien ne peut leur être attribué automatiquement. Faire ensuite un **inventaire par lieu** (ajustements).
- Les ventes continuent de déduire ce même stock (donc celui de l'entrepôt) : **aucun changement visible**. Ce n'est pas
  transitoire : c'est la règle retenue (voir « Ingrédients : stock central » plus bas).
- Un retrait manuel supérieur au stock du lieu est maintenant **refusé** (avant : stock négatif possible).
  Une vente, elle, ne bloque jamais : le manque apparaît comme une quantité négative.
- Nouveau rôle `warehouse` (magasinier) : accès limité aux écrans de stock, fournisseurs et achats, sur le lieu de sa succursale.

## Mise en place de l'entrepôt (une fois)
1. Créer la succursale « Entrepôt » (Admin -> Société -> Succursales).
2. L'attacher : `PUT /api/admin/stock-locations/warehouse {"branchId": <id>}` (ADMIN sans succursale).
3. Créer les comptes magasiniers (rôle `warehouse`) rattachés à cette succursale.
Tant que l'étape 2 n'est pas faite, seul le propriétaire (sans succursale) peut agir sur l'entrepôt.

## Marche arrière
`ingredients.stock` / `alert_qty` ne sont plus lus ni écrits par la nouvelle version : l'ancienne version relirait des
valeurs périmées. Avant de relancer l'ancien tag, recopier le stock de l'entrepôt :

```sql
UPDATE ingredients i
  JOIN ingredient_stock s ON s.ingredient_id = i.id
  JOIN stock_locations l ON l.id = s.location_id AND l.kind = 'WAREHOUSE'
SET i.stock = s.qty, i.alert_qty = s.alert_qty;
```
Valable tant que seuls l'entrepôt et les ventes ont bougé. Si des quantités ont été distribuées à des succursales
(phases suivantes), restaurer plutôt la sauvegarde. **Attention : `location_id` est obligatoire sur 3 tables (`stock_movements`, `product_stock_movements`, `purchase_orders`) et l'ancien code ne le renseigne pas : sans le SQL de la section « Marche arrière complète » ci-dessous, ajustements de stock, achats et déduction à la vente échouent.** `warehouse` reste dans `roles`.

## Limites de la phase 1
- Les produits revendables gardent leur stock actuel (par ligne produit) : achats de produits inchangés.
- Pas encore d'écrans Tauri dédiés (sélecteur de lieu, transferts) : phase 6. Les écrans Stock/Fournisseurs actuels
  fonctionnent ; pour les ingrédients ils affichent le **stock central** à tous les rôles de stock.
- Pas de transferts entrepôt -> succursale (phase 4).

---

# Catalogue commun : phase 2 (migration V30)

À livrer avec V29, ou juste après. **Aucun changement visible à la mise en service** : V30 donne à chaque catégorie et à
chaque produit existant exactement une ligne (sa succursale d'origine, sa station) ; tout se comporte comme avant.

## Ce qui change
- Une catégorie / un produit n'est plus lié à UNE succursale par sa catégorie : la liste des succursales qui l'utilisent est
  explicite (`category_branch_settings`, `product_branch`). La station de cuisine est un choix **par succursale**.
- Le POS, les écrans d'administration et la prise de commande lisent ces tables. Un produit **sans ligne** (créé par un chemin
  qui ignore le nouveau modèle) reste vendu dans la succursale de sa catégorie, comme avant : rien ne disparaît de la caisse.
- Partager un produit / une catégorie avec une autre succursale, lui donner un **prix local** ou sa **propre station** : API
  réservée au propriétaire (ADMIN sans succursale) sous `/api/admin/categories/{id}/branches/{branchId}` et
  `/api/admin/products/{id}/branches/{branchId}` (GET, PUT, DELETE). Pas encore d'écran dédié (phase 6).
- Un manager de succursale ne peut plus modifier / supprimer un produit ou une catégorie **vendus par plusieurs succursales**
  (réservé au propriétaire). Il garde la main sur ce que seule sa succursale utilise, et choisit toujours **sa** station.
- ~~Garde-fou temporaire sur les produits à stock suivi~~ : levé par V31 (stock produit par lieu, voir ci-dessous). Ce garde-fou
  ne protégeait d'ailleurs que les produits dont `trackStock` est vrai, alors que l'écran d'administration ne renseigne jamais
  ce drapeau : la déduction à la vente se fait sur `type = storable`.

## Marche arrière
Les colonnes historiques sont conservées et tenues à jour pour la succursale d'origine (`categories.branch_id`,
`categories.kitchen_station_id`), donc l'ancienne version relit des données justes pour tout ce qui n'a pas été partagé.
En revanche, après un retour arrière : les **prix locaux sont ignorés** (prix de base), les produits/catégories **partagés avec une
autre succursale disparaissent de celle-ci**, et la **station propre à une succursale** non d'origine est perdue. Si le partage a
été utilisé, restaurer plutôt la sauvegarde. Les tables `category_branch_settings` / `product_branch` restent sans effet sur
l'ancien code.

## Vérifié
V30 appliquée sur MySQL 8.4 avec des catégories et produits préexistants : une ligne par catégorie et par produit, même succursale,
même station, aucun orphelin, validation Hibernate OK.


---

# Stock produit par lieu : phase 3 (migration V31)

À livrer avec V29/V30. **Aucun changement de chiffre à la mise en service** : le stock actuel de chaque produit devient le stock du
lieu de sa succursale (même quantité, même seuil d'alerte) ; l'historique des mouvements est rattaché à ce lieu.

## Ce qui change
- Le stock d'un produit se tient **par lieu** (`product_stock`) : chaque succursale a son compte, l'entrepôt aussi (il démarre à 0 pour
  les produits). `products.stock_count` / `alert_stock` ne sont plus lus ni écrits.
- Une **vente** décompte le stock de la **succursale qui l'a faite** (celle de la commande), jamais celui d'une autre. Elle ne bloque
  jamais : elle plafonne à 0 et le dit dans le motif du mouvement.
- Un **achat de produit** est reçu au lieu du bon d'achat : l'**entrepôt** par défaut (ce stock n'est celui d'aucune succursale tant qu'il
  n'est pas distribué : transferts en phase 4).
- **Ajuster le stock** : un manager agit sur le lieu de sa succursale. Le propriétaire précise `?locationId=` (une succursale ou
  l'entrepôt) ; sans précision, c'est la succursale du produit s'il n'est vendu que dans une seule, sinon la requête est refusée (400).
- Le POS et l'administration voient le stock **de leur succursale** (`stockCount` / `alertStock` du produit). La vue du propriétaire
  sans succursale affiche le **total** de tous les lieux.
- Le seuil d'alerte est un réglage **de la succursale** : un manager peut le modifier même sur un produit partagé.
- Un produit partagé avec une nouvelle succursale y démarre à **0** : avec le contrôle de stock du POS, il ne s'y vend pas tant qu'elle n'a
  pas reçu de stock (entrée manuelle par le propriétaire, ou transfert en phase 4).

## Marche arrière
Avant de relancer l'ancienne version, recopier le stock de la succursale d'origine de chaque produit :

```sql
UPDATE products p
  JOIN categories c ON c.id = p.category_id
  JOIN stock_locations l ON l.branch_id = c.branch_id AND l.kind = 'BRANCH'
  JOIN product_stock s ON s.product_id = p.id AND s.location_id = l.id
SET p.stock_count = s.qty, p.alert_stock = s.alert_qty;
```
Le stock d'un produit dans une autre succursale que la sienne, ou à l'entrepôt, est perdu par ce retour arrière : s'il a été utilisé,
restaurer la sauvegarde.

## Limites
- Les comptes magasinier (`warehouse`) n'ont pas encore accès aux écrans de produits : le stock **produits** de l'entrepôt est géré par
  le propriétaire (`?locationId=`) jusqu'aux transferts et à l'écran dédié.
- Pas encore de transfert entrepôt -> succursale (phase 4).

## Vérifié
V31 appliquée sur MySQL 8.4 avec des produits, des comptes et un historique préexistants : stock et seuil repris à l'identique dans le
lieu de la bonne succursale, locations manquantes créées, historique rattaché, aucun produit sans ligne, validation Hibernate OK.

---

# Transferts entrepôt -> succursale : phase 4 (migration V32)

À livrer avec V29-V31. **Rien ne change tant qu'aucun transfert n'est créé.** Le stock **de produits** des succursales est rempli par ces
transferts (ou par une entrée manuelle du propriétaire). **Seuls les produits se transfèrent** : les ingrédients restent au stock central.

## Le flux
`REQUESTED -> APPROVED -> SHIPPED -> RECEIVED` (ou `CANCELLED`). Le stock ne bouge que deux fois :
- à l'**expédition** il sort de l'entrepôt (refusé s'il n'y en a pas assez ; tout ou rien) ;
- à la **réception** il entre dans la succursale, pour ce qu'elle a **réellement compté**. Entre les deux il est « en transit ».
Un écart (compté < expédié) est enregistré sur la ligne, le transfert est marqué et l'événement est tracé dans le journal d'activité.
Une succursale ne peut pas compter **plus** que ce qui a été expédié.

## Qui peut quoi
| Acteur | Peut |
|---|---|
| Compte d'une succursale (manager avec `manage_stock`) | **demander** pour SA succursale, **confirmer la réception** de SES transferts, annuler une demande en cours |
| Magasinier (rôle `warehouse`, compte de la succursale-entrepôt) | créer un transfert (déjà approuvé), approuver, **expédier**, annuler avant expédition |
| Propriétaire (ADMIN sans succursale) | tout, et **seul** à pouvoir annuler un transfert déjà expédié (le stock expédié retourne à l'entrepôt, motif obligatoire) |
Un transfert d'une autre succursale est invisible (404). L'entrepôt ne confirme jamais sa propre réception.
Seuil d'approbation optionnel : `app.inventory.transfer-owner-approval-qty` (0 = désactivé) ; au-delà, seul le propriétaire approuve.

## API (`/api/admin/...`)
`GET stock-transfers[?status=]`, `GET stock-transfers/{id}`, `POST stock-transfers` (lignes : un ingrédient OU un produit),
`POST stock-transfers/{id}/approve | ship | receive | cancel` (`ship` et `receive` acceptent des quantités par ligne).
`GET stock-items[?locationId=]` : les ingrédients (stock central) et les produits d'un lieu avec leur quantité (de quoi construire un transfert). Le rôle `warehouse`
atteint ces routes (et le stock, les fournisseurs, les achats) mais **pas** le reste de l'administration.
Les parties sont prévenues en direct (`stock-transfer.updated`) : l'entrepôt d'une demande, la succursale d'une expédition.

## Marche arrière
La table `stock_transfers` et ses lignes n'ont aucun effet sur l'ancien code. Les quantités déjà déplacées restent : l'ancienne version
ne connaît pas les lieux, voir les sections précédentes. Un transfert **expédié et non reçu** au moment du retour arrière est du stock sorti
de l'entrepôt qui n'est nulle part : le recevoir ou l'annuler (propriétaire) AVANT de revenir en arrière.

## Limites
- Pas d'écran dédié (phase 6) : les appels d'API ci-dessus.
- Transferts **entrepôt -> succursale uniquement** (pas entre succursales).
- Les produits transférés doivent être « storable » et en vente dans la succursale destinataire, en quantités entières.
- Une ligne d'ingrédient est refusée à la création (voir ci-dessous).

## Vérifié
V32 sur MySQL 8.4 (32 migrations d'un coup, validation Hibernate) ; contraintes essayées à la main : statut inconnu, ligne à la fois
ingrédient et produit, ligne vide, quantité nulle, lieu inexistant -> toutes refusées par la base.


---

# Ingrédients : stock central (phase 5, aucune migration)

**Décision** : la déduction des ingrédients à la vente reste faite sur le **stock central** (l'entrepôt), quelle que soit la succursale qui
vend et quelle que soit la cuisine (celle de la succursale ou la cuisine centrale) qui prépare. Les ingrédients ne sont **pas distribués**
aux succursales ; seuls les produits revendables le sont.

## Pourquoi c'est appliqué partout, et pas seulement « laissé tel quel »
Si un ingrédient pouvait être transféré à une succursale, il sortirait du stock central à l'expédition, puis chaque vente le retirerait
**une deuxième fois** du central, tandis que la copie de la succursale ne baisserait jamais. La règle est donc imposée au même endroit que
tout mouvement d'ingrédient : **aucune quantité d'ingrédient n'existe ailleurs qu'à l'entrepôt**.

## Ce qui change par rapport aux phases 1 à 4
- Un mouvement d'ingrédient (ajustement, achat, vente, transfert) sur un lieu autre que l'entrepôt est **refusé** (400, message explicite).
- Un **transfert** ne peut plus contenir de ligne d'ingrédient (refusé à la création).
- Les écrans de stock d'ingrédients affichent à **tous** les rôles de stock le **stock central** (comme avant les phases 1 à 4, où le stock était
  global). Un manager de succursale **consulte** ce stock mais ne le **modifie plus** : ajustement, achat d'ingrédients et stock initial relèvent
  du propriétaire et des magasiniers. Il peut toujours créer la **définition** d'un ingrédient (sans quantité).
- La cuisine centrale (hub) n'a pas de stock d'ingrédients propre : ses préparations décomptent le stock central.
- L'historique des mouvements d'ingrédients reste visible du propriétaire et de l'entrepôt ; un manager de succursale ne voit que les
  mouvements de son lieu (donc aucun pour les ingrédients).

## Si vous changez d'avis plus tard
Distribuer les ingrédients aux succursales demanderait de faire décompter les ventes sur le stock de la succursale (ou du hub qui prépare) et de
lever la règle ci-dessus : ce n'est pas fait, et les deux doivent changer ensemble, sinon les consommations seraient comptées deux fois.

## Vérifié
Tests : un mouvement d'ingrédient hors entrepôt est refusé quel que soit l'appelant (personne, achat, vente), un transfert d'ingrédient est refusé
et le stock central reste intact, un manager lit le stock central et ne peut pas l'ajuster. Pas de migration : rien à appliquer en base.

---

# Écrans d'administration : phase 6 (application Tauri)

Aucune migration. Il faut **reconstruire et redéployer l'application Tauri** pour que les terminaux voient les nouveaux écrans. Côté
serveur, un ajout : `GET /api/admin/stock-locations/destinations` et `toBranchId` à la création d'un transfert (voir ci-dessous).

## Mise en place de l'entrepôt (une fois, propriétaire)
1. **Organisation** : créer la succursale « Entrepôt ».
2. **Réglages -> Stations -> carte « Entrepôt général »** : la rattacher (seules les succursales sans stock propre sont proposées).
3. **Personnel** : donner le rôle `warehouse` aux comptes des magasiniers, rattachés à cette succursale.
4. Un magasinier qui se connecte arrive sur **Transferts** ; il n'atteint que Transferts, Inventaire et Fournisseurs (le reste lui est refusé par le serveur,
   et l'application le ramène sur ses pages).

## Les écrans
- **Admin -> Transferts de stock** (`/admin/transfers`) : liste filtrable (à traiter / en route / terminés), détail et actions selon l'état et le profil.
  - Succursale : « Demander du stock » (bouton **Suggérer** : remonte au double du seuil d'alerte les produits sous leur seuil), confirmation de réception
    en saisissant ce qui est **réellement arrivé** ; l'écart est affiché avant de confirmer et signalé au propriétaire.
  - Entrepôt / propriétaire : « Nouvel envoi » (choix de la succursale), approuver, expédier avec les quantités réellement parties, annuler.
  - Propriétaire seul : « Reprendre l'envoi » (stock remis à l'entrepôt, motif obligatoire).
  - Mise à jour **en direct** quand l'autre partie agit (`stock-transfer.updated`).
- **Admin -> Inventaire** : deux onglets. *Ingrédients · stock central* (lecture seule pour un compte de succursale) et *Produits · par lieu* :
  le propriétaire choisit le lieu, ajuste (entrée / sortie / comptage) et dispose d'une **vue consolidée** (chaque lieu en colonne, total, rouge sous le seuil).
  Un magasinier consulte l'entrepôt ; il le fait bouger par les achats et les transferts.
- **Admin -> Menu** : le bouton de stock d'un produit agit sur le lieu de la succursale de l'onglet. Pour le **propriétaire** : un bouton « Succursales »
  par produit (en vente, activé, **prix local**) et par catégorie (succursales qui l'utilisent, **station de cuisine de chacune**, y compris celle du hub).
- **Réglages** : carte « Entrepôt général » (ci-dessus) et carte « Cuisine centrale » (liens succursale -> hub).

## Vérifié
- Compilation, **build de production** de l'application et typage : sans erreur.
- **Test de bout en bout dans un vrai navigateur** (application exportée + faux serveur d'API qui enregistre les requêtes), 15 vérifications :
  compte de succursale (liste, pas d'action fournisseur, écart signalé puis réception envoyant les quantités comptées, demande suggérée sans destination),
  magasinier (pas de confirmation de réception, expédition partielle, envoi par identifiant de succursale, accès limité hors `/admin/menu`),
  propriétaire (stock par lieu, vue consolidée additionnée, ajustement envoyé au bon lieu).

## Non couvert par ce test (à regarder à l'usage)
Les boîtes « Succursales » du menu (produit et catégorie), la carte « Entrepôt général » et l'ajustement de stock depuis une carte produit du menu :
compilés et construits, mais pas exercés dans le navigateur. Les messages d'erreur du serveur sont affichés tels quels.

---

# Fusion des produits en double : phase 7, et ordre de déploiement de l'ensemble

## Ce qui change
- **Migration V33** (additive) : `products.merged_into_id`, `products.merged_at` (+ index sur `sku`). L'ancienne version du serveur les ignore.
- **Menu -> « Doublons »** (propriétaire uniquement, le bouton n'apparaît que s'il existe des doublons). API : `GET /api/admin/catalog/duplicates`,
  `POST .../preview` (simulation, n'écrit rien), `POST .../merge`.
- Les doublons sont **proposés par SKU** (sans tenir compte de la casse ni des espaces) et **seuls des produits de même SKU** peuvent être fusionnés.
  Le produit proposé à garder est celui qui a le plus d'historique.

## Ce que la fusion fait (le produit conservé reprend tout)
| Donnée | Traitement |
|---|---|
| Lignes de commande, d'achat, mouvements de stock, transferts clôturés | rattachés au produit conservé (les rapports gardent leurs totaux) |
| Stock | additionné **par lieu** (10 + 7 = 17 au même endroit) |
| Succursales | le produit conservé est vendu partout où le doublon l'était ; si son prix différait, il devient le **prix local** de cette succursale (aucune caisse ne voit un prix changer) |
| Variantes | rapprochées par nom, sinon déplacées |
| Groupes d'options | ajoutés s'ils manquent |
| Recette | celle du produit conservé gagne ; celle du doublon n'est reprise que si le produit conservé n'en a pas (avertissement si elles diffèrent) |
| Le doublon | masqué (pas supprimé) et il **mémorise son remplaçant** : une caisse qui a encore l'ancien identifiant (menu en cache, file hors ligne) continue de vendre, sur le produit conservé |

## La simulation bloque la fusion si
- les SKU diffèrent, ou les types (stockable / consommable / service) ;
- un **transfert de stock est en cours** (demandé, approuvé ou en route) sur le doublon : attendre qu'il soit reçu ou annulé ;
- la **catégorie du produit conservé n'est pas utilisée par une succursale** où le doublon se vendait : sans station de cuisine pour cette succursale,
  ses commandes n'iraient à aucune cuisine. Partager d'abord la catégorie (Menu -> catégorie -> Succursales, avec sa station), puis relancer la simulation.

Les avertissements (noms, prix, recettes, activation qui diffèrent) n'empêchent pas la fusion : la valeur du produit conservé est gardée.

## Marche arrière
**Une fusion n'est pas réversible depuis l'application.** Avant chaque lot : **sauvegarde de la base** (celle du §0 de ce document), puis un SKU à la fois pour
le premier. Revenir en arrière = restaurer la sauvegarde. Revenir à l'ancien code seul est sans danger : les colonnes de V33 sont ignorées, et les doublons
déjà fusionnés restent masqués (`deleted_at`), comme n'importe quel produit supprimé.

## Limites
- **Les catégories ne sont pas fusionnées** : un produit conservé apparaît dans sa propre catégorie, y compris dans les succursales où le doublon était rangé
  ailleurs. Deux catégories « Boissons » (une par succursale) coexisteront donc encore ; à regrouper à la main si besoin.
- La fusion se fait entre produits **de même SKU** : des doublons sans SKU, ou avec des SKU différents, ne sont pas proposés.
- Ces écrans ont été vus dans un navigateur contre un **faux serveur** ; la logique serveur, elle, est testée sur H2 **et** sur MySQL 8.4 (migrations V1 à V33).

## Vérifié
- 233 tests serveur ; 3 mutations volontaires du code détectées (rattachement du site d'origine, chaînage des fusions, addition des stocks).
- **MySQL 8.4 réel** : les 11 tests de fusion passent après Flyway V1 -> V33 et validation Hibernate. Ce passage a trouvé un vrai défaut que H2 cachait
  (un `UPDATE` dont la sous-requête lit la même table est refusé par MySQL, erreur 1093) : corrigé. Les clés étrangères étaient désactivées pendant ce
  passage (les tests utilisent des identifiants de succursale fictifs) : leur comportement n'a donc pas été éprouvé sur MySQL.
- **Navigateur** : 10 vérifications (liste des groupes, produit à garder proposé, aucune fusion sans simulation, simulation détaillée, changement de choix
  qui l'efface, requête de fusion exacte, blocage affiché sans bouton « Fusionner »).

---

# Ordre de déploiement conseillé pour l'ensemble (migrations V29 à V33)

1. **Sauvegarde** de la base ; noter le tag en production ; construire sous un **nouveau tag** (par exemple `stock-entrepot-1`) : serveur + application Tauri.
2. **Serveur d'abord** : au démarrage, Flyway applique V29 à V33 (`now at version v33` attendu). Rien ne change pour les caisses : chaque produit reste dans sa
   succursale (« pas de ligne = succursale d'origine »), les ventes déduisent le stock de la succursale vendeuse.
3. **Vérifier un service complet** : une vente décrémente le stock de **sa** succursale ; les achats arrivent à l'entrepôt ; aucune commande refusée.
4. **Entrepôt** : le créer et le rattacher (voir « Mise en place de l'entrepôt »), créer les comptes magasinier.
5. **Une succursale pilote** : premiers transferts entrepôt -> succursale, avec réception et écart.
6. **Catalogue commun** : partager catégories puis produits entre succursales (le serveur impose l'ordre).
7. **Doublons en dernier**, après au moins un service complet sur le catalogue commun : sauvegarde, un SKU, vérification en caisse, puis le reste.

---

# Image de sauvegarde (`monokek-backup`) : réparée

- **Problème** : l'image ne se reconstruisait plus (MinIO a retiré `mc` partout : Docker Hub, Quay, téléchargement direct « 410 Gone »). Les tags `cuisine-centrale-1` et
  `stock-entrepot-1` de `monokek-backup` sont des **re-étiquetages d'un ancien build** : ils visent un hôte `minio` qui n'existe plus et **plantent en boucle**
  avec le compose actuel (SeaweedFS). Ces deux tags ne sont donc pas utilisables.
- **Correction** : `deploy/backup/Dockerfile` et `backup.sh` utilisent `rclone` 1.68.2 (version fixée) à la place de `mc`. Les variables d'environnement sont inchangées.
  Image publiée : `monokek-backup:stock-entrepot-2`. `build-and-push.sh` la reconstruit de nouveau normalement.
- **Vérifié** (conteneurs jetables) : les deux bases sont sauvegardées et un dump **se restaure** (mêmes lignes), le contenu du stockage est copié, le conteneur ne plante plus.
- **À savoir** : la copie du stockage reste un simple avertissement si elle échoue (`WARN: storage mirror failed`) ; le conteneur continue. Surveillez cette ligne dans ses logs.
- **Au déploiement** : le compose utilise un seul `IMAGE_TAG`. Mettre `monokek-backup` en `stock-entrepot-2` (ou re-étiqueter spring et pms en `-2` pour tout aligner).
  Après la mise à jour, **vérifier qu'une sauvegarde est bien produite** (`deploy/backups/mysql/*.sql.gz` non vide) avant de s'y fier.


---

# Marche arrière complète : répétée sur une pile de test

Deux voies, **toutes deux essayées** (base de départ `cuisine-centrale-1` avec des données, mise à niveau vers `stock-entrepot-2`, puis retour).

## Voie A : restaurer la sauvegarde (la plus sûre, perd ce qui s'est passé depuis la mise à jour)
1. Arrêter spring, identity et pms. 2. `DROP DATABASE` puis `CREATE DATABASE` de la base `monokek`, y recharger le dump du §0 (`zcat monokek-….sql.gz | mysql monokek`).
3. `IMAGE_TAG` sur l'ancien tag, relancer. **Résultat vérifié** : Flyway indique « Schema is up to date », les 10 compteurs de contrôle sont identiques à ceux d'avant
   (produits, commandes, paiements et leur total, tickets, comptes, stocks), les tables du nouveau modèle ont disparu, les utilisateurs se reconnectent.
   Les ventes faites depuis la mise à jour sont perdues avec le reste.

## Voie B : garder la base, ne revenir qu'au code (garde les ventes faites depuis, mais exige ce SQL)
L'ancien serveur **démarre** sur la base migrée (Flyway ignore les migrations « futures »), **mais sans ce SQL le stock ne fonctionne plus** : `Field 'location_id' doesn't have a default value`
(ajustement de stock 500, achat 500, déduction à la vente perdue en silence). Avec ce SQL, tout repasse (vente, encaissement, ajustements, achats : vérifié) :
```sql
ALTER TABLE stock_movements         MODIFY COLUMN location_id BIGINT UNSIGNED NULL;
ALTER TABLE product_stock_movements MODIFY COLUMN location_id BIGINT UNSIGNED NULL;
ALTER TABLE purchase_orders         MODIFY COLUMN location_id BIGINT UNSIGNED NULL;
-- puis les deux recopies de stock des sections « Marche arrière » ci-dessus (ingrédients depuis l'entrepôt, produits depuis la succursale d'origine)
```
Limites : prix locaux ignorés, produits/catégories partagés disparaissent des autres succursales, stock d'une succursale autre que celle d'origine perdu (voir plus haut).
Si le partage, les transferts ou la fusion ont servi, **préférer la voie A**.

## À savoir
- **identity** : revenir à l'ancienne image réintroduit le défaut du rafraîchissement de session. Garder `monokek-identity:stock-entrepot-2` même après un retour de spring.
- Au passage `stock-entrepot-2` : les sessions déjà rafraîchies une fois **sous l'ancien code** ne peuvent plus l'être (401) : leurs utilisateurs se reconnectent une fois.
  Celles jamais rafraîchies continuent de fonctionner.
- Le registre d'événements de Spring Modulith a eu un **deadlock MySQL intermittent** (vu sous l'ancien code aussi : préexistant) : une ligne reste « non terminée » dans `EVENT_PUBLICATION`.
  Sans effet tant que la republication au redémarrage reste désactivée (c'est le cas) ; ne pas l'activer sans y avoir regardé.
