#!/bin/bash
# =============================================================================
# install-serveur-nethack.sh
#
# Installe automatiquement un serveur NetHack 5.0.0 (branche cybernethack)
# avec dgamelaunch, dans un conteneur LXD, accessible en SSH.
# Automatise le tutoriel « serveur-nethack-cybernethack_v5.md ».
#
# Usage, sur l'hôte :
#     sudo ./install-serveur-nethack.sh
#
# Le script peut être relancé : il saute ce qui est déjà fait. Si le chroot
# existe déjà, le jeu y est mis à jour sans toucher aux comptes, aux parties
# ni au sysconf du serveur.
# =============================================================================
set -euo pipefail

# ----------------------------------------------------------------- Réglages --
CONTENEUR="nethack"              # nom du conteneur LXD
IMAGE="ubuntu:26.04"             # image du conteneur
LIMITE_CPU="2"                   # processeurs alloués
LIMITE_MEMOIRE="1GiB"            # mémoire allouée
PORT_SSH="2222"                  # port de l'hôte ouvert aux joueurs
CANAL_LXD="6.0/stable"           # version de LXD à installer

UTILISATEUR="util01"             # compte de compilation dans le conteneur
DEPOT="https://github.com/HackTechDev/Nethack500_Lubuntu2604.git"
BRANCHE="cybernethack"
DEPOT_DGL="https://github.com/paxed/dgamelaunch.git"

PSEUDO_WIZARD="sam"              # pseudo dgamelaunch autorisé en mode debug
LANGUE="fr@cyber"                # langue par défaut des joueurs (fr, fr@cyber, en)
NOM_SERVEUR="NetHack 5.0 cybernethack"
MAX_JOUEURS="50"                 # connexions simultanées maximum
# -----------------------------------------------------------------------------

HOME_UTIL="/home/$UTILISATEUR"
NH="$HOME_UTIL/nethack500"       # dossier du jeu (gravé dans le binaire)
SRC_NH="$HOME_UTIL/Nethack500_Lubuntu2604"
SRC_DGL="$HOME_UTIL/dgamelaunch"
C="/opt/nethack/chroot"          # racine du chroot
CONF="/opt/nethack/dgamelaunch.conf"
COMMIT_DGL="/opt/nethack/dgamelaunch.commit"   # commit de la dernière compilation
WIZARD_AUCUN="-aucun-"           # valeur de WIZARDS quand le mode debug est désactivé

