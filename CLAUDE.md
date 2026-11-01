# CLAUDE.md

Consignes pour Claude Code dans ce dépôt.

## Projet

`install-serveur-nethack.sh` installe un serveur NetHack 5.0.0 (branche
`cybernethack` de HackTechDev/Nethack500_Lubuntu2604) derrière dgamelaunch
(paxed, SQLite), dans un conteneur LXD joignable en SSH
(`ssh -p 2222 nethack@hôte`). `README.md` documente tout le fonctionnement ;
`IMPROVEMENTS.md` liste les problèmes restants.

Un seul fichier, deux parties :

- `hote()` : sur l'hôte (LXD, ufw, conteneur, proxys SSH, sauvegardes sur
  l'hôte, tests d'accès). Se recopie dans le conteneur et s'y relance avec
  `--conteneur`.
- `conteneur()` : dans le conteneur (paquets, compilation de NetHack et de
  dgamelaunch, chroot `/opt/nethack/chroot`, sysconf, dgamelaunch.conf,
  sshd, pare-feu, entretien).

Plusieurs scripts sont **générés** par le script (heredocs) : ne jamais les
modifier directement, changer la fonction qui les écrit.

| Généré | Par | Où |
|---|---|---|
| `nethack-entretien` (+ timer) | `installer_entretien` | conteneur |
| `nethack-restaurer` | `restaurateur` | conteneur |
| `nethack-chroot-systeme` (+ crochet APT) | `copier_systeme_chroot` | conteneur |
| `/etc/nethack-pare-feu.nft` (+ service) | `pare_feu_jeu` | conteneur |
| `50-nethack.conf` (sshd) | `configurer_ssh` | conteneur |
| correctif des mots de passe | `correctif_dgamelaunch` | conteneur |
| `nethack-adresse` (+ timer) | `suivre_adresse_hote` | hôte |

## Langue et façon de travailler

- Tout en **français** : réponses, README, commentaires, messages de commit.
- **Un commit par correction**, message en français.
- **Pas de push sans demande explicite** de l'utilisateur.
- Avant de corriger une série de problèmes, les lister et attendre l'accord.
- Mettre à jour `README.md` dans le même commit que la correction.

## Choix de conception à préserver

Ne pas revenir sur ces points sans en parler à l'utilisateur :

- les parties tournent sous le compte système `nhjeu` ; le jeu, ses données
  et `sysconf` appartiennent à root ; dossier du jeu en `1775 root:nhjeu` ;
- `nhjeu` contrôle `dgldir`, `mail`, `save` et les scores : toute commande
  lancée en root sur ces chemins ne doit **jamais suivre un lien
  symbolique** (`chown -h`, pas de `chmod` ni `cp` sur un lien, mise en place
  par renommage depuis un dossier réservé à root) ;
- `nhjeu` n'a aucun accès réseau (nftables, table `inet nethack`) ;
- proxy LXD en mode NAT, pour que sshd voie l'adresse réelle des joueurs
  (OpenSSH 10 applique `PerSourcePenalties`) ;
- `WIZARDS` n'est accordé que si le compte existe déjà dans la base et a été
  confirmé par l'admin dans un terminal (empreinte n° + haché) ;
- relancer le script ne doit rien perdre : comptes, sauvegardes, scores et
  réglages modifiés à la main sont conservés ; seules les lignes qui
  dépendent des réglages du script sont réécrites ;
- le script fonctionne sous `set -euo pipefail` : une substitution de
  commande qui échoue dans une affectation arrête tout (prévoir `|| true`
  ou un test préalable).

## Vérifier une modification

L'agent n'a pas `sudo` : il ne peut pas lancer le script complet (seul
l'utilisateur le fait). Il peut utiliser `lxc` (groupe lxd).

- Syntaxe : `bash -n install-serveur-nethack.sh` (shellcheck absent).
- Tester une fonction dans un **conteneur jetable** (`lxc launch
  ubuntu:26.04 test-…`, supprimé ensuite avec `lxc delete -f`) : extraire
  l'en-tête du script (réglages et fonctions d'affichage, jusqu'à
  `PARTIE 1`) plus les fonctions voulues, puis les appeler.
- Les fonctions qui génèrent un script contiennent des `}` en début de ligne
  dans leurs heredocs : extraire jusqu'à la fonction suivante, pas jusqu'au
  premier `}`.
- Ne jamais toucher au conteneur de production `nethack` sans accord.
- Pièges déjà rencontrés : un quota de disque btrfs atteint bloque le
  conteneur (même pour retirer le quota) ; LXD 6.0 n'accepte pas d'ACL sur
  une carte de type bridge ; le noyau (`protected_regular`) empêche root
  d'écrire dans un fichier d'un autre compte placé dans un dossier sticky.
