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
cat images |sed 's|\(.*\)|&=\1|g' |sed "s|=.*/\([^/]*\)/\(.*\)@.*|=$REG/\1/\2|g" > mirror-list
rm images
echo -e "\n********** 2. Make imageContentSourcePolicy.yaml **********"
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

echo -e "\n********** 3. Pull image to local dir \"image-cache\"**********"
mkdir image-cache
index=0
count=$(cat mirror-list | wc -l)
while read line; do
    let index+=1
    src=$(echo $line | cut -d= -f1)
    dest=$(echo $line | cut -d/ -f3 |cut -d= -f1)
    echo "($index/$count)Pulling $src"
    skopeo copy --authfile=$AUTH --all docker://$src dir:image-cache/$dest
done < mirror-list

echo '
index=0
count=$(cat mirror-list | wc -l)
read -p "Path of the authentication file: " AUTH
for i in $(ls image-cache); do
 let index+=1
 dest=$(grep $i mirror-list | cut -d= -f2)
 echo "($index/$count)Pushing $dest"
 skopeo copy --authfile=$AUTH --all dir:image-cache/$i docker://$dest
done' > push.sh
chmod +x push.sh

echo -e "\n********** It's time to push images to private registry. **********"
echo -e "There will be two steps:\n1. push local images to private.\n2. create imageContentSourcePolicy(icsp) to openshift cluster.\n"
read -p "Do you want to do it right now?(y/n): " answer
if [ "$answer" = "y" ]; then 
    step1="./push.sh"
    step2="oc create -f imageContentSourcePolicy.yaml"
    echo "1. $step1"
    eval $step1
    read -p "2. $step2, all hosts will restart! Continue(y/n): " icsp
    if [ "$icsp" = "y" ]; then
       eval $step2
       echo "All done, Enjoy!"
    else
       echo "All right,Please do it manually. Enjoy!"
    fi  
else
    echo -e "\nAll right,You can do it when you need it.\nProcedure:"
    echo -e "1. Copy dir $DIR to your bastion machine. "
    echo -e "2. Change  the current directory to $DIR,\033[31m\"cd $DIR\"\033[0m"
    echo -e "2. Run script file,\033[31m\"sh push.sh\"\033[0m"
    echo -e "3. Create icsp,\033[31m\"oc create -f imageContentSourcePolicy.yaml\"\033[0m"
    echo -e "4. Enjoy!"
fi