etape()  { printf '\n\033[1;32m==> %s\033[0m\n' "$*"; }
info()   { printf '    %s\n' "$*"; }
alerte() { printf '\033[1;33m[!] %s\033[0m\n' "$*" >&2; }
erreur() { printf '\033[1;31m[ERREUR] %s\033[0m\n' "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || erreur "Lancer ce script en root (sudo $0)."

# =============================================================================
#                         PARTIE 1 : SUR L'HÔTE
# =============================================================================
hote() {
    etape "LXD"
    if ! snap list lxd >/dev/null 2>&1; then
        info "Installation de LXD ($CANAL_LXD)"
        snap install core 2>/dev/null || true
        snap install lxd --channel="$CANAL_LXD"
    else
        version=$(snap list lxd | awk 'NR==2 {print $2}')
        majeure=${version%%.*}
        info "LXD $version déjà installé"
        if [ "$majeure" -lt 5 ]; then
            alerte "LXD $version est trop ancien pour les noyaux récents (blocages AppArmor)."
            info "Mise à jour vers $CANAL_LXD (en passant par 5.0 et 5.21)"
            snap refresh lxd --channel=5.0/stable
            snap refresh lxd --channel=5.21/stable
            snap refresh lxd --channel="$CANAL_LXD"
        fi
    fi
    if ! lxc network show lxdbr0 >/dev/null 2>&1; then
        info "Initialisation de LXD (lxd init --minimal)"
        lxd init --minimal
    fi

    if command -v ufw >/dev/null && ufw status | grep -q "Status: active\|État : actif"; then
        etape "Pare-feu ufw"
        ufw allow in on lxdbr0 >/dev/null
        ufw route allow in on lxdbr0 >/dev/null
        ufw route allow out on lxdbr0 >/dev/null
        ufw allow "$PORT_SSH"/tcp >/dev/null
        info "lxdbr0 autorisé, port $PORT_SSH ouvert"
    fi

    etape "Conteneur $CONTENEUR"
    if lxc info "$CONTENEUR" >/dev/null 2>&1; then
        info "Déjà présent"
        lxc start "$CONTENEUR" 2>/dev/null || true
    else
        lxc launch "$IMAGE" "$CONTENEUR"
    fi
    lxc config set "$CONTENEUR" limits.cpu "$LIMITE_CPU"
    lxc config set "$CONTENEUR" limits.memory "$LIMITE_MEMOIRE"

    info "Attente du réseau du conteneur"
    for _ in $(seq 1 60); do
        if lxc exec "$CONTENEUR" -- sh -c 'ip -4 -o addr show eth0 | grep -q inet' 2>/dev/null; then
            break
        fi
        sleep 2
    done
    lxc exec "$CONTENEUR" -- sh -c 'ip -4 -o addr show eth0 | grep -q inet' \
        || erreur "Le conteneur n'a pas d'IPv4 (DHCP de lxdbr0 bloqué ? voir pgrep -a dnsmasq)."
    lxc exec "$CONTENEUR" -- cloud-init status --wait >/dev/null 2>&1 || true

    if ! lxc config device show "$CONTENEUR" | grep -q '^ssh-nethack:'; then
        lxc config device add "$CONTENEUR" ssh-nethack proxy \
            listen=tcp:0.0.0.0:"$PORT_SSH" connect=tcp:127.0.0.1:22
    fi
    info "Port $PORT_SSH de l'hôte → SSH du conteneur"

    etape "Installation dans le conteneur"
    lxc file push "$0" "$CONTENEUR/root/install-serveur-nethack.sh" --mode=0755
    lxc exec "$CONTENEUR" -- /root/install-serveur-nethack.sh --conteneur

    etape "Fichiers spéciaux du chroot (/dev/urandom, /dev/null)"
    for dev in urandom null; do
        if ! lxc config device show "$CONTENEUR" | grep -q "^chroot-$dev:"; then
            lxc config device add "$CONTENEUR" "chroot-$dev" unix-char \
                source="/dev/$dev" path="$C/dev/$dev" mode=0666
        elif ! lxc exec "$CONTENEUR" -- test -c "$C/dev/$dev"; then
            # chroot recréé : le device existe mais le fichier a disparu
            lxc config device remove "$CONTENEUR" "chroot-$dev"
            lxc config device add "$CONTENEUR" "chroot-$dev" unix-char \
                source="/dev/$dev" path="$C/dev/$dev" mode=0666
        fi
    done

    etape "Test du jeu dans le chroot"
    if lxc exec "$CONTENEUR" -- env LANG=C.UTF-8 chroot --userspec="$UTILISATEUR:$UTILISATEUR" \
            "$C" "$NH/nethack" --version; then
        info "NetHack démarre dans le chroot."
    else
        alerte "Le test --version a échoué : tester à la main dans le conteneur :"
        alerte "LANG=C.UTF-8 chroot --userspec=$UTILISATEUR:$UTILISATEUR $C $NH/nethack -u test"
    fi

    mot_de_passe_util

    ip_hote=$(hostname -I | awk '{print $1}')
    etape "Terminé"
    info "Connexion des joueurs : ssh -p $PORT_SSH nethack@$ip_hote"
    if lxc exec "$CONTENEUR" -- grep -qx "WIZARDS=$PSEUDO_WIZARD" "$C$NH/sysconf"; then
        info "Mode debug réservé au compte : $PSEUDO_WIZARD"
    else
        alerte "Mode debug désactivé : inscrivez le compte « $PSEUDO_WIZARD », puis relancez le script."
    fi
    if [ "$(etat_mot_de_passe)" != "P" ]; then
        alerte "$UTILISATEUR n'a toujours pas de mot de passe : lxc exec $CONTENEUR -- passwd $UTILISATEUR"
    fi
}

# État du mot de passe de $UTILISATEUR dans le conteneur :
# P = défini, L = verrouillé, NP = vide
etat_mot_de_passe() {
    lxc exec "$CONTENEUR" -- passwd -S "$UTILISATEUR" | awk '{print $2}'
}

# Demande un mot de passe pour $UTILISATEUR s'il n'en a pas encore
# (le compte est créé verrouillé par adduser --disabled-password)
mot_de_passe_util() {
    etape "Mot de passe de $UTILISATEUR"
    if [ "$(etat_mot_de_passe)" = "P" ]; then
        info "Déjà défini : conservé"
        return
    fi
    if [ ! -t 0 ]; then
        alerte "Pas de terminal interactif : mot de passe non défini."
        return
    fi
    info "Il sert à « lxc console $CONTENEUR » et à su (la connexion SSH par"
    info "mot de passe reste interdite pour ce compte)."
    local mdp1 mdp2 essai
    for essai in 1 2 3; do
        read -rsp "    Nouveau mot de passe (vide = plus tard) : " mdp1 || mdp1=""
        echo
        if [ -z "$mdp1" ]; then
            info "Mot de passe non défini."
            return
        fi
        read -rsp "    Confirmation : " mdp2 || mdp2=""
        echo
        if [ "$mdp1" = "$mdp2" ]; then
            # Transmis par l'entrée standard : n'apparaît ni dans ps ni dans l'historique
            if printf '%s:%s\n' "$UTILISATEUR" "$mdp1" | lxc exec "$CONTENEUR" -- chpasswd; then
                info "Mot de passe défini."
            else
                alerte "chpasswd a échoué (mot de passe refusé ?)."
            fi
            return
        fi
        alerte "Les deux saisies diffèrent (essai $essai/3)."
    done
    alerte "Abandon : mot de passe non défini."
}

# =============================================================================
#                      PARTIE 2 : DANS LE CONTENEUR
# =============================================================================

# Exécute un script bash sous l'utilisateur de compilation
en_util() {
    runuser -u "$UTILISATEUR" -- env HOME="$HOME_UTIL" \
        DEPOT="$DEPOT" BRANCHE="$BRANCHE" DEPOT_DGL="$DEPOT_DGL" \
        SRC_NH="$SRC_NH" SRC_DGL="$SRC_DGL" bash -euo pipefail -s
}

paquets() {
    etape "Paquets"
    export DEBIAN_FRONTEND=noninteractive
    apt-get -o DPkg::Lock::Timeout=600 update
    apt-get -o DPkg::Lock::Timeout=600 full-upgrade -y
    apt-get -o DPkg::Lock::Timeout=600 install -y \
        git gcc make curl gettext libncurses-dev \
        build-essential autoconf automake bison flex \
        libsqlite3-dev sqlite3 openssh-server rsync
}

utilisateur() {
    etape "Utilisateur $UTILISATEUR"
    if id "$UTILISATEUR" >/dev/null 2>&1; then
        info "Déjà présent"
    else
        adduser --disabled-password --gecos "" "$UTILISATEUR"
    fi
}

compiler_nethack() {
    etape "NetHack 5.0.0 (branche $BRANCHE)"
    # Les fichiers suivis par git ne sont jamais modifiés : le script compile à
    # partir de copies adaptées (ignorées par git) de linux.500 et install.sh,
    # régénérées à chaque exécution depuis les fichiers du dépôt. Vos éventuelles
    # modifications locales sont donc conservées et prises en compte.
    en_util <<'EOF'
HINTS=sys/unix/hints/linux.500
COPIE_HINTS=sys/unix/hints/linux.500.serveur
COPIE_INSTALL=.install-serveur.sh

# Installation dans ~/nethack500 et lanceur dans ~/bin
adapter_hints() {
    sed -e 's|^PREFIX=\$(wildcard ~)/nh/install$|PREFIX='"$HOME"'|' \
        -e 's|^HACKDIR=\$(PREFIX)/games/lib/nethackdir$|HACKDIR='"$HOME"'/nethack500|' \
        -e 's|^SHELLDIR = \$(PREFIX)/games$|SHELLDIR = '"$HOME"'/bin|' "$@"
}
adapter_install_base() {
    sed -e 's|^HACKDIR="\$HOME/nh/install/games/lib/nethackdir"$|HACKDIR="$HOME/nethack500"|' \
        -e 's|~/nh/install/games/nethack|~/bin/nethack|g' "$@"
}
adapter_install() {
    adapter_install_base "$@" \
        | sed -e 's|setup\.sh hints/linux\.500)|setup.sh hints/linux.500.serveur)|'
}

mkdir -p ~/bin
if [ -d "$SRC_NH/.git" ]; then
    cd "$SRC_NH"
    # Anciennes versions du script : elles modifiaient directement ces deux
    # fichiers. On ne les restaure que si la différence est exactement la leur.
    for f in "$HINTS" install.sh; do
        case "$f" in
            "$HINTS") adapter=adapter_hints ;;
            *)        adapter=adapter_install_base ;;
        esac
        if ! git diff --quiet -- "$f" \
                && git show "HEAD:$f" | "$adapter" | cmp -s - "$f"; then
            git checkout -- "$f"
            echo "    $f : modification d'une ancienne version du script annulée"
        fi
    done
    if [ -n "$(git status --porcelain --untracked-files=no)" ]; then
        echo "    Modifications locales conservées et compilées :"
        git status --short --untracked-files=no | sed 's/^/      /'
    fi
    git fetch origin "$BRANCHE"
    if ! { git checkout "$BRANCHE" && git pull --ff-only origin "$BRANCHE"; }; then
        printf '\033[1;33m[!] Mise à jour de %s impossible (modifications locales en conflit\n    ou commits divergents) : rien n'"'"'a été écrasé, la version locale est compilée.\033[0m\n' \
            "$BRANCHE" >&2
    fi
