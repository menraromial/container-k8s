#!/usr/bin/env bash
# Chapitre 3 : les images. Ne supprime que ses propres objets (conteneur « registre », fichiers dans ./out/ch03)
cd "$(dirname "$0")"; O=out/ch03; rm -rf $O; mkdir -p $O; T=$O/travail; mkdir -p $T
run() { local n=$1; shift; echo "### $n : $*"; bash -c "$*" > $O/$n.txt 2>&1; cat $O/$n.txt; }
docker rm -f registre >/dev/null 2>&1
run 01-pull-redis "docker pull redis:8.8-alpine"
run 02-pull-again "docker pull redis:8.8-alpine"
run 03-ls "docker image ls --format 'table {{.Repository}}\t{{.Tag}}\t{{.ID}}\t{{.Size}}' | grep -E 'REPOSITORY|^(nginx|redis|alpine|python) '"
run 04-history "docker image history nginx:1.30-alpine"
run 05-inspect-config "docker image inspect nginx:1.30-alpine --format 'Entrypoint={{json .Config.Entrypoint}}
Cmd={{json .Config.Cmd}}
Ports={{json .Config.ExposedPorts}}
Env={{json .Config.Env}}
StopSignal={{.Config.StopSignal}}'"
run 06-layers "docker image inspect nginx:1.30-alpine --format '{{range .RootFS.Layers}}{{println .}}{{end}}'; echo ---; docker image inspect redis:8.8-alpine --format '{{range .RootFS.Layers}}{{println .}}{{end}}'; echo ---; docker image inspect alpine:3.24 --format '{{range .RootFS.Layers}}{{println .}}{{end}}'"
run 07-digests "docker image inspect nginx:1.30-alpine --format '{{json .RepoDigests}}'; docker image inspect nginx:1.30-alpine --format '{{.Id}}'"
run 08-imagetools "docker buildx imagetools inspect nginx:1.30-alpine"
run 09-raw-index "docker buildx imagetools inspect --raw nginx:1.30-alpine | head -40"
run 10-pull-digest "D=\$(docker image inspect nginx:1.30-alpine --format '{{index .RepoDigests 0}}'); echo \$D; docker pull \$D"
run 11-pause "docker pull registry.k8s.io/pause:3.10.2; docker image ls registry.k8s.io/pause"
run 12-save "docker save alpine:3.24 -o $T/alpine.tar; ls -l $T/alpine.tar; tar -tvf $T/alpine.tar"
run 13-index-json "mkdir -p $T/x; tar -xf $T/alpine.tar -C $T/x; python3 -m json.tool $T/x/index.json"
run 14-manifest "cd $T/x; M=\$(python3 -c \"import json;print(json.load(open('index.json'))['manifests'][0]['digest'].split(':')[1])\"); python3 -m json.tool blobs/sha256/\$M"
run 15-config "cd $T/x; M=\$(python3 -c \"import json;print(json.load(open('index.json'))['manifests'][0]['digest'].split(':')[1])\"); C=\$(python3 -c \"import json;print(json.load(open('blobs/sha256/\$M'))['config']['digest'].split(':')[1])\"); python3 -c \"import json;d=json.load(open('blobs/sha256/\$C'));print(json.dumps({k:d[k] for k in ['architecture','os','config','rootfs']},indent=2)); print(json.dumps(d['history'],indent=2))\""
run 16-layer "cd $T/x; M=\$(python3 -c \"import json;print(json.load(open('index.json'))['manifests'][0]['digest'].split(':')[1])\"); L=\$(python3 -c \"import json;print(json.load(open('blobs/sha256/\$M'))['layers'][0]['digest'].split(':')[1])\"); file blobs/sha256/\$L; tar -tzf blobs/sha256/\$L | wc -l; tar -tzf blobs/sha256/\$L | head -12; sha256sum blobs/sha256/\$L"
run 17-registre "docker run -d --name registre -p 5001:5000 registry:3 && sleep 2 && docker ps --filter name=registre --format '{{.Names}} {{.Image}} {{.Ports}}'"
run 18-tag-push "docker tag alpine:3.24 localhost:5001/cours/alpine:3.24 && docker push localhost:5001/cours/alpine:3.24"
run 19-push-nginx "docker tag nginx:1.30-alpine localhost:5001/cours/nginx:1.30-alpine && docker push localhost:5001/cours/nginx:1.30-alpine"
run 20-api "curl -s http://localhost:5001/v2/_catalog; echo; curl -s http://localhost:5001/v2/cours/nginx/tags/list; echo; curl -s -H 'Accept: application/vnd.oci.image.manifest.v1+json' -H 'Accept: application/vnd.docker.distribution.manifest.v2+json' http://localhost:5001/v2/cours/nginx/manifests/1.30-alpine | python3 -m json.tool | head -30"
run 21-df "docker system df"
run 22-rmi "docker image rm localhost:5001/cours/alpine:3.24 localhost:5001/cours/nginx:1.30-alpine"
run 23-pull-local "docker pull localhost:5001/cours/nginx:1.30-alpine"
run 24-menage "docker image rm localhost:5001/cours/nginx:1.30-alpine; docker rm -f registre"
