# Serveur NetHack 5.0 « cybernethack » avec dgamelaunch

`install-serveur-nethack.sh` installe automatiquement un serveur public
**NetHack 5.0.0** (branche `cybernethack`) derrière **dgamelaunch**, dans un
conteneur **LXD**, accessible aux joueurs par **SSH**.

Il automatise le tutoriel `serveur-nethack-cybernethack_v5.md`.

```
Joueur ──ssh -p 2222──▶ Hôte ──proxy LXD──▶ Conteneur « nethack » :22
                                              └─ sshd (compte nethack, sans mot de passe)
                                                 └─ ForceCommand dgamelaunch
                                                    └─ chroot /opt/nethack/chroot
                                                       └─ nethack (fr@cyber)
```

## Prérequis

- Un hôte Linux avec `snap` (Ubuntu conseillé), sur une architecture pour
  laquelle l'image `ubuntu:26.04` existe (amd64, arm64, riscv64…).
- Un accès root (`sudo`).
- Un accès Internet (image `ubuntu:26.04`, dépôts GitHub, paquets apt).

## Utilisation

```bash
sudo ./install-serveur-nethack.sh
```

À la fin, le script affiche la commande de connexion :

```bash
ssh -p 2222 nethack@<ip-de-l-hôte>
```

Le compte de compilation `util01` est créé verrouillé. Si vous lancez le
script depuis un terminal et que ce compte n'a pas encore de mot de passe, le
script vous en demande un à la fin (saisie masquée, confirmée, trois essais,
réponse vide = plus tard). Il sert à `lxc console nethack` et à `su` ; la
connexion SSH par mot de passe reste interdite pour ce compte. Sans terminal
(lancement automatisé), ou pour le changer plus tard :

```bash
lxc exec nethack -- passwd util01
```

Le script est **ré-exécutable** : il saute ce qui est déjà fait. Si le chroot
contient déjà une base de comptes (`dgldir/dgamelaunch.db`), seul le jeu est
mis à jour ; comptes, sauvegardes, scores et `sysconf` sont conservés.
Les réglages du script (`PSEUDO_WIZARD`, `NOM_SERVEUR`, `MAX_JOUEURS`,
`LANGUE`) sont, eux, réappliqués à chaque exécution : il suffit de les
modifier et de relancer le script.

## Réglages

Les variables en tête du script :

| Variable          | Défaut                                                  | Rôle |
|-------------------|---------------------------------------------------------|------|
| `CONTENEUR`       | `nethack`                                               | Nom du conteneur LXD |
| `IMAGE`           | `ubuntu:26.04`                                          | Image du conteneur |
| `LIMITE_CPU`      | `2`                                                     | Processeurs alloués |
| `LIMITE_MEMOIRE`  | `1GiB`                                                  | Mémoire allouée |
| `PORT_SSH`        | `2222`                                                  | Port de l'hôte ouvert aux joueurs |
| `CANAL_LXD`       | `6.0/stable`                                            | Canal snap de LXD |
| `UTILISATEUR`     | `util01`                                                | Compte de compilation et d'administration |
| `COMPTE_JEU`      | `nhjeu`                                                 | Compte système sans connexion sous lequel tournent les parties |
| `DEPOT`           | `https://github.com/HackTechDev/Nethack500_Lubuntu2604.git` | Sources de NetHack |
| `BRANCHE`         | `cybernethack`                                          | Branche à compiler |
| `DEPOT_DGL`       | `https://github.com/paxed/dgamelaunch.git`              | Sources de dgamelaunch |
| `PSEUDO_WIZARD`   | `sam`                                                   | Seul compte dgamelaunch autorisé en mode debug (`WIZARDS`), une fois inscrit |
| `LANGUE`          | `fr@cyber`                                              | Langue par défaut des joueurs (`fr`, `fr@cyber`, `en`) |
| `NOM_SERVEUR`     | `NetHack 5.0 cybernethack`                              | Nom affiché dans le menu dgamelaunch |
| `MAX_JOUEURS`     | `50`                                                    | Connexions simultanées maximum |

Chemins dérivés (dans le conteneur) :