else
    git clone --branch "$BRANCHE" "$DEPOT" "$SRC_NH"
    cd "$SRC_NH"
fi

# Copies adaptées, ignorées par git
for f in "$COPIE_HINTS" "$COPIE_INSTALL"; do
    grep -qxF "/$f" .git/info/exclude 2>/dev/null || echo "/$f" >> .git/info/exclude
done
adapter_hints "$HINTS" > "$COPIE_HINTS"
adapter_install install.sh > "$COPIE_INSTALL"
chmod 755 "$COPIE_INSTALL"
grep -q "^HACKDIR=$HOME/nethack500$" "$COPIE_HINTS" \
    || { echo "$HINTS n'a pas pu être adapté (format changé ?)" >&2; exit 1; }
grep -q 'setup\.sh hints/linux\.500\.serveur)' "$COPIE_INSTALL" \
    && grep -q '^HACKDIR="$HOME/nethack500"$' "$COPIE_INSTALL" \
    || { echo "install.sh n'a pas pu être adapté (format changé ?)" >&2; exit 1; }

if ! ./"$COPIE_INSTALL" --console; then
    echo "Échec : nouvel essai après reconstruction de Lua" >&2
    rm -rf lib/lua include/nhlua.h lib/lua-*/src/*.o lib/lua-*/src/liblua.a
    ./"$COPIE_INSTALL" --console
