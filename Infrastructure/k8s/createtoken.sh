TOKEN=$(kubectl create token gitlab-runner-sa -n dotnet-app)
echo $TOKEN