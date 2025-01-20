mkdir -p ./srv/gitlab-runner/config
docker volume create gitlab-runner-config
mkdir -p ./srv/gitlab-runner/config/certs
cp /home/inno/.minikube/ca.crt ./srv/gitlab-runner/config/certs/
docker run -d --name gitlab-runner --restart always \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v ./srv/gitlab-runner/config:/etc/gitlab-runner \
  gitlab/gitlab-runner:alpine-v17.5.5
