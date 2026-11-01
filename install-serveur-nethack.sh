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
# existe déjà, le jeu y est mis à jour en conservant comptes, sauvegardes et
# scores (mise à jour reportée s'il y a des parties en cours ou si les
# sauvegardes deviendraient incompatibles). Les réglages ci-dessous sont
# réappliqués à chaque exécution ; dans sysconf et dgamelaunch.conf, seules
# les lignes qui en dépendent sont modifiées, le reste est conservé.
# Voir README.md pour le détail.
# =============================================================================
if [ -z "${BASH_VERSION:-}" ]; then
    echo "Ce script nécessite bash : sudo ./install-serveur-nethack.sh (ou sudo bash …)" >&2
    exit 1
fi
set -euo pipefail

# Chemin réel du script, recopié tel quel dans le conteneur
SCRIPT=$(readlink -f "${BASH_SOURCE[0]:-$0}" 2>/dev/null || true)

# ----------------------------------------------------------------- Réglages --
CONTENEUR="nethack"              # nom du conteneur LXD
IMAGE="ubuntu:26.04"             # image du conteneur
LIMITE_CPU="2"                   # processeurs alloués
LIMITE_MEMOIRE="1GiB"            # mémoire allouée
PORT_SSH="2222"                  # port de l'hôte ouvert aux joueurs
NAT_PROXY="oui"                  # oui : sshd voit l'adresse réelle des joueurs
                                 # (IPv4 fixe pour le conteneur) ; non : tous
                                 # les joueurs semblent venir de 127.0.0.1
ADRESSE_HOTE=""                  # IPv4 de l'hôte où écouter (vide = automatique)
IPV6="oui"                       # accepter aussi les joueurs en IPv6 (mode NAT)
CANAL_LXD="6.0/stable"           # version de LXD à installer

UTILISATEUR="util01"             # compte de compilation dans le conteneur
COMPTE_JEU="nhjeu"               # compte système sous lequel tournent les parties
DEPOT="https://github.com/HackTechDev/Nethack500_Lubuntu2604.git"
BRANCHE="cybernethack"
DEPOT_DGL="https://github.com/paxed/dgamelaunch.git"

PSEUDO_WIZARD="utildebug"        # pseudo dgamelaunch autorisé en mode debug
                                 # (lettres et chiffres, 10 caractères au plus)
LANGUE="fr@cyber"                # langue par défaut des joueurs (fr, fr@cyber, en)
NOM_SERVEUR="NetHack 5.0 cybernethack"
MAX_JOUEURS="50"                 # connexions simultanées maximum
INSCRIPTIONS="oui"               # oui : tout visiteur peut créer un compte ;
                                 # non : inscriptions fermées (comptes existants
                                 # conservés)
SAUVEGARDES_JOURS="14"           # sauvegardes quotidiennes (comptes, parties) gardées
SAUVEGARDES_HOTE="/var/backups/nethack"  # dossier de l'hôte où elles sont écrites,
                                 # pour survivre à la suppression du conteneur
                                 # (vide = dans le conteneur seulement)
TTYREC_JOURS="180"               # enregistrements de parties gardés (0 = tous)
MAJ_SYSTEME="premiere"           # apt full-upgrade du conteneur : premiere
                                 # (première installation), toujours ou jamais ;
                                 # les mises à jour de sécurité restent assurées
                                 # par unattended-upgrades
# -----------------------------------------------------------------------------

HOME_UTIL="/home/$UTILISATEUR"
NH="$HOME_UTIL/nethack500"       # dossier du jeu (gravé dans le binaire)
SRC_NH="$HOME_UTIL/Nethack500_Lubuntu2604"
SRC_DGL="$HOME_UTIL/dgamelaunch"
CONSTR_DGL="$HOME_UTIL/dgamelaunch-construction"   # copie corrigée, compilée
CORRECTIF_DGL="/opt/nethack/dgamelaunch-mots-de-passe.patch"
C="/opt/nethack/chroot"          # racine du chroot
CONF="/opt/nethack/dgamelaunch.conf"
COMMIT_DGL="/opt/nethack/dgamelaunch.commit"   # commit de la dernière compilation
WIZARD_AUCUN="-aucun-"           # valeur de WIZARDS quand le mode debug est désactivé
VERSION_NH="/opt/nethack/nethack.version"      # version du jeu installée dans le chroot
SYSTEME_INIT="/opt/nethack/systeme.initialise" # présent après le premier full-upgrade
MANIFESTE="/opt/nethack/nethack.fichiers"      # fichiers du jeu installés dans le chroot
SAUVEGARDES="/opt/nethack/sauvegardes"         # sauvegardes quotidiennes (hors chroot)

# Fichiers du dossier du jeu jamais recopiés depuis ~/nethack500 (motifs rsync
# ancrés à la racine) : fichiers variables du serveur et fichiers créés par les
# parties d'essai lancées hors du chroot (niveaux, os, verrous, plantages)
EXCLUS_JEU=(--exclude=/save --exclude=/record --exclude=/logfile
            --exclude=/xlogfile --exclude=/livelog --exclude=/perm
            --exclude=/archives --exclude=/paniclog --exclude='/bon*'
            --exclude='/*_lock' --exclude='/*.[0-9]' --exclude='/*.[0-9][0-9]'
            --exclude='/*.[0-9][0-9][0-9]')
UID_JEU="/opt/nethack/jeu.uid"   # UID des parties (nom des sauvegardes : <uid><pseudo>)
WIZARD_CONFIRME="/opt/nethack/wizard.confirme" # « pseudo:empreinte » du compte debug confirmé

