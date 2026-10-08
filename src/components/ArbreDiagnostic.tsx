import React, {useState, type ReactNode} from 'react';
import styles from './ArbreDiagnostic.module.css';

// « Par où commencer ? » (chapitre 49). Un arbre de diagnostic : on part de ce qu'affiche
// kubectl get pods, on répond à une ou deux questions, et l'arbre propose une cause probable,
// la commande qui la confirme et la correction. Les messages sont ceux mesurés dans rejeu-ch49.sh.

type Choix = {libelle: string; suite: string};
type Question = {type: 'question'; texte: string; aide?: string; choix: Choix[]};
type Feuille = {
  type: 'feuille';
  cause: string;
  confirmer: string[];
  corriger: string;
  ancre?: string; // section du chapitre 49
  ailleurs?: string; // ou chapitre qui traite le cas
};
type Noeud = Question | Feuille;

const ARBRE: Record<string, Noeud> = {
  racine: {type: 'question', texte: 'Que montre kubectl get pods pour ce Pod ?',
    aide: 'Colonnes READY, STATUS et RESTARTS.',
    choix: [
      {libelle: 'Pending', suite: 'pending'},
      {libelle: 'ContainerCreating, depuis plus d’une minute', suite: 'creating'},
      {libelle: 'ErrImagePull ou ImagePullBackOff', suite: 'image'},
      {libelle: 'CreateContainerConfigError', suite: 'config'},
      {libelle: 'CrashLoopBackOff, Error, Completed ou OOMKilled', suite: 'arret'},
      {libelle: 'Running, mais READY à 0/1', suite: 'pret'},
      {libelle: 'Running 1/1, mais RESTARTS augmente', suite: 'arret'},
      {libelle: 'Running 1/1, RESTARTS stable, mais l’application échoue', suite: 'appli'},
      {libelle: 'Terminating, depuis longtemps', suite: 'terminaison'},
    ]},

  pending: {type: 'question', texte: 'Que dit l’événement FailedScheduling ?',
    aide: 'kubectl events --for pod/<nom>',
    choix: [
      {libelle: 'Insufficient cpu, Insufficient memory', suite: 'f-ressources'},
      {libelle: 'didn’t match Pod’s node affinity/selector', suite: 'f-selecteur'},
      {libelle: 'had untolerated taint', suite: 'f-teinte'},
      {libelle: 'pod has unbound immediate PersistentVolumeClaims', suite: 'f-volume'},
      {libelle: 'aucun événement', suite: 'f-ordonnanceur'},
    ]},
  'f-ressources': {type: 'feuille', ancre: '1-des-requests-trop-grosses',
    cause: 'Aucun nœud n’a assez de ressources allouables pour les requests du Pod. Le scheduler compte les requests, pas la consommation réelle.',
    confirmer: ['kubectl describe node | grep -A8 "Allocated resources"', 'kubectl get pod <nom> -o jsonpath=\'{.spec.containers[*].resources}\''],
    corriger: 'Ramener les requests à une valeur mesurée (kubectl top, VPA en mode Off), libérer de la place, ou ajouter un nœud.'},
  'f-selecteur': {type: 'feuille', ancre: '2-un-nœud-qui-nexiste-pas',
    cause: 'Le nodeSelector ou l’affinité du Pod ne correspond à aucun nœud : étiquette absente ou mal orthographiée.',
    confirmer: ['kubectl get nodes --show-labels', 'kubectl get pod <nom> -o jsonpath=\'{.spec.nodeSelector}\''],
    corriger: 'Corriger le sélecteur dans le modèle du Pod, ou étiqueter le nœud voulu. Le scheduler réessaie seul.'},
  'f-teinte': {type: 'feuille', ailleurs: 'chapitre 32',
    cause: 'Les nœuds candidats portent une teinte (taint) que le Pod ne tolère pas.',
    confirmer: ['kubectl get nodes -o custom-columns=NOM:.metadata.name,TEINTES:.spec.taints'],
    corriger: 'Ajouter la tolérance au Pod si ce placement est voulu, sinon retirer la teinte (kubectl taint node <n> <clé>-).'},
  'f-volume': {type: 'feuille', ancre: '3-un-volume-qui-ne-vient-pas',
    cause: 'La PersistentVolumeClaim n’est pas liée : classe de stockage inexistante, aucun PersistentVolume compatible, ou provisionneur en panne.',
    confirmer: ['kubectl get pvc', 'kubectl events --for pvc/<nom>', 'kubectl get storageclass'],
    corriger: 'La classe d’une PVC ne se change pas : supprimer la PVC et la recréer avec une classe existante.'},
  'f-ordonnanceur': {type: 'feuille', ailleurs: 'chapitre 37',
    cause: 'Aucun scheduler ne s’occupe du Pod : schedulerName désigne un ordonnanceur absent, ou kube-scheduler est arrêté.',
    confirmer: ['kubectl get pod <nom> -o jsonpath=\'{.spec.schedulerName}\'', 'kubectl -n kube-system get pods -l component=kube-scheduler'],
    corriger: 'Corriger schedulerName, ou remettre l’ordonnanceur en marche.'},

  creating: {type: 'question', texte: 'Quel avertissement dans les événements du Pod ?',
    aide: 'kubectl events --for pod/<nom> --types=Warning',
    choix: [
      {libelle: 'FailedMount : configmap ou secret « not found »', suite: 'f-configmap'},
      {libelle: 'FailedCreatePodSandBox', suite: 'f-bac'},
      {libelle: 'aucun avertissement, Pulling image depuis longtemps', suite: 'f-lent'},
    ]},
  'f-configmap': {type: 'feuille', ancre: '7-une-configmap-absente',
    cause: 'Un volume vient d’une ConfigMap ou d’un Secret qui n’existe pas. Le kubelet ne lance pas le conteneur tant que le montage échoue.',
    confirmer: ['kubectl get configmap,secret', 'kubectl get pod <nom> -o jsonpath=\'{.spec.volumes}\''],
    corriger: 'Créer l’objet manquant (le kubelet réessaie seul), ou corriger son nom. optional: true accepte l’absence.'},
  'f-bac': {type: 'feuille', ailleurs: 'chapitres 38 et 39',
    cause: 'Le runtime n’a pas pu créer le bac à sable du Pod, le plus souvent faute de réseau : le plugin CNI ne répond pas ou n’a plus d’adresses.',
    confirmer: ['kubectl -n kube-system get pods -o wide (DaemonSet réseau)', 'journalctl -u kubelet sur le nœud'],
    corriger: 'Réparer le plugin réseau du nœud, puis supprimer le Pod pour qu’il soit recréé.'},
  'f-lent': {type: 'feuille', ailleurs: 'chapitre 13',
    cause: 'L’image est grosse ou le registre est lent : le kubelet est toujours en train de la tirer.',
    confirmer: ['kubectl events --for pod/<nom>', 'crictl images sur le nœud'],
    corriger: 'Attendre, puis réduire l’image (multi-étapes, base minimale) ou la pré-charger sur les nœuds.'},

  image: {type: 'question', texte: 'Que dit le message de l’événement Failed ?',
    aide: 'kubectl events --for pod/<nom> : la ligne « Failed to pull image ».',
    choix: [
      {libelle: 'not found, manifest unknown', suite: 'f-etiquette'},
      {libelle: 'connection refused, no such host, i/o timeout', suite: 'f-registre'},
      {libelle: '401 Unauthorized, 403 Forbidden', suite: 'f-auth'},
    ]},
  'f-etiquette': {type: 'feuille', ancre: '4-une-étiquette-qui-nexiste-pas',
    cause: 'Le registre répond, mais ce nom ou cette étiquette n’existent pas.',
    confirmer: ['curl http://<registre>/v2/<dépôt>/tags/list', 'crane ls <dépôt> ou skopeo list-tags'],
    corriger: 'Corriger l’étiquette. Le champ image d’un Pod est modifiable : kubectl set image suffit, même sur un Pod seul.'},
  'f-registre': {type: 'feuille', ancre: '5-un-registre-injoignable',
    cause: 'Le nœud ne joint pas le registre : nom, port, DNS, pare-feu ou proxy.',
    confirmer: ['le message exact de l’événement (dial tcp, lookup)', 'depuis le nœud : curl -v http://<registre>/v2/'],
    corriger: 'Corriger l’adresse du registre, ou la configuration réseau et le proxy du nœud.'},
  'f-auth': {type: 'feuille', ailleurs: 'chapitre 21',
    cause: 'Le registre exige une authentification que le Pod ne fournit pas.',
    confirmer: ['kubectl get pod <nom> -o jsonpath=\'{.spec.imagePullSecrets}\'', 'kubectl get secret <secret> -o jsonpath=\'{.type}\''],
    corriger: 'Créer un Secret de type kubernetes.io/dockerconfigjson et le référencer dans imagePullSecrets, ou sur le ServiceAccount.'},

  config: {type: 'question', texte: 'Que dit le message d’état du conteneur ?',
    aide: 'kubectl get pod <nom> -o jsonpath=\'{.status.containerStatuses[0].state.waiting.message}\'',
    choix: [
      {libelle: 'couldn’t find key … in Secret ou ConfigMap', suite: 'f-cle'},
      {libelle: 'secret … not found, configmap … not found', suite: 'f-cle'},
      {libelle: 'container has runAsNonRoot and image will run as root', suite: 'f-racine'},
    ]},
  'f-cle': {type: 'feuille', ancre: '6-une-clé-absente',
    cause: 'Une variable d’environnement vient d’un Secret ou d’une ConfigMap absents, ou d’une clé qui n’y figure pas.',
    confirmer: ['kubectl get secret <nom> -o jsonpath=\'{.data}\' | jq keys'],
    corriger: 'Ajouter la clé ou l’objet : le kubelet réessaie seul. Ou corriger la référence dans le modèle du Pod.'},
  'f-racine': {type: 'feuille', ailleurs: 'chapitre 44',
    cause: 'Le Pod exige runAsNonRoot, mais l’image ne déclare pas d’utilisateur non root (ou un nom au lieu d’un numéro).',
    confirmer: ['docker image inspect <image> --format \'{{.Config.User}}\''],
    corriger: 'Fixer runAsUser à un UID non nul, ou ajouter USER <uid> au Dockerfile.'},

  arret: {type: 'question', texte: 'Quelle raison et quel code pour le dernier arrêt ?',
    aide: 'kubectl get pod <nom> -o jsonpath=\'{.status.containerStatuses[0].lastState.terminated}\'',
    choix: [
      {libelle: 'OOMKilled, 137', suite: 'f-memoire'},
      {libelle: 'Completed, 0', suite: 'f-tache'},
      {libelle: 'Error, 137 ou 143, et « Liveness probe failed » dans les événements', suite: 'f-vie'},
      {libelle: 'Error, 1 ou un autre petit code', suite: 'f-appli'},
      {libelle: 'StartError, 128', suite: 'f-binaire'},
    ]},
  'f-memoire': {type: 'feuille', ancre: '8-la-limite-de-mémoire',
    cause: 'Le noyau a tué le processus : il dépassait la limite de mémoire de son conteneur.',
    confirmer: ['kubectl top pod', 'dmesg | grep "Memory cgroup out of memory" sur le nœud'],
    corriger: 'Mesurer le besoin réel, puis relever la limite (kubectl set resources) ou réduire la consommation.'},
  'f-tache': {type: 'feuille', ancre: '9-un-programme-qui-se-termine',
    cause: 'Le programme se termine normalement, mais un Deployment relance toujours ses conteneurs.',
    confirmer: ['kubectl logs <nom>', 'kubectl get pod <nom> -o jsonpath=\'{.spec.restartPolicy}\''],
    corriger: 'Un traitement qui finit relève d’un Job ou d’un CronJob, pas d’un Deployment.'},
  'f-vie': {type: 'feuille', ancre: '10-une-sonde-de-vie-impatiente',
    cause: 'La sonde de vie tue un conteneur qui n’a pas fini de démarrer, ou qui répond trop lentement.',
    confirmer: ['kubectl events --for pod/<nom> | grep -E "Unhealthy|Killing"', 'kubectl get pod <nom> -o jsonpath=\'{.spec.containers[0].livenessProbe}\''],
    corriger: 'Ajouter une sonde de démarrage qui couvre le temps de démarrage, et une sonde de vie qui ne teste que le processus.'},
  'f-appli': {type: 'feuille', ailleurs: 'chapitre 48',
    cause: 'Le programme a décidé de s’arrêter : configuration, dépendance, bogue.',
    confirmer: ['kubectl logs <nom> (et --previous si le conteneur tourne de nouveau)'],
    corriger: 'Lire la fin du journal ; si le conteneur meurt trop vite pour être examiné, kubectl debug --copy-to.'},
  'f-binaire': {type: 'feuille', ailleurs: 'chapitre 48, exercice 2',
    cause: 'Le runtime n’a pas pu lancer la commande : binaire absent de l’image, mauvais chemin, montage impossible.',
    confirmer: ['kubectl get pod <nom> -o jsonpath=\'{.status.containerStatuses[0].lastState.terminated.message}\''],
    corriger: 'Corriger command ou l’image.'},

  pret: {type: 'question', texte: 'Que disent les événements Unhealthy ?',
    aide: 'kubectl events --for pod/<nom> | grep Readiness',
    choix: [
      {libelle: 'HTTP probe failed with statuscode: 404', suite: 'f-chemin'},
      {libelle: 'HTTP probe failed with statuscode: 503', suite: 'f-dependance'},
      {libelle: 'connect: connection refused, durablement', suite: 'f-port'},
    ]},
  'f-chemin': {type: 'feuille', ancre: '11-une-sonde-de-disponibilité-fausse',
    cause: 'La sonde de disponibilité interroge un chemin que l’application ne connaît pas.',
    confirmer: ['kubectl exec <nom> -- wget -qO- http://localhost:<port>/<chemin>'],
    corriger: 'Corriger le chemin de la sonde dans le modèle du Pod.'},
  'f-dependance': {type: 'feuille', ailleurs: 'chapitres 22 et 48',
    cause: 'L’application répond qu’elle n’est pas prête : une de ses dépendances (base, file) ne répond pas.',
    confirmer: ['curl la sonde à la main et lire le corps de la réponse', 'kubectl logs <nom>'],
    corriger: 'Réparer la dépendance. Le Pod redevient prêt seul.'},
  'f-port': {type: 'feuille', ailleurs: 'chapitre 48',
    cause: 'Rien n’écoute sur le port de la sonde : mauvais port, ou application qui écoute sur 127.0.0.1 seulement.',
    confirmer: ['kubectl debug -it <nom> --image=nicolaka/netshoot --target=<conteneur> -- ss -ltnp'],
    corriger: 'Aligner le port de la sonde, le containerPort et le port d’écoute réel (0.0.0.0).'},

  appli: {type: 'question', texte: 'Que dit l’application dans son journal ?',
    choix: [
      {libelle: 'nom introuvable, Try again, timeout DNS', suite: 'f-dns'},
      {libelle: 'connection refused vers un Service', suite: 'f-service'},
      {libelle: 'timeout vers un Pod ou un Service', suite: 'f-politique'},
    ]},
  'f-dns': {type: 'feuille', ancre: '12-le-dns-coupé',
    cause: 'La résolution DNS échoue : nom faux, ou NetworkPolicy qui bloque la sortie vers kube-dns.',
    confirmer: ['kubectl debug -it <nom> --image=busybox -- nslookup <service>', 'kubectl get networkpolicy'],
    corriger: 'Corriger le nom, ou autoriser la sortie vers kube-system/kube-dns sur le port 53 (UDP et TCP).'},
  'f-service': {type: 'feuille', ailleurs: 'chapitre 48',
    cause: 'Le Service n’a aucun point d’accès prêt : sélecteur faux, ou Pods pas prêts.',
    confirmer: ['kubectl get endpointslices -l kubernetes.io/service-name=<service>'],
    corriger: 'Corriger le sélecteur, ou rendre les Pods prêts.'},
  'f-politique': {type: 'feuille', ailleurs: 'chapitre 41',
    cause: 'Une NetworkPolicy laisse tomber les paquets : pas de refus, une attente qui expire.',
    confirmer: ['kubectl get networkpolicy -A', 'kubectl describe networkpolicy <nom>'],
    corriger: 'Ajouter la règle d’entrée ou de sortie qui manque, des deux côtés si besoin.'},

  terminaison: {type: 'question', texte: 'Que montre l’objet ?',
    aide: 'kubectl get <type> <nom> -o jsonpath=\'{.metadata.finalizers} {.spec.nodeName}\'',
    choix: [
      {libelle: 'finalizers n’est pas vide', suite: 'f-finaliseur'},
      {libelle: 'le Pod est sur un nœud NotReady', suite: 'f-noeud'},
    ]},
  'f-finaliseur': {type: 'feuille', ancre: 'lobjet-ne-disparaît-pas',
    cause: 'Un finaliseur attend qu’un contrôleur fasse son nettoyage, et ce contrôleur ne le fait pas (absent, en panne, désinstallé).',
    confirmer: ['kubectl get <type> <nom> -o jsonpath=\'{.metadata.finalizers}\''],
    corriger: 'Réparer le contrôleur. En dernier recours, retirer le finaliseur à la main, en acceptant que son nettoyage n’ait pas lieu.'},
  'f-noeud': {type: 'feuille', ailleurs: 'chapitre 33',
    cause: 'Le kubelet du nœud ne répond plus, et personne ne peut confirmer l’arrêt des conteneurs.',
    confirmer: ['kubectl get nodes', 'kubectl describe node <nœud>'],
    corriger: 'Réparer ou retirer le nœud. kubectl delete pod --force seulement si l’on est sûr qu’il ne tourne plus.'},
};

