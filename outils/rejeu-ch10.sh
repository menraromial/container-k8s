#!/usr/bin/env bash
# Chapitre 10 : overlayfs. Utilise « labo » et « cible ». Crée ses fichiers dans /labo (volume labo),
# ne modifie cible que par des fichiers qu'il crée et retire lui-même (puis redémarre cible).
cd "$(dirname "$0")"; O=$PWD/out/ch10; rm -rf $O; mkdir -p $O
L() { local n=$1; shift; echo "### $n : $*"; docker exec labo bash -c "$*" > $O/$n.txt 2>&1; head -c 20000 $O/$n.txt; }
H() { local n=$1; shift; echo "### $n : $*"; bash -c "$*" > $O/$n.txt 2>&1; head -c 20000 $O/$n.txt; }
docker exec labo bash -c 'umount /labo/couches/fusion 2>/dev/null; umount /labo/nginx-fusion 2>/dev/null; rm -rf /labo/couches /labo/nginx /labo/nginx-couches /labo/nginx-fusion /labo/nginx-haut /labo/nginx-travail /labo/couches-nginx.txt'
UP=$(docker inspect cible --format '{{.GraphDriver.Data.UpperDir}}'); MG=$(docker inspect cible --format '{{.GraphDriver.Data.MergedDir}}')
# garde-fou : sans ces chemins, /proc/1/root désignerait la racine du poste et find tournerait sans fin
case "$UP" in /var/lib/docker/overlay2/*/diff) ;; *) echo "UpperDir inattendu : '$UP'"; exit 1;; esac
case "$MG" in /var/lib/docker/overlay2/*/merged) ;; *) echo "MergedDir inattendu : '$MG'"; exit 1;; esac

H 01-driver "docker info --format '{{.Driver}}'; docker info --format '{{json .DriverStatus}}'"
H 02-graphdriver "docker inspect cible --format '{{json .GraphDriver}}' | python3 -m json.tool"
L 03-findmnt "nsenter --target 1 --mount findmnt -n -o OPTIONS $MG | tr ',' '\n' | cut -c1-140 | head -8"
L 04-upper-avant "cd /proc/1/root$UP && timeout 10 find . -maxdepth 5 | sort | head -30"
H 05-docker-ecrit "docker exec cible sh -c 'echo bonjour > /tmp/note.txt; rm /etc/nginx/conf.d/default.conf'; docker diff cible"
L 06-upper-apres "cd /proc/1/root$UP && timeout 10 find . -maxdepth 5 | sort | head -30; ls -l etc/nginx/conf.d/; cat tmp/note.txt"
H 07-ps-s "docker ps -s --filter name=^cible\$ --format 'table {{.Names}}\t{{.Size}}'"

# overlay à la main
L 09-prepare "mkdir -p /labo/couches/{bas,haut,travail,fusion} && cd /labo/couches && echo 'version de base' > bas/lisez-moi.txt && echo 'config d origine' > bas/config.txt && mkdir bas/dossier && echo a > bas/dossier/a.txt && echo b > bas/dossier/b.txt && tree bas"
L 10-monte "cd /labo/couches && mount -t overlay overlay -o lowerdir=bas,upperdir=haut,workdir=travail fusion && findmnt fusion -o TARGET,FSTYPE | tail -1 && ls fusion && echo \"fichiers dans haut : \$(ls haut | wc -l)\""
L 11-lire "cd /labo/couches && cat fusion/lisez-moi.txt && echo \"fichiers dans haut : \$(ls -A haut | wc -l)\""
L 12-modifier "cd /labo/couches && echo 'modifié' >> fusion/config.txt && cat fusion/config.txt && echo --- && cat bas/config.txt && echo --- && ls -l haut"
L 13-creer "cd /labo/couches && echo nouveau > fusion/nouveau.txt && echo haut : && ls haut && echo bas : && ls bas"
L 14-supprimer "cd /labo/couches && rm fusion/lisez-moi.txt && ls fusion && ls -l haut/lisez-moi.txt && ls bas"
L 15-dossier "cd /labo/couches && rm -r fusion/dossier && mkdir fusion/dossier && echo c > fusion/dossier/c.txt && ls fusion/dossier && ls -la haut/dossier && ls bas/dossier && getfattr -d -m - haut/dossier haut/lisez-moi.txt 2>/dev/null"
L 16-demonte "cd /labo/couches && umount fusion && echo \"fusion après démontage : \$(ls fusion | wc -l) fichier\" && echo haut : && ls -l haut && echo bas : && ls bas"
# copie à l'écriture d'un gros fichier
L 17-gros "cd /labo/couches && mkdir bas2 haut2 trav2 fus2 && dd if=/dev/zero of=bas2/gros.bin bs=1M count=500 status=none && mount -t overlay overlay -o lowerdir=bas2,upperdir=haut2,workdir=trav2 fus2 && du -sh haut2 && time (echo x >> fus2/gros.bin) && du -sh haut2 && time (echo y >> fus2/gros.bin) && umount fus2 && rm -rf bas2 haut2 trav2 fus2"
# une image nginx en couches, montée à la main
L 18-nginx-couches "skopeo copy -q docker://nginx:1.30-alpine oci:/labo/nginx:1.30-alpine && cd /labo/nginx && M=\$(jq -r '.manifests[0].digest' index.json | cut -d: -f2) && jq -r '.layers[].digest' blobs/sha256/\$M | cut -d: -f2 > /labo/couches-nginx.txt && i=0; for d in \$(cat /labo/couches-nginx.txt); do i=\$((i+1)); mkdir -p /labo/nginx-couches/\$i; tar -xzf blobs/sha256/\$d -C /labo/nginx-couches/\$i; echo \"couche \$i : \$(du -sh /labo/nginx-couches/\$i | cut -f1)\"; done"
L 19-nginx-monte "cd /labo && mkdir -p nginx-haut nginx-travail nginx-fusion && L=\$(ls nginx-couches | sort -rn | sed 's|^|nginx-couches/|' | paste -sd:) && echo \"lowerdir=\$L\" && mount -t overlay overlay -o lowerdir=\$L,upperdir=nginx-haut,workdir=nginx-travail nginx-fusion && ls nginx-fusion && cat nginx-fusion/etc/alpine-release && chroot nginx-fusion nginx -v; umount nginx-fusion"
L 20-overlay-sur-overlay "mkdir -p /tmp/o/bas /tmp/o/haut /tmp/o/travail /tmp/o/fusion; mount -t overlay overlay -o lowerdir=/tmp/o/bas,upperdir=/tmp/o/haut,workdir=/tmp/o/travail /tmp/o/fusion; echo \"code=\$?\"; df -T /tmp | tail -1; rm -rf /tmp/o"
# remise en état de cible
H 21-remise "docker exec cible rm -f /tmp/note.txt; docker restart cible >/dev/null; docker diff cible | head -5; echo fin"