etape()  { printf '\n\033[1;32m==> %s\033[0m\n' "$*"; }
info()   { printf '    %s\n' "$*"; }
alerte() { printf '\033[1;33m[!] %s\033[0m\n' "$*" >&2; }
erreur() { printf '\033[1;31m[ERREUR] %s\033[0m\n' "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || erreur "Lancer ce script en root (sudo $0)."

# =============================================================================
#                         PARTIE 1 : SUR L'HÔTE
# =============================================================================
# IPv4 principale de l'hôte (celle de la route par défaut)
adresse_hote() {
    ip -4 route get 1.1.1.1 2>/dev/null \
        | awk '{ for (i = 1; i < NF; i++) if ($i == "src") { print $(i + 1); exit } }'
}

# Fixe l'IPv4 du conteneur (indispensable au mode NAT du proxy) ; affiche l'adresse
fixer_ip_conteneur() {
    local fixe actuelle
    fixe=$(lxc config device get "$CONTENEUR" eth0 ipv4.address 2>/dev/null || true)
    if [ -n "$fixe" ]; then
        echo "$fixe"
        return
    fi
    actuelle=$(lxc exec "$CONTENEUR" -- ip -4 -o addr show eth0 \
                   | awk '{ sub("/.*", "", $4); print $4; exit }')
    [ -n "$actuelle" ] || erreur "IPv4 du conteneur introuvable."
    if lxc config device show "$CONTENEUR" | grep -q '^eth0:'; then
        lxc config device set "$CONTENEUR" eth0 ipv4.address="$actuelle" >&2
    else
        # eth0 vient du profil : surchargé pour ce conteneur seulement
        lxc config device override "$CONTENEUR" eth0 ipv4.address="$actuelle" >&2
    fi
    echo "$actuelle"
}

# Sauvegardes quotidiennes écrites dans un dossier de l'hôte, monté dans le
# conteneur : elles survivent à sa suppression. Dossier root:root en 0700 sur
# l'hôte (il contient la base des comptes).
sauvegardes_sur_hote() {
    etape "Sauvegardes sur l'hôte"
    local actuelle uid_root
    actuelle=$(lxc config device get "$CONTENEUR" sauvegardes source 2>/dev/null || true)
    case "$SAUVEGARDES_HOTE" in
        "")
            if [ -n "$actuelle" ]; then
                lxc config device remove "$CONTENEUR" sauvegardes >/dev/null
                info "Montage retiré : les sauvegardes déjà faites restent dans $actuelle (hôte)"
            fi
            info "Sauvegardes dans le conteneur seulement ($SAUVEGARDES)"
            return ;;
        /*) ;;
        *)  erreur "SAUVEGARDES_HOTE doit être un chemin absolu." ;;
    esac
    mkdir -p "$SAUVEGARDES_HOTE"
    chown root:root "$SAUVEGARDES_HOTE"
    chmod 700 "$SAUVEGARDES_HOTE"
    if [ -z "$actuelle" ]; then
        # Sauvegardes déjà faites dans le conteneur : mises de côté, puis
        # déplacées dans le dossier monté (sinon le montage les masquerait)
        if lxc exec "$CONTENEUR" -- test -d "$SAUVEGARDES"; then
            lxc exec "$CONTENEUR" -- mv "$SAUVEGARDES" "$SAUVEGARDES.avant-hote"
        fi
        # shift=true : root du conteneur = root de l'hôte dans ce dossier ;
        # sinon, le dossier est donné au root du conteneur vu de l'hôte
        if ! lxc config device add "$CONTENEUR" sauvegardes disk \
                source="$SAUVEGARDES_HOTE" path="$SAUVEGARDES" shift=true >/dev/null 2>&1; then
            uid_root=$(lxc config get "$CONTENEUR" volatile.idmap.current \
                           | grep -o '"Isuid":true,"Isgid":false,"Hostid":[0-9]*' \
                           | head -n 1 | grep -o '[0-9]*$')
            [ -n "$uid_root" ] || erreur "Correspondance des UID du conteneur introuvable."
            chown "$uid_root:$uid_root" "$SAUVEGARDES_HOTE"
            lxc config device add "$CONTENEUR" sauvegardes disk \
                source="$SAUVEGARDES_HOTE" path="$SAUVEGARDES" >/dev/null
        fi
        if lxc exec "$CONTENEUR" -- test -d "$SAUVEGARDES.avant-hote"; then
            lxc exec "$CONTENEUR" -- sh -c "cp -a '$SAUVEGARDES.avant-hote/.' '$SAUVEGARDES/' \
                && rm -rf '$SAUVEGARDES.avant-hote'"
            info "Sauvegardes déjà faites déplacées sur l'hôte"
        fi
    elif [ "$actuelle" != "$SAUVEGARDES_HOTE" ]; then
        lxc config device set "$CONTENEUR" sauvegardes source="$SAUVEGARDES_HOTE"
        info "Dossier changé : $actuelle → $SAUVEGARDES_HOTE (anciennes sauvegardes laissées dans $actuelle)"
    fi
    info "$SAUVEGARDES_HOTE (hôte) monté sur $SAUVEGARDES (conteneur)"
}

# Sept premiers caractères envoyés par le serveur SSH sur $1:$2 (« SSH-2.0 »),
# vide s'il ne répond pas en 5 s
banniere_ssh() {
    timeout 5 bash -c 'exec 3<>"/dev/tcp/$1/$2" && head -c 7 <&3' _ "$1" "$2" \
        2>/dev/null || true
}

# Mode NAT avec adresse automatique : si l'IPv4 de l'hôte change (DHCP), le
# proxy écouterait sur une adresse disparue. Un timer systemd de l'hôte vérifie
# toutes les 2 minutes et déplace l'écoute sur la nouvelle adresse.
suivre_adresse_hote() {
    local unite=/etc/systemd/system/nethack-adresse
    if [ -z "$nat" ] || [ -n "$ADRESSE_HOTE" ]; then
        if [ -e "$unite.timer" ]; then
            systemctl disable --now nethack-adresse.timer >/dev/null 2>&1 || true
            rm -f "$unite.timer" "$unite.service" /usr/local/sbin/nethack-adresse
            systemctl daemon-reload
            info "Suivi de l'adresse de l'hôte retiré (adresse fixe ou mode sans NAT)"
        fi
        return
    fi
    {
        cat <<EOF
#!/bin/bash
# Généré par install-serveur-nethack.sh : ne pas modifier, relancer le script.
set -euo pipefail
CONTENEUR="$CONTENEUR"
PORT_SSH="$PORT_SSH"
EOF
        cat <<'EOF'
ip=$(ip -4 route get 1.1.1.1 2>/dev/null \
         | awk '{ for (i = 1; i < NF; i++) if ($i == "src") { print $(i + 1); exit } }')
[ -n "$ip" ] || exit 0                       # pas de réseau : rien à faire
actuelle=$(lxc config device get "$CONTENEUR" ssh-nethack listen 2>/dev/null) || exit 0
nouvelle="tcp:$ip:$PORT_SSH"
[ "$actuelle" = "$nouvelle" ] && exit 0
lxc config device set "$CONTENEUR" ssh-nethack listen="$nouvelle"
echo "Écoute des joueurs déplacée : $actuelle → $nouvelle"
EOF
    } > /usr/local/sbin/nethack-adresse
    chmod 755 /usr/local/sbin/nethack-adresse
    cat > "$unite.service" <<EOF
[Unit]
Description=Écoute du serveur NetHack sur l'IPv4 actuelle de l'hôte
After=network-online.target snap.lxd.daemon.service

[Service]
Type=oneshot
Environment=PATH=/snap/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
ExecStart=/usr/local/sbin/nethack-adresse
EOF
    cat > "$unite.timer" <<EOF
[Unit]
Description=Vérifie l'IPv4 de l'hôte pour le serveur NetHack

[Timer]
OnBootSec=1min
OnUnitActiveSec=2min

[Install]
WantedBy=timers.target
EOF
    systemctl daemon-reload
    systemctl enable --now nethack-adresse.timer >/dev/null 2>&1
    info "Suivi de l'IPv4 de l'hôte : toutes les 2 minutes (journalctl -u nethack-adresse)"
}

# Vrai si le pare-feu ufw est installé et actif (messages forcés en anglais
# pour que le test ne dépende pas de la langue du système)
ufw_actif() {
    command -v ufw >/dev/null && LC_ALL=C LANGUAGE= ufw status | grep -q "^Status: active"
}

hote() {
    # lxc exec n'ouvre un terminal dans le conteneur que si l'entrée et la
    # sortie en sont un : avec « | tee », les questions y reçoivent « non »
    if [ -t 0 ] && [ ! -t 1 ]; then
        alerte "Sortie redirigée : les questions posées dans le conteneur recevront « non »."
        alerte "Pour garder une trace avec les questions : script -q install.log -c \"sudo $0\""
    fi
    if [ -z "$SCRIPT" ] || [ ! -f "$SCRIPT" ] || ! grep -q '^conteneur() {' "$SCRIPT"; then
        erreur "Lancer le script depuis son fichier (sudo ./install-serveur-nethack.sh), pas par un tube."
    fi
    case "$PORT_SSH" in
        ''|*[!0-9]*) erreur "PORT_SSH doit être un numéro de port." ;;
    esac
    [ "$PORT_SSH" -ge 1 ] && [ "$PORT_SSH" -le 65535 ] || erreur "PORT_SSH hors limites (1-65535)."

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

    if ufw_actif; then
        etape "Pare-feu ufw"
        # Vers l'hôte lui-même, le conteneur n'a besoin que du DHCP (v4, v6)
        # et du DNS de lxdbr0 : les autres services de l'hôte lui restent
        # fermés (règle « allow in on lxdbr0 » des versions précédentes retirée)
        ufw delete allow in on lxdbr0 >/dev/null 2>&1 || true
        ufw allow in on lxdbr0 to any port 67 proto udp >/dev/null
        ufw allow in on lxdbr0 to any port 547 proto udp >/dev/null
        ufw allow in on lxdbr0 to any port 53 >/dev/null
        # Trafic traversant l'hôte : accès Internet du conteneur et joueurs
        # redirigés vers lui (mode NAT)
        ufw route allow in on lxdbr0 >/dev/null
        ufw route allow out on lxdbr0 >/dev/null
        ufw allow "$PORT_SSH"/tcp >/dev/null
        info "lxdbr0 : DHCP et DNS seulement vers l'hôte ; port $PORT_SSH ouvert"
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

    # Redirection du port vers le SSH du conteneur. En mode NAT, sshd voit
    # l'adresse réelle des joueurs (pénalités et limites par adresse
    # efficaces) ; LXD impose alors une adresse d'écoute précise et une IPv4
    # fixe pour le conteneur.
    case "$NAT_PROXY" in
        oui)
            ip_ecoute=${ADRESSE_HOTE:-$(adresse_hote)}
            [ -n "$ip_ecoute" ] || erreur "IPv4 de l'hôte introuvable : renseigner ADRESSE_HOTE."
            ip_conteneur=$(fixer_ip_conteneur)
            ecoute="tcp:$ip_ecoute:$PORT_SSH"; cible="tcp:$ip_conteneur:22"; nat="true" ;;
        non)
            ecoute="tcp:0.0.0.0:$PORT_SSH"; cible="tcp:127.0.0.1:22"; nat="" ;;
        *)  erreur "NAT_PROXY doit valoir oui ou non." ;;
    esac
    ancienne=$(lxc config device get "$CONTENEUR" ssh-nethack listen 2>/dev/null || true)
    ancienne_cible=$(lxc config device get "$CONTENEUR" ssh-nethack connect 2>/dev/null || true)
    ancien_nat=$(lxc config device get "$CONTENEUR" ssh-nethack nat 2>/dev/null || true)
    [ "$ancien_nat" = "false" ] && ancien_nat=""
    if [ "$ancienne $ancienne_cible $ancien_nat" != "$ecoute $cible $nat" ]; then
        [ -n "$ancienne" ] && lxc config device remove "$CONTENEUR" ssh-nethack >/dev/null
        lxc config device add "$CONTENEUR" ssh-nethack proxy \
            listen="$ecoute" connect="$cible" ${nat:+nat=true} >/dev/null
        if [ -n "$ancienne" ] && [ "${ancienne##*:}" != "$PORT_SSH" ] && ufw_actif; then
            ufw delete allow "${ancienne##*:}"/tcp >/dev/null 2>&1 || true
            info "Ancien port ${ancienne##*:} refermé dans ufw"
        fi
    fi
    info "${ecoute#tcp:} (hôte) → ${cible#tcp:} (SSH du conteneur)${nat:+, mode NAT}"

    # IPv6. Sans NAT, le proxy sur 0.0.0.0 écoute déjà en double pile. En mode
    # NAT, il n'écoute que sur une IPv4 : un second proxy, classique, reçoit
    # l'IPv6 et la transmet par [::1] (exempté des pénalités dans sshd).
    case "$IPV6" in oui|non) ;; *) erreur "IPV6 doit valoir oui ou non." ;; esac
    ecoute6="tcp:[::]:$PORT_SSH"
    ancienne6=$(lxc config device get "$CONTENEUR" ssh-nethack6 listen 2>/dev/null || true)
    if [ -n "$nat" ] && [ "$IPV6" = oui ]; then
        if [ "$ancienne6" != "$ecoute6" ]; then
            [ -n "$ancienne6" ] && lxc config device remove "$CONTENEUR" ssh-nethack6 >/dev/null
            lxc config device add "$CONTENEUR" ssh-nethack6 proxy \
                listen="$ecoute6" connect="tcp:[::1]:22" >/dev/null
        fi
        info "[::]:$PORT_SSH (hôte, IPv6) → [::1]:22 (SSH du conteneur)"
    elif [ -n "$ancienne6" ]; then
        lxc config device remove "$CONTENEUR" ssh-nethack6 >/dev/null
        info "Proxy IPv6 séparé retiré"
    fi
    suivre_adresse_hote

    etape "Installation dans le conteneur"
    lxc file push "$SCRIPT" "$CONTENEUR/root/install-serveur-nethack.sh" --mode=0755
    lxc exec "$CONTENEUR" -- /root/install-serveur-nethack.sh --conteneur

    sauvegardes_sur_hote

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
    if lxc exec "$CONTENEUR" -- env LANG=C.UTF-8 chroot --userspec="$COMPTE_JEU:$COMPTE_JEU" \
            "$C" "$NH/nethack" --version; then
        info "NetHack démarre dans le chroot."
    else
        alerte "Le test --version a échoué : tester à la main dans le conteneur :"
        alerte "LANG=C.UTF-8 chroot --userspec=$COMPTE_JEU:$COMPTE_JEU $C $NH/nethack -u test"
    fi

    mot_de_passe_util

    # Adresse à donner aux joueurs : celle d'écoute en mode NAT, sinon celle de
    # la route par défaut (hostname -I peut renvoyer lxdbr0 ou docker0 en premier)
    if [ -n "$nat" ]; then
        ip_hote=$ip_ecoute
    else
        ip_hote=${ADRESSE_HOTE:-$(adresse_hote)}
        [ -n "$ip_hote" ] || ip_hote=$(hostname -I | awk '{print $1}')
    fi

    # Test du chemin réel des joueurs : bannière SSH sur le port public (IPv4,
    # et IPv6 par ::1 s'il est servi), puis menu de dgamelaunch
    etape "Test de l'accès des joueurs"
    if [ "$(banniere_ssh "$ip_hote" "$PORT_SSH")" = "SSH-2.0" ]; then
        info "SSH répond sur $ip_hote:$PORT_SSH"
    else
        alerte "Pas de réponse SSH sur $ip_hote:$PORT_SSH : vérifier le pare-feu et « lxc config device show $CONTENEUR »."
    fi
    if [ "$IPV6" = oui ] || [ -z "$nat" ]; then
        if [ "$(banniere_ssh ::1 "$PORT_SSH")" = "SSH-2.0" ]; then
            info "SSH répond en IPv6 ([::1]:$PORT_SSH)"
        else
            alerte "Pas de réponse SSH en IPv6 sur [::1]:$PORT_SSH."
        fi
    fi
    menu=$(lxc exec "$CONTENEUR" -- env TERM=xterm timeout 5 \
               script -qec "/opt/nethack/dgamelaunch -f $CONF" /dev/null </dev/null 2>/dev/null || true)
    if printf '%s' "$menu" | grep -aqF -e "$NOM_SERVEUR"; then
        info "dgamelaunch affiche son menu (« $NOM_SERVEUR »)"
    else
        alerte "dgamelaunch n'affiche pas son menu : tester « lxc exec $CONTENEUR -- /opt/nethack/dgamelaunch -f $CONF »."
    fi

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
        SRC_NH="$SRC_NH" SRC_DGL="$SRC_DGL" CONSTR_DGL="$CONSTR_DGL" \
        CORRECTIF_DGL="$CORRECTIF_DGL" bash -euo pipefail -s
}

paquets() {
    etape "Paquets"
    export DEBIAN_FRONTEND=noninteractive
    local complet=0 p manquants=()
    local liste=(git gcc make curl gettext libncurses-dev
                 build-essential autoconf automake bison flex
                 libsqlite3-dev sqlite3 openssh-server rsync unattended-upgrades)
    case "$MAJ_SYSTEME" in
        toujours) complet=1 ;;
        premiere) [ -e "$SYSTEME_INIT" ] || complet=1 ;;
        jamais)   ;;
        *)        erreur "MAJ_SYSTEME doit valoir premiere, toujours ou jamais." ;;
    esac
    for p in "${liste[@]}"; do
        dpkg-query -W -f='${Status}' "$p" 2>/dev/null | grep -q "ok installed" \
            || manquants+=("$p")
    done
    # Rien à installer ni à mettre à jour : pas d'apt-get update, le script
    # fonctionne alors aussi sans accès aux dépôts
    if [ "$complet" = 0 ] && [ "${#manquants[@]}" -eq 0 ]; then
        info "Paquets déjà installés (MAJ_SYSTEME=$MAJ_SYSTEME : pas de mise à jour complète)"
        return
    fi
    apt-get -o DPkg::Lock::Timeout=600 update
    if [ "$complet" = 1 ]; then
        apt-get -o DPkg::Lock::Timeout=600 full-upgrade -y
        mkdir -p "$(dirname "$SYSTEME_INIT")"
        date > "$SYSTEME_INIT"
    else
        info "Pas de mise à jour complète du système (MAJ_SYSTEME=$MAJ_SYSTEME)"
    fi
    if [ "${#manquants[@]}" -gt 0 ]; then
        # --no-upgrade : n'installe que les paquets manquants, sans toucher aux autres
        apt-get -o DPkg::Lock::Timeout=600 install -y --no-upgrade "${manquants[@]}"
    fi
}

utilisateur() {
    etape "Utilisateur $UTILISATEUR"
    if id "$UTILISATEUR" >/dev/null 2>&1; then
        info "Déjà présent"
    else
        adduser --disabled-password --gecos "" "$UTILISATEUR"
    fi
    etape "Compte du jeu $COMPTE_JEU"
    if id "$COMPTE_JEU" >/dev/null 2>&1; then
        info "Déjà présent"
    else
        useradd --system --user-group --no-create-home --home-dir /nonexistent \
            --shell /usr/sbin/nologin "$COMPTE_JEU"
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
    # Dépôt injoignable (réseau, GitHub) : la version locale est compilée,
    # pour que le script puisse être relancé hors ligne
    if ! git fetch origin "$BRANCHE"; then
        printf '\033[1;33m[!] Dépôt %s injoignable : pas de mise à jour, la version locale est compilée.\033[0m\n' \
            "$DEPOT" >&2
        git checkout "$BRANCHE" >/dev/null 2>&1 || true
    elif ! { git checkout "$BRANCHE" && git merge --ff-only "origin/$BRANCHE"; }; then
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
    if ! git -C "$SRC_DGL" pull --ff-only; then
        printf '\033[1;33m[!] Mise à jour de dgamelaunch impossible (modifications locales en conflit,\n    commits divergents ou réseau) : rien n'"'"'a été écrasé, la version locale est utilisée.\033[0m\n' >&2
    fi
else
    git clone "$DEPOT_DGL" "$SRC_DGL"
fi
EOF
    # Correctif de sécurité appliqué à une copie des sources (les sources
    # clonées ne sont pas modifiées) : voir correctif_dgamelaunch
    mkdir -p /opt/nethack
    correctif_dgamelaunch > "$CORRECTIF_DGL"
    chmod 644 "$CORRECTIF_DGL"
    # Recompilation si le binaire manque, ou si les sources ou le correctif ont
    # changé depuis la dernière compilation (empreinte notée dans $COMMIT_DGL)
    commit=$(runuser -u "$UTILISATEUR" -- git -C "$SRC_DGL" rev-parse HEAD)
    empreinte="$commit+$(sha256sum "$CORRECTIF_DGL" | cut -c1-16)"
    if [ -x /opt/nethack/dgamelaunch ] && [ -x "$CONSTR_DGL/dgamelaunch" ] \
            && [ "$(cat "$COMMIT_DGL" 2>/dev/null)" = "$empreinte" ]; then
        info "Déjà à jour (commit ${commit:0:12}, correctif des mots de passe appliqué)"
        return
    fi
    info "Compilation du commit ${commit:0:12} avec le correctif des mots de passe"
    en_util <<'EOF'
rsync -a --delete --exclude=.git "$SRC_DGL/" "$CONSTR_DGL/"
cd "$CONSTR_DGL"
if ! patch -p1 --dry-run --silent < "$CORRECTIF_DGL" >/dev/null; then
    echo "Le correctif des mots de passe ne s'applique plus aux sources de dgamelaunch" >&2
    echo "(code modifié en amont) : rien n'est installé, à adapter dans le script." >&2
    exit 1
fi
patch -p1 --silent < "$CORRECTIF_DGL"
[ -f Makefile ] && make distclean >/dev/null 2>&1 || true
./autogen.sh --enable-sqlite --enable-shmem \
    --with-config-file=/opt/nethack/dgamelaunch.conf \
    CFLAGS="-O2 -std=gnu17 -fcommon \
      -Wno-error=implicit-function-declaration \
      -Wno-error=incompatible-pointer-types \
      -Wno-error=int-conversion"
make
EOF
    # install remplace le fichier (unlink) : sans risque pour les sessions en cours
    install -o root -g root -m 4755 "$CONSTR_DGL/dgamelaunch" /opt/nethack/
    echo "$empreinte" > "$COMMIT_DGL"
}

# Correctif de dgamelaunch (mots de passe). Sans lui :
# - le hachage est crypt(mdp, mdp), en DES : 8 caractères utiles, et les deux
#   premiers caractères du mot de passe, servant de sel, sont stockés en clair ;
# - le haché stocké est accepté comme mot de passe : lire la base suffit pour
#   se connecter sous n'importe quel compte.
# Avec lui : yescrypt (méthode par défaut de libxcrypt) avec sel aléatoire,
# haché refusé comme mot de passe ; un ancien haché DES est vérifié une
# dernière fois puis remplacé à la connexion suivante du joueur.
correctif_dgamelaunch() {
    cat <<'FIN_CORRECTIF'
--- a/dgamelaunch.c
+++ b/dgamelaunch.c
@@ -1485,6 +1485,23 @@
   }
 }
 
+/* Hachage moderne (méthode par défaut de libxcrypt : yescrypt), sel aléatoire.
+   Remplace crypt(mdp, mdp) : DES, 8 caractères utiles, et les 2 premiers
+   caractères du mot de passe servaient de sel, stocké en clair. */
+static char *
+dgl_hash_password (const char *pw)
+{
+  char *salt, *h;
+
+  salt = crypt_gensalt (NULL, 0, NULL, 0);
+  if (salt == NULL)
+      return NULL;
+  h = crypt (pw, salt);
+  if (h == NULL || h[0] == '*')
+      return NULL;
+  return strdup (h);
+}
+
 int
 changepw (int dowrite)
 {
@@ -1553,8 +1570,15 @@
         error = 1;
     }
 
-  free(me->password);
-  me->password = strdup (crypt (buf, buf));
+  {
+    char *h = dgl_hash_password (buf);
+    if (h == NULL) {
+	debug_write("password hashing failed");
+	graceful_exit (113);
+    }
+    free(me->password);
+    me->password = h;
+  }
 
   if (dowrite)
     writefile (0);
@@ -2048,21 +2072,35 @@
 
 /* ************************************************************* */
 
+/* Vérifie le mot de passe. Le haché stocké n'est plus accepté comme mot de
+   passe (l'ancien code le permettait : lire la base suffisait pour se
+   connecter sous n'importe quel compte). Un ancien haché DES est encore
+   vérifié, puis remplacé aussitôt par un haché moderne. */
 int
 passwordgood (char *cpw)
 {
-  char *crypted;
+  char *crypted, *h;
   assert (me != NULL);
 
-  crypted = crypt (cpw, cpw);
-  if (crypted == NULL)
+  if (me->password == NULL || me->password[0] == '\0')
       return 0;
-  if (!strncmp (crypted, me->password, DGL_PASSWDLEN))
-    return 1;
-  if (!strncmp (cpw, me->password, DGL_PASSWDLEN))
-    return 1;
 
-  return 0;
+  if (me->password[0] == '$') {
+      crypted = crypt (cpw, me->password);
+      return (crypted != NULL && crypted[0] != '*'
+	      && !strcmp (crypted, me->password));
+  }
+
+  crypted = crypt (cpw, cpw);
+  if (crypted == NULL || crypted[0] == '*' || strcmp (crypted, me->password))
+      return 0;
+  h = dgl_hash_password (cpw);
+  if (h != NULL) {
+      free (me->password);
+      me->password = h;
+      writefile (0);
+  }
+  return 1;
 }
 
 /* ************************************************************* */
FIN_CORRECTIF
}

