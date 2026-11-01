# Améliorations restantes

Analyse de `install-serveur-nethack.sh` du 2026-11-01, après le commit
`1773e03`. Chaque point indique comment il a été établi (lecture du script,
du code source de dgamelaunch, ou test dans un conteneur jetable) et une
correction possible. Rien de ce qui suit n'est encore corrigé.

## Importants

### 1. Essais de mot de passe illimités dans dgamelaunch

*Établi par la lecture de `dgamelaunch.c` (paxed/dgamelaunch), fonction
`loginprompt`, lignes 1866 à 1890.*

Après un mot de passe faux, dgamelaunch revient aussitôt au menu : pas de
délai, pas de limite d'essais, aucune trace dans un journal. La connexion SSH
a déjà réussi (le compte `nethack` n'a pas de mot de passe), donc les
pénalités de sshd (`PerSourcePenalties`) n'interviennent pas.

- Un robot peut deviner les mots de passe en boucle, y compris celui du
  compte du mode debug (`PSEUDO_WIZARD`).
- yescrypt ralentit chaque essai, mais les comptes encore en DES (inscrits
  avant le correctif des mots de passe) se testent très vite.

**Correction possible** : compléter le correctif embarqué
(`correctif_dgamelaunch`) avec une pause de quelques secondes après un échec,
une fin de session après 3 échecs, et une ligne dans un journal (pseudo,
heure). Le point 2 (limite de sessions par adresse) ralentit aussi les
essais en parallèle.

### 2. Une seule adresse peut occuper toutes les places

*Établi par la lecture du script et de dgamelaunch (`config.l`,
`examples/dgamelaunch.conf`).*

- `MaxStartups` et `PerSourceMaxStartups` ne comptent que les connexions
  pas encore authentifiées ; le compte `nethack` s'authentifie aussitôt.
- `menu_max_idle_time` (menu) et `max_idle_time` (en jeu) sont commentés
  dans l'exemple de configuration, donc absents de `dgamelaunch.conf` :
  aucune session inactive n'est coupée.
- `ClientAliveInterval` n'est pas réglé dans sshd : une connexion morte
  reste ouverte environ 2 heures (keepalive TCP).

Une seule machine peut donc ouvrir `MAX_JOUEURS` (50) sessions, les laisser
au menu, et plus personne ne peut entrer.

**Correction possible** :

- limite de connexions simultanées par adresse source sur le port 22, dans
  le pare-feu nftables du conteneur (`ct count`) : le mode NAT y montre
  l'adresse réelle. Valeur proposée : 3 sessions par adresse, en exemptant
  `127.0.0.1` et `::1` (mode sans NAT et joueurs IPv6, voir point 3) ;
- `menu_max_idle_time` : 15 minutes ;
- `max_idle_time` en jeu : 1 heure (dgamelaunch envoie SIGHUP, NetHack
  sauvegarde la partie) ;
- `ClientAliveInterval 60` et `ClientAliveCountMax 3` dans
  `50-nethack.conf`.

## Moyens

### 3. IPv6 : tous les joueurs arrivent par `::1` — décision en attente

*Établi par des tests dans un conteneur jetable.*

En mode NAT, le proxy IPv6 est un proxy classique : sshd voit tous les
joueurs IPv6 comme `::1`. Ils sont exemptés des pénalités de sshd, partagent
le quota `PerSourceMaxStartups` (10 connexions non authentifiées), et
partageraient aussi la limite par adresse du point 2.

De plus, le proxy écoute sur `[::]` en double pile : il accepte aussi l'IPv4
vers les autres adresses de l'hôte (vérifié avec `127.0.0.1` et
`10.42.86.1`), qui arrive alors par `::1`.

Un vrai NAT IPv6 (adresse réelle visible) demande un changement qui touche
tout l'hôte :

- `ipv6.dhcp.stateful=true` sur `lxdbr0` (concerne tous les conteneurs du
  pont), pour donner une IPv6 fixe au conteneur ;
- ou le module noyau `br_netfilter` chargé sur l'hôte, pour
  `security.ipv6_filtering` sur la carte du conteneur.

Option intermédiaire : écouter sur une IPv6 précise de l'hôte (suivie par
`nethack-adresse`, comme l'IPv4) pour ne plus capter l'IPv4 ; le partage de
`::1` resterait. L'hôte actuel a deux IPv6 publiques, dont une dynamique.

### 4. Restauration : nouvelles connexions non bloquées

*Établi par la lecture de `nethack-restaurer`.*

L'absence de partie est vérifiée au début, mais la sauvegarde de l'état
actuel (`nethack-entretien`) peut prendre du temps : un joueur peut se
connecter et lancer une partie entre-temps. Pendant la mise en place,
`dgldir` est brièvement retiré de sa place : les sessions ouvertes au menu
ne peuvent plus écrire dans la base.

**Correction possible** : refuser temporairement les nouvelles connexions
sur le port 22 (règle nftables ajoutée puis retirée, aussi en cas d'échec),
puis revérifier les parties en cours juste avant la mise en place.

## Mineurs

### 5. Le pare-feu ne couvre que le compte `nhjeu`

Sur une ancienne installation dont le passage à `nhjeu` est reporté (des
parties tournent encore sous `util01`), ces parties gardent l'accès au
réseau. Cas transitoire et rare.

### 6. Pas encore testé en conditions réelles

Les corrections ont été testées séparément dans des conteneurs jetables,
mais le script complet n'a pas été relancé en root depuis. Restent à vérifier
sur le vrai serveur :

- les règles ufw (DHCP et DNS seulement vers l'hôte) ;
- le pare-feu de `nhjeu` avec le vrai dgamelaunch ;
- le test de connexion `ssh nethack@` et les messages de fin côté hôte ;
- `nethack-adresse` lors d'un changement d'IPv4 de l'hôte ;
- le montage des sauvegardes sans `shift=true`.

## Limites connues (documentées dans le README)

- dgamelaunch et NetHack partagent le compte `nhjeu` : une faille de NetHack
  donne accès à la base des comptes et aux fichiers des autres joueurs (mais
  pas au jeu, à `sysconf`, au réseau ni hors du chroot).
- Les hachés DES des comptes inactifs restent faibles : ils ne sont
  remplacés qu'à la reconnexion de chaque joueur.
- Le correctif de dgamelaunch devra être adapté si le code amont change (le
  script refuse alors d'installer).
- Pas de limite de taille du disque du conteneur : sur un pool btrfs, un
  quota atteint bloque toute écriture, y compris celle qui permettrait de le
  relever (constaté avec LXD 6).
