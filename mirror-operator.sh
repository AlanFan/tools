#!/bin/bash
#########################################################
# Function :Mirror operator image                       #
# Platform :All Linux Based Platform                    #
# Version  :1.0                                         #
# Date     :2020-10-28                                  #
# Author   :Fan PeiLun                                  #
# Contact  :pfan@redhat.com                             #
# Company  :Red Hat                                     #
#########################################################
set -e
echo "********** Check tools **********"
type oc
type jq
type skopeo 
type grpcurl
type podman

echo -e "\n********** Check openshift session **********"
echo "USER: $(oc whoami)"
echo " API: $(oc whoami --show-server)"

echo -e "\n********** Please select catalogsource **********"
OPTIONS=$(oc get catalogsource -n openshift-marketplace --sort-by=.metadata.name -o json | jq -r .items[].metadata.name)
select opt in $OPTIONS;do
 if [ "$opt" != "" ]; then
    CATALOGSOURCE=$opt
    break
 else
    echo "Bad option"
 fi
done


echo -e "\n********** Please select operator **********"
OPTIONS=$(eval "oc get packagemanifests --sort-by=.metadata.name -o go-template='{{range .items}}{{if eq .status.catalogSource \"$CATALOGSOURCE\" }}{{.metadata.name}}{{\"\\n\"}}{{end}}{{end}}'")
select opt in $OPTIONS;do
    if [ "$opt" != "" ]; then
      PACKAGE=$opt
    break
    else
      echo "Bad option"
    fi
done


echo -e "\n********** Please select \"$(oc get packagemanifests $PACKAGE -o json | jq -r .status.channels[0].currentCSVDesc.displayName)\" Channels **********"
OPTIONS=$(oc get packagemanifests $PACKAGE -o json | jq -r .status.channels[].name)
select opt in $OPTIONS;do
    if [ "$opt" != "" ]; then
      CHANNEL=$opt
    break
    else
      echo "Bad option"
    fi
done
echo -e "\n"

read -p "Please input private registry: " REG
read -p "Path of the authentication file: " AUTH

echo -e "\n********** OK,Let's do it! **********"
DIR="$PACKAGE-$( date '+%Y%m%d-%H-%M-%S')"
echo -e "\n********** 1. Make directory  $DIR **********"
mkdir $DIR 
cd $DIR
eval "oc get packagemanifests $PACKAGE -o go-template='{{range .status.channels}}{{if eq .name \"$CHANNEL\" }}{{range .currentCSVDesc.relatedImages}}{{.}}{{\"\\n\"}}{{end}}{{end}}{{end}}'" > images
echo -e "\n********** 2. Get bundle image **********"
#Get bundle image
podman pull --authfile $AUTH $(oc get catalogsource $CATALOGSOURCE -n openshift-marketplace -o json | jq -r .spec.image)
podman run -p50051:50051 --name=tmp -d --rm $(oc get catalogsource $CATALOGSOURCE  -n openshift-marketplace -o json | jq -r .spec.image) > /dev/null
sleep 3
eval "grpcurl -plaintext -d '{\"pkgName\":\"$PACKAGE\",\"channelName\":\"$CHANNEL\"}' localhost:50051 api.Registry/GetBundleForChannel | jq -r .bundlePath >> images"
podman stop tmp > /dev/null
cat images |sed 's|\(.*\)|&=\1|g' |sed "s|=.*/\([^/]*\)/\(.*\)@.*|=$REG/\1/\2|g" > mirror-list
echo -e "\n********** 3. Make imageContentSourcePolicy.yaml **********"
echo -e -n "apiVersion: operator.openshift.io/v1alpha1
kind: ImageContentSourcePolicy
metadata:
    name: $PACKAGE
spec:
    repositoryDigestMirrors:
" > imageContentSourcePolicy.yaml
while read line; do
    mirror=$(echo $line |cut -d= -f2)
    source=$(echo $line |cut -d@ -f1)
    echo "    - mirrors:"
    echo "      - $mirror"
    echo "      source: $source"
done < mirror-list >> imageContentSourcePolicy.yaml

echo -e "\n********** 4. Pull image **********"
select opt in {"cache image to local dir","mirror image to $REG immediately"};do
case "$REPLY" in
    1) PUSH=1 ; break;;
    2) PUSH=2 ; break;;
    *) echo "Bad option";
esac
done

mkdir cache
index=0
count=$(cat mirror-list | wc -l)
while read line; do
    let index+=1
    src=$(echo $line | cut -d= -f1)
    if [ "$PUSH" == "1" ]; then
      echo "($index/$count)Pulling $src"
      break
      skopeo copy --authfile=$AUTH --all docker://$src dir:cache/$(echo $line | cut -d/ -f3 |cut -d= -f1)
    else
      echo "($index/$count)Mirroring $src"
      skopeo copy --authfile=$AUTH --all docker://$src docker://$(grep $src mirror-list | cut -d= -f2)
    fi
done < mirror-list

echo '
index=0
count=$(cat mirror-list | wc -l)
read -p "Path of the authentication file: " AUTH
for i in $(ls cache); do
 let index+=1
 dest=$(grep $i mirror-list | cut -d= -f2)
 echo "($index/$count)Pushing $dest"
 skopeo copy --authfile=$AUTH --all dir:cache/$i docker://$dest
done' > push.sh
chmod +x push.sh

read -p "Do you want to create ImageContentSourcePolicy(icsp) to openshift cluster right now?(y/n): " answer
if [ "$answer" = "y" ]; then 
    oc apply -f imageContentSourcePolicy.yaml 
    echo "All done, Enjoy!"
else
    echo -e "\nAll right,You can do it when you need it.\nProcedure:"
    echo -e "1. Copy dir $DIR to your bastion machine. "
    echo -e "2. Change  the current directory to $DIR,\033[31m\"cd $DIR\"\033[0m"
    if [ "$PUSH" == "1" ]; then
    echo -e "3. Run script file,\033[31m\"sh push.sh\"\033[0m"
    echo -e "4. Create icsp,\033[31m\"oc apply -f imageContentSourcePolicy.yaml\"\033[0m"
    else
    echo -e "3. Create icsp,\033[31m\"oc apply -f imageContentSourcePolicy.yaml\"\033[0m"
    fi
    echo -e "Enjoy!"
fi