creer_chroot() {
    etape "Chroot $C"
    cd "$CONSTR_DGL"      # contient le binaire compilé, utilisé par dgl-create-chroot
    # Copie adaptée du script d'origine, générée hors du dépôt de $UTILISATEUR
    # (variables modifiées uniquement dans l'en-tête, jusqu'à « END OF CONFIG »).
    # Il doit être lancé depuis le dossier des sources (il utilise pwd).
    local script_chroot
    script_chroot=$(mktemp /tmp/dgl-create-chroot.XXXXXX)
    rm -f "$SRC_DGL/dgl-create-chroot.nh500"    # laissé là par les versions précédentes
    sed -e "1,/END OF CONFIG/{
            s|^CHROOT=.*|CHROOT=\"$C/\"|
            s|^USRGRP=.*|USRGRP=\"$COMPTE_JEU:$COMPTE_JEU\"|
            s|^#\?NETHACKBIN=.*|NETHACKBIN=\"$NH/nethack\"|
            s|^#\?NH_PLAYGROUND_FIXED=.*|NH_PLAYGROUND_FIXED=\"\"|
            s|^NHSUBDIR=.*|NHSUBDIR=\"$NH/\"|
            s|^NH_VAR_PLAYGROUND=.*|NH_VAR_PLAYGROUND=\"$NH/\"|
        }" \
        -e 's|^mknod urandom c 1 9$|: # urandom fourni par LXD (unix-char)|' \
        -e 's|^mkdir "\$CHROOT/\$NHSUBDIR"$|mkdir -p "$CHROOT/$NHSUBDIR"|' \
        dgl-create-chroot > "$script_chroot"
    sh "$script_chroot"
    rm -f "$script_chroot"

    # Compléments pour NetHack 5.0 : le jeu, sans les fichiers des parties
    # d'essai faites hors du chroot ; fichiers variables neufs
    mkdir -p "$C$NH/save"
    rsync -a "${EXCLUS_JEU[@]}" "$NH/" "$C$NH/"
    (cd "$C$NH" && touch record logfile xlogfile livelog perm)
    nettoyer_binaire_dgl
    manifeste_jeu > "$MANIFESTE"
    mkdir -p "$C"/dgldir/{inprogress-nh500,userdata} "$C/mail"
}