| Chemin                               | Contenu |
|--------------------------------------|---------|
| `/home/util01/nethack500`            | Jeu installé (chemin gravé dans le binaire) |
| `/home/util01/Nethack500_Lubuntu2604`| Sources NetHack |
| `/home/util01/dgamelaunch`           | Sources dgamelaunch |
| `/opt/nethack/dgamelaunch`           | Binaire dgamelaunch (setuid root) |
| `/opt/nethack/dgamelaunch.conf`      | Configuration dgamelaunch |
| `/opt/nethack/dgamelaunch.commit`    | Commit de la dernière compilation de dgamelaunch |
| `/opt/nethack/nethack.version`       | Version du jeu installée dans le chroot |
| `/opt/nethack/jeu.uid`               | UID sous lequel tournent les parties |
| `/opt/nethack/chroot`                | Chroot des joueurs |

## Fonctionnement

Le script s'exécute en deux temps : sur l'hôte, puis il se copie dans le
conteneur et se relance avec l'option interne `--conteneur`.

### Partie 1 — sur l'hôte (`hote`)

1. **LXD** : installe le snap (canal `CANAL_LXD`) s'il manque. Une version
   < 5 est mise à jour par paliers (5.0 → 5.21 → `CANAL_LXD`), car les vieux
   LXD bloquent sur AppArmor avec les noyaux récents. Lance
   `lxd init --minimal` si le pont `lxdbr0` n'existe pas.
