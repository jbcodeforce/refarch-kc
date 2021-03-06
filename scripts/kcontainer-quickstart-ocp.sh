#!/bin/bash

##################
### PARAMETERS ###
##################

# Username and Password for an OpenShift user with cluster-admin privileges.
# cluster-admin privileges are required as this script deploys operators to
# watch all namespaces.
OCP_ADMIN_USER=${OCP_ADMIN_USER:=admin}
OCP_ADMIN_PASSWORD=${OCP_ADMIN_PASSWORD:=admin}

# Strimzi operator version stability appears to be not so stable, so this will
# specify the latest verified operator version instead of just the "stable"
# stream.
STRIMZI_OPERATOR_VERSION="strimzi-0.20.x"

###################################
### DO NOT EDIT BELOW THIS LINE ###
###################################
### EDIT AT YOUR OWN RISK      ####
###################################

#################################################
### UTILITY FUNCTION FOR Open Liberty LOGGING ###
### Usage: oc logs <pod_name> | ol_logs
#################################################
alias ol_logs="jq '.ibm_datetime + \" \" + .loglevel + \"\\t\" + \" \" + .message' -r"

function install_operator() {
### function will create an operator subscription to the openshift-operators
###          namespace for CR use in all namespaces
### parameters:
### $1 - operator name
### $2 - operator channel
### $3 - operator catalog source
cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: ${1}
  namespace: openshift-operators
spec:
  channel: ${2}
  name: ${1}
  source: $3
  sourceNamespace: openshift-marketplace
EOF
}


############
### MAIN ###
############

oc login -u ${OCP_ADMIN_USER} -p ${OCP_ADMIN_PASSWORD}

##TODO## Add error check to validate login

git clone https://github.com/ibm-cloud-architecture/refarch-kc-gitops.git

cd refarch-kc-gitops/environments

### INSTALL Strimzi OPERATOR
### More info available via `oc describe packagemanifests strimzi-kafka-operator -n openshift-marketplace`
install_operator "strimzi-kafka-operator" "${STRIMZI_OPERATOR_VERSION}" "community-operators"

### INSTALL Appsody OPERATOR
### More info available via `oc describe packagemanifests appsody-operator-certified -n openshift-marketplace`
install_operator "appsody-operator-certified" "beta" "certified-operators"

### INSTALL OpenLiberty OPERATOR
### More info available via `oc describe packagemanifests open-liberty-certified -n openshift-marketplace`
install_operator "open-liberty-certified" "beta" "certified-operators"

###TODO### Alternate implementation for `oc wait --for=condition=AtLatestKnown subscription/__operator_subscription__ --timeout 300s`
for operator in strimzi-kafka-operator appsody-operator-certified open-liberty-certified
do
  counter=0
  desired_state="AtLatestKnown"
  until [[ ("$(oc get -o json -n openshift-operators subscription ${operator} | jq -r .status.state)" == "${desired_state}") || ( ${counter} == 60 ) ]]
  do
    echo Waiting for ${operator} operator to be deployed...
    ((counter++))
    sleep 5
  done
done

### CREATE PROJECT & KAFKA INFRASTRUCTURE
oc apply -k dev/infrastructure/

oc project shipping

oc adm policy add-scc-to-user anyuid -z kcontainer-runtime -n shipping

echo Waiting for Kafka cluster to be available...
oc wait --for=condition=ready kafka my-cluster --timeout 300s -n shipping

### DEPLOY APPLICATION MICROSERVICES
oc apply -k dev/

### WAIT FOR MICROSERVICE DEPLOYMENTS TO BECOME AVAILABLE
echo Waiting for application microservices to be available...
sleep 10
oc wait --for=condition=available deploy -l app.kubernetes.io/part-of=refarch-kc --timeout 300s -n shipping

### GET ROUTE FOR USER INTERFACE MICROSERVICE
echo "User Interface Microservice is available via http://$(oc get route kc-ui -o jsonpath='{.status.ingress[0].host}')"

### MANUAL STEP ### Send order event via browser
echo Login to the browser UI with \"eddie@email.com\" / \"Eddie\" and submit an order via the \"Initiate Orders\" tab
read -rsp $'Press any key to continue once an order has been submitted...\n' -n1 key

### Track kafka record via kafka-console-consumer and `oc rsh`
echo "Checking ORDER-COMMANDS topic for Kafka records produced by the order-command microservice..."
oc rsh my-cluster-kafka-0 bin/kafka-console-consumer.sh --bootstrap-server localhost:9092 --from-beginning --timeout-ms 10000 --topic order-commands

echo "Checking ORDERS topic for Kafka records produced by the order-command microservice..."
oc rsh my-cluster-kafka-0 bin/kafka-console-consumer.sh --bootstrap-server localhost:9092 --from-beginning --timeout-ms 10000 --topic orders