# Restes de dgl-create-chroot, prévu pour NetHack 3.4.3 et un dgamelaunch
# lancé depuis le chroot : dossiers vides inutilisés (enregistrements et
# options sont dans userdata/<pseudo>), options par défaut 3.4.3 et copie du
# binaire dgamelaunch (SSH lance /opt/nethack/dgamelaunch). Seul ce qui est
# vide ou inutilisé par la configuration est supprimé.
nettoyer_restes_dgl() {
    local d f
    for d in inprogress-nh343 ttyrec rcfiles; do
        [ -d "$C/dgldir/$d" ] && rmdir --ignore-fail-on-non-empty "$C/dgldir/$d"
    done
    if ! grep -q 'nh343' "$CONF" 2>/dev/null; then
        rm -f "$C/dgl-default-rcfile.nh343"
    fi
    if ! grep -q '^[^#]*"/dgamelaunch' "$CONF" 2>/dev/null; then
        [ -L "$C/dgamelaunch" ] && rm -f "$C/dgamelaunch"
        for f in "$C"/dgamelaunch.[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]; do
            [ -f "$f" ] && rm -f "$f"
        done
    fi
    return 0
}

# dgl-create-chroot copie le binaire sous nethack.AAAAMMJJ avec un lien
# « nethack » vers lui ; rsync remplace ensuite ce lien par le vrai binaire et
# la copie datée ne sert plus
nettoyer_binaire_dgl() {
    local f
    [ -f "$C$NH/nethack" ] && [ ! -L "$C$NH/nethack" ] || return 0
    for f in "$C$NH"/nethack.[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]; do
        [ -f "$f" ] || continue
        rm -f "$f"
        info "Ancienne copie du binaire supprimée : ${f##*/}"
    done
}