export default function ArbreDiagnostic(): ReactNode {
  const [chemin, setChemin] = useState<{noeud: string; reponse: string}[]>([]);
  const courant = chemin.length ? ARBRE[chemin[chemin.length - 1].noeud] : ARBRE.racine;
  const historique = chemin.map((c, i) => ({
    question: (i === 0 ? ARBRE.racine : ARBRE[chemin[i - 1].noeud]) as Question,
    reponse: c.reponse,
  }));

  return (
    <div className={styles.cadre}>
      <div className={styles.titre}>Par où commencer ?</div>
      {historique.length > 0 && (
        <ol className={styles.historique}>
          {historique.map((h, i) => (
            <li key={i}>
              <span className={styles.q}>{h.question.texte}</span>{' '}
              <button type="button" className={styles.reponse} onClick={() => setChemin(chemin.slice(0, i))}
                title="Revenir à cette question">{h.reponse}</button>
            </li>
          ))}
        </ol>
      )}
      {courant.type === 'question' ? (
        <div>
          <div className={styles.question}>{courant.texte}</div>
          {courant.aide && <div className={styles.aide}><code>{courant.aide}</code></div>}
          <div className={styles.choix}>
            {courant.choix.map((c) => (
              <button type="button" key={c.libelle} className={styles.bouton}
                onClick={() => setChemin([...chemin, {noeud: c.suite, reponse: c.libelle}])}>
                {c.libelle}
              </button>
            ))}
          </div>
        </div>
      ) : (
        <div className={styles.feuille}>
          <p><strong>Cause probable.</strong> {courant.cause}</p>
          <p className={styles.etiquette}>Pour confirmer</p>
          <ul className={styles.commandes}>
            {courant.confirmer.map((c) => <li key={c}><code>{c}</code></li>)}
          </ul>
          <p><strong>Correction.</strong> {courant.corriger}</p>
          <p className={styles.renvoi}>
            {courant.ancre
              ? <a href={`#${courant.ancre}`}>Voir cette panne dans le chapitre</a>
              : <>Traité au {courant.ailleurs}.</>}
          </p>
        </div>
      )}
      {chemin.length > 0 && (
        <div className={styles.actions}>
          <button type="button" className={styles.lien} onClick={() => setChemin(chemin.slice(0, -1))}>Revenir d’un pas</button>
          <button type="button" className={styles.lien} onClick={() => setChemin([])}>Recommencer</button>
        </div>
      )}
    </div>
  );
}
