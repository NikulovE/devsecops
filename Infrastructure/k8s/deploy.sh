kubectl apply -f 1-namespace.yaml
kubectl apply -f 4-postgres-init-sql-configmap.yaml
kubectl apply -f 2-postgres-deployment.yaml
kubectl apply -f 3-postgres-service.yaml
kubectl apply -f 5-dotnet-deployment.yaml
kubectl apply -f 6-dotnet-service.yaml
kubectl apply -f 7-dotnet-ingress.yaml