fi
EOF
    [ -x "$NH/nethack" ] || erreur "NetHack n'est pas installé dans $NH."
}

compiler_dgamelaunch() {
    etape "dgamelaunch"
    # Sources clonées ou mises à jour à chaque exécution
    en_util <<'EOF'
if [ -d "$SRC_DGL/.git" ]; then
    git -C "$SRC_DGL" pull --ff-only
else
    git clone "$DEPOT_DGL" "$SRC_DGL"
fi
EOF
    # Recompilation si le binaire manque ou si les sources ont changé depuis
    # la dernière compilation (commit noté dans $COMMIT_DGL)
    commit=$(runuser -u "$UTILISATEUR" -- git -C "$SRC_DGL" rev-parse HEAD)
    if [ -x /opt/nethack/dgamelaunch ] && [ -f "$COMMIT_DGL" ] \
            && [ "$(cat "$COMMIT_DGL")" = "$commit" ]; then
        info "Déjà à jour (commit ${commit:0:12})"
        return
    fi
    info "Compilation du commit ${commit:0:12}"
    en_util <<'EOF'
cd "$SRC_DGL"
[ -f Makefile ] && make distclean >/dev/null 2>&1 || true
./autogen.sh --enable-sqlite --enable-shmem \
    --with-config-file=/opt/nethack/dgamelaunch.conf \
    CFLAGS="-O2 -std=gnu17 -fcommon \
      -Wno-error=implicit-function-declaration \
      -Wno-error=incompatible-pointer-types \
      -Wno-error=int-conversion"
make
EOF
    mkdir -p /opt/nethack
    # install remplace le fichier (unlink) : sans risque pour les sessions en cours
    install -o root -g root -m 4755 "$SRC_DGL/dgamelaunch" /opt/nethack/
    echo "$commit" > "$COMMIT_DGL"
}

