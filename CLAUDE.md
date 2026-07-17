We are using k3s on server using sst "travel-dev" it has config in ssh export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
and we have config in our local /Users/ahmed3mar/Sites/clients/mine/marbit/devops/configs/travel-dev.yaml it's same config


this k3s has nodes works only for about 5 -> 6h and killed and another nodes joinned nodes run and join from ./linux-ser.sh

our goal is to make app zero downtime

configurations are in ./configs