# Liste triée des fichiers du jeu installés (chemins relatifs au dossier du jeu)
manifeste_jeu() {
    rsync -r --list-only "${EXCLUS_JEU[@]}" --exclude=/sysconf "$NH/" \
        | awk '$NF != "." { print $NF }' | LC_ALL=C sort
}

# Bibliothèques et fichiers système du chroot : le jeu étant compilé avec les
# bibliothèques du conteneur, le chroot doit avoir les mêmes, correctifs de
# sécurité compris. Le script /usr/local/sbin/nethack-chroot-systeme les
# recopie ; il est lancé ici et, par un crochet APT, après chaque mise à jour
# de paquets (unattended-upgrades compris). rsync remplace chaque fichier par
# renommage, sans risque pour les parties en cours ; les fichiers inchangés
# ne sont pas recopiés.
copier_systeme_chroot() {
    etape "Fichiers système du chroot"
    {
        cat <<EOF
#!/bin/bash
# Généré par install-serveur-nethack.sh : ne pas modifier, relancer le script.
# Recopie dans le chroot les bibliothèques et fichiers système du conteneur.
set -euo pipefail
C="$C"
NH="$NH"
COMPTE_JEU="$COMPTE_JEU"
UTILISATEUR="$UTILISATEUR"
UID_JEU="$UID_JEU"
EOF
        cat <<'EOF'
alerte() { printf '[!] nethack-chroot-systeme : %s\n' "$*" >&2; }
jeu="$C$NH/nethack"
[ -f "$jeu" ] || exit 0          # chroot pas encore créé

# Bibliothèques : celles listées par ldd pour le jeu du chroot (chargeur
# dynamique compris), plus libgcc_s, que ldd ne montre pas car la glibc la
# charge à l'exécution (pile d'appels en cas de plantage, annulation de
# thread). Son dossier dépend de l'architecture : x86_64-linux-gnu…
multiarch=$(gcc -dumpmachine 2>/dev/null || dpkg-architecture -qDEB_HOST_MULTIARCH)
for lib in $(ldd "$jeu" | grep -o '/[^ ]*' | sort -u) \
           "/lib/$multiarch/libgcc_s.so.1" "/usr/lib/$multiarch/libgcc_s.so.1"; do
    [ -e "$lib" ] || continue
    mkdir -p "$C$(dirname "$lib")"
    rsync -aL "$lib" "$C$lib"
done
if ! ls "$C"/lib/"$multiarch"/libgcc_s.so.1 "$C"/usr/lib/"$multiarch"/libgcc_s.so.1 \
        >/dev/null 2>&1; then
    alerte "libgcc_s.so.1 introuvable pour $multiarch : NetHack risque de planter dans le chroot."
    alerte "Chercher son chemin avec « ldconfig -p | grep libgcc_s » et la copier dans $C."
fi

mkdir -p "$C/usr/share/terminfo" "$C/usr/lib/locale" "$C/etc" "$C/dev"
rsync -a /usr/share/terminfo/ "$C/usr/share/terminfo/"
if [ -d /lib/terminfo ]; then
    mkdir -p "$C/lib/terminfo"
    rsync -a /lib/terminfo/ "$C/lib/terminfo/"
fi
rsync -a /usr/lib/locale/ "$C/usr/lib/locale/"
rsync -aL /etc/localtime "$C/etc/localtime"
grep -E "^(root|$COMPTE_JEU|$UTILISATEUR):" /etc/passwd > "$C/etc/passwd.nouveau"
grep -E "^(root|$COMPTE_JEU|$UTILISATEUR):" /etc/group  > "$C/etc/group.nouveau"
mv "$C/etc/passwd.nouveau" "$C/etc/passwd"
mv "$C/etc/group.nouveau" "$C/etc/group"
EOF
    } > /usr/local/sbin/nethack-chroot-systeme
    chmod 755 /usr/local/sbin/nethack-chroot-systeme
    cat > /etc/apt/apt.conf.d/90nethack-chroot <<'EOF'
// Généré par install-serveur-nethack.sh : après chaque installation ou mise
// à jour de paquets (unattended-upgrades compris), le chroot du serveur
// NetHack reçoit les mêmes bibliothèques que le conteneur.
DPkg::Post-Invoke { "if [ -x /usr/local/sbin/nethack-chroot-systeme ]; then /usr/local/sbin/nethack-chroot-systeme || true; fi"; };
EOF
    /usr/local/sbin/nethack-chroot-systeme
    info "Bibliothèques, terminfo, locales, fuseau horaire et comptes à jour."
    info "Recopiés aussi après chaque mise à jour de paquets (crochet APT 90nethack-chroot)."
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

# Champ $2 (id, email…) du compte dgamelaunch $1 (pseudo déjà validé : lettres
# et chiffres) ; vide si le compte n'existe pas. Les caractères non imprimables
# sont retirés : le courriel est saisi par le joueur et affiché à l'admin.
champ_compte_dgl() {
    sqlite3 "$C/dgldir/dgamelaunch.db" \
        "SELECT $2 FROM dglusers WHERE username = '$1';" 2>/dev/null \
        | head -n 1 | tr -cd '[:print:]'
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
    # dgamelaunch refuse les pseudos plus longs que maxnicklen (10 par défaut)
    # (dgamelaunch.conf n'existe pas encore à la première installation)
    maxnick=""
    if [ -f "$CONF" ]; then
        maxnick=$(sed -n 's/^maxnicklen *= *\([0-9]*\).*/\1/p' "$CONF" | head -n 1)
    fi
    [ "${#PSEUDO_WIZARD}" -le "${maxnick:-10}" ] \
        || erreur "PSEUDO_WIZARD dépasse ${maxnick:-10} caractères : ce compte ne pourrait pas être inscrit."
    # Même existant, le compte peut avoir été inscrit par quelqu'un d'autre
    # avant l'admin : il doit être confirmé une fois dans un terminal. Une
    # empreinte de son identifiant et de son haché de mot de passe est retenue
    # (SQLite peut réattribuer l'identifiant d'un compte supprimé) : si le compte
    # est réinscrit ou son mot de passe changé, la confirmation est redemandée.
    local id courriel empreinte accorde=0
    id=$(champ_compte_dgl "$PSEUDO_WIZARD" id)
    empreinte=$(printf '%s:%s' "$id" "$(champ_compte_dgl "$PSEUDO_WIZARD" password)" \
                    | sha256sum | cut -c1-32)
    if [ -z "$id" ]; then
        alerte "Le compte « $PSEUDO_WIZARD » n'existe pas encore : mode debug désactivé."
        alerte "Inscrivez-le vous-même (ssh -p $PORT_SSH nethack@…), puis relancez le script."
    elif [ "$(cat "$WIZARD_CONFIRME" 2>/dev/null)" = "$PSEUDO_WIZARD:$empreinte" ]; then
        accorde=1
    else
        if grep -q "^$PSEUDO_WIZARD:" "$WIZARD_CONFIRME" 2>/dev/null; then
            alerte "Le compte « $PSEUDO_WIZARD » a changé depuis sa confirmation (mot de passe"
            alerte "modifié, ou compte supprimé puis réinscrit) : nouvelle confirmation nécessaire."
        fi
        courriel=$(champ_compte_dgl "$PSEUDO_WIZARD" email)
        alerte "Le compte « $PSEUDO_WIZARD » existe (n° $id, courriel : ${courriel:-aucun})."
        alerte "Vérifiez que c'est bien vous qui l'avez inscrit avant de lui donner le mode debug."
        if confirmer "Ce compte est-il le vôtre ?"; then
            echo "$PSEUDO_WIZARD:$empreinte" > "$WIZARD_CONFIRME"
            accorde=1
        elif [ -t 0 ]; then
            alerte "Mode debug refusé. Si ce compte n'est pas le vôtre, supprimez-le :"
            alerte "  lxc exec $CONTENEUR -- sqlite3 $C/dgldir/dgamelaunch.db \"DELETE FROM dglusers WHERE id = $id;\""
        else
            alerte "Mode debug non accordé pour l'instant."
        fi
    fi
    if [ "$accorde" = 1 ]; then
        regler_cle "$S" WIZARDS "$PSEUDO_WIZARD"
        info "Mode debug accordé au compte confirmé « $PSEUDO_WIZARD » (n° $id)"
    else
        regler_cle "$S" WIZARDS "$WIZARD_AUCUN"
    fi
    regler_cle "$S" CHECK_PLNAME 1
    regler_cle "$S" DUMPLOGFILE /dgldir/userdata/%n/dumplog/%t.txt
    regler_cle "$S" PANICTRACE_GDB 0
    sed -i -e 's|^GDBPATH=|#GDBPATH=|' -e 's|^GREPPATH=|#GREPPATH=|' "$S"
}

# Demande une confirmation ; « non » sans terminal interactif (dit pourquoi)
confirmer() {
    if [ ! -t 0 ]; then
        alerte "Question « $1 » : pas de terminal interactif, réponse « non »."
        alerte "Relancez le script dans un terminal, sans tube (voir README, Utilisation)."
        return 1
    fi
    local reponse
    read -rp "    $1 (o/N) : " reponse || return 1
    case "$reponse" in o|O|oui|OUI) return 0 ;; *) return 1 ;; esac
}

