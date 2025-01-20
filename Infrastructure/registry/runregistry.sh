mkdir -p ./certs/registry

openssl req -new -nodes -out ./certs/registry/registry.tehlab.org.csr -keyout ./certs/registry/registry.tehlab.org.key -config san.cnf

openssl x509 -req -in ./certs/registry/registry.tehlab.org.csr -CA /home/inno/.minikube/ca.crt -CAkey /home/inno/.minikube/ca.key -CAcreateserial -out  ./certs/registry/registry.tehlab.org.crt -days 365 -sha256 -extensions req_ext -extfile san.cnf

docker run -d \
  --name registry \
  -p 5000:5000 \
  -v ./certs/registry:/certs \
  -e REGISTRY_HTTP_ADDR=0.0.0.0:5000 \
  -e REGISTRY_HTTP_TLS_CERTIFICATE=/certs/registry.tehlab.org.crt \
  -e REGISTRY_HTTP_TLS_KEY=/certs/registry.tehlab.org.key \
  registry:2
