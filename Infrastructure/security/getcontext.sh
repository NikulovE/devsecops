kubectl config view --raw > .kubeconfig
export KUBECONFIG=.kubeconfig
kubectl get nodes --context=minikube