# Version complète des sources (MAJEURE.MINEURE.PATCHLEVEL.EDITLEVEL) : un
# changement rend les sauvegardes et les os (bones) existants inutilisables
version_sources_nh() {
    awk '/^#define[ \t]+(VERSION_MAJOR|VERSION_MINOR|PATCHLEVEL|EDITLEVEL)[ \t]/ {
             v = v (v == "" ? "" : ".") $3 } END { print v }' \
        "$SRC_NH/include/patchlevel.h"
}

# Parties en cours : fichiers de dgamelaunch dont le processus (PID en
# première ligne) existe encore
parties_en_cours() {
    local f pid n=0
    for f in "$C"/dgldir/inprogress-nh500/*; do
        [ -f "$f" ] || continue
        pid=$(head -n 1 "$f" 2>/dev/null || true)
        case "$pid" in ''|*[!0-9]*) continue ;; esac
        kill -0 "$pid" 2>/dev/null && n=$((n + 1))
    done
    echo "$n"
}

# Vérifie qu'on peut mettre le jeu à jour dans le chroot sans gêner les
# joueurs ; met de côté les sauvegardes devenues incompatibles si l'admin
# l'accepte. Code de retour non nul : mise à jour reportée.
verifier_mise_a_jour() {
    local n ancienne nouvelle J="$C$NH" archive
    n=$(parties_en_cours)
    if [ "$n" -gt 0 ]; then
        alerte "$n partie(s) en cours : remplacer le jeu maintenant peut les perturber."
        if ! confirmer "Mettre à jour quand même ?"; then
            alerte "Mise à jour du jeu reportée : relancez le script quand plus personne ne joue."
            return 1
        fi
    fi

    nouvelle=$(version_sources_nh)
    ancienne=$(cat "$VERSION_NH" 2>/dev/null || echo "$nouvelle")
    if [ "$ancienne" != "$nouvelle" ] \
            && [ -n "$(ls -A "$J/save" 2>/dev/null)$(ls "$J"/bon* 2>/dev/null)" ]; then
        alerte "Version du jeu : $ancienne → $nouvelle. Les sauvegardes et les os"
        alerte "existants ne pourront plus être chargés par la nouvelle version."
        if ! confirmer "Mettre à jour et archiver les sauvegardes actuelles ?"; then
            alerte "Mise à jour du jeu reportée : version $ancienne conservée dans le chroot."
            return 1
        fi
        archive="$J/archives/version-$ancienne-$(date +%Y%m%d-%H%M%S)"
        mkdir -p "$archive"
        [ -d "$J/save" ] && find "$J/save" -mindepth 1 -maxdepth 1 -exec mv -t "$archive" {} +
        find "$J" -maxdepth 1 -name 'bon*' -exec mv -t "$archive" {} +
        info "Sauvegardes et os archivés dans $archive"
    fi
    return 0
}

# Fichiers modifiables par les parties (le reste du jeu appartient à root)
est_fichier_variable() {
    case "$1" in save|record|logfile|xlogfile|livelog|perm) return 0 ;; esac
    return 1
}

# Fichiers créés par NetHack pendant les parties : niveaux (<uid><pseudo>.<n>,
# alock.<n>), os (bon*), verrous (*_lock) et journal des plantages
est_fichier_de_partie() {
    case "$1" in *.[0-9]|*.[0-9][0-9]|*.[0-9][0-9][0-9]|bon*|*_lock|paniclog) return 0 ;; esac
    return 1
}

# Propriétaires du chroot. Les parties tournent sous $COMPTE_JEU, un compte
# système sans connexion distinct du compte d'administration $UTILISATEUR.
# Binaire, données et sysconf appartiennent à root : une partie (même via une
# faille de NetHack) ne peut ni les modifier ni se donner le mode debug.
# Le dossier du jeu a le sticky bit : le compte du jeu y crée ses fichiers de
# niveaux et ses os, mais ne peut pas supprimer ni remplacer ceux de root.
proprietaires_chroot() {
    etape "Propriétaires des fichiers du chroot"
    local J="$C$NH" ancien nouveau f nom
    nouveau=$(id -u "$COMPTE_JEU")
    # Versions précédentes du script : parties sous $UTILISATEUR
    ancien=$(cat "$UID_JEU" 2>/dev/null || id -u "$UTILISATEUR")
    JEU="$COMPTE_JEU"
    if [ "$ancien" != "$nouveau" ]; then
        if [ "$(parties_en_cours)" -gt 0 ]; then
            # Une partie en cours écrirait sa sauvegarde sous l'ancien UID
            JEU=$(getent passwd "$ancien" | cut -d: -f1)
            [ -n "$JEU" ] || erreur "Aucun compte pour l'UID $ancien."
            alerte "Parties en cours : passage au compte $COMPTE_JEU reporté (parties sous $JEU)."
        else
            # Les sauvegardes s'appellent <uid><pseudo> : renommées pour le nouvel UID
            for f in "$J"/save/"$ancien"*; do
                [ -e "$f" ] || continue
                nom=${f##*/}
                mv -n "$f" "$J/save/$nouveau${nom#"$ancien"}"
            done
            info "Parties désormais sous $COMPTE_JEU (UID $nouveau), sauvegardes renommées"
        fi
    fi

    chown root:root "$C/home" "$C$HOME_UTIL"
    chmod 755 "$C/home" "$C$HOME_UTIL"
    chown root:"$JEU" "$J"
    chmod 1775 "$J"
    for f in "$J"/* "$J"/.[!.]*; do
        [ -e "$f" ] || [ -L "$f" ] || continue
        nom=${f##*/}
        if [ "$nom" = archives ]; then
            chown -R root:root "$f"
        elif est_fichier_variable "$nom" || est_fichier_de_partie "$nom"; then
            chown -R "$JEU:$JEU" "$f"        # sauvegardes, scores, niveaux, os…
        else
            chown -R -h root:root "$f"       # fichier installé ou ajouté par l'admin
            chmod -R go-w "$f"
        fi
    done
    chmod 644 "$J/sysconf"
    chown -R "$JEU:$JEU" "$C/dgldir" "$C/mail"

    [ "$JEU" = "$COMPTE_JEU" ] && echo "$nouveau" > "$UID_JEU"
    info "Jeu en lecture seule (root), parties sous $JEU"
}

