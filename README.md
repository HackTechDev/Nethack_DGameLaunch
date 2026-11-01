# Serveur NetHack 5.0 « cybernethack » avec dgamelaunch

`install-serveur-nethack.sh` installe automatiquement un serveur public
**NetHack 5.0.0** (branche `cybernethack`) derrière **dgamelaunch**, dans un
conteneur **LXD**, accessible aux joueurs par **SSH**.

Il automatise le tutoriel `serveur-nethack-cybernethack_v5.md`.

```
Joueur ──ssh -p 2222──▶ Hôte ──proxy LXD (NAT)──▶ Conteneur « nethack » :22
                                                    └─ sshd (compte nethack, sans mot de passe)
                                                       └─ ForceCommand dgamelaunch
                                                          └─ chroot /opt/nethack/chroot
                                                             └─ nethack sous nhjeu (fr@cyber)
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

Pour garder une trace de l'installation, utilisez `script`, qui conserve le
terminal :

```bash
script -q install.log -c "sudo ./install-serveur-nethack.sh"
```

Évitez `| tee` : la sortie n'étant plus un terminal, `lxc exec` n'en ouvre
pas dans le conteneur, et les questions qui y sont posées (mise à jour
pendant des parties, archivage des sauvegardes, confirmation du compte du
mode debug) reçoivent automatiquement « non ». Le script le signale.

Le script doit être lancé avec bash et depuis son fichier : il se recopie
dans le conteneur. Lancé avec `sh` ou par un tube (`curl … | sudo bash`), il
s'arrête avec un message clair.

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
`LANGUE`, `PORT_SSH`) sont, eux, réappliqués à chaque exécution : il suffit de les
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
| `NAT_PROXY`       | `oui`                                                   | `oui` : sshd voit l'adresse réelle des joueurs (IPv4 fixe pour le conteneur) ; `non` : tous semblent venir de `127.0.0.1` |
| `ADRESSE_HOTE`    | *(vide)*                                                | IPv4 de l'hôte où écouter en mode NAT (vide = celle de la route par défaut) |
| `IPV6`            | `oui`                                                   | Accepter aussi les joueurs en IPv6 en mode NAT |
| `CANAL_LXD`       | `6.0/stable`                                            | Canal snap de LXD |
| `UTILISATEUR`     | `util01`                                                | Compte de compilation et d'administration |
| `COMPTE_JEU`      | `nhjeu`                                                 | Compte système sans connexion sous lequel tournent les parties |
| `DEPOT`           | `https://github.com/HackTechDev/Nethack500_Lubuntu2604.git` | Sources de NetHack |
| `BRANCHE`         | `cybernethack`                                          | Branche à compiler |
| `DEPOT_DGL`       | `https://github.com/paxed/dgamelaunch.git`              | Sources de dgamelaunch |
| `PSEUDO_WIZARD`   | `utildebug`                                             | Seul compte dgamelaunch autorisé en mode debug (`WIZARDS`), une fois inscrit ; lettres et chiffres, 10 caractères au plus |
| `LANGUE`          | `fr@cyber`                                              | Langue par défaut des joueurs (`fr`, `fr@cyber`, `en`) |
| `NOM_SERVEUR`     | `NetHack 5.0 cybernethack`                              | Nom affiché dans le menu dgamelaunch |
| `MAX_JOUEURS`     | `50`                                                    | Connexions simultanées maximum |
| `INSCRIPTIONS`    | `oui`                                                   | `non` ferme les inscriptions (les comptes existants restent utilisables) |
| `SAUVEGARDES_JOURS` | `14`                                                  | Nombre de jours de sauvegardes quotidiennes gardés |
| `SAUVEGARDES_HOTE` | `/var/backups/nethack`                                | Dossier de l'hôte où sont écrites les sauvegardes (vide = dans le conteneur seulement) |
| `TTYREC_JOURS`    | `180`                                                   | Enregistrements de parties gardés, en jours (`0` = tous) |
| `MAJ_SYSTEME`     | `premiere`                                              | `apt full-upgrade` du conteneur : `premiere` (première installation), `toujours` ou `jamais` |

