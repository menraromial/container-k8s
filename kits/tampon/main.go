// tampon : un petit service HTTP qui renvoie un « tampon de la poste »,
// exemple du chapitre 13 (images de production).
package main

import (
	"encoding/json"
	"log"
	"net/http"
	"os"
	"runtime"
	"time"
)

// version est remplacée à la construction : go build -ldflags "-X main.version=1.0.0"
var version = "dev"

type tampon struct {
	Service string `json:"service"`
	Version string `json:"version"`
	Hote    string `json:"hote"`
	Arch    string `json:"arch"`
	Go      string `json:"go"`
	Heure   string `json:"heure"`
}

func racine(w http.ResponseWriter, r *http.Request) {
	paris, err := time.LoadLocation("Europe/Paris")
	if err != nil {
		http.Error(w, "fuseau horaire : "+err.Error(), http.StatusInternalServerError)
		return
	}
	hote, _ := os.Hostname()
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(tampon{
		Service: "tampon",
		Version: version,
		Hote:    hote,
		Arch:    runtime.GOARCH,
		Go:      runtime.Version(),
		Heure:   time.Now().In(paris).Format("2006-01-02 15:04:05 MST"),
	})
}

// distant vérifie qu'on sait joindre un site en HTTPS (certificats racine présents).
func distant(w http.ResponseWriter, r *http.Request) {
	client := http.Client{Timeout: 5 * time.Second}
	rep, err := client.Get("https://example.org/")
	if err != nil {
		http.Error(w, "HTTPS : "+err.Error(), http.StatusBadGateway)
		return
	}
	rep.Body.Close()
	w.Write([]byte("HTTPS : " + rep.Status + "\n"))
}

func main() {
	http.HandleFunc("/", racine)
	http.HandleFunc("/distant", distant)
	http.HandleFunc("/sante", func(w http.ResponseWriter, r *http.Request) { w.Write([]byte("ok\n")) })
	log.Printf("tampon %s à l'écoute sur :8080", version)
	log.Fatal(http.ListenAndServe(":8080", nil))
}