creer_chroot() {
    etape "Chroot $C"
    cd "$SRC_DGL"
    # Copie adaptée du script d'origine (laissé intact dans le dépôt)
    # (variables modifiées uniquement dans l'en-tête, jusqu'à « END OF CONFIG »)
    sed -e "1,/END OF CONFIG/{
            s|^CHROOT=.*|CHROOT=\"$C/\"|
            s|^USRGRP=.*|USRGRP=\"$UTILISATEUR:$UTILISATEUR\"|
            s|^#\?NETHACKBIN=.*|NETHACKBIN=\"$NH/nethack\"|
            s|^#\?NH_PLAYGROUND_FIXED=.*|NH_PLAYGROUND_FIXED=\"\"|
            s|^NHSUBDIR=.*|NHSUBDIR=\"$NH/\"|
            s|^NH_VAR_PLAYGROUND=.*|NH_VAR_PLAYGROUND=\"$NH/\"|
        }" \
        -e 's|^mknod urandom c 1 9$|: # urandom fourni par LXD (unix-char)|' \
        -e 's|^mkdir "\$CHROOT/\$NHSUBDIR"$|mkdir -p "$CHROOT/$NHSUBDIR"|' \
        dgl-create-chroot > dgl-create-chroot.nh500
    sh dgl-create-chroot.nh500

    # Compléments pour NetHack 5.0
    rsync -a "$NH/" "$C$NH/"
    mkdir -p "$C"/dgldir/{inprogress-nh500,userdata,ttyrec,rcfiles} "$C/mail"
    chown -R "$UTILISATEUR:$UTILISATEUR" "$C/dgldir" "$C/mail" "$C$HOME_UTIL"

    # Bibliothèques : celles listées par ldd (chargeur dynamique compris), plus
    # libgcc_s, que ldd ne montre pas car la glibc la charge à l'exécution
    # (pile d'appels en cas de plantage, annulation de thread). Son dossier
    # dépend de l'architecture : x86_64-linux-gnu, aarch64-linux-gnu…
    multiarch=$(gcc -dumpmachine)
    for lib in $(ldd "$NH/nethack" | grep -o '/[^ ]*') \
               "/lib/$multiarch/libgcc_s.so.1" "/usr/lib/$multiarch/libgcc_s.so.1"; do
        [ -e "$lib" ] || continue
        mkdir -p "$C$(dirname "$lib")"
        [ -e "$C$lib" ] || cp "$lib" "$C$lib"
    done
    if ! ls "$C"/lib/"$multiarch"/libgcc_s.so.1 "$C"/usr/lib/"$multiarch"/libgcc_s.so.1 \
            >/dev/null 2>&1; then
        alerte "libgcc_s.so.1 introuvable pour $multiarch : NetHack risque de planter dans le chroot."
        alerte "Chercher son chemin avec « ldconfig -p | grep libgcc_s » et la copier dans $C."
    fi

    mkdir -p "$C/usr/share" "$C/usr/lib" "$C/lib" "$C/etc" "$C/dev"
    cp -a /usr/share/terminfo "$C/usr/share/"
    [ -d /lib/terminfo ] && cp -a /lib/terminfo "$C/lib/"
    cp /etc/localtime "$C/etc/"
    cp -a /usr/lib/locale "$C/usr/lib/"
    grep -E "^(root|$UTILISATEUR):" /etc/passwd > "$C/etc/passwd"
    grep -E "^(root|$UTILISATEUR):" /etc/group  > "$C/etc/group"
}