Chemins dérivés (dans le conteneur) :

| Chemin                               | Contenu |
|--------------------------------------|---------|
| `/home/util01/nethack500`            | Jeu installé (chemin gravé dans le binaire) |
| `/home/util01/Nethack500_Lubuntu2604`| Sources NetHack |
| `/home/util01/dgamelaunch`           | Sources dgamelaunch |
| `/opt/nethack/dgamelaunch`           | Binaire dgamelaunch (setuid root) |
| `/opt/nethack/dgamelaunch.conf`      | Configuration dgamelaunch |
| `/opt/nethack/dgamelaunch.commit`    | Empreinte (commit + correctif) de la dernière compilation de dgamelaunch |
| `/opt/nethack/dgamelaunch-mots-de-passe.patch` | Correctif de sécurité appliqué à dgamelaunch |
| `/home/util01/dgamelaunch-construction` | Copie corrigée des sources dgamelaunch, compilée |
| `/opt/nethack/nethack.version`       | Version du jeu installée dans le chroot |
| `/opt/nethack/jeu.uid`               | UID sous lequel tournent les parties |
| `/opt/nethack/wizard.confirme`      | Empreinte du compte du mode debug confirmé par l'admin |
| `/opt/nethack/nethack.fichiers`     | Liste des fichiers du jeu installés dans le chroot |
| `/opt/nethack/sauvegardes/`         | Sauvegardes quotidiennes (`nethack-AAAAMMJJ-HHMMSS.tar.gz`) |
| `/usr/local/sbin/nethack-entretien` | Script d'entretien quotidien (généré) |
| `/usr/local/sbin/nethack-adresse` (hôte) | Suivi de l'IPv4 de l'hôte en mode NAT (généré, timer `nethack-adresse.timer`) |
| `/opt/nethack/chroot`                | Chroot des joueurs |

## Fonctionnement

Le script s'exécute en deux temps : sur l'hôte, puis il se copie dans le
conteneur et se relance avec l'option interne `--conteneur`.

### Partie 1 — sur l'hôte (`hote`)

1. **LXD** : installe le snap (canal `CANAL_LXD`) s'il manque. Une version
   < 5 est mise à jour par paliers (5.0 → 5.21 → `CANAL_LXD`), car les vieux
   LXD bloquent sur AppArmor avec les noyaux récents. Lance
   `lxd init --minimal` si le pont `lxdbr0` n'existe pas.
