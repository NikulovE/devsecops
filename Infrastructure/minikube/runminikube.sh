minikube start --driver=docker --apiserver-names="minikube.tehlab.org" --apiserver-ips="0.0.0.0,172.17.0.2,10.70.23.38" --apiserver-port=8443 --ports="8443:8443" --cpus 4 --memory 8192
minikube addons enable ingress