# Échappe une valeur pour la partie remplacement d'un s|...|...| de sed
echapper() { printf '%s' "$1" | sed -e 's/[\\|&]/\\&/g'; }

# Donne la valeur $3 à la clé $2 (« CLÉ=valeur ») du fichier $1 : modifie la
# ligne active, sinon décommente la première ligne commentée, sinon l'ajoute
regler_cle() {
    if grep -q "^$2=" "$1"; then
        sed -i "s|^$2=.*|$2=$(echapper "$3")|" "$1"
    elif grep -q "^#$2=" "$1"; then
        sed -i "0,/^#$2=.*/s||$2=$(echapper "$3")|" "$1"
    else
        echo "$2=$3" >> "$1"
    fi
}

# Vrai si le compte dgamelaunch $1 existe (pseudo déjà validé : lettres et chiffres)
compte_dgl_existe() {
    [ "$(sqlite3 "$C/dgldir/dgamelaunch.db" \
        "SELECT COUNT(*) FROM dglusers WHERE username = '$1';" 2>/dev/null)" = "1" ]
}

# sysconf du serveur : appliqué à chaque exécution, sans toucher au reste
regler_sysconf() {
    etape "sysconf du serveur"
    S="$C$NH/sysconf"
    [ -f "$S" ] || erreur "$S introuvable."
    # Le mode debug n'est accordé que si le compte existe déjà : l'inscription
    # étant ouverte, le premier venu pourrait sinon s'inscrire sous ce pseudo.
    # Valeur par défaut : un nom impossible à inscrire (dgamelaunch n'accepte
    # que lettres et chiffres), car celle d'origine (« root games ») peut l'être.
    case "$PSEUDO_WIZARD" in
        ''|*[!A-Za-z0-9]*) erreur "PSEUDO_WIZARD ne doit contenir que des lettres et des chiffres." ;;
    esac
    if compte_dgl_existe "$PSEUDO_WIZARD"; then
        regler_cle "$S" WIZARDS "$PSEUDO_WIZARD"
        info "Mode debug accordé au compte existant « $PSEUDO_WIZARD »"
    else
        regler_cle "$S" WIZARDS "$WIZARD_AUCUN"
        alerte "Le compte « $PSEUDO_WIZARD » n'existe pas encore : mode debug désactivé."
        alerte "Inscrivez-le vous-même (ssh -p $PORT_SSH nethack@…), puis relancez le script."
    fi
    regler_cle "$S" CHECK_PLNAME 1
    regler_cle "$S" DUMPLOGFILE /dgldir/userdata/%n/dumplog/%t.txt
    regler_cle "$S" PANICTRACE_GDB 0
    sed -i -e 's|^GDBPATH=|#GDBPATH=|' -e 's|^GREPPATH=|#GREPPATH=|' "$S"
}

mettre_a_jour_chroot() {
    etape "Mise à jour du jeu dans le chroot existant"
    rsync -a \
      --exclude save --exclude record --exclude logfile --exclude xlogfile \
      --exclude livelog --exclude perm --exclude sysconf \
      "$NH/" "$C$NH/"
    chown -R "$UTILISATEUR:$UTILISATEUR" "$C$HOME_UTIL"
    info "Comptes, parties et sysconf conservés (réglages du script réappliqués ensuite)."
}

