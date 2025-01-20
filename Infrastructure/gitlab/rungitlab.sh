mkdir -p ./certs/gitlab

openssl req -new -nodes -out ./certs/gitlab/mygitlab.tehlab.org.csr -keyout ./certs/gitlab/mygitlab.tehlab.org.key -config san.cnf

openssl x509 -req -in ./certs/gitlab/mygitlab.tehlab.org.csr -CA /home/inno/.minikube/ca.crt -CAkey /home/inno/.minikube/ca.key -CAcreateserial -out  ./certs/gitlab/mygitlab.tehlab.org.crt -days 365 -sha256 -extensions req_ext -extfile san.cnf

docker run -d \
  --hostname mygitlab.tehlab.org \
  --name gitlab-ce \
  -p 8080:80 \
  -p 9443:9443 \
  -p 2222:22 \
  -v ./certs/gitlab:/etc/gitlab/ssl \
  -e GITLAB_OMNIBUS_CONFIG="external_url 'https://mygitlab.tehlab.org:9443'; gitlab_rails['gitlab_shell_ssh_port'] = 2222;" \
  gitlab/gitlab-ce:latest