mettre_a_jour_chroot() {
    etape "Mise à jour du jeu dans le chroot existant"
    local nouveau f
    rsync -a "${EXCLUS_JEU[@]}" --exclude=/sysconf "$NH/" "$C$NH/"
    # Fichiers d'une version précédente qui n'existent plus : supprimés, et
    # seulement eux (pas de rsync --delete, qui effacerait aussi les fichiers
    # des parties et ceux ajoutés par l'admin)
    nouveau=$(manifeste_jeu)
    if [ -f "$MANIFESTE" ]; then
        LC_ALL=C comm -23 "$MANIFESTE" <(printf '%s\n' "$nouveau") | LC_ALL=C sort -r \
            | while IFS= read -r f; do
                  [ -n "$f" ] || continue
                  if [ -d "$C$NH/$f" ] && [ ! -L "$C$NH/$f" ]; then
                      rmdir --ignore-fail-on-non-empty "$C$NH/$f"
                  elif [ -e "$C$NH/$f" ] || [ -L "$C$NH/$f" ]; then
                      rm -f "$C$NH/$f"
                      info "Supprimé (absent de la nouvelle version) : $f"
                  fi
              done
    fi
    printf '%s\n' "$nouveau" > "$MANIFESTE"
    nettoyer_binaire_dgl
    info "Comptes, parties et sysconf conservés (réglages du script réappliqués ensuite)."
}

configurer_dgamelaunch() {
    etape "Configuration de dgamelaunch"
    if [ -f "$CONF" ]; then
        info "$CONF existe déjà : conservé, seuls les réglages du script sont réappliqués"
    else
        # Création à partir de l'exemple (une seule fois)
        cd "$CONSTR_DGL"
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
    case "$INSCRIPTIONS" in
        oui) inscr=yes ;;
        non) inscr=no ;;
        *)   erreur "INSCRIPTIONS doit valoir oui ou non." ;;
    esac
    U=$(id -u "$JEU"); G=$(id -g "$JEU")
    sed -i -e "s|^chroot_path = .*|chroot_path = \"$(echapper "$C")/\"|" \
           -e "s|^shed_uid = .*|shed_uid = $U|" \
           -e "s|^shed_gid = .*|shed_gid = $G|" \
           -e "s|^maxusers = .*|maxusers = $MAX_JOUEURS|" \
           -e "s|^allow_new_nicks = .*|allow_new_nicks = $inscr|" \
           -e "s|\"\\\$SERVERID\" = \"[^\"]*\"|\"\$SERVERID\" = \"\$ATTR(14)$(echapper "$NOM_SERVEUR")\$ATTR()\"|" \
        "$CONF"
    for motif in '^chroot_path = ' '^shed_uid = ' '^shed_gid = ' '^maxusers = ' \
                 '^allow_new_nicks = ' '"\$SERVERID" = '; do
        grep -q "$motif" "$CONF" || alerte "Ligne « $motif » absente de $CONF : réglage non appliqué"
    done
    info "maxusers = $MAX_JOUEURS, inscriptions : $INSCRIPTIONS, nom du serveur : $NOM_SERVEUR"

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
# Généré par install-serveur-nethack.sh. Lu avant les autres fichiers de ce
# dossier : la première valeur lue l'emporte.

