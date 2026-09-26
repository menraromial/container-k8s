# À charger avec « source acces.sh » : l'adresse de l'API server et les fichiers
# d'identité que minikube a écrits pour kubectl (profil minikube par défaut).
PROFIL=${1:-minikube}
API=$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')
M=~/.minikube
ID=(--cacert $M/ca.crt --cert $M/profiles/$PROFIL/client.crt --key $M/profiles/$PROFIL/client.key)
echo "API server : $API"