2. **ufw** (s'il est actif) : ouvre `PORT_SSH/tcp` et laisse passer le
   trafic routé par `lxdbr0` (Internet du conteneur, joueurs redirigés en
   mode NAT). Vers l'hôte lui-même, le conteneur n'atteint que le DHCP
   (67/udp, 547/udp) et le DNS (53) de `lxdbr0` : même compromis, il ne peut
   pas joindre les autres services de l'hôte. L'ancienne règle large
   `allow in on lxdbr0` est retirée.
3. **Conteneur** : le crée (ou le démarre), applique les limites CPU/mémoire,
   attend son IPv4 (2 min max) et la fin de cloud-init.
4. **Proxy SSH** : device `ssh-nethack` qui relie `PORT_SSH` de l'hôte au
   port 22 du conteneur.
   - **Mode NAT** (`NAT_PROXY=oui`, par défaut) : sshd voit l'adresse réelle
     des joueurs, donc les pénalités par adresse d'OpenSSH
     (`PerSourcePenalties`) et les limites visent le seul fautif. LXD impose
     une adresse d'écoute précise (`ADRESSE_HOTE`, ou celle de la route par
     défaut) et une IPv4 fixe pour le conteneur : son adresse actuelle est
     fixée sur `eth0`. Si l'IPv4 de l'hôte change (DHCP) et que
     `ADRESSE_HOTE` est vide, le timer systemd `nethack-adresse.timer` de
     l'hôte le détecte en moins de 2 minutes et déplace l'écoute
     (`journalctl -u nethack-adresse`). Une réservation DHCP reste préférable.
   - **Sans NAT** : écoute sur `0.0.0.0`, tous les joueurs semblent venir de
     `127.0.0.1` ; cette adresse est donc exemptée des pénalités
     (`PerSourcePenaltyExemptList`), sinon un seul client fautif bloquerait
     tout le monde.

   - **IPv6** : sans NAT, le proxy sur `0.0.0.0` écoute déjà en double pile.
     En mode NAT, il n'écoute que sur une IPv4 : un second device,
     `ssh-nethack6` (`[::]:PORT_SSH` → `[::1]:22`, proxy classique), reçoit
     les joueurs IPv6 (`IPV6=oui`). Ils arrivent dans sshd sous l'adresse
     `::1`, exemptée des pénalités.
   - **Connexions non authentifiées** (sshd) : au plus 10 par adresse
     (`PerSourceMaxStartups`), 50 à 150 au total (`MaxStartups`), 30 s pour
     s'authentifier (`LoginGraceTime`). Un client seul ne peut donc plus
     occuper toutes les places. Limite connue : en mode NAT, les joueurs
     IPv6 partagent le quota de `::1`, si bien qu'un attaquant IPv6 peut
     gêner les autres joueurs IPv6 (pas les joueurs IPv4). Une protection
     complète demanderait le NAT IPv6, donc une IPv6 fixe pour le conteneur
     (DHCPv6 avec attribution d'adresses sur `lxdbr0`) ; `IPV6=non` supprime
     l'accès IPv6.

   Si un de ces réglages ou `PORT_SSH` change, le device est recréé et
   l'ancien port refermé dans ufw.
5. **Installation** dans le conteneur (partie 2).
6. **Sauvegardes sur l'hôte** : dossier `SAUVEGARDES_HOTE` créé (`root:root`,
   `0700`) et monté dans le conteneur sur `/opt/nethack/sauvegardes`.
7. **Fichiers spéciaux** : `/dev/urandom` et `/dev/null` sont fournis au chroot
   via des devices LXD `unix-char` (`mknod` est impossible dans un conteneur
   non privilégié). Ils sont recréés si le chroot a été reconstruit.
8. **Test** : lance `nethack --version` dans le chroot.
9. **Mot de passe de `util01`** : demandé seulement s'il n'est pas déjà
   défini et si le script tourne dans un terminal. Il est transmis à
   `chpasswd` par l'entrée standard, donc n'apparaît ni dans `ps` ni dans
   l'historique. S'il manque toujours à la fin, une alerte le rappelle.
10. **Test de l'accès des joueurs** : bannière SSH sur `adresse:PORT_SSH`
    (et en IPv6 par `[::1]` quand il est servi), puis affichage du menu de
    dgamelaunch dans le conteneur. Une alerte indique quoi vérifier en cas
    d'échec.

### Partie 2 — dans le conteneur (`conteneur`)

1. **Paquets** : `apt full-upgrade` à la première installation seulement
   (réglable par `MAJ_SYSTEME`), puis installation des seuls paquets
   manquants (`--no-upgrade`). S'il n'y a rien à installer ni à mettre à
   jour, `apt-get update` n'est même pas lancé : relancer le script pour
   changer un réglage fonctionne aussi sans accès aux dépôts. Paquets : outils de compilation, ncurses, SQLite,
   OpenSSH, rsync, unattended-upgrades. Relancer le script pour changer un
   réglage ne met donc pas tout le système à jour ; les mises à jour de
   sécurité restent appliquées chaque jour par unattended-upgrades. Le chroot
   est autonome : ces mises à jour ne le cassent pas, et un crochet APT
   (`/etc/apt/apt.conf.d/90nethack-chroot`) lui recopie les bibliothèques
   après chaque mise à jour de paquets : il reçoit les correctifs de sécurité
   le jour même, sans relancer le script. Sur une
   installation existante, le premier passage à cette version fait encore une
   mise à jour complète.
2. **Comptes** : `util01` créé avec mot de passe désactivé
   (`adduser --disabled-password`) ; `nhjeu`, compte système sans connexion
   ni dossier personnel, pour les parties.