2. **ufw** (s'il est actif) : autorise le trafic sur `lxdbr0` et ouvre
   `PORT_SSH/tcp`.
3. **Conteneur** : le crée (ou le démarre), applique les limites CPU/mémoire,
   attend son IPv4 (2 min max) et la fin de cloud-init.
4. **Proxy SSH** : device `ssh-nethack` qui relie `0.0.0.0:PORT_SSH` de l'hôte
   au port 22 du conteneur.
5. **Installation** dans le conteneur (partie 2).
6. **Fichiers spéciaux** : `/dev/urandom` et `/dev/null` sont fournis au chroot
   via des devices LXD `unix-char` (`mknod` est impossible dans un conteneur
   non privilégié). Ils sont recréés si le chroot a été reconstruit.
7. **Test** : lance `nethack --version` dans le chroot.
8. **Mot de passe de `util01`** : demandé seulement s'il n'est pas déjà
   défini et si le script tourne dans un terminal. Il est transmis à
   `chpasswd` par l'entrée standard, donc n'apparaît ni dans `ps` ni dans
   l'historique. S'il manque toujours à la fin, une alerte le rappelle.

### Partie 2 — dans le conteneur (`conteneur`)

1. **Paquets** : `apt full-upgrade`, puis outils de compilation, ncurses,
   SQLite, OpenSSH, rsync…
2. **Comptes** : `util01` créé avec mot de passe désactivé
   (`adduser --disabled-password`) ; `nhjeu`, compte système sans connexion
   ni dossier personnel, pour les parties.
3. **Compilation de NetHack** (sous `util01`) : clone ou met à jour la
   branche (`git pull --ff-only`). Les fichiers suivis par git ne sont jamais
   modifiés : le script génère à chaque exécution deux copies adaptées,
   ignorées par git (`.git/info/exclude`), pour installer dans `~/nethack500`
   avec le lanceur dans `~/bin` :
   - `sys/unix/hints/linux.500.serveur`, copie de `linux.500` ;
   - `.install-serveur.sh`, copie de `install.sh` qui utilise ce fichier de
     hints.

   Puis il lance `./.install-serveur.sh --console`. En cas d'échec, Lua est
   nettoyé et la compilation relancée une fois.
4. **Compilation de dgamelaunch** : les sources sont clonées ou mises à jour
   (`git pull --ff-only`) à chaque exécution. La compilation n'a lieu que si
   le binaire manque ou si le commit des sources diffère de celui noté dans
   `/opt/nethack/dgamelaunch.commit` lors de la dernière compilation. Options :
   `--enable-sqlite --enable-shmem`, avec des `CFLAGS` tolérants
   (`-std=gnu17 -fcommon`, erreurs GCC 14+ rétrogradées en avertissements) car
   le code est ancien. Installé setuid root.
5. **Chroot** :
   - **première installation** : copie modifiée de `dgl-create-chroot`
     (`dgl-create-chroot.nh500`, l'original reste intact), puis ajout du jeu,
     des dossiers `dgldir/{inprogress-nh500,userdata,ttyrec,rcfiles}` et
     `mail` ;
   - **mise à jour** : d'abord deux vérifications.
     - **Parties en cours** (fichiers de `dgldir/inprogress-nh500` dont le
       processus existe encore) : la mise à jour est reportée, sauf
       confirmation dans un terminal.
     - **Changement de version** (`MAJEURE.MINEURE.PATCHLEVEL.EDITLEVEL` de
       `include/patchlevel.h`, comparée à `/opt/nethack/nethack.version`) :
       les sauvegardes et les os existants deviendraient illisibles. S'il y en
       a, la mise à jour est reportée, sauf confirmation dans un terminal ;
       ils sont alors déplacés dans `archives/version-<ancienne>-<date>/` du
       dossier du jeu, jamais supprimés.

     Puis `rsync` du jeu en excluant `save`, `record`,
     `logfile`, `xlogfile`, `livelog`, `perm` et `sysconf` ;
   - **dans les deux cas**, fichiers système recopiés depuis le conteneur :
     bibliothèques de NetHack et de dgamelaunch (`ldd` + `libgcc_s`, cherchée
     dans le dossier de l'architecture donné par `gcc -dumpmachine`),
     terminfo, locales, `localtime` et `passwd`/`group` minimaux. Comme le jeu
     est recompilé avec les bibliothèques du conteneur, le chroot doit avoir
     les mêmes. `rsync` remplace les fichiers par renommage : les parties en
     cours ne sont pas perturbées.
6. **sysconf** (à chaque exécution) : `WIZARDS=<PSEUDO_WIZARD>` seulement si
   ce compte existe déjà dans la base dgamelaunch (sinon `WIZARDS=-aucun-`,
   un nom impossible à inscrire), `CHECK_PLNAME=1`, dumplogs dans `/dgldir/userdata/<pseudo>/dumplog/`,
   `PANICTRACE_GDB=0`, gdb/grep désactivés. Seules ces clés sont modifiées
   (ligne active, sinon décommentée, sinon ajoutée) ; le reste du fichier est
   conservé.
7. **dgamelaunch.conf** :
   - **création** (s'il n'existe pas) : copié depuis les exemples, les
     références 3.4.3 sont converties en 5.0.0, dossier de sauvegardes,
     `LANG=C.UTF-8` et date du MOTD renseignés ; menus et bannière copiés dans
     le chroot ;
   - **à chaque exécution** : `chroot_path`, `shed_uid`/`shed_gid`,
     `maxusers` (`MAX_JOUEURS`) et nom du serveur (`NOM_SERVEUR`) sont
     réappliqués. Une alerte signale toute ligne introuvable.
8. **rcfile par défaut** `dgl-default-rcfile.nh500` : basé sur
   `config/nethackrc`, avec une unique ligne `OPTIONS=language:<LANGUE>`
   (réécrite à chaque exécution).
9. **SSH** : compte `nethack` sans mot de passe, et
   `/etc/ssh/sshd_config.d/50-nethack.conf` qui force dgamelaunch
   (`ForceCommand`) et interdit tunnels, redirections et X11. La configuration
   est vérifiée par `sshd -t` avant le redémarrage.

## Administration

### Passage au compte `nhjeu` (installations existantes)

Les versions précédentes faisaient tourner les parties sous `util01`. À la
première exécution de cette version, et s'il n'y a pas de partie en cours,
le script passe les parties sous `nhjeu` et renomme les sauvegardes, dont le
nom commence par l'UID (`1001sam.gz` → `999sam.gz`). S'il y a des parties en
cours, ce passage est reporté à l'exécution suivante.

### Activer le mode debug

L'inscription étant ouverte à tous, le mode debug n'est jamais accordé à un
pseudo qui n'existe pas encore : sinon, le premier venu pourrait s'inscrire
sous ce nom et en profiter. Après la première installation :

1. connectez-vous (`ssh -p 2222 nethack@<ip>`) et inscrivez le compte
   `PSEUDO_WIZARD` (`sam` par défaut) ;
2. relancez `sudo ./install-serveur-nethack.sh` : le mode debug est alors
   activé pour ce compte.

### Commandes utiles

```bash
lxc exec nethack -- bash                    # shell dans le conteneur
lxc exec nethack -- sqlite3 /opt/nethack/chroot/dgldir/dgamelaunch.db \
    'select username from dglusers;'        # liste des comptes
lxc stop nethack / lxc start nethack        # arrêt / démarrage
```

Pour modifier la configuration dgamelaunch après coup, éditez directement
`/opt/nethack/dgamelaunch.conf` dans le conteneur : le script ne l'écrase
jamais et ne touche qu'aux lignes `chroot_path`, `shed_uid`, `shed_gid`,
`maxusers` et `$SERVERID`.

## Points d'attention

- **Chroot sans base de comptes** : si `/opt/nethack/chroot` existe mais
  sans `dgldir/dgamelaunch.db`, il n'est pas supprimé : il est déplacé vers
  `/opt/nethack/chroot.sauvegarde-AAAAMMJJ-HHMMSS`, puis un chroot neuf est
  créé. Récupérez-y ce qui vous intéresse (sauvegardes, scores), puis
  supprimez ces dossiers à la main pour libérer de la place.
- **Recompilation de dgamelaunch** : elle se fait seule quand le dépôt amont
  évolue. Pour la forcer (par exemple après un changement des `CFLAGS`),
  supprimez `/opt/nethack/dgamelaunch.commit` puis relancez le script. Le
  remplacement du binaire n'interrompt pas les parties en cours.
- **Modifications locales des sources NetHack** : elles sont conservées,
  listées au début de la compilation et compilées (les copies adaptées sont
  faites à partir des fichiers tels qu'ils sont sur le disque). Si elles
  empêchent la mise à jour (conflit ou commits divergents), une alerte
  l'indique et la version locale est compilée telle quelle. Les modifications
  laissées par une ancienne version du script dans `linux.500` et `install.sh`
  sont annulées automatiquement, seulement si elles correspondent exactement
  aux siennes. Si le format de ces fichiers change en amont, le script
  s'arrête au lieu de compiler avec de mauvais chemins.
- **Architecture** : le script ne contient plus de chemin propre à x86_64,
  mais il n'a été écrit et utilisé que sur x86_64. Si `libgcc_s.so.1` n'est
  pas trouvée, une alerte l'indique pendant la création du chroot.
- **Sécurité** : le compte `nethack` n'a pas de mot de passe, par conception ;
  il est limité à dgamelaunch par `ForceCommand`. Le binaire dgamelaunch est
  setuid root (il fait le `chroot` puis abandonne ses droits vers
  `shed_uid`/`shed_gid`, ici `nhjeu`). Le binaire du jeu, ses données et
  `sysconf` appartiennent à root : une partie, même via une faille de
  NetHack, ne peut ni les modifier ni se donner le mode debug. Le dossier du
  jeu a le sticky bit (`1775 root:nhjeu`) : `nhjeu` y crée ses fichiers de
  niveaux et ses os, mais ne peut pas supprimer ni remplacer ceux de root.
  Seuls les sauvegardes, scores et journaux, `dgldir` et `mail` appartiennent
  à `nhjeu`. Le compte `util01` reste verrouillé tant qu'aucun
  mot de passe n'a été saisi ; même avec un mot de passe, il ne peut pas se
  connecter en SSH par mot de passe (`PasswordAuthentication no` de l'image
  Ubuntu).
- **Réglages du script prioritaires** : à chaque exécution, `WIZARDS` (et
  les autres clés listées plus haut) dans `sysconf`, ainsi que `maxusers` et
  le nom du serveur dans `dgamelaunch.conf`, reprennent les valeurs du
  script. Une modification manuelle de ces lignes serait écrasée : changez
  plutôt la variable en tête du script. `NOM_SERVEUR` ne doit pas contenir
  de guillemet.

## Dépannage

| Symptôme | Piste |
|----------|-------|
| « Le conteneur n'a pas d'IPv4 » | DHCP de `lxdbr0` bloqué : vérifier `pgrep -a dnsmasq` et le pare-feu de l'hôte. |
| Le test `--version` échoue | Tester à la main : `LANG=C.UTF-8 chroot --userspec=util01:util01 /opt/nethack/chroot /home/util01/nethack500/nethack -u test` |
| Bibliothèque manquante dans le chroot | Comparer `ldd /home/util01/nethack500/nethack` avec le contenu du chroot. |
| « Des références à 3.4.3 restent » | Corriger à la main `/opt/nethack/dgamelaunch.conf`. |