configurer_dgamelaunch() {
    etape "Configuration de dgamelaunch"
    if [ -f "$CONF" ]; then
        info "$CONF existe déjà : conservé, seuls les réglages du script sont réappliqués"
    else
        # Création à partir de l'exemple (une seule fois)
        cd "$SRC_DGL"
        cp examples/dgamelaunch.conf "$CONF"
        cp examples/dgl_menu_*.txt examples/dgl-banner "$C/" 2>/dev/null || true
        sed -i -e "s|/nh343/nethack|$NH/nethack|g" \
               -e 's/nh343/nh500/g' -e 's/NH343/NH500/g' -e 's/3\.4\.3/5.0.0/g' \
            "$CONF" "$C"/dgl_menu_*.txt "$C/dgl-banner"
        sed -i -e "s|/nh500/var/save/|$NH/save/|g" \
               -e '/setenv "NETHACKOPTIONS"/a\             setenv "LANG" "C.UTF-8",' \
               -e "s|\"\\\$MOTDTIME\" = \"[^\"]*\"|\"\$MOTDTIME\" = \"$(date +%Y.%m.%d)\"|" \
            "$CONF"
        if grep -q 'nh343\|3\.4\.3' "$CONF"; then
            alerte "Des références à 3.4.3 restent dans $CONF"
        fi
    fi

    # Réglages du script : appliqués à chaque exécution
    case "$NOM_SERVEUR" in *'"'*) erreur "NOM_SERVEUR ne doit pas contenir de guillemet." ;; esac
    case "$MAX_JOUEURS" in ''|*[!0-9]*) erreur "MAX_JOUEURS doit être un nombre." ;; esac
    U=$(id -u "$UTILISATEUR"); G=$(id -g "$UTILISATEUR")
    sed -i -e "s|^chroot_path = .*|chroot_path = \"$(echapper "$C")/\"|" \
           -e "s|^shed_uid = .*|shed_uid = $U|" \
           -e "s|^shed_gid = .*|shed_gid = $G|" \
           -e "s|^maxusers = .*|maxusers = $MAX_JOUEURS|" \
           -e "s|\"\\\$SERVERID\" = \"[^\"]*\"|\"\$SERVERID\" = \"\$ATTR(14)$(echapper "$NOM_SERVEUR")\$ATTR()\"|" \
        "$CONF"
    for motif in '^chroot_path = ' '^shed_uid = ' '^shed_gid = ' '^maxusers = ' '"\$SERVERID" = '; do
        grep -q "$motif" "$CONF" || alerte "Ligne « $motif » absente de $CONF : réglage non appliqué"
    done
    info "maxusers = $MAX_JOUEURS, nom du serveur : $NOM_SERVEUR"

    # Options par défaut des joueurs : une seule ligne language
    R="$C/dgl-default-rcfile.nh500"
    [ -f "$R" ] || cp "$SRC_NH/config/nethackrc" "$R"
    sed -i '/^OPTIONS=language:/d' "$R"
    echo "OPTIONS=language:$LANGUE" >> "$R"
    chmod 644 "$R"
}

configurer_ssh() {
    etape "Accès SSH public (compte nethack)"
    id nethack >/dev/null 2>&1 || useradd -m -s /bin/sh nethack
    passwd -d nethack >/dev/null
    cat > /etc/ssh/sshd_config.d/50-nethack.conf <<EOF
Match User nethack
    PasswordAuthentication yes
    PermitEmptyPasswords yes
    KbdInteractiveAuthentication no
    PermitTTY yes
    X11Forwarding no
    AllowTcpForwarding no
    AllowAgentForwarding no
    PermitTunnel no
    ForceCommand /opt/nethack/dgamelaunch -f $CONF
EOF
    sshd -t
    systemctl restart ssh
}

conteneur() {
    paquets
    utilisateur
    compiler_nethack
    compiler_dgamelaunch
    if [ -e "$C/dgldir/dgamelaunch.db" ]; then
        mettre_a_jour_chroot
    else
        if [ -e "$C" ]; then
            # Chroot incomplet ou sans base de comptes : mis de côté, jamais supprimé
            sauvegarde="$C.sauvegarde-$(date +%Y%m%d-%H%M%S)"
            alerte "$C existe sans $C/dgldir/dgamelaunch.db : déplacé vers $sauvegarde"
            mv "$C" "$sauvegarde"
        fi
        creer_chroot
    fi
    regler_sysconf
    configurer_dgamelaunch
    configurer_ssh
}

# =============================================================================
case "${1:-}" in
    --conteneur) conteneur ;;
    "")          hote ;;
    *)           erreur "Option inconnue : $1 (usage : sudo $0)" ;;
esac