3. **Compilation de NetHack** (sous `util01`) : clone ou met à jour la
   branche (`git fetch`, puis avance rapide seulement). Si le dépôt est
   injoignable (réseau, GitHub), une alerte l'indique et la version locale
   est compilée : le script peut être relancé hors ligne. Les fichiers suivis par git ne sont jamais
   modifiés : le script génère à chaque exécution deux copies adaptées,
   ignorées par git (`.git/info/exclude`), pour installer dans `~/nethack500`
   avec le lanceur dans `~/bin` :
   - `sys/unix/hints/linux.500.serveur`, copie de `linux.500` ;
   - `.install-serveur.sh`, copie de `install.sh` qui utilise ce fichier de
     hints.

   Puis il lance `./.install-serveur.sh --console`. En cas d'échec, Lua est
   nettoyé et la compilation relancée une fois.
4. **Compilation de dgamelaunch** : les sources sont clonées ou mises à jour
   (`git pull --ff-only`) à chaque exécution. Si la mise à jour échoue
   (modification locale en conflit, commits divergents, réseau), une alerte
   l'indique et la version locale est utilisée, comme pour NetHack.
   La compilation se fait dans une copie, `~/dgamelaunch-construction`, à
   laquelle est appliqué un **correctif de sécurité des mots de passe**
   (enregistré dans `/opt/nethack/dgamelaunch-mots-de-passe.patch`) ; les
   sources clonées ne sont pas modifiées. Sans lui, dgamelaunch hache les
   mots de passe en DES par `crypt(mdp, mdp)` (8 caractères utiles, les deux
   premiers stockés en clair comme sel) et accepte le haché stocké comme mot
   de passe : lire la base suffit pour se connecter sous n'importe quel
   compte. Avec lui : yescrypt avec sel aléatoire, haché refusé comme mot de
   passe ; un ancien mot de passe est vérifié une dernière fois puis re-haché
   à la connexion suivante du joueur. Si le code amont change et que le
   correctif ne s'applique plus, le script s'arrête sans rien installer.
   La compilation n'a lieu que si le binaire manque, ou si le commit des
   sources ou le correctif diffèrent de l'empreinte notée dans
   `/opt/nethack/dgamelaunch.commit`. Options :
   `--enable-sqlite --enable-shmem`, avec des `CFLAGS` tolérants
   (`-std=gnu17 -fcommon`, erreurs GCC 14+ rétrogradées en avertissements) car
   le code est ancien. Installé setuid root.