# Le port est public : connexion par mot de passe interdite à tous les
# comptes sauf nethack (plus bas), sans compter sur le réglage de l'image
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitEmptyPasswords no
PermitRootLogin prohibit-password

# Connexions arrivant par la boucle locale (proxy LXD sans NAT) : toutes
# semblent venir de la même adresse, qui ne doit donc pas être pénalisée,
# sinon un seul client fautif bloquerait tous les joueurs.
PerSourcePenaltyExemptList 127.0.0.1/32,::1/128

# Connexions non authentifiées : au plus 10 par adresse (un seul client ne
# peut plus occuper toutes les places ; les joueurs IPv6, qui arrivent tous
# par ::1 en mode NAT, partagent ce quota), 50 à 150 au total, 30 s pour
# s'authentifier (immédiat pour le compte nethack, sans mot de passe).
PerSourceMaxStartups 10
MaxStartups 50:30:150
LoginGraceTime 30

Match User nethack
    PasswordAuthentication yes
    PermitEmptyPasswords yes
    KbdInteractiveAuthentication no
    PermitTTY yes
    # Aucune redirection (TCP, sockets Unix, agent, X11) ni ~/.ssh/rc
    DisableForwarding yes
    PermitTunnel no
    PermitUserRC no
    ForceCommand /opt/nethack/dgamelaunch -f $CONF
EOF
    sshd -t
    systemctl restart ssh
}

# Entretien quotidien (timer systemd) : sauvegarde des comptes et des parties,
# compression et suppression des vieux enregistrements de parties (ttyrec)
installer_entretien() {
    etape "Entretien quotidien (sauvegardes, enregistrements de parties)"
    case "$SAUVEGARDES_JOURS$TTYREC_JOURS" in
        *[!0-9]*) erreur "SAUVEGARDES_JOURS et TTYREC_JOURS doivent être des nombres." ;;
    esac
    [ "$SAUVEGARDES_JOURS" -ge 1 ] || erreur "SAUVEGARDES_JOURS doit valoir au moins 1."
    {
        cat <<EOF
#!/bin/bash
# Généré par install-serveur-nethack.sh : ne pas modifier, relancer le script.
set -euo pipefail
C="$C"
NH="${NH#/}"
CONF="$CONF"
DEST="$SAUVEGARDES"
SAUVEGARDES_JOURS=$SAUVEGARDES_JOURS
TTYREC_JOURS=$TTYREC_JOURS
EOF
        cat <<'EOF'
umask 077
mkdir -p "$DEST"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# Sauvegarde : base des comptes (copie cohérente même en cours d'écriture),
# sauvegardes, scores et journaux du jeu, sysconf, configuration et réglages
# des joueurs. Les enregistrements de parties (volumineux) n'y sont pas.
sqlite3 "$C/dgldir/dgamelaunch.db" ".backup '$tmp/dgamelaunch.db'"
cp "$CONF" "$tmp/"
elements=(dgldir)
for f in save record logfile xlogfile livelog sysconf archives; do
    if [ -e "$C/$NH/$f" ]; then elements+=("$NH/$f"); fi
done
archive="$DEST/nethack-$(date +%Y%m%d-%H%M%S).tar.gz"
tar -C "$C" --exclude=dgldir/dgamelaunch.db --exclude='dgldir/userdata/*/ttyrec' \
    --exclude='dgldir/inprogress-*' -czf "$archive.partiel" "${elements[@]}" \
    -C "$tmp" dgamelaunch.db "$(basename "$CONF")"
mv "$archive.partiel" "$archive"
find "$DEST" -maxdepth 1 -name 'nethack-*.tar.gz' -mtime +"$SAUVEGARDES_JOURS" -delete

# Enregistrements de parties : compressés au bout d'un jour, sauf ceux des
# parties en cours (même inactives depuis plus d'un jour, elles y écrivent
# encore : les compresser perdrait la suite). dgamelaunch nomme le fichier de
# partie en cours « pseudo:fichier.ttyrec ». Supprimés au bout de TTYREC_JOURS.
declare -A en_cours=()
for f in "$C"/dgldir/inprogress-*/*; do
    [ -f "$f" ] || continue
    nom=${f##*/}
    en_cours["$C/dgldir/userdata/${nom%%:*}/ttyrec/${nom#*:}"]=1
done
find "$C/dgldir/userdata" -path '*/ttyrec/*' -type f -name '*.ttyrec' -mtime +0 -print0 \
    | while IFS= read -r -d '' t; do
          [ -n "${en_cours[$t]:-}" ] || gzip -q "$t"
      done
if [ "$TTYREC_JOURS" -gt 0 ]; then
    find "$C/dgldir/userdata" -path '*/ttyrec/*' -type f -mtime +"$TTYREC_JOURS" -delete
fi
echo "Sauvegarde : $archive ($(du -h "$archive" | cut -f1))"

# Bilan : les inscriptions étant ouvertes à tous, une vague de comptes peut
# remplir la base et le disque. Alerte dans le journal au-delà de 90 %.
comptes=$(sqlite3 "$C/dgldir/dgamelaunch.db" "SELECT COUNT(*) FROM dglusers;")
echo "Comptes : $comptes ; données des joueurs : $(du -sh "$C/dgldir" | cut -f1)"
occupe=$(df --output=pcent "$C" | tail -n 1 | tr -dc '0-9')
if [ "$occupe" -ge 90 ]; then
    echo "ALERTE : disque occupé à $occupe % (INSCRIPTIONS=non pour fermer les inscriptions)" >&2
fi
EOF
    } > /usr/local/sbin/nethack-entretien
    chmod 755 /usr/local/sbin/nethack-entretien

    cat > /etc/systemd/system/nethack-entretien.service <<EOF
[Unit]
Description=Entretien du serveur NetHack (sauvegardes, enregistrements de parties)

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/nethack-entretien
Nice=10
IOSchedulingClass=idle
EOF
    cat > /etc/systemd/system/nethack-entretien.timer <<EOF
[Unit]
Description=Entretien quotidien du serveur NetHack

[Timer]
OnCalendar=*-*-* 04:30:00
RandomizedDelaySec=15min
Persistent=true

[Install]
WantedBy=timers.target
EOF
    systemctl daemon-reload
    systemctl enable --now nethack-entretien.timer >/dev/null 2>&1
    info "Tous les jours vers 4 h 30 : sauvegarde dans $SAUVEGARDES ($SAUVEGARDES_JOURS jours gardés)"
    if [ "$TTYREC_JOURS" -gt 0 ]; then
        info "Enregistrements de parties compressés après 1 jour, supprimés après $TTYREC_JOURS jours"
    else
        info "Enregistrements de parties compressés après 1 jour, jamais supprimés"
    fi
}

conteneur() {
    paquets
    utilisateur
    compiler_nethack
    compiler_dgamelaunch
    if [ -e "$C/dgldir/dgamelaunch.db" ]; then
        if verifier_mise_a_jour; then
            mettre_a_jour_chroot
            version_sources_nh > "$VERSION_NH"
        fi
    else
        if [ -e "$C" ]; then
            # Chroot incomplet ou sans base de comptes : mis de côté, jamais supprimé
            sauvegarde="$C.sauvegarde-$(date +%Y%m%d-%H%M%S)"
            alerte "$C existe sans $C/dgldir/dgamelaunch.db : déplacé vers $sauvegarde"
            mv "$C" "$sauvegarde"
        fi
        creer_chroot
        version_sources_nh > "$VERSION_NH"
    fi
    copier_systeme_chroot
    proprietaires_chroot
    regler_sysconf
    configurer_dgamelaunch
    nettoyer_restes_dgl
    configurer_ssh
    installer_entretien
}

# =============================================================================
case "${1:-}" in
    --conteneur) conteneur ;;
    "")          hote ;;
    *)           erreur "Option inconnue : $1 (usage : sudo $0)" ;;
esac