5. **Chroot** :
   - **première installation** : copie modifiée de `dgl-create-chroot`,
     générée dans `/tmp` et supprimée après usage (l'original et le dépôt de
     `util01` restent intacts), puis ajout du jeu,
     des dossiers `dgldir/{inprogress-nh500,userdata}` et `mail`. Les restes
     de `dgl-create-chroot`, prévu pour NetHack 3.4.3 (dossiers vides
     `inprogress-nh343`, `ttyrec`, `rcfiles`, options `dgl-default-rcfile.nh343`
     et copie inutilisée du binaire dgamelaunch dans le chroot), sont
     supprimés à chaque exécution, seulement s'ils sont vides ou inutilisés ;
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

     Puis `rsync` du jeu ; seuls les fichiers retirés de la nouvelle version
     (d'après la liste `/opt/nethack/nethack.fichiers`) sont supprimés du
     chroot, jamais ceux des parties ni ceux ajoutés par l'admin ;
   - **dans les deux cas**, ne sont jamais recopiés depuis `~/nethack500` :
     sauvegardes, scores et journaux (`save`, `record`, `logfile`,
     `xlogfile`, `livelog`, `perm`), `archives`, fichiers laissés par des
     parties d'essai hors du chroot (niveaux, os, verrous, `paniclog`) et,
     lors d'une mise à jour, `sysconf`. Les motifs sont ancrés à la racine du
     dossier du jeu. La copie datée du binaire laissée par `dgl-create-chroot`
     (`nethack.AAAAMMJJ`) est supprimée ;
   - **dans les deux cas**, fichiers système recopiés depuis le conteneur par
     `/usr/local/sbin/nethack-chroot-systeme` : bibliothèques du jeu du
     chroot (`ldd` + `libgcc_s`, cherchée dans le dossier de l'architecture
     donné par `gcc -dumpmachine`), terminfo, locales, `localtime` et
     `passwd`/`group` minimaux. dgamelaunch tourne hors du chroot : ses
     bibliothèques n'y sont pas recopiées. Comme le jeu est compilé avec les
     bibliothèques du conteneur, le chroot doit avoir les mêmes ; le crochet
     APT `90nethack-chroot` relance ce script après chaque `apt`/`dpkg`
     (unattended-upgrades compris). `rsync` remplace les fichiers par
     renommage : les parties en cours ne sont pas perturbées.
6. **sysconf** (à chaque exécution) : `WIZARDS=<PSEUDO_WIZARD>` seulement si
   ce compte existe déjà dans la base dgamelaunch et que vous avez confirmé
   qu'il est le vôtre (sinon `WIZARDS=-aucun-`, un nom impossible à inscrire), `CHECK_PLNAME=1`, dumplogs dans `/dgldir/userdata/<pseudo>/dumplog/`,
   `PANICTRACE_GDB=0`, gdb/grep désactivés. Seules ces clés sont modifiées
   (ligne active, sinon décommentée, sinon ajoutée) ; le reste du fichier est
   conservé.
7. **dgamelaunch.conf** :
   - **création** (s'il n'existe pas) : copié depuis les exemples, les
     références 3.4.3 sont converties en 5.0.0, dossier de sauvegardes,
     `LANG=C.UTF-8` et date du MOTD renseignés ; menus et bannière copiés dans
     le chroot ;
   - **à chaque exécution** : `chroot_path`, `shed_uid`/`shed_gid`,
     `maxusers` (`MAX_JOUEURS`), `allow_new_nicks` (`INSCRIPTIONS`) et nom
     du serveur (`NOM_SERVEUR`) sont
     réappliqués. Une alerte signale toute ligne introuvable.
8. **rcfile par défaut** `dgl-default-rcfile.nh500` : basé sur
   `config/nethackrc`, avec une unique ligne `OPTIONS=language:<LANGUE>`
   (réécrite à chaque exécution).
9. **SSH** : compte `nethack` sans mot de passe, et
   `/etc/ssh/sshd_config.d/50-nethack.conf` qui force dgamelaunch
   (`ForceCommand`) et interdit toute redirection (`DisableForwarding` : TCP,
   sockets Unix, agent, X11), les tunnels et `~/.ssh/rc` (`PermitUserRC no`).
   Pour tous les autres comptes, la connexion par mot de passe est interdite
   explicitement (`PasswordAuthentication no`, `KbdInteractiveAuthentication
   no`, `PermitRootLogin prohibit-password`), sans dépendre du réglage de
   l'image : le port est public. La configuration est vérifiée par `sshd -t` avant le redémarrage.
10. **Entretien quotidien** : script `/usr/local/sbin/nethack-entretien`
    lancé vers 4 h 30 par le timer systemd `nethack-entretien.timer` (rattrapé
    au démarrage s'il a été manqué).
    - **Sauvegarde** dans `/opt/nethack/sauvegardes/` : base des comptes
      (copie cohérente par `sqlite3 .backup`), `dgldir` (réglages et dumplogs
      des joueurs), sauvegardes, scores et journaux du jeu, `sysconf`,
      `archives` et `dgamelaunch.conf`. Les enregistrements de parties n'y
      sont pas (trop volumineux). `SAUVEGARDES_JOURS` jours sont gardés.
    - **Enregistrements de parties** (ttyrec) : compressés au bout d'un jour,
      sauf ceux des parties encore en cours (même inactives), supprimés au
      bout de `TTYREC_JOURS` jours (`0` = jamais).
    - **Bilan** : nombre de comptes et place occupée par les données des
      joueurs, avec une alerte au-delà de 90 % de disque occupé
      (`journalctl -u nethack-entretien`). dgamelaunch ne limite pas le
      rythme des inscriptions : en cas de vague de comptes indésirables,
      passez `INSCRIPTIONS=non` et relancez le script.

## Administration

### Passage au compte `nhjeu` (installations existantes)

Les versions précédentes faisaient tourner les parties sous `util01`. À la
première exécution de cette version, et s'il n'y a pas de partie en cours,
le script passe les parties sous `nhjeu` et renomme les sauvegardes, dont le
nom commence par l'UID (`1001toto.gz` → `999toto.gz`). S'il y a des parties en
cours, ce passage est reporté à l'exécution suivante.

### Activer le mode debug

L'inscription étant ouverte à tous, le mode debug n'est jamais accordé à un
pseudo qui n'existe pas encore : sinon, le premier venu pourrait s'inscrire
sous ce nom et en profiter. Après la première installation :

1. connectez-vous (`ssh -p 2222 nethack@<ip>`) et inscrivez le compte
   `PSEUDO_WIZARD` (`utildebug` par défaut) ;
2. relancez `sudo ./install-serveur-nethack.sh` **dans un terminal** : le
   script affiche le numéro et le courriel du compte et demande de confirmer
   que c'est bien le vôtre (quelqu'un a pu l'inscrire avant vous). Si vous
   répondez non, il donne la commande pour supprimer ce compte.

La confirmation est retenue dans `/opt/nethack/wizard.confirme` sous forme
d'empreinte du compte (identifiant et haché du mot de passe). Elle est
redemandée si le compte est réinscrit ou si son mot de passe change (y compris
une fois, lors du passage automatique des mots de passe à yescrypt).

Pour jouer en mode debug : menu `o` de dgamelaunch, ajoutez
`OPTIONS=playmode:debug` au fichier d'options, puis lancez une partie.

### Sauvegardes

Les sauvegardes quotidiennes sont écrites directement sur l'hôte, dans
`SAUVEGARDES_HOTE` (`/var/backups/nethack` par défaut, `root:root`, `0700` :
elles contiennent la base des comptes). Ce dossier est monté dans le
conteneur sur `/opt/nethack/sauvegardes` (device LXD `sauvegardes`, avec
`shift=true`) : supprimer le conteneur ne les efface pas. Les sauvegardes déjà
faites dans le conteneur y sont déplacées au premier montage. Pensez tout de
même à les copier hors de la machine.

```bash
sudo ls -l /var/backups/nethack/
lxc exec nethack -- nethack-entretien      # sauvegarde immédiate
```

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
`maxusers`, `allow_new_nicks` et `$SERVERID`.

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
  à `nhjeu`.
- **Limite connue : dgamelaunch et NetHack partagent le compte `nhjeu`.**
  dgamelaunch abandonne ses droits root pour `shed_uid` avant de lancer la
  partie, et doit alors pouvoir écrire dans la base des comptes et dans les
  dossiers de tous les joueurs. Une faille de NetHack exploitée en jeu
  donnerait donc accès à la base (hachés des mots de passe), aux sauvegardes,
  options et enregistrements des autres joueurs, et aux scores. Elle ne
  permettrait pas de modifier le jeu, `sysconf` ni le mode debug (root), ni
  de sortir du chroot. Depuis le correctif des mots de passe, une base volée
  ne suffit plus à se connecter : il faudrait casser des hachés yescrypt.
  Séparer les deux comptes demanderait de modifier dgamelaunch en
  profondeur. Le compte `util01` reste verrouillé tant qu'aucun
  mot de passe n'a été saisi ; même avec un mot de passe, il ne peut pas se
  connecter en SSH par mot de passe (`PasswordAuthentication no` dans
  `50-nethack.conf`).
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
| Le test `--version` échoue | Tester à la main : `LANG=C.UTF-8 chroot --userspec=nhjeu:nhjeu /opt/nethack/chroot /home/util01/nethack500/nethack -u test` |
| Bibliothèque manquante dans le chroot | Comparer `ldd /home/util01/nethack500/nethack` avec le contenu du chroot. |
| « Des références à 3.4.3 restent » | Corriger à la main `/opt/nethack/dgamelaunch.conf`. |
